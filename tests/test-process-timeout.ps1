# Safe local verification for the process wrapper and upload decision paths.
# It never contacts an SSH host and writes only to a unique directory under TEMP.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\ctrl-ccv-core.ps1")
$script:testProcessMutexSuffix = [Guid]::NewGuid().ToString("N")
function Get-CtrlCcvMutexName { param([string]$Purpose) return "Local\CtrlCcvProcessTest-$Purpose-$script:testProcessMutexSuffix" }

function Assert-CtrlCcv([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$processProbeRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP ("ctrl-ccv-process-probes-{0}" -f [Guid]::NewGuid())))
$processProbeBoundary = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
Assert-CtrlCcv ($processProbeRoot.StartsWith($processProbeBoundary, [StringComparison]::OrdinalIgnoreCase)) "Process probe directory is outside TEMP."
$originalRuntimeConfig = $script:CtrlCcvConfig
try {
    [void][IO.Directory]::CreateDirectory($processProbeRoot)
    # Process timeouts log before the upload fixtures below are installed.
    # Give every runtime path disposable state before starting the first child.
    $script:CtrlCcvConfig = New-CtrlCcvDefaultConfig
    $script:CtrlCcvConfig.HostAlias = "process-test-host"
    $script:CtrlCcvConfig.DataRoot = $processProbeRoot
    foreach ($entry in @{
        LocalCache = "cache"; StateFile = "last-hash.txt"; LastRemotePathFile = "last-remote-path.txt"
        UploadStatusFile = "upload-status.txt"; LogFile = "watch.log"; HeartbeatFile = "watch.heartbeat"
    }.GetEnumerator()) {
        $script:CtrlCcvConfig[$entry.Key] = Join-Path $processProbeRoot $entry.Value
    }

$quick = Invoke-CtrlCcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "Write-Output healthy") -TimeoutSeconds 5 -Label "quick smoke test"
Assert-CtrlCcv $quick.Ok "Quick process test failed: $($quick.Detail)"
Assert-CtrlCcv ($quick.StdOut.Trim() -eq "healthy") "Quick process output was not captured."

$large = Invoke-CtrlCcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "[Console]::Out.Write('x' * 200000)") -TimeoutSeconds 5 -Label "large-output smoke test"
Assert-CtrlCcv ($large.Ok -and $large.OutputTruncated) "Large subprocess output was not marked truncated."
Assert-CtrlCcv ($large.StdOut.Length -le $script:CtrlCcvConfig.MaxCommandOutputBytes) "Large subprocess output exceeded the configured bound."
$redacted = Protect-CtrlCcvLogDetail "Authorization: Bearer secret-value`nhttps://example.test/callback?token=super-secret"
Assert-CtrlCcv ($redacted -notmatch 'secret-value|super-secret') "Credential-like subprocess text was not redacted for logging."
Assert-CtrlCcv ((Get-CtrlCcvRetryDelay 1 2) -eq 4 -and (Get-CtrlCcvRetryDelay 8 2) -eq 60) "Failure retry backoff is not capped as expected."
$bannerFailure = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Connection timed out during banner exchange'; Detail = 'synthetic banner timeout' }
Assert-CtrlCcv ((Get-CtrlCcvSshConnectionFailureKind -ProcessResult $bannerFailure) -eq 'connect-timeout') "A banner-exchange timeout was not classified as a controlled connection timeout."
$authFailure = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Permission denied (publickey).'; Detail = '' }
Assert-CtrlCcv ((Get-CtrlCcvSshConnectionFailureKind -ProcessResult $authFailure) -eq 'authentication') "A non-interactive SSH sign-in failure was not classified safely."
$interactiveAuthFailure = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Permission denied (publickey,keyboard-interactive).'; Detail = '' }
Assert-CtrlCcv ((Get-CtrlCcvSshConnectionFailureKind -ProcessResult $interactiveAuthFailure) -eq 'authentication') "An interactive/MFA-style SSH sign-in failure was not classified safely."
$tooManyAuthFailures = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Received disconnect: Too many authentication failures'; Detail = '' }
Assert-CtrlCcv ((Get-CtrlCcvSshConnectionFailureKind -ProcessResult $tooManyAuthFailures) -eq 'authentication') "An SSH agent authentication-limit failure was not classified safely."
$noAuthMethods = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'No supported authentication methods available'; Detail = '' }
Assert-CtrlCcv ((Get-CtrlCcvSshConnectionFailureKind -ProcessResult $noAuthMethods) -eq 'authentication') "An unsupported SSH authentication-method failure was not classified safely."
$remoteFolderPermission = @{ Ok = $false; TimedOut = $false; ExitCode = 1; StdOut = ''; StdErr = "mkdir: cannot create directory '/home/example/clipboard-images': Permission denied"; Detail = '' }
Assert-CtrlCcv ((Get-CtrlCcvSshConnectionFailureKind -ProcessResult $remoteFolderPermission) -ne 'authentication') "A remote-folder permission failure was incorrectly classified as SSH authentication."
Assert-CtrlCcv ((Get-CtrlCcvSshMkdirFailureReason -ProcessResult $remoteFolderPermission) -eq 'ssh-mkdir-remote-folder-failed') "A remote-folder permission failure was not given its own controlled status token."
$authPresentation = Get-CtrlCcvSshConnectionCheckPresentation -FailureKind 'authentication'
Assert-CtrlCcv ($authPresentation.Detail -match 'one-time-code' -and $authPresentation.NextStep -match 'normal SSH workflow') "Authentication guidance did not explain an interactive or MFA-style sign-in safely."
$hostKeyFailure = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ''; StdErr = 'Host key verification failed.'; Detail = '' }
Assert-CtrlCcv ((Get-CtrlCcvSshConnectionFailureKind -ProcessResult $hostKeyFailure) -eq 'host-key') "An SSH host-key failure was not classified safely."
$sshOptions = @(Get-CtrlCcvSshOptions)
Assert-CtrlCcv (($sshOptions -join ' ') -eq '-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ServerAliveInterval=3 -o ServerAliveCountMax=2') "The shared unattended SSH option set changed unexpectedly."

# The separately owned tray helper must emit only a compact category, even
# before a valid connection exists. Point its child process at an invalid local
# config so this contract test cannot contact SSH or change remote state.
$connectionHelper = Join-Path (Split-Path $PSScriptRoot -Parent) 'ctrl-ccv-connection-check.ps1'
Assert-CtrlCcv (Test-Path -LiteralPath $connectionHelper -PathType Leaf) "The owned tray connection-check helper is missing."
$helperConfigPath = Join-Path $processProbeRoot "helper-config.psd1"
$priorHelperConfig = $env:CTRL_CCV_CONFIG
try {
    [IO.File]::WriteAllText($helperConfigPath, "@{}`n", [Text.UTF8Encoding]::new($false))
    $env:CTRL_CCV_CONFIG = $helperConfigPath
    $helperOutput = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $connectionHelper 2>&1 | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-CtrlCcv ($LASTEXITCODE -eq 0 -and $helperOutput.Count -eq 1) "The owned tray connection-check helper did not emit one controlled result."
    $helperResult = $helperOutput[0] | ConvertFrom-Json -ErrorAction Stop
    Assert-CtrlCcv ([string]$helperResult.Version -eq '1' -and [string]$helperResult.FailureKind -eq 'configuration') "The owned tray connection-check helper exposed an unexpected result category."
}
finally {
    if ($null -eq $priorHelperConfig) { Remove-Item Env:CTRL_CCV_CONFIG -ErrorAction SilentlyContinue } else { $env:CTRL_CCV_CONFIG = $priorHelperConfig }
    Remove-Item -LiteralPath $helperConfigPath -Force -ErrorAction SilentlyContinue
}

$validConfig = New-CtrlCcvDefaultConfig
$validConfig.HostAlias = "example-host"
Assert-CtrlCcv (-not (Test-CtrlCcvConfigValue $validConfig)) "A valid generic SSH alias was rejected."
$badHost = New-CtrlCcvDefaultConfig
$badHost.HostAlias = "-oProxyCommand=bad"
Assert-CtrlCcv ((Test-CtrlCcvConfigValue $badHost) -match "HostAlias") "Option-like SSH host was accepted."
$badDir = New-CtrlCcvDefaultConfig
$badDir.HostAlias = "example-host"
$badDir.RemoteDir = "../unsafe"
Assert-CtrlCcv ((Test-CtrlCcvConfigValue $badDir) -match "RemoteDir") "Traversal remote directory was accepted."
Assert-CtrlCcv (Test-CtrlCcvRemotePath "/home/tester/clipboard-images/latest.png") "Safe remote path was rejected."
Assert-CtrlCcv (-not (Test-CtrlCcvRemotePath "/tmp/path;not-safe")) "Unsafe remote output path was accepted."

$configProbe = Join-Path $processProbeRoot "config-probe.psd1"
$originalConfigPath = $script:CtrlCcvConfigPath
try {
    @'
@{
    HostAlias = "example-host"
    RemoteDir = "screens/latest"
    RemoteHome = "/srv/example"
}
'@ | Set-Content -LiteralPath $configProbe -NoNewline
    $script:CtrlCcvConfigPath = $configProbe
    $loadedConfig = Get-CtrlCcvConfig
    Assert-CtrlCcv (-not $loadedConfig.ConfigError -and $loadedConfig.HostAlias -eq "example-host") "Valid local config did not load."
    Assert-CtrlCcv ($loadedConfig.RemoteDir -eq "screens/latest" -and $loadedConfig.RemoteHome -eq "/srv/example") "Loaded config values were not preserved."

    @'
@{
    HostAlias = "example-host"
    RemoteDir = "../../unsafe"
}
'@ | Set-Content -LiteralPath $configProbe -NoNewline
    $invalidConfig = Get-CtrlCcvConfig
    Assert-CtrlCcv ($invalidConfig.ConfigError -match "RemoteDir") "Unsafe local config was accepted."
}
finally {
    $script:CtrlCcvConfigPath = $originalConfigPath
    Remove-Item -LiteralPath $configProbe -Force -ErrorAction SilentlyContinue
}

# A parent PowerShell starts a child PowerShell. The parent script uses an
# explicit quoted command line so this check remains valid from a checkout
# whose path contains spaces. The hard timeout must kill both processes.
$childPidFile = Join-Path $processProbeRoot "child-pid.txt"
$childScript = Join-Path $PSScriptRoot "child-sleeper.ps1"
$parentScript = Join-Path $PSScriptRoot "child-tree-parent.ps1"
$timer = [Diagnostics.Stopwatch]::StartNew()
$timeout = Invoke-CtrlCcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-File", $parentScript, "-ChildScript", $childScript, "-PidFile", $childPidFile) -TimeoutSeconds 3 -Label "process-tree timeout test"
$timer.Stop()
Assert-CtrlCcv $timeout.TimedOut "Expected process-tree command to time out."
Assert-CtrlCcv ((Get-Content -LiteralPath $script:CtrlCcvConfig.LogFile -Raw) -match 'process-tree timeout test') "The process timeout diagnostic was not written to disposable runtime state."
Assert-CtrlCcv ($timer.Elapsed.TotalSeconds -lt 9) "Timeout took too long: $($timer.Elapsed.TotalSeconds)s"
Start-Sleep -Milliseconds 500
Assert-CtrlCcv (Test-Path $childPidFile) "Child process did not publish its PID; process-tree test did not run."
$childPid = [int](Get-Content -Raw $childPidFile)
if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) {
    Stop-CtrlCcvProcessTree -ProcessId $childPid
    throw "Child process $childPid survived the timeout tree cleanup."
}
Remove-Item -LiteralPath $childPidFile -Force

# Simulate clipboard states and SSH outcomes without calling the network.
$tempRoot = Join-Path $processProbeRoot "upload"
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$originalConfig = $script:CtrlCcvConfig
try {
    $script:CtrlCcvConfig = @{
        HostAlias = "example-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); LogFile = (Join-Path $tempRoot "watch.log")
        UploadStatusFile = (Join-Path $tempRoot "upload-status.txt")
        HeartbeatFile = (Join-Path $tempRoot "watch.heartbeat"); CommandTimeoutSeconds = 3; MaxCommandOutputBytes = 65536
        PollIntervalSeconds = 2; WatchdogCheckSeconds = 15; WatchdogStaleSeconds = 120
        MaxLogBytes = 1048576; MaxCacheFiles = 200; MaxCacheBytes = 268435456; MaxImageBytes = 52428800; ConfigError = ""
    }

    Set-CtrlCcvAtomicText -Path $script:CtrlCcvConfig.HeartbeatFile -Value "2026-01-01T00:00:00.0000000Z pid=123 checking"
    Assert-CtrlCcv (Test-CtrlCcvHeartbeat -Path $script:CtrlCcvConfig.HeartbeatFile -ExpectedProcessId 123) "Atomic heartbeat write was not readable/valid."

    Set-Content -Path $script:CtrlCcvConfig.LogFile -Value "https://example.test/callback?token=legacy-secret" -NoNewline
    Sanitize-CtrlCcvLog
    Assert-CtrlCcv ((Get-Content -Raw $script:CtrlCcvConfig.LogFile) -notmatch 'legacy-secret') "Legacy log sanitizer retained a credential-like query."

    function Get-ClipboardImageBytes { return $null }
    $noImage = Publish-ClipboardImage
    Assert-CtrlCcv ($noImage.Reason -eq "no-image") "No-image clipboard path was not handled."

    function Get-ClipboardImageBytes { throw [System.Runtime.InteropServices.ExternalException]::new("simulated clipboard busy", -2147221040) }
    $busy = Publish-ClipboardImage
    Assert-CtrlCcv (-not $busy.Ok -and $busy.Reason -eq "clipboard-busy") "Clipboard contention did not return a controlled retry result."

    function Get-ClipboardImageBytes { return [byte[]](137,80,78,71,13,10,26,10,0,1,2,3) }
    $script:simulatedNetworkUp = $false
    function Invoke-CtrlCcvProcess {
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
            $stdout = "CTRL_CCV_UPLOAD_OK /home/tester/clipboard-images/$leaf`n"
        }
        return @{ Ok = $true; TimedOut = $false; ExitCode = 0; StdOut = $stdout; StdErr = ""; Detail = "" }
    }
    $failedUpload = Publish-ClipboardImage -Force
    Assert-CtrlCcv ($failedUpload.Reason -eq "ssh-mkdir-failed") "Simulated SSH failure was not reported."
    Assert-CtrlCcv (-not (Test-Path $script:CtrlCcvConfig.StateFile)) "Failed upload incorrectly advanced the last-upload state."
    Assert-CtrlCcv ((Get-Content -Raw $script:CtrlCcvConfig.LogFile) -notmatch 'super-secret') "Sensitive proxy/auth text reached the log."
    $failedUploadStatus = Get-CtrlCcvUploadStatusInfo -Path $script:CtrlCcvConfig.UploadStatusFile
    Assert-CtrlCcv ($failedUploadStatus -and $failedUploadStatus.Result -eq "failed" -and $failedUploadStatus.Reason -eq "ssh-mkdir-failed") "A failed upload did not persist a controlled tray status."
    Assert-CtrlCcv ((Get-Content -Raw $script:CtrlCcvConfig.UploadStatusFile) -notmatch 'super-secret|example-host|clipboard-images') "Upload status exposed diagnostic or configuration detail."

    $stateBeforeConnectionCheck = Test-Path -LiteralPath $script:CtrlCcvConfig.StateFile
    $pathBeforeConnectionCheck = Test-Path -LiteralPath $script:CtrlCcvConfig.LastRemotePathFile
    $connectionCheck = Get-CtrlCcvSshConnectionCheckResult
    $connectionCheckText = "$($connectionCheck.Summary) $($connectionCheck.Detail) $($connectionCheck.NextStep)"
    Assert-CtrlCcv (-not $connectionCheck.Ok -and $connectionCheck.FailureKind -eq 'connect-timeout') "The unattended SSH check did not map a banner timeout to a safe customer category."
    Assert-CtrlCcv ($connectionCheckText -match 'unattended SSH' -and $connectionCheckText -notmatch 'super-secret|example-host|clipboard-images|example\.test') "The unattended SSH check exposed raw SSH or configuration data."
    Assert-CtrlCcv ((@($script:connectionCheckArguments) -join ' ') -eq ' -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 example-host true'.Trim()) "The unattended SSH check did not use the same unattended SSH settings and fixed read-only command."
    Assert-CtrlCcv ((Test-Path -LiteralPath $script:CtrlCcvConfig.StateFile) -eq $stateBeforeConnectionCheck -and (Test-Path -LiteralPath $script:CtrlCcvConfig.LastRemotePathFile) -eq $pathBeforeConnectionCheck) "The unattended SSH check changed upload state."

    $script:simulatedNetworkUp = $true
    $recoveredUpload = Publish-ClipboardImage -Force
    Assert-CtrlCcv ($recoveredUpload.Ok -and $recoveredUpload.Reason -eq "uploaded") "Simulated network recovery did not upload."
    Assert-CtrlCcv (Test-Path (Join-Path $script:CtrlCcvConfig.LocalCache "latest.png")) "Recovery did not refresh latest.png."
    Assert-CtrlCcv ((Get-Content -Raw $script:CtrlCcvConfig.StateFile).Length -eq 64) "Recovery did not persist the image hash."
    $recoveredUploadStatus = Get-CtrlCcvUploadStatusInfo -Path $script:CtrlCcvConfig.UploadStatusFile
    Assert-CtrlCcv ($recoveredUploadStatus -and $recoveredUploadStatus.Result -eq "succeeded") "A recovered upload did not clear the tray failure status."
}
finally {
    $script:CtrlCcvConfig = $originalConfig
}

Write-Host "PASS: configuration validation, bounded/redacted output, retry backoff, process-tree timeout, clipboard states, SSH failure/recovery, and latest-image state"
& (Join-Path $PSScriptRoot "test-release-hardening.ps1")
}
finally {
    $script:CtrlCcvConfig = $originalRuntimeConfig
    $resolvedProbeRoot = [IO.Path]::GetFullPath($processProbeRoot)
    Assert-CtrlCcv ($resolvedProbeRoot.StartsWith($processProbeBoundary, [StringComparison]::OrdinalIgnoreCase)) "Process probe cleanup escaped TEMP."
    if (Test-Path -LiteralPath $resolvedProbeRoot) { Remove-Item -LiteralPath $resolvedProbeRoot -Recurse -Force }
}
