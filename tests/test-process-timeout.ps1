# Safe local verification for the process wrapper and upload decision paths.
# It never contacts an SSH host and writes only to a unique directory under TEMP.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\imgpaste-core.ps1")

function Assert-ImgPaste([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$quick = Invoke-ImgPasteProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "Write-Output healthy") -TimeoutSeconds 5 -Label "quick smoke test"
Assert-ImgPaste $quick.Ok "Quick process test failed: $($quick.Detail)"
Assert-ImgPaste ($quick.StdOut.Trim() -eq "healthy") "Quick process output was not captured."

$large = Invoke-ImgPasteProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "[Console]::Out.Write('x' * 200000)") -TimeoutSeconds 5 -Label "large-output smoke test"
Assert-ImgPaste ($large.Ok -and $large.OutputTruncated) "Large subprocess output was not marked truncated."
Assert-ImgPaste ($large.StdOut.Length -le $script:ImgPasteConfig.MaxCommandOutputBytes) "Large subprocess output exceeded the configured bound."
$redacted = Protect-ImgPasteLogDetail "Authorization: Bearer secret-value`nhttps://example.test/callback?token=super-secret"
Assert-ImgPaste ($redacted -notmatch 'secret-value|super-secret') "Credential-like subprocess text was not redacted for logging."
Assert-ImgPaste ((Get-ImgPasteRetryDelay 1 2) -eq 4 -and (Get-ImgPasteRetryDelay 8 2) -eq 60) "Failure retry backoff is not capped as expected."

$validConfig = New-ImgPasteDefaultConfig
$validConfig.HostAlias = "example-host"
Assert-ImgPaste (-not (Test-ImgPasteConfigValue $validConfig)) "A valid generic SSH alias was rejected."
$badHost = New-ImgPasteDefaultConfig
$badHost.HostAlias = "-oProxyCommand=bad"
Assert-ImgPaste ((Test-ImgPasteConfigValue $badHost) -match "HostAlias") "Option-like SSH host was accepted."
$badDir = New-ImgPasteDefaultConfig
$badDir.HostAlias = "example-host"
$badDir.RemoteDir = "../unsafe"
Assert-ImgPaste ((Test-ImgPasteConfigValue $badDir) -match "RemoteDir") "Traversal remote directory was accepted."
Assert-ImgPaste (Test-ImgPasteRemotePath "/home/tester/clipboard-images/latest.png") "Safe remote path was rejected."
Assert-ImgPaste (-not (Test-ImgPasteRemotePath "/tmp/path;not-safe")) "Unsafe remote output path was accepted."

$configProbe = Join-Path $env:TEMP ("imgpaste-config-{0}.psd1" -f [Guid]::NewGuid())
$originalConfigPath = $script:ImgPasteConfigPath
try {
    @'
@{
    HostAlias = "example-host"
    RemoteDir = "screens/latest"
    RemoteHome = "/srv/example"
}
'@ | Set-Content -LiteralPath $configProbe -NoNewline
    $script:ImgPasteConfigPath = $configProbe
    $loadedConfig = Get-ImgPasteConfig
    Assert-ImgPaste (-not $loadedConfig.ConfigError -and $loadedConfig.HostAlias -eq "example-host") "Valid local config did not load."
    Assert-ImgPaste ($loadedConfig.RemoteDir -eq "screens/latest" -and $loadedConfig.RemoteHome -eq "/srv/example") "Loaded config values were not preserved."

    @'
@{
    HostAlias = "example-host"
    RemoteDir = "../../unsafe"
}
'@ | Set-Content -LiteralPath $configProbe -NoNewline
    $invalidConfig = Get-ImgPasteConfig
    Assert-ImgPaste ($invalidConfig.ConfigError -match "RemoteDir") "Unsafe local config was accepted."
}
finally {
    $script:ImgPasteConfigPath = $originalConfigPath
    Remove-Item -LiteralPath $configProbe -Force -ErrorAction SilentlyContinue
}

# A parent PowerShell starts a child PowerShell. The parent script uses an
# explicit quoted command line so this check remains valid from a checkout
# whose path contains spaces. The hard timeout must kill both processes.
$childPidFile = Join-Path $env:TEMP ("imgpaste-child-{0}.txt" -f [Guid]::NewGuid())
$childScript = Join-Path $PSScriptRoot "child-sleeper.ps1"
$parentScript = Join-Path $PSScriptRoot "child-tree-parent.ps1"
$timer = [Diagnostics.Stopwatch]::StartNew()
$timeout = Invoke-ImgPasteProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-File", $parentScript, "-ChildScript", $childScript, "-PidFile", $childPidFile) -TimeoutSeconds 3 -Label "process-tree timeout test"
$timer.Stop()
Assert-ImgPaste $timeout.TimedOut "Expected process-tree command to time out."
Assert-ImgPaste ($timer.Elapsed.TotalSeconds -lt 9) "Timeout took too long: $($timer.Elapsed.TotalSeconds)s"
Start-Sleep -Milliseconds 500
Assert-ImgPaste (Test-Path $childPidFile) "Child process did not publish its PID; process-tree test did not run."
$childPid = [int](Get-Content -Raw $childPidFile)
if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) {
    Stop-ImgPasteProcessTree -ProcessId $childPid
    throw "Child process $childPid survived the timeout tree cleanup."
}
Remove-Item -LiteralPath $childPidFile -Force

# Simulate clipboard states and SSH outcomes without calling the network.
$tempRoot = Join-Path $env:TEMP ("imgpaste-test-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$originalConfig = $script:ImgPasteConfig
try {
    $script:ImgPasteConfig = @{
        HostAlias = "example-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); LogFile = (Join-Path $tempRoot "watch.log")
        HeartbeatFile = (Join-Path $tempRoot "watch.heartbeat"); CommandTimeoutSeconds = 3; MaxCommandOutputBytes = 65536
        PollIntervalSeconds = 2; WatchdogCheckSeconds = 15; WatchdogStaleSeconds = 120
        MaxLogBytes = 1048576; MaxCacheFiles = 200; MaxCacheBytes = 268435456; MaxImageBytes = 52428800; ConfigError = ""
    }

    Set-ImgPasteAtomicText -Path $script:ImgPasteConfig.HeartbeatFile -Value "2026-01-01T00:00:00.0000000Z pid=123 checking"
    Assert-ImgPaste (Test-ImgPasteHeartbeat -Path $script:ImgPasteConfig.HeartbeatFile -ExpectedProcessId 123) "Atomic heartbeat write was not readable/valid."

    Set-Content -Path $script:ImgPasteConfig.LogFile -Value "https://example.test/callback?token=legacy-secret" -NoNewline
    Sanitize-ImgPasteLog
    Assert-ImgPaste ((Get-Content -Raw $script:ImgPasteConfig.LogFile) -notmatch 'legacy-secret') "Legacy log sanitizer retained a credential-like query."

    function Get-ClipboardImageBytes { return $null }
    $noImage = Publish-ClipboardImage
    Assert-ImgPaste ($noImage.Reason -eq "no-image") "No-image clipboard path was not handled."

    function Get-ClipboardImageBytes { throw "simulated clipboard busy" }
    $busyCaught = $false
    try { Publish-ClipboardImage | Out-Null } catch { $busyCaught = $_.Exception.Message -match "simulated clipboard busy" }
    Assert-ImgPaste $busyCaught "Clipboard-busy error did not propagate for the watcher to log/retry."

    function Get-ClipboardImageBytes { return [byte[]](137,80,78,71,13,10,26,10,0,1,2,3) }
    $script:simulatedNetworkUp = $false
    function Invoke-ImgPasteProcess {
        param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label)
        if (-not $script:simulatedNetworkUp) {
            return @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ""; StdErr = "simulated network failure"; Detail = "https://example.test/callback?token=super-secret" }
        }
        return @{ Ok = $true; TimedOut = $false; ExitCode = 0; StdOut = "/home/tester/clipboard-images/clip-test.png`n"; StdErr = ""; Detail = "" }
    }
    $failedUpload = Publish-ClipboardImage -Force
    Assert-ImgPaste ($failedUpload.Reason -eq "ssh-mkdir-failed") "Simulated SSH failure was not reported."
    Assert-ImgPaste (-not (Test-Path $script:ImgPasteConfig.StateFile)) "Failed upload incorrectly advanced the last-upload state."
    Assert-ImgPaste ((Get-Content -Raw $script:ImgPasteConfig.LogFile) -notmatch 'super-secret') "Sensitive proxy/auth text reached the log."

    $script:simulatedNetworkUp = $true
    $recoveredUpload = Publish-ClipboardImage -Force
    Assert-ImgPaste ($recoveredUpload.Ok -and $recoveredUpload.Reason -eq "uploaded") "Simulated network recovery did not upload."
    Assert-ImgPaste (Test-Path (Join-Path $script:ImgPasteConfig.LocalCache "latest.png")) "Recovery did not refresh latest.png."
    Assert-ImgPaste ((Get-Content -Raw $script:ImgPasteConfig.StateFile).Length -eq 64) "Recovery did not persist the image hash."
}
finally {
    $script:ImgPasteConfig = $originalConfig
    if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "PASS: configuration validation, bounded/redacted output, retry backoff, process-tree timeout, clipboard states, SSH failure/recovery, and latest-image state"
& (Join-Path $PSScriptRoot "test-release-hardening.ps1")
