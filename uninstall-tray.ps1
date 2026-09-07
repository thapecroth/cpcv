<#
.SYNOPSIS
Removes the optional Windows cpcv tray companion for this checkout.

.DESCRIPTION
This does not stop the guardian or watcher, delete screenshots, delete logs,
or modify SSH configuration. It only removes this checkout's tray Startup
shortcut and, unless -KeepRunning is specified, its exact tray process.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"
if (-not $IsWindows -and $env:OS -ne "Windows_NT") { throw "uninstall-tray.ps1 is for Windows. Use macos/uninstall-tray.sh on macOS." }
. (Join-Path $PSScriptRoot "cpcv-tray.ps1") -NoRun

$trayScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-tray.ps1"))
$shortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "cpcv-tray.lnk"

if (Test-Path -LiteralPath $shortcut) {
    if (-not (Test-CpcvTrayShortcutOwnership -ShortcutPath $shortcut -ScriptPath $trayScript -WorkingDirectory $PSScriptRoot)) {
        throw "Refusing to remove an unrelated Startup shortcut: $shortcut"
    }
    if ($PSCmdlet.ShouldProcess($shortcut, "remove Startup shortcut")) {
        Remove-Item -LiteralPath $shortcut -Force
    }
}

if (-not $KeepRunning) {
    $probe = Get-CpcvTrayProcessProbe -ScriptPath $trayScript
    if (-not $probe.Available) { throw "Cannot inspect local processes; refusing to stop anything." }
    foreach ($process in @($probe.Processes)) {
        if ($PSCmdlet.ShouldProcess("PID $($process.ProcessId)", "stop tray process for this checkout")) {
            Stop-CpcvProcessTree -ProcessId ([int]$process.ProcessId)
        }
    }
}

if ($WhatIfPreference) {
    Write-Host "WhatIf: no changes were made to the optional cpcv tray integration."
    return
}

Write-Host "Removed optional cpcv tray integration for this checkout. The uploader service and its data were preserved."
