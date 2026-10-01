# Local-only child-process tests. They never start SSH, inspect the clipboard,
# contact a host, or stop an existing application process.
param([switch]$InputChild)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\cpcv-core.ps1")

if ($InputChild) {
    # This copy is launched with its own parent input pipe deliberately open.
    # Keep even timeout logs in memory so a regression cannot touch real state.
    function Write-CpcvLog { param([string]$Message) }
    $script:CpcvConfig = New-CpcvDefaultConfig
    $emptyInput = Invoke-CpcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "[Console]::In.ReadToEnd().Length") -TimeoutSeconds 3 -Label "unattended input EOF test"
    [pscustomobject]@{ Ok = $emptyInput.Ok; TimedOut = $emptyInput.TimedOut; Bytes = $emptyInput.StdOut.Trim() } | ConvertTo-Json -Compress
    return
}

function Assert-CpcvProcessError([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path $env:TEMP ("cpcv-process-errors-{0}" -f [Guid]::NewGuid().ToString("N"))
$originalConfig = $script:CpcvConfig
$script:originalProcessStop = ${function:Stop-CpcvProcessTree}
$script:processErrorStoppedId = 0
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $script:CpcvConfig = New-CpcvDefaultConfig
    $script:CpcvConfig.DataRoot = $testRoot
    $script:CpcvConfig.LogFile = Join-Path $testRoot "watch.log"
    $script:CpcvConfig.MaxCommandOutputBytes = 1024

    $inputStartInfo = New-Object Diagnostics.ProcessStartInfo
    $inputStartInfo.FileName = "powershell.exe"
    $inputStartInfo.Arguments = ((@("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath, "-InputChild") | ForEach-Object { ConvertTo-CpcvCommandArgument $_ }) -join " ")
    $inputStartInfo.UseShellExecute = $false
    $inputStartInfo.CreateNoWindow = $true
    $inputStartInfo.RedirectStandardInput = $true
    $inputStartInfo.RedirectStandardOutput = $true
    $inputStartInfo.RedirectStandardError = $true
    $inputProcess = New-Object Diagnostics.Process
    $inputProcess.StartInfo = $inputStartInfo
    try {
        [void]$inputProcess.Start()
        # Keep StandardInput open throughout the wait. The nested wrapper must
        # provide its own EOF instead of passing this open parent pipe onward.
        if (-not $inputProcess.WaitForExit(10000)) {
            Stop-CpcvProcessTree -ProcessId $inputProcess.Id
            throw "The owned unattended-input fixture did not finish."
        }
        $emptyInput = $inputProcess.StandardOutput.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
        Assert-CpcvProcessError ($inputProcess.ExitCode -eq 0 -and $emptyInput.Ok -and -not $emptyInput.TimedOut -and $emptyInput.Bytes -eq "0") "A no-input command inherited an open parent input handle or failed to receive immediate EOF."
    }
    finally { $inputProcess.Dispose() }

    # An STA caller can own a UI context while waiting synchronously for a
    # child. Deliberately retain every posted callback without executing it:
    # subprocess output must still drain without borrowing that caller's loop.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Threading;
public sealed class CpcvNonPumpingContext : SynchronizationContext {
    readonly Queue<Tuple<SendOrPostCallback, object>> queue = new Queue<Tuple<SendOrPostCallback, object>>();
    public override void Post(SendOrPostCallback callback, object state) {
        lock (queue) { queue.Enqueue(Tuple.Create(callback, state)); }
    }
    public int PostedCount { get { lock (queue) { return queue.Count; } } }
}
'@
    $priorContext = [Threading.SynchronizationContext]::Current
    $nonPumpingContext = New-Object CpcvNonPumpingContext
    try {
        [Threading.SynchronizationContext]::SetSynchronizationContext($nonPumpingContext)
        $contextTimer = [Diagnostics.Stopwatch]::StartNew()
        $contextOutput = Invoke-CpcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "[Console]::Out.Write('x' * 200000); [Console]::Error.Write('y' * 200000)") -TimeoutSeconds 3 -Label "non-pumping STA output test"
        $contextTimer.Stop()
        Assert-CpcvProcessError ($contextOutput.Ok -and -not $contextOutput.TimedOut -and $contextOutput.OutputTruncated -and $contextTimer.Elapsed.TotalSeconds -lt 3) "A non-pumping caller context prevented output draining or child exit."
        Assert-CpcvProcessError ($contextOutput.StdOut.Length -eq 1024 -and $contextOutput.StdErr.Length -eq 1024) "Output capture under a non-pumping caller context was incomplete or unbounded."
        Assert-CpcvProcessError ($nonPumpingContext.PostedCount -eq 0) "The output pumps queued work onto the blocked caller context."
    }
    finally { [Threading.SynchronizationContext]::SetSynchronizationContext($priorContext) }

    $timeout = Invoke-CpcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "[Console]::Out.WriteLine('Waiting for login'); [Console]::Error.WriteLine('Authorization: Bearer synthetic-timeout-secret'); [Console]::Error.WriteLine('https://example.test/?token=synthetic-query-secret'); Start-Sleep -Seconds 30") -TimeoutSeconds 2 -Label "redacted timeout diagnostic test"
    Assert-CpcvProcessError ($timeout.TimedOut -and $timeout.Detail -match 'Waiting for login') "A process timeout discarded its actionable diagnostic."
    Assert-CpcvProcessError ($timeout.Detail -notmatch 'synthetic-timeout-secret|synthetic-query-secret') "A timeout result exposed a credential."
    Assert-CpcvProcessError ($timeout.Detail.Length -le $script:CpcvConfig.MaxCommandOutputBytes) "The combined timeout diagnostic exceeded its configured output bound."
    Assert-CpcvProcessError ((Get-Content -LiteralPath $script:CpcvConfig.LogFile -Raw) -notmatch 'synthetic-timeout-secret|synthetic-query-secret|Waiting for login') "The generic timeout log copied private subprocess output."

    $largeTimeout = Invoke-CpcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "[Console]::Error.WriteLine('Proxy authentication is waiting'); [Console]::Out.Write('x' * 200000); Start-Sleep -Seconds 30") -TimeoutSeconds 2 -Label "bounded timeout diagnostic test"
    Assert-CpcvProcessError ($largeTimeout.TimedOut -and $largeTimeout.OutputTruncated -and $largeTimeout.Detail.Length -le 1024) "A timeout with noisy output did not remain bounded."
    Assert-CpcvProcessError ($largeTimeout.Detail -match 'Proxy authentication is waiting') "Noisy stdout hid the actionable stderr timeout diagnostic."

    # Inject a capture-construction error after a real, newly owned local child
    # starts. The catch path must stop that child instead of orphaning it.
    function Stop-CpcvProcessTree {
        param([int]$ProcessId)
        $script:processErrorStoppedId = $ProcessId
        & $script:originalProcessStop -ProcessId $ProcessId
    }
    function New-Object {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string]$TypeName, [object[]]$ArgumentList = @())
        if ($TypeName -eq "CpcvBoundedOutput") { throw "Synthetic post-start capture failure; token=synthetic-capture-secret" }
        Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $failedCapture = Invoke-CpcvProcess -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") -TimeoutSeconds 20 -Label "owned child capture error test"
    $timer.Stop()
    Remove-Item Function:\New-Object
    Assert-CpcvProcessError (-not $failedCapture.Ok -and -not $failedCapture.TimedOut -and $failedCapture.Detail -match '^Could not complete ') "A post-start capture failure was incorrectly reported as a launch failure."
    Assert-CpcvProcessError ($failedCapture.Detail -notmatch 'synthetic-capture-secret') "A post-start failure result exposed a credential."
    Assert-CpcvProcessError ($script:processErrorStoppedId -gt 0 -and $timer.Elapsed.TotalSeconds -lt 10) "The catch path did not promptly stop its already-started owned process."
    Assert-CpcvProcessError (-not (Get-Process -Id $script:processErrorStoppedId -ErrorAction SilentlyContinue)) "The owned child survived its output-capture failure."

    Write-Host "PASS: explicit unattended stdin EOF, context-independent bounded output pumps, redacted timeout diagnostics, and prompt owned-child cleanup after a post-start error"
}
finally {
    if (Test-Path Function:\New-Object) { Remove-Item Function:\New-Object }
    $script:CpcvConfig = $originalConfig
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
