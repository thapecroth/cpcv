# Safe local verification for the process wrapper and upload decision paths.
# It never contacts an SSH host and writes only to a unique directory under TEMP.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\cpcv-core.ps1")
$script:testProcessMutexSuffix = [Guid]::NewGuid().ToString("N")
function Get-CpcvMutexName { param([string]$Purpose) return "Local\CpcvProcessTest-$Purpose-$script:testProcessMutexSuffix" }

function Assert-Cpcv([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$quick = Invoke-CpcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "Write-Output healthy") -TimeoutSeconds 5 -Label "quick smoke test"
Assert-Cpcv $quick.Ok "Quick process test failed: $($quick.Detail)"
Assert-Cpcv ($quick.StdOut.Trim() -eq "healthy") "Quick process output was not captured."

$large = Invoke-CpcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "[Console]::Out.Write('x' * 200000)") -TimeoutSeconds 5 -Label "large-output smoke test"
Assert-Cpcv ($large.Ok -and $large.OutputTruncated) "Large subprocess output was not marked truncated."
Assert-Cpcv ($large.StdOut.Length -le $script:CpcvConfig.MaxCommandOutputBytes) "Large subprocess output exceeded the configured bound."
$redacted = Protect-CpcvLogDetail "Authorization: Bearer secret-value`nhttps://example.test/callback?token=super-secret"
Assert-Cpcv ($redacted -notmatch 'secret-value|super-secret') "Credential-like subprocess text was not redacted for logging."
Assert-Cpcv ((Get-CpcvRetryDelay 1 2) -eq 4 -and (Get-CpcvRetryDelay 8 2) -eq 60) "Failure retry backoff is not capped as expected."
$bannerFailure = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Connection timed out during banner exchange'; Detail = 'synthetic banner timeout' }
Assert-Cpcv ((Get-CpcvSshConnectionFailureKind -ProcessResult $bannerFailure) -eq 'connect-timeout') "A banner-exchange timeout was not classified as a controlled connection timeout."
$authFailure = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Permission denied (publickey).'; Detail = '' }
Assert-Cpcv ((Get-CpcvSshConnectionFailureKind -ProcessResult $authFailure) -eq 'authentication') "A non-interactive SSH sign-in failure was not classified safely."
$interactiveAuthFailure = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Permission denied (publickey,keyboard-interactive).'; Detail = '' }
Assert-Cpcv ((Get-CpcvSshConnectionFailureKind -ProcessResult $interactiveAuthFailure) -eq 'authentication') "An interactive/MFA-style SSH sign-in failure was not classified safely."
$tooManyAuthFailures = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Received disconnect: Too many authentication failures'; Detail = '' }
Assert-Cpcv ((Get-CpcvSshConnectionFailureKind -ProcessResult $tooManyAuthFailures) -eq 'authentication') "An SSH agent authentication-limit failure was not classified safely."
$noAuthMethods = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'No supported authentication methods available'; Detail = '' }
Assert-Cpcv ((Get-CpcvSshConnectionFailureKind -ProcessResult $noAuthMethods) -eq 'authentication') "An unsupported SSH authentication-method failure was not classified safely."
$remoteFolderPermission = @{ Ok = $false; TimedOut = $false; ExitCode = 1; StdOut = ''; StdErr = "mkdir: cannot create directory '/home/example/clipboard-images': Permission denied"; Detail = '' }
Assert-Cpcv ((Get-CpcvSshConnectionFailureKind -ProcessResult $remoteFolderPermission) -ne 'authentication') "A remote-folder permission failure was incorrectly classified as SSH authentication."
Assert-Cpcv ((Get-CpcvSshMkdirFailureReason -ProcessResult $remoteFolderPermission) -eq 'ssh-mkdir-remote-folder-failed') "A remote-folder permission failure was not given its own controlled status token."
$authPresentation = Get-CpcvSshConnectionCheckPresentation -FailureKind 'authentication'
Assert-Cpcv ($authPresentation.Detail -match 'one-time-code' -and $authPresentation.NextStep -match 'normal SSH workflow') "Authentication guidance did not explain an interactive or MFA-style sign-in safely."
$hostKeyFailure = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Host key verification failed.'; Detail = '' }
Assert-Cpcv ((Get-CpcvSshConnectionFailureKind -ProcessResult $hostKeyFailure) -eq 'host-key') "An SSH host-key failure was not classified safely."
$sshOptions = @(Get-CpcvSshOptions)
Assert-Cpcv (($sshOptions -join ' ') -eq '-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ServerAliveInterval=3 -o ServerAliveCountMax=2') "The shared unattended SSH option set changed unexpectedly."

# The separately owned tray helper must emit only a compact category, even
# before a valid connection exists. Point its child process at an invalid local
# config so this contract test cannot contact SSH or change remote state.
$connectionHelper = Join-Path (Split-Path $PSScriptRoot -Parent) 'cpcv-connection-check.ps1'
Assert-Cpcv (Test-Path -LiteralPath $connectionHelper -PathType Leaf) "The owned tray connection-check helper is missing."
$helperConfigPath = Join-Path $env:TEMP ("cpcv-helper-config-{0}.psd1" -f [Guid]::NewGuid())
$priorHelperConfig = $env:CPCV_CONFIG
try {
    [IO.File]::WriteAllText($helperConfigPath, "@{}`n", [Text.UTF8Encoding]::new($false))
    $env:CPCV_CONFIG = $helperConfigPath
    $helperOutput = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $connectionHelper 2>&1 | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-Cpcv ($LASTEXITCODE -eq 0 -and $helperOutput.Count -eq 1) "The owned tray connection-check helper did not emit one controlled result."
    $helperResult = $helperOutput[0] | ConvertFrom-Json -ErrorAction Stop
    Assert-Cpcv ([string]$helperResult.Version -eq '1' -and [string]$helperResult.FailureKind -eq 'configuration') "The owned tray connection-check helper exposed an unexpected result category."
}
finally {
    if ($null -eq $priorHelperConfig) { Remove-Item Env:CPCV_CONFIG -ErrorAction SilentlyContinue } else { $env:CPCV_CONFIG = $priorHelperConfig }
    Remove-Item -LiteralPath $helperConfigPath -Force -ErrorAction SilentlyContinue
}

$validConfig = New-CpcvDefaultConfig
$validConfig.HostAlias = "example-host"
Assert-Cpcv (-not (Test-CpcvConfigValue $validConfig)) "A valid generic SSH alias was rejected."
$badHost = New-CpcvDefaultConfig
$badHost.HostAlias = "-oProxyCommand=bad"
Assert-Cpcv ((Test-CpcvConfigValue $badHost) -match "HostAlias") "Option-like SSH host was accepted."
$badDir = New-CpcvDefaultConfig
$badDir.HostAlias = "example-host"
$badDir.RemoteDir = "../unsafe"
Assert-Cpcv ((Test-CpcvConfigValue $badDir) -match "RemoteDir") "Traversal remote directory was accepted."
Assert-Cpcv (Test-CpcvRemotePath "/home/tester/clipboard-images/latest.png") "Safe remote path was rejected."
Assert-Cpcv (-not (Test-CpcvRemotePath "/tmp/path;not-safe")) "Unsafe remote output path was accepted."

$configProbe = Join-Path $env:TEMP ("cpcv-config-{0}.psd1" -f [Guid]::NewGuid())
$originalConfigPath = $script:CpcvConfigPath
try {
    @'
@{
    HostAlias = "example-host"
    RemoteDir = "screens/latest"
    RemoteHome = "/srv/example"
}
'@ | Set-Content -LiteralPath $configProbe -NoNewline
    $script:CpcvConfigPath = $configProbe
    $loadedConfig = Get-CpcvConfig
    Assert-Cpcv (-not $loadedConfig.ConfigError -and $loadedConfig.HostAlias -eq "example-host") "Valid local config did not load."
    Assert-Cpcv ($loadedConfig.RemoteDir -eq "screens/latest" -and $loadedConfig.RemoteHome -eq "/srv/example") "Loaded config values were not preserved."

    @'
@{
    HostAlias = "example-host"
    RemoteDir = "../../unsafe"
}
'@ | Set-Content -LiteralPath $configProbe -NoNewline
    $invalidConfig = Get-CpcvConfig
    Assert-Cpcv ($invalidConfig.ConfigError -match "RemoteDir") "Unsafe local config was accepted."
}
finally {
    $script:CpcvConfigPath = $originalConfigPath
    Remove-Item -LiteralPath $configProbe -Force -ErrorAction SilentlyContinue
}

# A parent PowerShell starts a child PowerShell. The parent script uses an
# explicit quoted command line so this check remains valid from a checkout
# whose path contains spaces. The hard timeout must kill both processes.
$childPidFile = Join-Path $env:TEMP ("cpcv-child-{0}.txt" -f [Guid]::NewGuid())
$childScript = Join-Path $PSScriptRoot "child-sleeper.ps1"
$parentScript = Join-Path $PSScriptRoot "child-tree-parent.ps1"
$timer = [Diagnostics.Stopwatch]::StartNew()
$timeout = Invoke-CpcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-File", $parentScript, "-ChildScript", $childScript, "-PidFile", $childPidFile) -TimeoutSeconds 3 -Label "process-tree timeout test"
$timer.Stop()
Assert-Cpcv $timeout.TimedOut "Expected process-tree command to time out."
Assert-Cpcv ($timer.Elapsed.TotalSeconds -lt 9) "Timeout took too long: $($timer.Elapsed.TotalSeconds)s"
Start-Sleep -Milliseconds 500
Assert-Cpcv (Test-Path $childPidFile) "Child process did not publish its PID; process-tree test did not run."
$childPid = [int](Get-Content -Raw $childPidFile)
if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) {
    Stop-CpcvProcessTree -ProcessId $childPid
    throw "Child process $childPid survived the timeout tree cleanup."
}
Remove-Item -LiteralPath $childPidFile -Force

# Simulate clipboard states and SSH outcomes without calling the network.
$tempRoot = Join-Path $env:TEMP ("cpcv-test-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$originalConfig = $script:CpcvConfig
try {
    $script:CpcvConfig = @{
        HostAlias = "example-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); LogFile = (Join-Path $tempRoot "watch.log")
        UploadStatusFile = (Join-Path $tempRoot "upload-status.txt")
        HeartbeatFile = (Join-Path $tempRoot "watch.heartbeat"); CommandTimeoutSeconds = 3; MaxCommandOutputBytes = 65536
        PollIntervalSeconds = 2; WatchdogCheckSeconds = 15; WatchdogStaleSeconds = 120
        MaxLogBytes = 1048576; MaxCacheFiles = 200; MaxCacheBytes = 268435456; MaxImageBytes = 52428800; ConfigError = ""
    }

    Set-CpcvAtomicText -Path $script:CpcvConfig.HeartbeatFile -Value "2026-01-01T00:00:00.0000000Z pid=123 checking"
    Assert-Cpcv (Test-CpcvHeartbeat -Path $script:CpcvConfig.HeartbeatFile -ExpectedProcessId 123) "Atomic heartbeat write was not readable/valid."

    Set-Content -Path $script:CpcvConfig.LogFile -Value "https://example.test/callback?token=legacy-secret" -NoNewline
    Sanitize-CpcvLog
    Assert-Cpcv ((Get-Content -Raw $script:CpcvConfig.LogFile) -notmatch 'legacy-secret') "Legacy log sanitizer retained a credential-like query."

    function Get-ClipboardImageBytes { return $null }
    $noImage = Publish-ClipboardImage
    Assert-Cpcv ($noImage.Reason -eq "no-image") "No-image clipboard path was not handled."

    function Get-ClipboardImageBytes { throw [System.Runtime.InteropServices.ExternalException]::new("simulated clipboard busy", -2147221040) }
    $busy = Publish-ClipboardImage
    Assert-Cpcv (-not $busy.Ok -and $busy.Reason -eq "clipboard-busy") "Clipboard contention did not return a controlled retry result."

    function Get-ClipboardImageBytes { return [byte[]](137,80,78,71,13,10,26,10,0,1,2,3) }
    $script:simulatedNetworkUp = $false
    function Invoke-CpcvProcess {
        param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label)
        if ($Label -eq 'ssh connection check') {
            $script:connectionCheckArguments = @($Arguments)
            return @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Connection timed out during banner exchange'; Detail = 'https://example.test/callback?token=super-secret' }
        }
        if (-not $script:simulatedNetworkUp) {
            return @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ""; StdErr = "simulated network failure"; Detail = "https://example.test/callback?token=super-secret" }
        }
        $stdout = ""
        if ($Label -eq 'ssh update latest') {
            $leaf = [regex]::Match($Arguments[-1], 'clip-[a-f0-9]{64}\.png').Value
            $stdout = "CPCV_UPLOAD_OK /home/tester/clipboard-images/$leaf`n"
        }
        return @{ Ok = $true; TimedOut = $false; ExitCode = 0; StdOut = $stdout; StdErr = ""; Detail = "" }
    }
    $failedUpload = Publish-ClipboardImage -Force
    Assert-Cpcv ($failedUpload.Reason -eq "ssh-mkdir-failed") "Simulated SSH failure was not reported."
    Assert-Cpcv (-not (Test-Path $script:CpcvConfig.StateFile)) "Failed upload incorrectly advanced the last-upload state."
    Assert-Cpcv ((Get-Content -Raw $script:CpcvConfig.LogFile) -notmatch 'super-secret') "Sensitive proxy/auth text reached the log."
    $failedUploadStatus = Get-CpcvUploadStatusInfo -Path $script:CpcvConfig.UploadStatusFile
    Assert-Cpcv ($failedUploadStatus -and $failedUploadStatus.Result -eq "failed" -and $failedUploadStatus.Reason -eq "ssh-mkdir-failed") "A failed upload did not persist a controlled tray status."
    Assert-Cpcv ((Get-Content -Raw $script:CpcvConfig.UploadStatusFile) -notmatch 'super-secret|example-host|clipboard-images') "Upload status exposed diagnostic or configuration detail."

    $stateBeforeConnectionCheck = Test-Path -LiteralPath $script:CpcvConfig.StateFile
    $pathBeforeConnectionCheck = Test-Path -LiteralPath $script:CpcvConfig.LastRemotePathFile
    $connectionCheck = Get-CpcvSshConnectionCheckResult
    $connectionCheckText = "$($connectionCheck.Summary) $($connectionCheck.Detail) $($connectionCheck.NextStep)"
    Assert-Cpcv (-not $connectionCheck.Ok -and $connectionCheck.FailureKind -eq 'connect-timeout') "The unattended SSH check did not map a banner timeout to a safe customer category."
    Assert-Cpcv ($connectionCheckText -match 'unattended SSH' -and $connectionCheckText -notmatch 'super-secret|example-host|clipboard-images|example\.test') "The unattended SSH check exposed raw SSH or configuration data."
    Assert-Cpcv ((@($script:connectionCheckArguments) -join ' ') -eq ' -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 example-host true'.Trim()) "The unattended SSH check did not use the same unattended SSH settings and fixed read-only command."
    Assert-Cpcv ((Test-Path -LiteralPath $script:CpcvConfig.StateFile) -eq $stateBeforeConnectionCheck -and (Test-Path -LiteralPath $script:CpcvConfig.LastRemotePathFile) -eq $pathBeforeConnectionCheck) "The unattended SSH check changed upload state."

    $script:simulatedNetworkUp = $true
    $recoveredUpload = Publish-ClipboardImage -Force
    Assert-Cpcv ($recoveredUpload.Ok -and $recoveredUpload.Reason -eq "uploaded") "Simulated network recovery did not upload."
    Assert-Cpcv (Test-Path (Join-Path $script:CpcvConfig.LocalCache "latest.png")) "Recovery did not refresh latest.png."
    Assert-Cpcv ((Get-Content -Raw $script:CpcvConfig.StateFile).Length -eq 64) "Recovery did not persist the image hash."
    $recoveredUploadStatus = Get-CpcvUploadStatusInfo -Path $script:CpcvConfig.UploadStatusFile
    Assert-Cpcv ($recoveredUploadStatus -and $recoveredUploadStatus.Result -eq "succeeded") "A recovered upload did not clear the tray failure status."
}
finally {
    $script:CpcvConfig = $originalConfig
    if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "PASS: configuration validation, bounded/redacted output, retry backoff, process-tree timeout, clipboard states, SSH failure/recovery, and latest-image state"
& (Join-Path $PSScriptRoot "test-release-hardening.ps1")
