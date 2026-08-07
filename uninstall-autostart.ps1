<#
.SYNOPSIS
Removes imgpaste's local startup integration and optional helpers.

.DESCRIPTION
By default this removes only the current user's imgpaste Startup and Start
Menu shortcuts, command wrappers, and processes launched from this checkout.
It deliberately preserves configuration, logs, and screenshots. Use the
explicit removal switches only after reviewing their targets.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$RemoveRemoteHelpers,
    [switch]$RemoveRemoteImages,
    [switch]$RemoveLocalData,
    [switch]$RemoveLocalConfig
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\imgpaste-core.ps1"

if ($RemoveRemoteImages -and -not $RemoveRemoteHelpers) {
    throw '-RemoveRemoteImages requires -RemoveRemoteHelpers so the remote target is explicit.'
}

function Remove-ImgPasteLocalItem {
    param([Parameter(Mandatory)][string]$Path)
    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Remove')) {
        Remove-Item -LiteralPath $Path -Force
        Write-Host "Removed $Path"
    }
}

function Get-ImgPasteCheckoutProcesses {
    $guardian = Join-Path ([IO.Path]::GetFullPath($PSScriptRoot)) 'imgpaste-guardian.ps1'
    $watch = Join-Path ([IO.Path]::GetFullPath($PSScriptRoot)) 'imgpaste-watch.ps1'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('powershell.exe', 'pwsh.exe') -and
            ((Test-ImgPasteProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $guardian) -or
             (Test-ImgPasteProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $watch))
        }
}

$startup = [Environment]::GetFolderPath('Startup')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$bin = Join-Path $env:USERPROFILE '.local\bin'
$share = [IO.Path]::GetFullPath($PSScriptRoot)
$nowScript = Join-Path $share 'imgpaste-now.ps1'
$guardianScript = Join-Path $share 'imgpaste-guardian.ps1'
$nowWrapperPath = Join-Path $bin 'imgpaste.cmd'
$watchWrapperPath = Join-Path $bin 'imgpaste-watch.cmd'
$watchLnk = Join-Path $startup 'imgpaste-watch.lnk'
$nowLnk = Join-Path $startMenu 'ImgPaste Now.lnk'
$watchDescription = 'Managed by imgpaste install-autostart.ps1 (guardian)'
$nowDescription = 'Managed by imgpaste install-autostart.ps1 (one-shot)'
$nowWrapper = @"
:: Managed by imgpaste install-autostart.ps1
@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "$nowScript" %*
"@
$legacyNowWrapper = @"
@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "$nowScript" %*
"@
$watchWrapper = @"
:: Managed by imgpaste install-autostart.ps1
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$guardianScript"
"@
$legacyWatchWrapper = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$guardianScript"
"@

# Validate every fixed-name item before stopping a process or removing a file.
# This makes an ownership collision fail closed without a partial uninstall.
if (-not (Test-ImgPasteCommandWrapperOwnership -Path $nowWrapperPath -ExpectedContent $nowWrapper -LegacyContent $legacyNowWrapper)) {
    throw "Refusing to remove an unrelated command wrapper: $nowWrapperPath"
}
if (-not (Test-ImgPasteCommandWrapperOwnership -Path $watchWrapperPath -ExpectedContent $watchWrapper -LegacyContent $legacyWatchWrapper)) {
    throw "Refusing to remove an unrelated command wrapper: $watchWrapperPath"
}
if (-not (Test-ImgPasteShortcutOwnership -ShortcutPath $watchLnk -ScriptPath $guardianScript -WorkingDirectory $share -Description $watchDescription -LegacyDescriptionPattern 'Watch and upload clipboard images via SSH (*)')) {
    throw "Refusing to remove an unrelated Startup shortcut: $watchLnk"
}
if (-not (Test-ImgPasteShortcutOwnership -ShortcutPath $nowLnk -ScriptPath $nowScript -WorkingDirectory $share -Description $nowDescription -LegacyDescriptionPattern 'Upload a clipboard image via SSH (*)')) {
    throw "Refusing to remove an unrelated Start Menu shortcut: $nowLnk"
}

$active = @(Get-ImgPasteCheckoutProcesses)
foreach ($process in $active) {
    if ($PSCmdlet.ShouldProcess("PowerShell process $($process.ProcessId)", 'Stop imgpaste process tree')) {
        Stop-ImgPasteProcessTree -ProcessId $process.ProcessId
    }
}

@($watchLnk, $nowLnk, $nowWrapperPath, $watchWrapperPath) |
    ForEach-Object { Remove-ImgPasteLocalItem -Path $_ }

$cfg = Get-ImgPasteConfig
if ($RemoveRemoteHelpers) {
    if ($cfg.ConfigError) { throw "Cannot remove remote helpers: $($cfg.ConfigError)" }
    $remoteDir = $cfg.RemoteDir.Trim('/')
    $remote = @"
set -eu
rm -f "`$HOME/.local/bin/imgpaste-latest" "`$HOME/.local/bin/imgpaste-xclip" "`$HOME/.local/bin/imgpaste-wl-paste"
if [ -f "`$HOME/.config/imgpaste/env" ] && grep -q '^export IMGPASTE_DIR=' "`$HOME/.config/imgpaste/env"; then
  rm -f "`$HOME/.config/imgpaste/env"
fi
"@
    if ($RemoveRemoteImages) { $remote += "`nrm -rf `"`$HOME/$remoteDir`"`n" }
    $target = "$($cfg.HostAlias): optional imgpaste remote helpers"
    if ($PSCmdlet.ShouldProcess($target, $(if ($RemoveRemoteImages) { 'Remove helpers and configured image directory' } else { 'Remove helpers' }))) {
        $sshOpts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=3', '-o', 'ServerAliveCountMax=2')
        $result = Invoke-ImgPasteProcess -FilePath 'ssh' -Arguments ($sshOpts + @($cfg.HostAlias, $remote)) -Label 'ssh remove remote helpers'
        if (-not $result.Ok) { throw "Could not remove remote helpers: $(Protect-ImgPasteLogDetail $result.Detail)" }
        Write-Host "Removed optional remote helpers from $($cfg.HostAlias)."
    }
}

if ($RemoveLocalData) {
    $dataRoot = [IO.Path]::GetFullPath($cfg.DataRoot)
    $defaultRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'imgpaste'))
    if ($dataRoot -ne $defaultRoot) {
        throw "Refusing to remove custom DataRoot '$dataRoot'. Remove it manually after verifying its contents."
    }
    if ($PSCmdlet.ShouldProcess($dataRoot, 'Remove all local imgpaste screenshots, logs, and state')) {
        Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed local imgpaste data at $dataRoot"
    }
}

if ($RemoveLocalConfig) {
    Remove-ImgPasteLocalItem -Path (Get-ImgPasteConfigPath)
}

if ($WhatIfPreference) {
    Write-Host 'No changes were made because -WhatIf was supplied.'
}
else {
    Write-Host 'imgpaste automatic startup has been removed.'
    Write-Host 'Configuration, screenshots, logs, and remote images were preserved unless their explicit removal switches were supplied.'
}
