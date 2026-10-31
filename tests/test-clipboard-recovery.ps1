# Safe clipboard-contention regression tests. Every clipboard read/write and
# SSH/SCP operation is stubbed; local state is confined to a unique TEMP folder.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\ctrl-ccv-core.ps1")

function Assert-CtrlCcvClipboard([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$script:clipboardBusyException = [System.Runtime.InteropServices.ExternalException]::new("Requested Clipboard operation did not succeed.", -2147221040)
$script:clipboardOtherException = [System.Runtime.InteropServices.ExternalException]::new("Requested Clipboard operation did not succeed. password=clipboard-secret", -2147467259)
Assert-CtrlCcvClipboard (Test-CtrlCcvClipboardBusyException $script:clipboardBusyException) "The Windows clipboard-open HRESULT was not recognized."
Assert-CtrlCcvClipboard (Test-CtrlCcvClipboardBusyException ([System.Reflection.TargetInvocationException]::new($script:clipboardBusyException))) "A wrapped Windows clipboard-open error was not recognized."
Assert-CtrlCcvClipboard (-not (Test-CtrlCcvClipboardBusyException $script:clipboardOtherException)) "An unrelated ExternalException was classified as clipboard contention."
Assert-CtrlCcvClipboard (-not (Test-CtrlCcvClipboardBusyException ([System.Threading.ThreadStateException]::new("STA required")))) "An apartment-mode error was classified as temporary clipboard contention."

$script:clipboardInitialBytes = [byte[]](137,80,78,71,13,10,26,10,1,2,3)
$script:clipboardNewerBytes = [byte[]](137,80,78,71,13,10,26,10,4,5,6)
function Set-CtrlCcvClipboardTestSequence {
    param([string[]]$Sequence)
    $script:clipboardTestSequence = $Sequence
    $script:clipboardReadCount = 0
    $script:clipboardWaits = @()
    $script:clipboardProcessLabels = @()
    $script:clipboardWriteCount = 0
}
function Get-CtrlCcvClipboardImageBytesOnce {
    $index = [Math]::Min($script:clipboardReadCount, $script:clipboardTestSequence.Count - 1)
    $script:clipboardReadCount++
    switch ($script:clipboardTestSequence[$index]) {
        "busy" { throw [System.Reflection.TargetInvocationException]::new($script:clipboardBusyException) }
        "other-error" { throw $script:clipboardOtherException }
        "empty" { return $null }
        "newer" { return $script:clipboardNewerBytes }
        default { return $script:clipboardInitialBytes }
    }
}
function Start-Sleep { param([int]$Milliseconds) $script:clipboardWaits += $Milliseconds }
function Set-Clipboard { param([string]$Value) $script:clipboardWriteCount++ }

Set-CtrlCcvClipboardTestSequence @("busy", "busy", "image")
$recoveredBytes = Get-ClipboardImageBytes
Assert-CtrlCcvClipboard ((Get-BytesHash $recoveredBytes) -eq (Get-BytesHash $script:clipboardInitialBytes)) "A temporary clipboard lock did not recover the image."
Assert-CtrlCcvClipboard ($script:clipboardReadCount -eq 3 -and $script:clipboardWaits.Count -eq 2) "Temporary contention did not use the bounded retry policy."
Assert-CtrlCcvClipboard (($script:clipboardWaits | Measure-Object -Sum).Sum -eq 200) "Clipboard retries added more than the expected 200 ms delay."

Set-CtrlCcvClipboardTestSequence @("busy")
$busyThrown = $false
try { Get-ClipboardImageBytes | Out-Null }
catch { $busyThrown = Test-CtrlCcvClipboardBusyException $_.Exception }
Assert-CtrlCcvClipboard $busyThrown "An exhausted clipboard lock was hidden from the uploader."
Assert-CtrlCcvClipboard ($script:clipboardReadCount -eq 3 -and $script:clipboardWaits.Count -eq 2) "Persistent contention retried beyond the fixed bound."

Set-CtrlCcvClipboardTestSequence @("other-error")
$otherThrown = $false
try { Get-ClipboardImageBytes | Out-Null }
catch { $otherThrown = -not (Test-CtrlCcvClipboardBusyException $_.Exception) }
Assert-CtrlCcvClipboard $otherThrown "An unexpected clipboard error was swallowed."
Assert-CtrlCcvClipboard ($script:clipboardReadCount -eq 1 -and $script:clipboardWaits.Count -eq 0) "An unexpected clipboard error was retried as contention."

$tempRoot = Join-Path $env:TEMP ("ctrl-ccv-clipboard-recovery-{0}" -f [Guid]::NewGuid())
$originalConfig = $script:CtrlCcvConfig
$script:clipboardMutexSuffix = [Guid]::NewGuid().ToString("N")
function Get-CtrlCcvMutexName { param([string]$Purpose) return "Local\CtrlCcvClipboardTest-$Purpose-$script:clipboardMutexSuffix" }
function Invoke-CtrlCcvProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label)
    $script:clipboardProcessLabels += $Label
    $stdout = ""
    if ($Label -eq "ssh update latest") {
        $leaf = [regex]::Match($Arguments[-1], 'clip-[a-f0-9]{64}\.png').Value
        $stdout = "CTRL_CCV_UPLOAD_OK /home/tester/clipboard-images/$leaf`n"
    }
    return @{ Ok = $true; TimedOut = $false; ExitCode = 0; StdOut = $stdout; StdErr = ""; OutputTruncated = $false; Detail = "" }
}
function Reset-CtrlCcvClipboardTestState {
    foreach ($path in @($script:CtrlCcvConfig.StateFile, $script:CtrlCcvConfig.LastRemotePathFile, $script:CtrlCcvConfig.UploadStatusFile, (Join-Path $script:CtrlCcvConfig.LocalCache "latest.png"))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class CtrlCcvClipboardMutexFixture {
    public static void Abandon(Mutex mutex) {
        Thread worker = new Thread(delegate() { mutex.WaitOne(); });
        worker.Start();
        worker.Join();
    }
    public static Thread Hold(Mutex mutex, EventWaitHandle release) {
        ManualResetEvent ready = new ManualResetEvent(false);
        Thread worker = new Thread(delegate() {
            mutex.WaitOne();
            ready.Set();
            release.WaitOne(5000);
            mutex.ReleaseMutex();
        });
        worker.IsBackground = true;
        worker.Start();
        if (!ready.WaitOne(5000)) { throw new Exception("Synthetic mutex owner did not start."); }
        ready.Dispose();
        return worker;
    }
    public static bool IsAvailableFromAnotherThread(Mutex mutex) {
        bool acquired = false;
        Thread worker = new Thread(delegate() {
            try { acquired = mutex.WaitOne(0, false); }
            catch (AbandonedMutexException) { acquired = true; }
            finally { if (acquired) { mutex.ReleaseMutex(); } }
        });
        worker.Start();
        worker.Join();
        return acquired;
    }
}
'@
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $script:CtrlCcvConfig = @{
        HostAlias = "clipboard-test-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); UploadStatusFile = (Join-Path $tempRoot "upload-status.txt")
        LogFile = (Join-Path $tempRoot "watch.log"); MaxLogBytes = 1048576; MaxCommandOutputBytes = 65536
        MaxCacheFiles = 20; MaxCacheBytes = 8388608; MaxImageBytes = 1048576; ConfigError = ""
    }

    # Use an isolated real named mutex and a .NET worker thread. A process
    # dying with ownership must not strand the next uploader; a live owner
    # must still exclude concurrent uploads without reading the clipboard.
    $mutexFixture = [System.Threading.Mutex]::new($false, (Get-CtrlCcvMutexName -Purpose "Upload"))
    $mutexRelease = [System.Threading.ManualResetEvent]::new($false)
    try {
        Set-CtrlCcvClipboardTestSequence @("empty")
        $mutexOwner = [CtrlCcvClipboardMutexFixture]::Hold($mutexFixture, $mutexRelease)
        try {
            $activeOwner = Publish-ClipboardImage -Force
            Assert-CtrlCcvClipboard ($activeOwner.Reason -eq "upload-in-progress" -and $script:clipboardReadCount -eq 0) "A live upload owner did not exclude a concurrent upload."
        }
        finally { [void]$mutexRelease.Set(); [void]$mutexOwner.Join(5000) }
        [CtrlCcvClipboardMutexFixture]::Abandon($mutexFixture)
        $abandonedRecovery = Publish-ClipboardImage -Force
        Assert-CtrlCcvClipboard ($abandonedRecovery.Reason -eq "no-image") "An abandoned upload mutex prevented the next upload attempt."
        Assert-CtrlCcvClipboard ([CtrlCcvClipboardMutexFixture]::IsAvailableFromAnotherThread($mutexFixture)) "Abandoned-mutex recovery retained upload ownership after returning."
    }
    finally { $mutexRelease.Dispose(); $mutexFixture.Dispose() }

    Set-CtrlCcvClipboardTestSequence @("busy")
    $initialBusy = Publish-ClipboardImage -CopyPath -Force
    Assert-CtrlCcvClipboard (-not $initialBusy.Ok -and $initialBusy.Reason -eq "clipboard-busy") "Initial contention did not return a controlled clipboard-busy result."
    Assert-CtrlCcvClipboard ($script:clipboardProcessLabels.Count -eq 0 -and $script:clipboardWriteCount -eq 0) "Initial clipboard contention launched a transport or changed the clipboard."
    Assert-CtrlCcvClipboard (-not (Test-Path -LiteralPath $script:CtrlCcvConfig.StateFile)) "Initial clipboard contention advanced upload state."
    $busyStatus = Get-CtrlCcvUploadStatusInfo $script:CtrlCcvConfig.UploadStatusFile
    Assert-CtrlCcvClipboard ($busyStatus.Result -eq "failed" -and $busyStatus.Reason -eq "clipboard-busy") "Clipboard contention did not persist its safe status reason."

    Set-CtrlCcvClipboardTestSequence @("busy", "image")
    $recoveredUpload = Publish-ClipboardImage -Force
    Assert-CtrlCcvClipboard ($recoveredUpload.Ok -and $recoveredUpload.Reason -eq "uploaded") "Upload did not recover after clipboard contention, or its mutex remained held."
    Assert-CtrlCcvClipboard ($script:clipboardProcessLabels.Count -eq 3 -and $script:clipboardWriteCount -eq 0) "Recovered automatic upload did not preserve the clipboard and normal transport sequence."
    $successStatus = Get-CtrlCcvUploadStatusInfo $script:CtrlCcvConfig.UploadStatusFile
    Assert-CtrlCcvClipboard ($successStatus.Result -eq "succeeded") "A recovered upload did not clear clipboard contention status."

    # Both latest-state guards use the bounded reader. A persistent lock does
    # not assert that the clipboard changed or commit potentially stale state.
    foreach ($sequence in @(@("image", "busy"), @("image", "image", "busy"))) {
        Reset-CtrlCcvClipboardTestState
        Set-CtrlCcvClipboardTestSequence $sequence
        $finalBusy = Publish-ClipboardImage -CopyPath -Force
        Assert-CtrlCcvClipboard (-not $finalBusy.Ok -and $finalBusy.Reason -eq "clipboard-busy") "Finalization contention was incorrectly classified as a changed clipboard."
        $expectedProcessCount = if ($sequence.Count -eq 2) { 2 } else { 3 }
        Assert-CtrlCcvClipboard ($script:clipboardProcessLabels.Count -eq $expectedProcessCount) "Finalization contention crossed an unexpected transport boundary."
        Assert-CtrlCcvClipboard (-not (Test-Path -LiteralPath $script:CtrlCcvConfig.StateFile) -and -not (Test-Path -LiteralPath $script:CtrlCcvConfig.LastRemotePathFile) -and -not (Test-Path -LiteralPath (Join-Path $script:CtrlCcvConfig.LocalCache "latest.png"))) "Finalization contention committed local latest or retry state."
        Assert-CtrlCcvClipboard ($script:clipboardWriteCount -eq 0) "Finalization contention replaced the clipboard."
    }

    Reset-CtrlCcvClipboardTestState
    Set-CtrlCcvClipboardTestSequence @("image", "busy", "newer")
    $superseded = Publish-ClipboardImage -CopyPath -Force
    Assert-CtrlCcvClipboard ($superseded.Reason -eq "clipboard-changed") "A new image appearing during contention retries did not supersede the upload."
    Assert-CtrlCcvClipboard ($script:clipboardProcessLabels.Count -eq 2 -and $script:clipboardWriteCount -eq 0 -and -not (Test-Path -LiteralPath $script:CtrlCcvConfig.StateFile)) "A superseded image updated latest state or overwrote the newer clipboard."

    Reset-CtrlCcvClipboardTestState
    Set-CtrlCcvClipboardTestSequence @("other-error")
    $unexpected = Publish-ClipboardImage -Force
    Assert-CtrlCcvClipboard (-not $unexpected.Ok -and $unexpected.Reason -eq "upload-error") "An unexpected local error did not use the controlled upload result contract."
    Assert-CtrlCcvClipboard ($unexpected.Detail -notmatch 'clipboard-secret|Requested Clipboard') "Unexpected local error details leaked into the customer-facing result."
    Assert-CtrlCcvClipboard ((Get-Content -LiteralPath $script:CtrlCcvConfig.LogFile -Raw) -notmatch 'clipboard-secret') "Unexpected clipboard diagnostics retained a credential."
    Assert-CtrlCcvClipboard ($script:clipboardProcessLabels.Count -eq 0 -and $script:clipboardWaits.Count -eq 0) "An unexpected local error was retried or launched a transport."

    Set-CtrlCcvClipboardTestSequence @("empty")
    $empty = Publish-ClipboardImage -Force
    Assert-CtrlCcvClipboard ($empty.Reason -eq "no-image" -and $script:clipboardReadCount -eq 1 -and $script:clipboardWaits.Count -eq 0) "An empty clipboard was retried or changed to a clipboard error."
}
finally {
    $script:CtrlCcvConfig = $originalConfig
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "PASS: bounded clipboard-contention recovery, exact HRESULT classification, controlled safe errors, live/abandoned upload mutex handling, preserved latest retry state, and newer clipboard protection"
