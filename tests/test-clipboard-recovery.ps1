# Safe clipboard-contention regression tests. Every clipboard read/write and
# SSH/SCP operation is stubbed; local state is confined to a unique TEMP folder.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\cpcv-core.ps1")

function Assert-CpcvClipboard([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$script:clipboardBusyException = [System.Runtime.InteropServices.ExternalException]::new("Requested Clipboard operation did not succeed.", -2147221040)
$script:clipboardOtherException = [System.Runtime.InteropServices.ExternalException]::new("Requested Clipboard operation did not succeed. password=clipboard-secret", -2147467259)
Assert-CpcvClipboard (Test-CpcvClipboardBusyException $script:clipboardBusyException) "The Windows clipboard-open HRESULT was not recognized."
Assert-CpcvClipboard (Test-CpcvClipboardBusyException ([System.Reflection.TargetInvocationException]::new($script:clipboardBusyException))) "A wrapped Windows clipboard-open error was not recognized."
Assert-CpcvClipboard (-not (Test-CpcvClipboardBusyException $script:clipboardOtherException)) "An unrelated ExternalException was classified as clipboard contention."
Assert-CpcvClipboard (-not (Test-CpcvClipboardBusyException ([System.Threading.ThreadStateException]::new("STA required")))) "An apartment-mode error was classified as temporary clipboard contention."

$script:clipboardInitialBytes = [byte[]](137,80,78,71,13,10,26,10,1,2,3)
$script:clipboardNewerBytes = [byte[]](137,80,78,71,13,10,26,10,4,5,6)
function Set-CpcvClipboardTestSequence {
    param([string[]]$Sequence)
    $script:clipboardTestSequence = $Sequence
    $script:clipboardReadCount = 0
    $script:clipboardWaits = @()
    $script:clipboardProcessLabels = @()
    $script:clipboardWriteCount = 0
}
function Get-CpcvClipboardImageBytesOnce {
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

Set-CpcvClipboardTestSequence @("busy", "busy", "image")
$recoveredBytes = Get-ClipboardImageBytes
Assert-CpcvClipboard ((Get-BytesHash $recoveredBytes) -eq (Get-BytesHash $script:clipboardInitialBytes)) "A temporary clipboard lock did not recover the image."
Assert-CpcvClipboard ($script:clipboardReadCount -eq 3 -and $script:clipboardWaits.Count -eq 2) "Temporary contention did not use the bounded retry policy."
Assert-CpcvClipboard (($script:clipboardWaits | Measure-Object -Sum).Sum -eq 200) "Clipboard retries added more than the expected 200 ms delay."

Set-CpcvClipboardTestSequence @("busy")
$busyThrown = $false
try { Get-ClipboardImageBytes | Out-Null }
catch { $busyThrown = Test-CpcvClipboardBusyException $_.Exception }
Assert-CpcvClipboard $busyThrown "An exhausted clipboard lock was hidden from the uploader."
Assert-CpcvClipboard ($script:clipboardReadCount -eq 3 -and $script:clipboardWaits.Count -eq 2) "Persistent contention retried beyond the fixed bound."

Set-CpcvClipboardTestSequence @("other-error")
$otherThrown = $false
try { Get-ClipboardImageBytes | Out-Null }
catch { $otherThrown = -not (Test-CpcvClipboardBusyException $_.Exception) }
Assert-CpcvClipboard $otherThrown "An unexpected clipboard error was swallowed."
Assert-CpcvClipboard ($script:clipboardReadCount -eq 1 -and $script:clipboardWaits.Count -eq 0) "An unexpected clipboard error was retried as contention."

$tempRoot = Join-Path $env:TEMP ("cpcv-clipboard-recovery-{0}" -f [Guid]::NewGuid())
$originalConfig = $script:CpcvConfig
$script:clipboardMutexSuffix = [Guid]::NewGuid().ToString("N")
function Get-CpcvMutexName { param([string]$Purpose) return "Local\CpcvClipboardTest-$Purpose-$script:clipboardMutexSuffix" }
function Invoke-CpcvProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label)
    $script:clipboardProcessLabels += $Label
    $stdout = ""
    if ($Label -eq "ssh update latest") {
        $leaf = [regex]::Match($Arguments[-1], 'clip-[a-f0-9]{64}\.png').Value
        $stdout = "CPCV_UPLOAD_OK /home/tester/clipboard-images/$leaf`n"
    }
    return @{ Ok = $true; TimedOut = $false; ExitCode = 0; StdOut = $stdout; StdErr = ""; OutputTruncated = $false; Detail = "" }
}
function Reset-CpcvClipboardTestState {
    foreach ($path in @($script:CpcvConfig.StateFile, $script:CpcvConfig.LastRemotePathFile, $script:CpcvConfig.UploadStatusFile, (Join-Path $script:CpcvConfig.LocalCache "latest.png"))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class CpcvClipboardMutexFixture {
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
    $script:CpcvConfig = @{
        HostAlias = "clipboard-test-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); UploadStatusFile = (Join-Path $tempRoot "upload-status.txt")
        LogFile = (Join-Path $tempRoot "watch.log"); MaxLogBytes = 1048576; MaxCommandOutputBytes = 65536
        MaxCacheFiles = 20; MaxCacheBytes = 8388608; MaxImageBytes = 1048576; ConfigError = ""
    }

    # Use an isolated real named mutex and a .NET worker thread. A process
    # dying with ownership must not strand the next uploader; a live owner
    # must still exclude concurrent uploads without reading the clipboard.
    $mutexFixture = [System.Threading.Mutex]::new($false, (Get-CpcvMutexName -Purpose "Upload"))
    $mutexRelease = [System.Threading.ManualResetEvent]::new($false)
    try {
        Set-CpcvClipboardTestSequence @("empty")
        $mutexOwner = [CpcvClipboardMutexFixture]::Hold($mutexFixture, $mutexRelease)
        try {
            $activeOwner = Publish-ClipboardImage -Force
            Assert-CpcvClipboard ($activeOwner.Reason -eq "upload-in-progress" -and $script:clipboardReadCount -eq 0) "A live upload owner did not exclude a concurrent upload."
        }
        finally { [void]$mutexRelease.Set(); [void]$mutexOwner.Join(5000) }
        [CpcvClipboardMutexFixture]::Abandon($mutexFixture)
        $abandonedRecovery = Publish-ClipboardImage -Force
        Assert-CpcvClipboard ($abandonedRecovery.Reason -eq "no-image") "An abandoned upload mutex prevented the next upload attempt."
        Assert-CpcvClipboard ([CpcvClipboardMutexFixture]::IsAvailableFromAnotherThread($mutexFixture)) "Abandoned-mutex recovery retained upload ownership after returning."
    }
    finally { $mutexRelease.Dispose(); $mutexFixture.Dispose() }

    Set-CpcvClipboardTestSequence @("busy")
    $initialBusy = Publish-ClipboardImage -CopyPath -Force
    Assert-CpcvClipboard (-not $initialBusy.Ok -and $initialBusy.Reason -eq "clipboard-busy") "Initial contention did not return a controlled clipboard-busy result."
    Assert-CpcvClipboard ($script:clipboardProcessLabels.Count -eq 0 -and $script:clipboardWriteCount -eq 0) "Initial clipboard contention launched a transport or changed the clipboard."
    Assert-CpcvClipboard (-not (Test-Path -LiteralPath $script:CpcvConfig.StateFile)) "Initial clipboard contention advanced upload state."
    $busyStatus = Get-CpcvUploadStatusInfo $script:CpcvConfig.UploadStatusFile
    Assert-CpcvClipboard ($busyStatus.Result -eq "failed" -and $busyStatus.Reason -eq "clipboard-busy") "Clipboard contention did not persist its safe status reason."

    Set-CpcvClipboardTestSequence @("busy", "image")
    $recoveredUpload = Publish-ClipboardImage -Force
    Assert-CpcvClipboard ($recoveredUpload.Ok -and $recoveredUpload.Reason -eq "uploaded") "Upload did not recover after clipboard contention, or its mutex remained held."
    Assert-CpcvClipboard ($script:clipboardProcessLabels.Count -eq 3 -and $script:clipboardWriteCount -eq 0) "Recovered automatic upload did not preserve the clipboard and normal transport sequence."
    $successStatus = Get-CpcvUploadStatusInfo $script:CpcvConfig.UploadStatusFile
    Assert-CpcvClipboard ($successStatus.Result -eq "succeeded") "A recovered upload did not clear clipboard contention status."

    # Both latest-state guards use the bounded reader. A persistent lock does
    # not assert that the clipboard changed or commit potentially stale state.
    foreach ($sequence in @(@("image", "busy"), @("image", "image", "busy"))) {
        Reset-CpcvClipboardTestState
        Set-CpcvClipboardTestSequence $sequence
        $finalBusy = Publish-ClipboardImage -CopyPath -Force
        Assert-CpcvClipboard (-not $finalBusy.Ok -and $finalBusy.Reason -eq "clipboard-busy") "Finalization contention was incorrectly classified as a changed clipboard."
        $expectedProcessCount = if ($sequence.Count -eq 2) { 2 } else { 3 }
        Assert-CpcvClipboard ($script:clipboardProcessLabels.Count -eq $expectedProcessCount) "Finalization contention crossed an unexpected transport boundary."
        Assert-CpcvClipboard (-not (Test-Path -LiteralPath $script:CpcvConfig.StateFile) -and -not (Test-Path -LiteralPath $script:CpcvConfig.LastRemotePathFile) -and -not (Test-Path -LiteralPath (Join-Path $script:CpcvConfig.LocalCache "latest.png"))) "Finalization contention committed local latest or retry state."
        Assert-CpcvClipboard ($script:clipboardWriteCount -eq 0) "Finalization contention replaced the clipboard."
    }

    Reset-CpcvClipboardTestState
    Set-CpcvClipboardTestSequence @("image", "busy", "newer")
    $superseded = Publish-ClipboardImage -CopyPath -Force
    Assert-CpcvClipboard ($superseded.Reason -eq "clipboard-changed") "A new image appearing during contention retries did not supersede the upload."
    Assert-CpcvClipboard ($script:clipboardProcessLabels.Count -eq 2 -and $script:clipboardWriteCount -eq 0 -and -not (Test-Path -LiteralPath $script:CpcvConfig.StateFile)) "A superseded image updated latest state or overwrote the newer clipboard."

    Reset-CpcvClipboardTestState
    Set-CpcvClipboardTestSequence @("other-error")
    $unexpected = Publish-ClipboardImage -Force
    Assert-CpcvClipboard (-not $unexpected.Ok -and $unexpected.Reason -eq "upload-error") "An unexpected local error did not use the controlled upload result contract."
    Assert-CpcvClipboard ($unexpected.Detail -notmatch 'clipboard-secret|Requested Clipboard') "Unexpected local error details leaked into the customer-facing result."
    Assert-CpcvClipboard ((Get-Content -LiteralPath $script:CpcvConfig.LogFile -Raw) -notmatch 'clipboard-secret') "Unexpected clipboard diagnostics retained a credential."
    Assert-CpcvClipboard ($script:clipboardProcessLabels.Count -eq 0 -and $script:clipboardWaits.Count -eq 0) "An unexpected local error was retried or launched a transport."

    Set-CpcvClipboardTestSequence @("empty")
    $empty = Publish-ClipboardImage -Force
    Assert-CpcvClipboard ($empty.Reason -eq "no-image" -and $script:clipboardReadCount -eq 1 -and $script:clipboardWaits.Count -eq 0) "An empty clipboard was retried or changed to a clipboard error."
}
finally {
    $script:CpcvConfig = $originalConfig
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "PASS: bounded clipboard-contention recovery, exact HRESULT classification, controlled safe errors, live/abandoned upload mutex handling, preserved latest retry state, and newer clipboard protection"
