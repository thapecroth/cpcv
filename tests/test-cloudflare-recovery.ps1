# Network-free regression tests for Cloudflare Access recovery. Every cache,
# credential, process and discovery value below is synthetic and lives in TEMP.
# Run with Windows PowerShell 5.1: powershell.exe -NoProfile -File <this file>.
$ErrorActionPreference = 'Stop'

function Assert-Cpcv([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$testRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('cpcv-cf-{0}' -f [Guid]::NewGuid().ToString('N').Substring(0, 12))))
$tempBoundary = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
Assert-Cpcv ($testRoot.StartsWith($tempBoundary, [StringComparison]::OrdinalIgnoreCase)) 'Test directory is outside TEMP.'
[void][IO.Directory]::CreateDirectory($testRoot)

$priorEnvironment = @{}
foreach ($name in @('LOCALAPPDATA', 'USERPROFILE', 'HOME', 'CPCV_CONFIG')) {
    $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$junctionPaths = [System.Collections.Generic.List[string]]::new()
try {
    $env:LOCALAPPDATA = Join-Path $testRoot 'appdata'
    $env:USERPROFILE = Join-Path $testRoot 'profile'
    $env:HOME = $env:USERPROFILE
    $env:CPCV_CONFIG = Join-Path $testRoot 'config.psd1'
    [IO.File]::WriteAllText($env:CPCV_CONFIG, "@{ HostAlias = 'synthetic-test-host' }", [Text.UTF8Encoding]::new($false))

    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repositoryRoot 'cpcv-core.ps1')
    $script:testCloudflareMutexSuffix = [Guid]::NewGuid().ToString('N')
    function Get-CpcvMutexName { param([string]$Purpose) return "Local\CpcvCloudflareTest-$Purpose-$script:testCloudflareMutexSuffix" }
    . (Join-Path $repositoryRoot 'cpcv-cloudflare-recovery.ps1')

    $proxyWithAlias = ConvertFrom-CpcvCloudflareProxyCommand -ProxyCommand 'cloudflared access ssh --hostname %h' -ResolvedHostname 'images.example.test'
    Assert-Cpcv ($proxyWithAlias -and $proxyWithAlias.Hostname -eq 'images.example.test') 'An ordinary Cloudflare SSH ProxyCommand was not recognized.'
    $proxyWithSpaces = ConvertFrom-CpcvCloudflareProxyCommand -ProxyCommand '"C:\Program Files\Cloudflare\cloudflared.exe" access tcp --hostname=images.example.test' -ResolvedHostname 'ignored.example.test'
    Assert-Cpcv ($proxyWithSpaces -and $proxyWithSpaces.Executable -eq 'C:\Program Files\Cloudflare\cloudflared.exe') 'A quoted executable with spaces was not parsed safely.'
    foreach ($unsupportedProxy in @(
        'cmd /c cloudflared access ssh --hostname images.example.test',
        'powershell -Command "cloudflared access ssh --hostname images.example.test"',
        'cloudflared access ssh --hostname images.example.test & echo unexpected',
        'cloudflared access ssh --hostname images.example.test --token secret',
        'cloudflared access ssh --hostname images.example.test --logfile other-file',
        'cloudflared.exe.bak access ssh --hostname images.example.test',
        'C:\other\lookalike.exe access ssh --hostname images.example.test',
        'cloudflared access ssh --hostname https://images.example.test/path',
        'cloudflared access ssh --hostname ..\outside',
        'cloudflared access ssh --hostname images.example.test;echo unexpected'
    )) {
        $invalidProxy = ConvertFrom-CpcvCloudflareProxyCommand -ProxyCommand $unsupportedProxy -ResolvedHostname 'images.example.test'
        Assert-Cpcv ($null -eq $invalidProxy) ('Unsupported or ambiguous ProxyCommand was accepted: ' + $unsupportedProxy)
    }

    # Adapters are replaced before any recovery invocation. Unexpected network
    # requests and process termination fail the test, rather than being executed.
    function Stop-CpcvProcessTree { throw 'Recovery must never terminate an existing SSH or Cloudflare process.' }
    function Stop-Process { throw 'Recovery must never terminate an existing SSH or Cloudflare process.' }
    function Invoke-WebRequest { throw 'Test attempted an unmocked HTTP request.' }
    function Invoke-RestMethod { throw 'Test attempted an unmocked HTTP request.' }
    function Get-CpcvCloudflareProxyContext {
        param($Config, [int]$TimeoutSeconds)
        $script:discoveryCalls++
        return $script:fakeContext
    }
    function Get-CpcvCloudflareAccessMetadata {
        param([string]$Hostname, [int]$TimeoutSeconds)
        $script:metadataCalls++
        Assert-Cpcv ($Hostname -eq 'images.example.test') 'Metadata discovery received an unexpected hostname.'
        if ($script:metadataThrows) { throw 'Authorization: Bearer metadata-secret https://example.test/?token=metadata-secret' }
        return $script:fakeMetadata
    }
    function Get-CpcvCloudflareProcesses {
        if ($script:processDiscoveryThrows) { throw 'synthetic process enumeration failure' }
        # Match the production adapter's cloudflared.exe-only CIM filter.
        # Ordinary ssh.exe sessions remain in the fixture inventory untouched.
        return @($script:fakeProcesses | Where-Object { $_.Name -eq 'cloudflared.exe' })
    }
    function Invoke-CpcvProcess {
        param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label)
        $script:processCalls.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = @($Arguments); TimeoutSeconds = $TimeoutSeconds; Label = $Label })
        if ($script:uploadHarnessMode -and $FilePath -in @('ssh', 'scp')) {
            if ($Label -eq 'ssh mkdir' -and $script:uploadHarnessMode -eq 'failed') {
                return @{ Ok = $false; TimedOut = $true; ExitCode = -1; StdOut = ''; StdErr = ''; Detail = 'Authorization: Bearer synthetic-jwt-secret' }
            }
            Assert-Cpcv ($Label -in @('ssh mkdir', 'scp upload', 'ssh update latest')) 'Upload attempted an unexpected network operation.'
            $stdout = ''
            if ($Label -eq 'ssh update latest') {
                $leaf = [regex]::Match($Arguments[-1], 'clip-[a-f0-9]{64}\.png').Value
                $stdout = "CPCV_UPLOAD_OK /home/tester/clipboard-images/$leaf`n"
            }
            return @{ Ok = $true; TimedOut = $false; ExitCode = 0; StdOut = $stdout; StdErr = ''; Detail = '' }
        }
        Assert-Cpcv ($FilePath -eq $script:fakeContext.Executable) 'Recovery launched an unexpected executable.'
        Assert-Cpcv (($Arguments -join ' ') -match '^access login ') 'Recovery attempted a command other than an ordinary Access login.'
        Assert-Cpcv (($Arguments -join ' ') -notmatch 'force|token|service-token|client-secret') 'Recovery used credential or forced-refresh arguments.'
        Assert-Cpcv ($TimeoutSeconds -ge 1 -and $TimeoutSeconds -le 30) 'Refresh timeout was not bounded.'
        return $script:fakeLoginResult
    }

    function Reset-CpcvCloudflareTest {
        # Keep legacy Windows paths beneath MAX_PATH even after quarantine adds
        # a suffix to the hostname + 64-character Access audience lock name.
        $caseRoot = Join-Path $testRoot ('c-{0}' -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][IO.Directory]::CreateDirectory($caseRoot)
        $script:CpcvConfig = New-CpcvDefaultConfig
        $script:CpcvConfig.HostAlias = 'synthetic-test-host'
        $script:CpcvConfig.DataRoot = Join-Path $caseRoot 'runtime'
        $script:CpcvConfig.LogFile = Join-Path $script:CpcvConfig.DataRoot 'watch.log'
        $script:CpcvConfig.LocalCache = Join-Path $script:CpcvConfig.DataRoot 'cache'
        $script:CpcvConfig.StateFile = Join-Path $script:CpcvConfig.DataRoot 'last-hash.txt'
        $script:CpcvConfig.LastRemotePathFile = Join-Path $script:CpcvConfig.DataRoot 'last-remote-path.txt'
        $script:CpcvConfig.UploadStatusFile = Join-Path $script:CpcvConfig.DataRoot 'upload-status.txt'
        $script:CpcvConfig.HeartbeatFile = Join-Path $script:CpcvConfig.DataRoot 'watch.heartbeat'
        [void][IO.Directory]::CreateDirectory($script:CpcvConfig.DataRoot)
        $cacheRoot = Join-Path $caseRoot '.cloudflared'
        [void][IO.Directory]::CreateDirectory($cacheRoot)
        $script:fakeContext = @{ Executable = (Join-Path $caseRoot 'cloudflared.exe'); Hostname = 'images.example.test'; CacheRoot = $cacheRoot }
        $script:fakeMetadata = @{ AppDomain = 'images.example.test'; AppAUD = ('a' * 64); AuthDomain = 'test-org.cloudflareaccess.com' }
        $script:fakeProcesses = @()
        $script:metadataThrows = $false
        $script:processDiscoveryThrows = $false
        $script:uploadHarnessMode = ''
        $script:discoveryCalls = 0
        $script:metadataCalls = 0
        $script:processCalls = [System.Collections.Generic.List[object]]::new()
        $script:fakeLoginResult = @{ Ok = $true; TimedOut = $false; ExitCode = 0; StdOut = 'synthetic-jwt-secret'; StdErr = ''; Detail = 'Authorization: Bearer synthetic-jwt-secret' }
        $script:appLock = Join-Path $cacheRoot ($script:fakeMetadata.AppDomain + '-' + $script:fakeMetadata.AppAUD + '-token.lock')
        $script:orgLock = Join-Path $cacheRoot ($script:fakeMetadata.AuthDomain + '-org-token.lock')
    }

    function New-CpcvCloudflareTestLock {
        param([string]$Path, [int]$AgeSeconds = 600, [string]$Content = '')
        [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddSeconds(-$AgeSeconds))
    }

    function Invoke-CpcvCloudflareTestRepair {
        param([string]$FailureKind = 'connect-timeout')
        $result = Repair-CpcvCloudflareAccess -Config $script:CpcvConfig -FailureKind $FailureKind
        $serialized = $result | ConvertTo-Json -Depth 6 -Compress
        Assert-Cpcv ($serialized -notmatch 'synthetic-jwt-secret|metadata-secret|token=|Authorization:|images\.example\.test|test-org\.cloudflareaccess\.com') 'Recovery result exposed raw credentials or discovery data.'
        if (Test-Path -LiteralPath $script:CpcvConfig.LogFile) {
            $log = Get-Content -LiteralPath $script:CpcvConfig.LogFile -Raw
            Assert-Cpcv ($log -notmatch 'synthetic-jwt-secret|metadata-secret|token=|Authorization:') 'Recovery log exposed raw credentials.'
        }
        return $result
    }

    # Verify the actual Windows handle mover in TEMP, instead of mocking away
    # the race/reparse protections that make lock cleanup safe.
    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    Initialize-CpcvCloudflareLockMover
    $nativeItem = Get-Item -LiteralPath $script:appLock
    $nativeDestination = $script:appLock + '.synthetic-quarantine'
    $nativeMoved = [CpcvCloudflareLockMover]::Move($script:appLock, $nativeDestination, $nativeItem.LastWriteTimeUtc.Ticks, $nativeItem.CreationTimeUtc.Ticks)
    $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Assert-Cpcv $nativeMoved "The Windows handle mover did not quarantine a synthetic empty file (Win32 error $nativeError)."
    $nativeNames = @(Get-ChildItem -LiteralPath $script:fakeContext.CacheRoot -Force | Select-Object -ExpandProperty Name) -join ', '
    Assert-Cpcv ((Test-Path -LiteralPath $nativeDestination) -and -not (Test-Path -LiteralPath $script:appLock)) "Native lock quarantine did not rename the exact file (files: $nativeNames)."

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $changedItem = Get-Item -LiteralPath $script:appLock
    [IO.File]::WriteAllText($script:appLock, '{"pid":12345}')
    $changedMoved = [CpcvCloudflareLockMover]::Move($script:appLock, $script:appLock + '.synthetic-quarantine', $changedItem.LastWriteTimeUtc.Ticks, $changedItem.CreationTimeUtc.Ticks)
    Assert-Cpcv (-not $changedMoved -and (Test-Path -LiteralPath $script:appLock)) 'Native mover accepted a lock replaced with owned/nonempty content.'

    Reset-CpcvCloudflareTest
    $ineligibleFailure = Invoke-CpcvCloudflareTestRepair -FailureKind 'host-key'
    Assert-Cpcv (-not $ineligibleFailure.Recovered -and $ineligibleFailure.State -eq 'not-applicable') 'Host-key failure triggered recovery.'
    Assert-Cpcv ($script:processCalls.Count -eq 0 -and $script:discoveryCalls -eq 0) 'Host-key failure performed recovery discovery or login.'

    Reset-CpcvCloudflareTest
    $script:fakeContext = $null
    $unsupported = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $unsupported.Recovered -and $unsupported.State -eq 'not-applicable') 'Unsupported ProxyCommand triggered Cloudflare recovery.'
    Assert-Cpcv ($script:processCalls.Count -eq 0 -and $script:metadataCalls -eq 0) 'Unsupported proxy attempted metadata or login.'

    Reset-CpcvCloudflareTest
    $noLocks = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $noLocks.Recovered -and $script:processCalls.Count -eq 0) 'Recovery launched login without evidence of a stale lock.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock
    $unrelatedLock = Join-Path $script:fakeContext.CacheRoot 'another.example.test-other-aud-token.lock'
    $otherOrgLock = Join-Path $script:fakeContext.CacheRoot 'other-org.cloudflareaccess.com-org-token.lock'
    $credentialPath = Join-Path $script:fakeContext.CacheRoot ($script:fakeMetadata.AuthDomain + '-org-token')
    New-CpcvCloudflareTestLock $unrelatedLock
    New-CpcvCloudflareTestLock $otherOrgLock
    [IO.File]::WriteAllText($credentialPath, 'synthetic-credential-do-not-delete')
    $recovered = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv ($recovered.Recovered -and $recovered.State -eq 'recovered') "Successful bounded login did not report recovery (state=$($recovered.State), calls=$($script:processCalls.Count))."
    Assert-Cpcv (-not (Test-Path -LiteralPath $script:appLock) -and -not (Test-Path -LiteralPath $script:orgLock)) 'Aged, empty matching lock files were not removed.'
    Assert-Cpcv ((Test-Path -LiteralPath $unrelatedLock) -and (Test-Path -LiteralPath $otherOrgLock)) 'Recovery removed a lock belonging to another application or account.'
    Assert-Cpcv ((Get-Content -LiteralPath $credentialPath -Raw) -eq 'synthetic-credential-do-not-delete') 'Recovery modified an Access credential.'
    Assert-Cpcv ($script:processCalls.Count -eq 1) 'Recovery performed more than one ordinary login.'

    $throttled = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $throttled.Recovered -and $script:processCalls.Count -eq 1) 'Recovery cooldown permitted a repeated login.'
    $attemptFile = Join-Path $script:CpcvConfig.DataRoot 'cloudflare-recovery-attempt.txt'
    Assert-Cpcv (Test-Path -LiteralPath $attemptFile) 'Recovery did not persist its retry cooldown.'
    $attemptContents = Get-Content -LiteralPath $attemptFile -Raw
    Assert-Cpcv ($attemptContents -notmatch 'secret|images\.example\.test|test-org|token|Authorization:') 'Recovery cooldown exposed credentials or configuration.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock -AgeSeconds 10
    New-CpcvCloudflareTestLock $script:orgLock -AgeSeconds 10
    $fresh = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $fresh.Recovered -and (Test-Path -LiteralPath $script:appLock) -and (Test-Path -LiteralPath $script:orgLock)) 'Recovery deleted a fresh lock.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login while a fresh lock was present.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock -AgeSeconds 10
    $mixedAges = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $mixedAges.Recovered -and (Test-Path -LiteralPath $script:appLock) -and (Test-Path -LiteralPath $script:orgLock)) 'Recovery partially removed stale locks while a fresh lock could be owned.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery refreshed credentials while a fresh organization lock was present.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock -Content '{"pid":12345,"started":"synthetic"}'
    New-CpcvCloudflareTestLock $script:orgLock -Content '{"pid":12345}'
    $pidLocks = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $pidLocks.Recovered -and (Test-Path -LiteralPath $script:appLock) -and (Test-Path -LiteralPath $script:orgLock)) 'Recovery deleted an owned PID/JSON lock.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login despite an owned PID/JSON lock.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock
    $script:fakeProcesses = @([pscustomobject]@{ ProcessId = 12345; Name = 'cloudflared.exe'; CommandLine = ('"{0}" access login https://images.example.test' -f $script:fakeContext.Executable); CreationTimeUtc = [DateTime]::UtcNow.AddSeconds(-30) })
    $activeLogin = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $activeLogin.Recovered -and (Test-Path -LiteralPath $script:appLock) -and (Test-Path -LiteralPath $script:orgLock)) 'Recovery interfered with an active Access login.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery raced an active Access login.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock
    $script:fakeProcesses = @([pscustomobject]@{ ProcessId = 12345; Name = 'cloudflared.exe'; CommandLine = ('"{0}" access ssh --hostname images.example.test' -f $script:fakeContext.Executable); CreationTimeUtc = [DateTime]::UtcNow.AddSeconds(-30) })
    $newProxy = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $newProxy.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Recovery deleted a lock while a new SSH proxy could own it.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery raced a newly started SSH proxy.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock
    # Legacy proxies can wait on both app and organization locks before
    # creating a lock of their own, so creation time may precede it by minutes.
    $script:fakeProcesses = @([pscustomobject]@{ ProcessId = 12345; Name = 'cloudflared.exe'; CommandLine = ('"{0}" access ssh --hostname images.example.test' -f $script:fakeContext.Executable); CreationTimeUtc = [DateTime]::UtcNow.AddMinutes(-15) })
    $waitingProxy = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $waitingProxy.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Recovery ignored a proxy that could have waited on earlier legacy locks.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery raced a proxy created minutes before its lock.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock
    $script:fakeProcesses = @([pscustomobject]@{ ProcessId = 12345; Name = 'cloudflared.exe'; CommandLine = ('"{0}" access ssh --hostname another.example.test' -f $script:fakeContext.Executable); CreationTimeUtc = [DateTime]::UtcNow.AddSeconds(-30) })
    $sharedOrgOwner = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $sharedOrgOwner.Recovered -and (Test-Path -LiteralPath $script:orgLock)) 'Recovery removed an organization lock while another new proxy could own it.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery raced another proxy using the shared organization lock.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $script:fakeProcesses = @([pscustomobject]@{ ProcessId = 12345; Name = 'cloudflared.exe'; CommandLine = $null; CreationTimeUtc = $null })
    $unknownOwner = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $unknownOwner.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Recovery did not fail closed for an uninspectable Cloudflare process.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login despite an unknown process owner.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock
    $script:fakeProcesses = @(
        [pscustomobject]@{ ProcessId = 12345; Name = 'cloudflared.exe'; CommandLine = ('"{0}" access ssh --hostname images.example.test' -f $script:fakeContext.Executable); CreationTimeUtc = [DateTime]::UtcNow.AddHours(-2) },
        [pscustomobject]@{ ProcessId = 23456; Name = 'ssh.exe'; CommandLine = 'ssh.exe synthetic-test-host'; CreationTimeUtc = [DateTime]::UtcNow.AddHours(-2) }
    )
    $liveStream = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv ($liveStream.Recovered -and $script:processCalls.Count -eq 1) 'A longstanding SSH stream prevented stale-lock recovery.'
    Assert-Cpcv ($script:fakeProcesses.Count -eq 2) 'Recovery changed the existing process inventory.'

    foreach ($listenerArguments in @(
        'access ssh --hostname images.example.test --url localhost:2200',
        'access tcp --hostname images.example.test --listener localhost:2200',
        'access ssh --hostname images.example.test -L 2200',
        'access rdp --hostname images.example.test',
        'access smb --hostname images.example.test'
    )) {
        Reset-CpcvCloudflareTest
        New-CpcvCloudflareTestLock $script:appLock
        $script:fakeProcesses = @([pscustomobject]@{ ProcessId = 12345; Name = 'cloudflared.exe'; CommandLine = ('"{0}" {1}' -f $script:fakeContext.Executable, $listenerArguments); CreationTimeUtc = [DateTime]::UtcNow.AddHours(-2) })
        $listenerOwner = Invoke-CpcvCloudflareTestRepair
        Assert-Cpcv (-not $listenerOwner.Recovered -and (Test-Path -LiteralPath $script:appLock)) "Recovery interfered with a longstanding Access listener ($listenerArguments)."
        Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery raced a longstanding listener that can renew its token.'
    }

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock
    $script:processDiscoveryThrows = $true
    $unknownProcesses = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $unknownProcesses.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Failed process discovery did not preserve locks.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login after process discovery failed.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $script:metadataThrows = $true
    $badMetadata = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $badMetadata.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Failed Access discovery modified cache locks.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login after Access discovery failed.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $script:fakeLoginResult = @{ Ok = $false; TimedOut = $true; ExitCode = -1; StdOut = 'synthetic-jwt-secret'; StdErr = 'https://example.test/?token=synthetic-jwt-secret'; Detail = 'Authorization: Bearer synthetic-jwt-secret' }
    $timedOutLogin = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $timedOutLogin.Recovered -and $timedOutLogin.State -eq 'sign-in-required') 'A timed out refresh did not require user sign-in.'
    Assert-Cpcv ($script:processCalls.Count -eq 1) 'Timed out refresh was repeated in one recovery attempt.'
    $afterTimeout = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $afterTimeout.Recovered -and $afterTimeout.State -eq 'sign-in-required' -and $script:processCalls.Count -eq 1) 'A timed out refresh did not preserve sign-in guidance throughout cooldown.'

    # Lock/cache junctions are real local reparse points, with both target and
    # link under the test directory. Never put fixtures in the user's cache.
    Reset-CpcvCloudflareTest
    $targetCache = Join-Path $testRoot ('junction-target-{0}' -f [Guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($targetCache)
    $targetLock = Join-Path $targetCache ([IO.Path]::GetFileName($script:appLock))
    New-CpcvCloudflareTestLock $targetLock
    $linkCache = Join-Path $testRoot ('junction-cache-{0}' -f [Guid]::NewGuid())
    [void](New-Item -ItemType Junction -Path $linkCache -Value $targetCache)
    $junctionPaths.Add($linkCache)
    $script:fakeContext.CacheRoot = $linkCache
    $junctionResult = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $junctionResult.Recovered -and (Test-Path -LiteralPath $targetLock)) 'Recovery followed a cache-directory junction.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login for a linked cache.'

    Reset-CpcvCloudflareTest
    $leafTarget = Join-Path $testRoot ('leaf-target-{0}' -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($leafTarget)
    $leafSentinel = Join-Path $leafTarget 'keep.txt'
    [IO.File]::WriteAllText($leafSentinel, 'synthetic-do-not-touch')
    [void](New-Item -ItemType Junction -Path $script:appLock -Value $leafTarget)
    $junctionPaths.Add($script:appLock)
    $leafResult = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $leafResult.Recovered -and (Test-Path -LiteralPath $script:appLock) -and (Get-Content -LiteralPath $leafSentinel -Raw) -eq 'synthetic-do-not-touch') 'Recovery followed or removed a linked lock leaf.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login for a linked lock leaf.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $hardLink = Join-Path $script:fakeContext.CacheRoot 'shared-synthetic-file.lock'
    [void](New-Item -ItemType HardLink -Path $hardLink -Value $script:appLock)
    $hardLinkResult = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $hardLinkResult.Recovered -and (Test-Path -LiteralPath $script:appLock) -and (Test-Path -LiteralPath $hardLink)) 'Recovery quarantined a lock with multiple hard links.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login for a multiply linked lock.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $script:fakeMetadata.AppDomain = '..\outside'
    $traversal = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $traversal.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Untrusted metadata was accepted as a filesystem path.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login with path-traversal metadata.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $script:fakeMetadata.AppDomain = 'another.example.test'
    $wrongApp = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $wrongApp.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Metadata from a different application was accepted for the configured SSH host.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login for a different application domain.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $script:fakeMetadata.AuthDomain = '..\outside'
    $orgTraversal = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $orgTraversal.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Untrusted organization metadata was accepted as a filesystem path.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login with organization traversal metadata.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $script:fakeMetadata.AppAUD = '..\outside'
    $audTraversal = Invoke-CpcvCloudflareTestRepair
    Assert-Cpcv (-not $audTraversal.Recovered -and (Test-Path -LiteralPath $script:appLock)) 'Untrusted application audience was accepted as a filesystem path.'
    Assert-Cpcv ($script:processCalls.Count -eq 0) 'Recovery launched login with application-audience traversal metadata.'

    # Exercise the first failed upload and its next ordinary attempt. Clipboard,
    # SSH, SCP and Access login are all stubs; no native clipboard is accessed.
    function Get-ClipboardImageBytes { return [byte[]](137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3) }
    function Set-Clipboard { throw 'Test must never modify the native clipboard.' }
    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    New-CpcvCloudflareTestLock $script:orgLock
    $script:uploadHarnessMode = 'failed'
    $firstUpload = Publish-ClipboardImage -Force
    Assert-Cpcv (-not $firstUpload.Ok -and $firstUpload.Reason -eq 'cloudflare-retry') 'An upload did not expose the controlled automatic-retry status after recovery.'
    Assert-Cpcv ($script:processCalls.Count -eq 2) 'Recovery retried SSH immediately instead of waiting for the next normal upload attempt.'
    Assert-Cpcv (-not (Test-Path -LiteralPath $script:CpcvConfig.StateFile)) 'A recovered transport failure advanced the image hash before upload.'
    $firstStatus = Get-CpcvUploadStatusInfo -Path $script:CpcvConfig.UploadStatusFile
    Assert-Cpcv ($firstStatus -and $firstStatus.Reason -eq 'cloudflare-retry' -and $firstStatus.Result -eq 'failed') 'Automatic-retry status was not saved for the tray.'
    $script:uploadHarnessMode = 'healthy'
    $nextUpload = Publish-ClipboardImage -Force
    Assert-Cpcv ($nextUpload.Ok -and $nextUpload.Reason -eq 'uploaded') 'The next ordinary attempt did not upload after Access recovery.'
    Assert-Cpcv ($script:processCalls.Count -eq 5) 'A normal upload did not use the existing three-stage SSH/SCP flow.'
    $nextStatus = Get-CpcvUploadStatusInfo -Path $script:CpcvConfig.UploadStatusFile
    Assert-Cpcv ($nextStatus -and $nextStatus.Result -eq 'succeeded') 'A successful upload did not clear the retry failure status.'
    Assert-Cpcv ((Get-Content -LiteralPath $script:CpcvConfig.StateFile -Raw).Trim().Length -eq 64) 'A successful upload did not preserve normal hash state.'
    Assert-Cpcv ((Get-Content -LiteralPath $script:CpcvConfig.LogFile -Raw) -notmatch 'synthetic-jwt-secret') 'Upload recovery exposed an Access credential in logs.'

    Reset-CpcvCloudflareTest
    New-CpcvCloudflareTestLock $script:appLock
    $script:uploadHarnessMode = 'failed'
    $script:fakeLoginResult = @{ Ok = $false; TimedOut = $true; ExitCode = -1; StdOut = 'synthetic-jwt-secret'; StdErr = ''; Detail = 'Authorization: Bearer synthetic-jwt-secret' }
    $interactiveUpload = Publish-ClipboardImage -Force
    Assert-Cpcv (-not $interactiveUpload.Ok -and $interactiveUpload.Reason -eq 'cloudflare-sign-in-required') 'A refresh requiring interaction did not expose the controlled sign-in status.'
    $interactiveStatus = Get-CpcvUploadStatusInfo -Path $script:CpcvConfig.UploadStatusFile
    Assert-Cpcv ($interactiveStatus -and $interactiveStatus.Reason -eq 'cloudflare-sign-in-required') 'Sign-in-required status was not saved for the tray.'
    Assert-Cpcv ((Get-Content -LiteralPath $script:CpcvConfig.UploadStatusFile -Raw) -notmatch 'synthetic-jwt-secret|Authorization:|images\.example\.test') 'Sign-in-required status exposed credentials or discovery data.'

    Write-Host 'PASS: isolated Cloudflare recovery, exact cache paths, conservative locks/processes, bounded refresh, cooldown, reparse guards, and credential-safe results'
}
finally {
    foreach ($name in $priorEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $priorEnvironment[$name], 'Process')
    }
    # Remove junction objects before recursive cleanup so older PowerShell
    # versions cannot traverse their targets. Verify every deletion boundary.
    foreach ($junctionPath in $junctionPaths) {
        $resolvedLink = [IO.Path]::GetFullPath($junctionPath)
        Assert-Cpcv ($resolvedLink.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'Junction cleanup escaped the test directory.'
        if ([IO.Directory]::Exists($resolvedLink)) { [IO.Directory]::Delete($resolvedLink) }
    }
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    Assert-Cpcv ($resolvedRoot.StartsWith($tempBoundary, [StringComparison]::OrdinalIgnoreCase)) 'Recursive cleanup escaped TEMP.'
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
