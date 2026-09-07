# Safe local regression tests for release-hardening edge cases.  These tests
# stub all clipboard and SSH/SCP activity and write only beneath TEMP.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\cpcv-core.ps1")

function Assert-Cpcv([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-CpcvTestProcessResult {
    param(
        [bool]$Ok = $true,
        [bool]$TimedOut = $false,
        [int]$ExitCode = 0,
        [string]$StdOut = "/home/tester/clipboard-images/clip-test.png`n",
        [string]$Detail = ""
    )
    return @{ Ok = $Ok; TimedOut = $TimedOut; ExitCode = $ExitCode; StdOut = $StdOut; StdErr = ""; OutputTruncated = $false; Detail = $Detail }
}

function Reset-CpcvTestUploadState {
    foreach ($path in @($script:CpcvConfig.StateFile, $script:CpcvConfig.LastRemotePathFile, (Join-Path $script:CpcvConfig.LocalCache "latest.png"))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

# Strict configuration parsing must reject values that PowerShell would
# otherwise coerce silently, while keeping compatible numeric strings usable.
$validConfig = New-CpcvDefaultConfig
$validConfig.HostAlias = "example-host"
Assert-Cpcv (-not (Test-CpcvConfigValue $validConfig)) "Default valid configuration was rejected."

$badNumericConfig = New-CpcvDefaultConfig
$badNumericConfig.HostAlias = "example-host"
$badNumericConfig.CommandTimeoutSeconds = "thirty-five"
Assert-Cpcv ((Test-CpcvConfigValue $badNumericConfig) -match "CommandTimeoutSeconds.*whole number") "Malformed numeric configuration was accepted."

$fractionalConfig = New-CpcvDefaultConfig
$fractionalConfig.HostAlias = "example-host"
$fractionalConfig.PollIntervalSeconds = 2.5
Assert-Cpcv ((Test-CpcvConfigValue $fractionalConfig) -match "PollIntervalSeconds.*whole number") "Fractional numeric configuration was accepted."

$badWatchdogConfig = New-CpcvDefaultConfig
$badWatchdogConfig.HostAlias = "example-host"
$badWatchdogConfig.WatchdogStaleSeconds = 119
Assert-Cpcv ((Test-CpcvConfigValue $badWatchdogConfig) -match "WatchdogStaleSeconds.*at least 120") "Unsafe watchdog timing was accepted."

$badCacheSizeConfig = New-CpcvDefaultConfig
$badCacheSizeConfig.HostAlias = "example-host"
$badCacheSizeConfig.MaxImageBytes = 268435456
$badCacheSizeConfig.MaxCacheBytes = 268435455
Assert-Cpcv ((Test-CpcvConfigValue $badCacheSizeConfig) -match "MaxImageBytes cannot exceed MaxCacheBytes") "Image size cap larger than cache budget was accepted."

$configProbe = Join-Path $env:TEMP ("cpcv-hardening-config-{0}.psd1" -f [Guid]::NewGuid())
$originalConfigPath = $script:CpcvConfigPath
try {
    @'
@{
    HostAlias = "example-host"
    RemoteDir = "clipboard-images"
    CommandTimeoutSeconds = "35"
}
'@ | Set-Content -LiteralPath $configProbe -NoNewline
    $script:CpcvConfigPath = $configProbe
    $normalizedConfig = Get-CpcvConfig
    Assert-Cpcv (-not $normalizedConfig.ConfigError) "Numeric-string configuration did not load."
    Assert-Cpcv ($normalizedConfig.CommandTimeoutSeconds -is [int] -and $normalizedConfig.CommandTimeoutSeconds -eq 35) "Numeric configuration was not normalized to an integer."

    @'
@{
    HostAlias = "example-host"
    RemoteDir = "clipboard-images"
    CommandTimeoutSeconds = "not-a-number"
}
'@ | Set-Content -LiteralPath $configProbe -NoNewline
    $malformedConfig = Get-CpcvConfig
    Assert-Cpcv ($malformedConfig.ConfigError -match "CommandTimeoutSeconds.*whole number") "Malformed numeric config did not fail closed."
}
finally {
    $script:CpcvConfigPath = $originalConfigPath
    Remove-Item -LiteralPath $configProbe -Force -ErrorAction SilentlyContinue
}

# The guardian must recognize only the exact -File path for this checkout.
$watchScript = [IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) "cpcv-watch.ps1"))
$otherWatchScript = [IO.Path]::GetFullPath((Join-Path $env:TEMP "other-cpcv\cpcv-watch.ps1"))
Assert-Cpcv (Test-CpcvProcessCommandLineForScript -CommandLine ('powershell.exe -NoProfile -File "' + $watchScript + '"') -ScriptPath $watchScript) "Exact watcher command line was not recognized."
Assert-Cpcv (-not (Test-CpcvProcessCommandLineForScript -CommandLine ('powershell.exe -File "' + $otherWatchScript + '"') -ScriptPath $watchScript)) "Watcher from another checkout was matched."
Assert-Cpcv (-not (Test-CpcvProcessCommandLineForScript -CommandLine ('powershell.exe -File "' + $watchScript + '.bak"') -ScriptPath $watchScript)) "Lookalike watcher filename was matched."
Assert-Cpcv (-not (Test-CpcvProcessCommandLineForScript -CommandLine ('powershell.exe -Command "& { ' + $watchScript + ' }"') -ScriptPath $watchScript)) "Command-line text without -File was matched."

$tempRoot = Join-Path $env:TEMP ("cpcv-hardening-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$originalConfig = $script:CpcvConfig
try {
    $script:CpcvConfig = @{
        HostAlias = "example-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); LogFile = (Join-Path $tempRoot "watch.log")
        HeartbeatFile = (Join-Path $tempRoot "watch.heartbeat"); CommandTimeoutSeconds = 35; MaxCommandOutputBytes = 65536
        PollIntervalSeconds = 2; WatchdogCheckSeconds = 15; WatchdogStaleSeconds = 120
        MaxLogBytes = 1048576; MaxCacheFiles = 2; MaxCacheBytes = 8388608; MaxImageBytes = 1048576; ConfigError = ""
    }
    New-Item -ItemType Directory -Path $script:CpcvConfig.LocalCache | Out-Null

    Set-CpcvAtomicText -Path $script:CpcvConfig.HeartbeatFile -Value "2026-01-01T00:00:00.0000000Z pid=456 checking"
    $heartbeatInfo = Get-CpcvHeartbeatInfo -Path $script:CpcvConfig.HeartbeatFile
    Assert-Cpcv ($heartbeatInfo -and $heartbeatInfo.ProcessId -eq 456) "Valid heartbeat did not expose its process ID."
    Assert-Cpcv (Test-CpcvHeartbeat -Path $script:CpcvConfig.HeartbeatFile -ExpectedProcessId 456) "Expected heartbeat PID was rejected."
    Assert-Cpcv (-not (Test-CpcvHeartbeat -Path $script:CpcvConfig.HeartbeatFile -ExpectedProcessId 457)) "Unexpected heartbeat PID was accepted."
    Set-Content -LiteralPath $script:CpcvConfig.HeartbeatFile -Value ("x" * 513) -NoNewline
    Assert-Cpcv (-not (Test-CpcvHeartbeat -Path $script:CpcvConfig.HeartbeatFile)) "Oversized corrupt heartbeat was accepted."

    $script:CpcvConfig.MaxCommandOutputBytes = "malformed"
    Write-CpcvLog "config validation diagnostic"
    $script:CpcvConfig.MaxCommandOutputBytes = 65536

    $credentialDetail = @'
Authorization: Bearer authorization-secret
Proxy-Authorization: Basic proxy-secret
X-Api-Key: header-key-secret
password=plain-password
proxy_password=underscored-password
client_secret: "oauth-client-secret"
api_key=api-key-secret
private-key = private-key-secret
Bearer loose-bearer-token
https://user:basic-url-password@example.test/path
https://example.test/callback?token=url-query-secret
'@
    $redacted = Protect-CpcvLogDetail $credentialDetail
    Assert-Cpcv ($redacted -notmatch 'authorization-secret|proxy-secret|header-key-secret|plain-password|underscored-password|oauth-client-secret|api-key-secret|private-key-secret|loose-bearer-token|basic-url-password|url-query-secret') "Expanded credential redaction retained a secret."
    Write-CpcvLog "network response: password=log-password client_secret=log-client-secret"
    $logged = Get-Content -Raw -LiteralPath $script:CpcvConfig.LogFile
    Assert-Cpcv ($logged -notmatch 'log-password|log-client-secret') "Central log writer retained a secret."
    Write-CpcvLog ("x" * 70000)
    $lastLogLine = Get-Content -LiteralPath $script:CpcvConfig.LogFile | Select-Object -Last 1
    Assert-Cpcv ($lastLogLine.Length -le 65600 -and $lastLogLine -match '\[message truncated\]$') "Central log writer did not bound a large detail."

    # Failed retries for an unchanged image reuse one content-addressed local
    # file. Different failed images are pruned immediately to the configured cap.
    $script:simulatedScenario = "mkdir-failure"
    $script:processLabels = @()
    function Invoke-CpcvProcess {
        param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label)
        $script:processLabels += $Label
        if ($script:simulatedScenario -eq "mkdir-failure" -and $Label -eq "ssh mkdir") {
            return New-CpcvTestProcessResult -Ok:$false -ExitCode 255 -StdOut "" -Detail "password=network-secret"
        }
        if ($script:simulatedScenario -eq "latest-failure" -and $Label -eq "ssh update latest") {
            return New-CpcvTestProcessResult -Ok:$false -ExitCode 255 -StdOut "" -Detail "client_secret=latest-secret"
        }
        return New-CpcvTestProcessResult
    }

    $script:currentClipboardBytes = [byte[]](137,80,78,71,13,10,26,10,1,2,3)
    function Get-ClipboardImageBytes { return $script:currentClipboardBytes }
    1..3 | ForEach-Object {
        $failed = Publish-ClipboardImage -Force
        Assert-Cpcv ($failed.Reason -eq "ssh-mkdir-failed") "Simulated mkdir failure was not reported."
    }
    $sameHashFiles = @(Get-ChildItem -LiteralPath $script:CpcvConfig.LocalCache -Filter "clip-*.png" -File)
    Assert-Cpcv ($sameHashFiles.Count -eq 1) "Repeated failed retries created more than one cache file."
    Assert-Cpcv (-not (Test-Path $script:CpcvConfig.StateFile)) "Failed upload advanced the retry state."

    foreach ($suffix in 4..6) {
        $script:currentClipboardBytes = [byte[]](137,80,78,71,13,10,26,10,1,2,$suffix)
        $failed = Publish-ClipboardImage -Force
        Assert-Cpcv ($failed.Reason -eq "ssh-mkdir-failed") "Failed upload scenario changed unexpectedly."
    }
    $boundedCacheFiles = @(Get-ChildItem -LiteralPath $script:CpcvConfig.LocalCache -Filter "clip-*.png" -File)
    Assert-Cpcv ($boundedCacheFiles.Count -le $script:CpcvConfig.MaxCacheFiles) "Failed uploads exceeded the configured cache cap."
    $currentHashFile = Join-Path $script:CpcvConfig.LocalCache ("clip-$(Get-BytesHash -Bytes $script:currentClipboardBytes).png")
    Assert-Cpcv (Test-Path $currentHashFile) "Cache pruning removed the active retry image."

    # Byte pruning remains active even when a user intentionally disables the
    # optional file-count cap.  This bounds disk use by large failures too.
    Get-ChildItem -LiteralPath $script:CpcvConfig.LocalCache -Filter "clip-*.png" -File | Remove-Item -Force
    $script:CpcvConfig.MaxCacheFiles = 0
    $script:CpcvConfig.MaxCacheBytes = 12
    1..3 | ForEach-Object {
        $path = Join-Path $script:CpcvConfig.LocalCache ("clip-byte-$_.png")
        [IO.File]::WriteAllBytes($path, [byte[]](1,2,3,4,5,6,7,8))
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds($_ * -1)
    }
    Prune-CpcvCache
    $byteBounded = @(Get-ChildItem -LiteralPath $script:CpcvConfig.LocalCache -Filter "clip-*.png" -File)
    [int64]$byteBoundedTotal = @($byteBounded | Measure-Object -Property Length -Sum).Sum
    Assert-Cpcv ($byteBoundedTotal -le 12) "Byte cache pruning did not enforce MaxCacheBytes with file-count pruning disabled."
    $script:CpcvConfig.MaxCacheFiles = 2
    $script:CpcvConfig.MaxCacheBytes = 8388608

    # Oversized clipboard data is refused before it creates a cache copy or
    # launches a subprocess.
    $script:CpcvConfig.MaxImageBytes = 16
    $script:currentClipboardBytes = [byte[]](1..17)
    $script:processLabels = @()
    $tooLarge = Publish-ClipboardImage -Force
    Assert-Cpcv ($tooLarge.Reason -eq "image-too-large") "Oversized clipboard image was accepted."
    Assert-Cpcv ($script:processLabels.Count -eq 0) "Oversized clipboard image launched a subprocess."
    $script:CpcvConfig.MaxImageBytes = 1048576

    # A remote latest-link failure is an upload failure: local latest/state must
    # remain untouched so the watcher will retry after connectivity recovers.
    Reset-CpcvTestUploadState
    $script:currentClipboardBytes = [byte[]](137,80,78,71,13,10,26,10,9,8,7)
    $script:simulatedScenario = "latest-failure"
    $script:processLabels = @()
    $latestFailure = Publish-ClipboardImage -Force
    Assert-Cpcv ($latestFailure.Reason -eq "ssh-latest-failed") "Latest-link failure was not returned as an upload failure."
    Assert-Cpcv (-not (Test-Path $script:CpcvConfig.StateFile)) "Latest-link failure advanced the hash state."
    Assert-Cpcv (-not (Test-Path $script:CpcvConfig.LastRemotePathFile)) "Latest-link failure advanced the remote path state."
    Assert-Cpcv (-not (Test-Path (Join-Path $script:CpcvConfig.LocalCache "latest.png"))) "Latest-link failure refreshed local latest.png."
    Assert-Cpcv ($script:processLabels -contains "ssh update latest") "Latest-link failure test never reached the latest operation."

    $script:simulatedScenario = "success"
    $recoveredUpload = Publish-ClipboardImage -Force
    Assert-Cpcv ($recoveredUpload.Ok -and $recoveredUpload.Reason -eq "uploaded") "Upload did not recover after latest-link failure."
    Assert-Cpcv (Test-Path $script:CpcvConfig.StateFile) "Recovered upload did not persist state."
    Assert-Cpcv (Test-Path (Join-Path $script:CpcvConfig.LocalCache "latest.png")) "Recovered upload did not refresh local latest.png."

    # If the user copies a newer image before the latest operation begins, do
    # not update remote latest or overwrite their clipboard with an old path.
    Reset-CpcvTestUploadState
    $script:initialClipboardBytes = [byte[]](137,80,78,71,13,10,26,10,11,12,13)
    $script:newerClipboardBytes = [byte[]](137,80,78,71,13,10,26,10,21,22,23)
    $script:clipboardReadCount = 0
    function Get-ClipboardImageBytes {
        $script:clipboardReadCount++
        if ($script:clipboardReadCount -eq 1) { return $script:initialClipboardBytes }
        return $script:newerClipboardBytes
    }
    $script:setClipboardCalls = 0
    function Set-Clipboard { param($Value) $script:setClipboardCalls++ }
    $script:processLabels = @()
    $supersededBeforeLatest = Publish-ClipboardImage -CopyPath -Force
    Assert-Cpcv ($supersededBeforeLatest.Reason -eq "clipboard-changed") "Newer clipboard image did not supersede stale upload."
    Assert-Cpcv (-not ($script:processLabels -contains "ssh update latest")) "Stale upload updated remote latest after a newer clipboard image appeared."
    Assert-Cpcv (-not (Test-Path $script:CpcvConfig.StateFile)) "Superseded upload advanced retry state."
    Assert-Cpcv ($script:setClipboardCalls -eq 0) "Superseded upload overwrote the newer clipboard with an old path."

    # Also preserve retry state when the clipboard changes during the small
    # interval while the remote latest command is completing.
    Reset-CpcvTestUploadState
    $script:clipboardReadCount = 0
    function Get-ClipboardImageBytes {
        $script:clipboardReadCount++
        if ($script:clipboardReadCount -le 2) { return $script:initialClipboardBytes }
        return $script:newerClipboardBytes
    }
    $script:processLabels = @()
    $supersededAfterLatest = Publish-ClipboardImage -CopyPath -Force
    Assert-Cpcv ($supersededAfterLatest.Reason -eq "clipboard-changed") "Clipboard change during latest update was not detected."
    Assert-Cpcv ($script:processLabels -contains "ssh update latest") "During-latest supersession test did not reach the latest operation."
    Assert-Cpcv (-not (Test-Path $script:CpcvConfig.StateFile)) "During-latest supersession advanced retry state."
    Assert-Cpcv (-not (Test-Path (Join-Path $script:CpcvConfig.LocalCache "latest.png"))) "During-latest supersession refreshed local latest.png."
    Assert-Cpcv ($script:setClipboardCalls -eq 0) "During-latest supersession overwrote the newer clipboard with an old path."
}
finally {
    $script:CpcvConfig = $originalConfig
    if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "PASS: strict config, exact guardian matching, heartbeat PID validation, redaction, bounded failed-upload cache, latest-link retry, and stale clipboard protection"
