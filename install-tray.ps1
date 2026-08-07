<#
.SYNOPSIS
Installs the optional Windows notification-area controller for this checkout.

.DESCRIPTION
The tray companion is separate from the uploader's guardian.  Installing it
adds one user Startup shortcut and launches one scoped tray process; it does
not upload anything, alter SSH configuration, or restart the uploader.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
if (-not $IsWindows -and $env:OS -ne "Windows_NT") { throw "install-tray.ps1 is for Windows. Use macos/install-tray.sh on macOS." }
. (Join-Path $PSScriptRoot "imgpaste-tray.ps1") -NoRun

$trayScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-tray.ps1"))
if (-not (Test-Path -LiteralPath $trayScript)) { throw "Missing tray script: $trayScript" }
$startup = [Environment]::GetFolderPath("Startup")
$shortcut = Join-Path $startup "imgpaste-tray.lnk"

if (-not (Test-ImgPasteTrayShortcutOwnership -ShortcutPath $shortcut -ScriptPath $trayScript -WorkingDirectory $PSScriptRoot)) {
    throw "Refusing to replace an unrelated Startup shortcut: $shortcut"
}

if ($PSCmdlet.ShouldProcess($shortcut, "create or update Startup shortcut")) {
    $wsh = New-Object -ComObject WScript.Shell
    $item = $wsh.CreateShortcut($shortcut)
    $item.TargetPath = "powershell.exe"
    $item.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$trayScript`""
    $item.WorkingDirectory = $PSScriptRoot
    $item.WindowStyle = 7
    $item.Description = "Managed by imgpaste install-tray.ps1"
    $item.Save()
}

if (-not $NoStart) {
    $probe = Get-ImgPasteTrayProcessProbe -ScriptPath $trayScript
    if (-not $probe.Available) { throw "Cannot inspect local processes; refusing to launch a duplicate tray app." }
    if ((@($probe.Processes)).Count -eq 0 -and $PSCmdlet.ShouldProcess($trayScript, "start tray app")) {
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $trayScript)
        ) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    }
}

if ($WhatIfPreference) {
    Write-Host "WhatIf: no changes were made to the optional imgpaste tray integration."
    return
}

Write-Host "Installed optional imgpaste tray startup shortcut: $shortcut"
if ($NoStart) { Write-Host "The tray was not started. Run .\imgpaste-tray.ps1 with powershell.exe -STA when ready." }
