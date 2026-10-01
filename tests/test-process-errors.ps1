# Local-only child-process tests. They never start SSH, inspect the clipboard,
# contact a host, or stop an existing application process.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\cpcv-core.ps1")

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

    Write-Host "PASS: preserved redacted timeout diagnostics, bounded noisy output, and prompt owned-child cleanup after a post-start error"
}
finally {
    if (Test-Path Function:\New-Object) { Remove-Item Function:\New-Object }
    $script:CpcvConfig = $originalConfig
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
