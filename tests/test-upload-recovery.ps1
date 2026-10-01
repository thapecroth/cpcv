# Network-free upload regression tests. SSH, SCP, Access recovery and clipboard
# access are replaced before any upload; all state belongs to a unique TEMP root.
param([string]$BashPath = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\cpcv-core.ps1")

function Assert-CpcvUpload([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path $env:TEMP ("cpcv-upload-recovery-{0}" -f [Guid]::NewGuid().ToString("N"))
$originalConfig = $script:CpcvConfig
$script:realUploadProcess = ${function:Invoke-CpcvProcess}
$script:uploadBytes = [byte[]](137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3)
$script:uploadStages = @("ssh mkdir", "scp upload", "ssh update latest")
$script:uploadFailureReasons = @("ssh-mkdir-timeout", "scp-timeout", "ssh-latest-timeout")
$script:uploadTestMutex = "Local\Cpcv-UploadTest-$([Guid]::NewGuid().ToString('N'))"
$script:uploadTestBash = $BashPath
if (-not $script:uploadTestBash) {
    foreach ($gitRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA "Programs"))) {
        if (-not $gitRoot) { continue }
        $candidate = Join-Path $gitRoot "Git\bin\bash.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:uploadTestBash = $candidate; break }
    }
}
if ($script:uploadTestBash) {
    Assert-CpcvUpload (Test-Path -LiteralPath $script:uploadTestBash -PathType Leaf) "The requested optional Bash fixture executable does not exist."
}

function ConvertTo-CpcvUploadShellLiteral {
    param([string]$Value)
    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $escapedQuote = "$singleQuote$doubleQuote$singleQuote$doubleQuote$singleQuote"
    return ($singleQuote + $Value.Replace($singleQuote, $escapedQuote) + $singleQuote)
}

function Invoke-CpcvUploadShellFixture {
    param([string]$Command, [string]$Mode, [string]$Base)
    # The generated command uses a fixture-specific variable in place of HOME,
    # leaving the actual user/process home and remote configuration untouched.
    $fixtureHome = Join-Path $testRoot ("remote-home-" + [char]0x6D4B + [char]0x8BD5 + "-" + [Guid]::NewGuid().ToString("N"))
    $fixtureImages = Join-Path $fixtureHome "clipboard-images"
    [void][IO.Directory]::CreateDirectory($fixtureImages)
    [IO.File]::WriteAllBytes((Join-Path $fixtureImages $Base), $script:uploadBytes)
    if ($Mode -eq "failed-ln") { [void][IO.Directory]::CreateDirectory((Join-Path $fixtureImages "latest.png")) }
    $fixtureCommand = "cd -- $(ConvertTo-CpcvUploadShellLiteral ($fixtureImages.Replace('\', '/'))) && CPCV_TEST_HOME=`$(dirname `"`$PWD`"); "
    # Git Bash otherwise emulates ln -s by copying. Its system-link format
    # preserves readlink semantics here without requiring Windows privileges;
    # this setting belongs only to the newly owned fixture shell and children.
    $fixtureCommand += 'MSYS=winsymlinks:sys; export MSYS; '
    if ($Mode -eq "bsd-unicode-home") {
        $fixtureCommand += 'readlink() { if [ "$1" = "-f" ]; then return 1; else command readlink "$@"; fi; }; '
    }
    elseif ($Mode -eq "ascii-resolved") {
        $canonical = ConvertTo-CpcvUploadShellLiteral "/home/tester/clipboard-images/$Base"
        $fixtureCommand += 'readlink() { if [ "$1" = "-f" ]; then printf ''%s\n'' ' + $canonical + '; else command readlink "$@"; fi; }; '
    }
    $fixtureCommand += $Command.Replace('$HOME', '$CPCV_TEST_HOME')
    $script:uploadShellResult = & $script:realUploadProcess -FilePath $script:uploadTestBash -Arguments @("--noprofile", "--norc", "-c", $fixtureCommand) -TimeoutSeconds 5 -Label "local publication shell fixture"
    return $script:uploadShellResult
}

function Get-ClipboardImageBytes { return $script:uploadBytes }
function Get-CpcvMutexName { param([string]$Purpose) return "$script:uploadTestMutex-$Purpose" }
function Set-Clipboard { throw "Upload recovery tests must never change the native clipboard." }
function Invoke-CpcvProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label)
    Assert-CpcvUpload ($Label -in $script:uploadStages) "An unexpected external command escaped the fake transport."
    Assert-CpcvUpload ($FilePath -eq $(if ($Label -eq "scp upload") { "scp" } else { "ssh" })) "Upload used an unexpected transport executable."
    $script:uploadCalls.Add([pscustomobject]@{ Label = $Label; Arguments = @($Arguments); Heartbeat = (Get-CpcvHeartbeatInfo -Path $script:CpcvConfig.HeartbeatFile) })
    if ($Label -eq $script:uploadFailureStage) { return $script:uploadFailureResult }
    $output = ""
    if ($Label -eq "ssh update latest") {
        $hash = Get-BytesHash -Bytes $script:uploadBytes
        $marker = "CPCV_UPLOAD_OK /home/tester/clipboard-images/clip-$hash.png"
        if ($script:uploadAckMode -in @("unicode-home", "bsd-unicode-home", "ascii-resolved", "failed-ln")) {
            return (Invoke-CpcvUploadShellFixture -Command $Arguments[-1] -Mode $script:uploadAckMode -Base "clip-$hash.png")
        }
        switch ($script:uploadAckMode) {
            "missing" { $output = "/home/tester/clipboard-images/clip-$hash.png`n" }
            "duplicate" { $output = "$marker`n$marker`n" }
            "unsafe" { $output = "CPCV_UPLOAD_OK /tmp/path;unsafe`n" }
            "wrong-image" { $output = "CPCV_UPLOAD_OK /home/tester/clipboard-images/clip-other.png`n" }
            "tilde" { $output = "CPCV_UPLOAD_OK ~/clipboard-images/clip-$hash.png`n" }
            "raw-unicode" { $output = "CPCV_UPLOAD_OK /home/$([char]0x6D4B)$([char]0x8BD5)/clipboard-images/clip-$hash.png`n" }
            default { $output = "synthetic SSH banner`n$marker`n" }
        }
    }
    return @{ Ok = $true; TimedOut = $false; ExitCode = 0; StdOut = $output; StdErr = ""; OutputTruncated = ($script:uploadAckMode -eq "truncated"); Detail = "" }
}
function Repair-CpcvCloudflareAccess {
    param($Config, [string]$FailureKind)
    $script:uploadRecoveryCalls.Add([pscustomobject]@{ FailureKind = $FailureKind; Heartbeat = (Get-CpcvHeartbeatInfo -Path $Config.HeartbeatFile) })
    if ($script:uploadRecoveryState -eq "throw") { throw "Authorization: Bearer synthetic-recovery-secret" }
    return @{ State = $script:uploadRecoveryState; Recovered = ($script:uploadRecoveryState -eq "recovered") }
}
function Reset-CpcvUploadTest {
    foreach ($path in @($script:CpcvConfig.StateFile, $script:CpcvConfig.LastRemotePathFile, $script:CpcvConfig.UploadStatusFile, (Join-Path $script:CpcvConfig.LocalCache "latest.png"))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    $script:uploadCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:uploadRecoveryCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:uploadFailureStage = ""
    $script:uploadRecoveryState = "not-applicable"
    $script:uploadAckMode = "healthy"
    $script:uploadFailureResult = @{ Ok = $false; TimedOut = $true; ExitCode = $null; StdOut = ""; StdErr = ""; OutputTruncated = $false; Detail = "Timed out; token=synthetic-transport-secret" }
    Set-CpcvAtomicText -Path $script:CpcvConfig.HeartbeatFile -Value (([datetime]::UtcNow.AddSeconds(-5).ToString("o")) + " pid=$PID checking")
}
function Assert-CpcvUploadStateUncommitted {
    Assert-CpcvUpload (-not (Test-Path -LiteralPath $script:CpcvConfig.StateFile)) "A failed upload advanced its image hash."
    Assert-CpcvUpload (-not (Test-Path -LiteralPath $script:CpcvConfig.LastRemotePathFile)) "A failed upload advanced its remote path."
    Assert-CpcvUpload (-not (Test-Path -LiteralPath (Join-Path $script:CpcvConfig.LocalCache "latest.png"))) "A failed upload replaced the local latest image."
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $script:CpcvConfig = @{
        HostAlias = "upload-test-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $testRoot
        LocalCache = (Join-Path $testRoot "cache"); StateFile = (Join-Path $testRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $testRoot "last-remote-path.txt"); UploadStatusFile = (Join-Path $testRoot "upload-status.txt")
        HeartbeatFile = (Join-Path $testRoot "watch.heartbeat"); LogFile = (Join-Path $testRoot "watch.log")
        CommandTimeoutSeconds = 35; MaxCommandOutputBytes = 65536; MaxLogBytes = 1048576
        MaxCacheFiles = 20; MaxCacheBytes = 8388608; MaxImageBytes = 1048576; ConfigError = ""
    }

    foreach ($index in 0..2) {
        foreach ($recoveryState in @("recovered", "sign-in-required", "not-applicable", "failed", "throw")) {
            Reset-CpcvUploadTest
            $script:uploadFailureStage = $script:uploadStages[$index]
            $script:uploadRecoveryState = $recoveryState
            $result = Publish-ClipboardImage -Force
            $expectedReason = switch ($recoveryState) {
                "recovered" { "cloudflare-retry" }
                "sign-in-required" { "cloudflare-sign-in-required" }
                default { $script:uploadFailureReasons[$index] }
            }
            Assert-CpcvUpload (-not $result.Ok -and $result.Reason -eq $expectedReason) "The $($script:uploadStages[$index]) failure lost its controlled recovery result ($recoveryState): $($result.Reason); $($result.Detail)."
            Assert-CpcvUpload ($script:uploadCalls.Count -eq ($index + 1) -and $script:uploadRecoveryCalls.Count -eq 1) "An upload retried immediately or skipped recovery at a failed transport stage."
            Assert-CpcvUpload ($script:uploadRecoveryCalls[0].FailureKind -eq "command-timeout") "A timed-out transport used the wrong recovery category."
            Assert-CpcvUpload ([datetime]::UtcNow - $script:uploadRecoveryCalls[0].Heartbeat.Timestamp.UtcDateTime -lt [timespan]::FromSeconds(3)) "The watcher health record was not refreshed before recovery."
            Assert-CpcvUploadStateUncommitted
            $status = Get-CpcvUploadStatusInfo -Path $script:CpcvConfig.UploadStatusFile
            Assert-CpcvUpload ($status.Result -eq "failed" -and $status.Reason -eq $expectedReason) "The upload did not persist its controlled failed status."
            Assert-CpcvUpload (($result.Detail + (Get-Content -LiteralPath $script:CpcvConfig.LogFile -Raw)) -notmatch 'synthetic-transport-secret|synthetic-recovery-secret') "Transport recovery exposed a credential in its result or log."

            $script:uploadFailureStage = ""
            $retry = Publish-ClipboardImage -Force
            Assert-CpcvUpload ($retry.Ok -and $retry.Reason -eq "uploaded") "The next ordinary upload did not recover after a transport failure."
            Assert-CpcvUpload ($script:uploadCalls.Count -eq ($index + 4)) "The next ordinary attempt did not use the normal three-stage flow."
            Assert-CpcvUpload ((Get-CpcvUploadStatusInfo -Path $script:CpcvConfig.UploadStatusFile).Result -eq "succeeded") "A successful retry did not clear its failed upload status."
        }
    }

    foreach ($stage in $script:uploadStages) {
        Reset-CpcvUploadTest
        $script:uploadFailureStage = $stage
        $script:uploadFailureResult = @{ Ok = $false; TimedOut = $false; ExitCode = 255; StdOut = ""; StdErr = "Host key verification failed."; OutputTruncated = $false; Detail = "Host key verification failed." }
        $result = Publish-ClipboardImage -Force
        Assert-CpcvUpload (-not $result.Ok -and $script:uploadRecoveryCalls.Count -eq 0) "A host-key failure incorrectly initiated Access recovery."
        Assert-CpcvUploadStateUncommitted
    }

    foreach ($ackMode in @("missing", "duplicate", "unsafe", "wrong-image", "truncated", "raw-unicode")) {
        Reset-CpcvUploadTest
        $script:uploadAckMode = $ackMode
        $result = Publish-ClipboardImage -Force
        Assert-CpcvUpload (-not $result.Ok -and $result.Reason -eq "ssh-latest-failed") "An unverified remote publication was treated as success ($ackMode)."
        Assert-CpcvUpload ($script:uploadCalls.Count -eq 3 -and $script:uploadRecoveryCalls.Count -eq 0) "Malformed publication output triggered an extra transport or Access recovery."
        Assert-CpcvUploadStateUncommitted
    }

    Reset-CpcvUploadTest
    $healthy = Publish-ClipboardImage -Force
    Assert-CpcvUpload $healthy.Ok "A valid acknowledgment with an SSH banner did not complete the upload."
    foreach ($call in $script:uploadCalls) {
        Assert-CpcvUpload ([datetime]::UtcNow - $call.Heartbeat.Timestamp.UtcDateTime -lt [timespan]::FromSeconds(3)) "The watcher health record was not refreshed before a remote stage."
    }
    $finalCommand = $script:uploadCalls[2].Arguments[-1]
    Assert-CpcvUpload ($finalCommand -match '^ln -sfn .+ && test ' -and $finalCommand -match 'CPCV_UPLOAD_OK') "The remote publication command did not condition acknowledgment on a verified latest link."

    Reset-CpcvUploadTest
    $script:uploadAckMode = "tilde"
    $fallback = Publish-ClipboardImage -Force
    $expectedFallback = "~/clipboard-images/clip-$(Get-BytesHash -Bytes $script:uploadBytes).png"
    Assert-CpcvUpload ($fallback.Ok -and $fallback.RemotePath -ceq $expectedFallback) "A verified safe tilde path was not accepted for a home outside the path alphabet."
    Assert-CpcvUpload ((Get-Content -LiteralPath $script:CpcvConfig.LastRemotePathFile -Raw).Trim() -ceq $expectedFallback) "A verified fallback path was not persisted after publication."

    if ($script:uploadTestBash) {
        foreach ($mode in @("unicode-home", "bsd-unicode-home", "ascii-resolved", "failed-ln")) {
            Reset-CpcvUploadTest
            $script:uploadAckMode = $mode
            $fixtureResult = Publish-ClipboardImage -Force
            if ($mode -eq "failed-ln") {
                Assert-CpcvUpload (-not $fixtureResult.Ok -and $fixtureResult.Reason -eq "ssh-latest-failed") "An actual failed latest-link command emitted or accepted a success acknowledgment."
                Assert-CpcvUploadStateUncommitted
            }
            else {
                $expectedPath = if ($mode -eq "ascii-resolved") { "/home/tester/clipboard-images/clip-$(Get-BytesHash -Bytes $script:uploadBytes).png" } else { $expectedFallback }
                Assert-CpcvUpload ($fixtureResult.Ok -and $fixtureResult.RemotePath -ceq $expectedPath) "The generated remote command selected the wrong path for $mode ($($fixtureResult.Reason)): $($script:uploadShellResult.Detail)"
                Assert-CpcvUpload ((Get-Content -LiteralPath $script:CpcvConfig.LastRemotePathFile -Raw).Trim() -ceq $expectedPath) "The generated remote command did not commit its verified path for $mode."
            }
        }
        Write-Host "PASS: generated remote command with an isolated Unicode home, BSD readlink fallback, ASCII canonical path, and failed latest-link publication"
    }
    else { Write-Host "SKIP: optional generated-command shell fixtures; Git Bash is unavailable (use -BashPath to provide it)." }

    Reset-CpcvUploadTest
    $foreignHeartbeat = ([datetime]::UtcNow.AddSeconds(-5).ToString("o")) + " pid=$($PID + 1000) checking"
    Set-CpcvAtomicText -Path $script:CpcvConfig.HeartbeatFile -Value $foreignHeartbeat
    $healthy = Publish-ClipboardImage -Force
    Assert-CpcvUpload ($healthy.Ok -and (Get-Content -LiteralPath $script:CpcvConfig.HeartbeatFile -Raw).Trim() -eq $foreignHeartbeat) "A tray/hotkey upload overwrote another watcher's health record."

    Write-Host "PASS: all-stage transport recovery, bounded next-attempt retry, credential-safe failures, verified publication acknowledgments, and watcher-owned stage heartbeats"
}
finally {
    $script:CpcvConfig = $originalConfig
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTestRoot) -notmatch '^cpcv-upload-recovery-[a-f0-9]{32}$') {
        throw "Refusing to remove an upload-recovery fixture outside its generated TEMP directory."
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
