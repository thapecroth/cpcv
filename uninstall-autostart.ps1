<#
.SYNOPSIS
Removes cpcv's local startup integration and optional helpers.

.DESCRIPTION
By default this removes only the current user's cpcv Startup and Start
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
. "$PSScriptRoot\cpcv-core.ps1"

if ($RemoveRemoteImages -and -not $RemoveRemoteHelpers) {
    throw '-RemoveRemoteImages requires -RemoveRemoteHelpers so the remote target is explicit.'
}

function Remove-CpcvLocalItem {
    param([Parameter(Mandatory)][string]$Path)
    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Remove')) {
        Remove-Item -LiteralPath $Path -Force
        Write-Host "Removed $Path"
    }
}

function Get-CpcvCheckoutProcesses {
    $guardian = Join-Path ([IO.Path]::GetFullPath($PSScriptRoot)) 'cpcv-guardian.ps1'
    $watch = Join-Path ([IO.Path]::GetFullPath($PSScriptRoot)) 'cpcv-watch.ps1'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('powershell.exe', 'pwsh.exe') -and
            ((Test-CpcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $guardian) -or
             (Test-CpcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $watch))
        }
}

$startup = [Environment]::GetFolderPath('Startup')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$bin = Join-Path $env:USERPROFILE '.local\bin'
$share = [IO.Path]::GetFullPath($PSScriptRoot)
$nowScript = Join-Path $share 'cpcv-now.ps1'
$guardianScript = Join-Path $share 'cpcv-guardian.ps1'
$nowWrapperPath = Join-Path $bin 'cpcv.cmd'
$watchWrapperPath = Join-Path $bin 'cpcv-watch.cmd'
$watchLnk = Join-Path $startup 'cpcv-watch.lnk'
$nowLnk = Join-Path $startMenu 'Cpcv Now.lnk'
$watchDescription = 'Managed by cpcv install-autostart.ps1 (guardian)'
$nowDescription = 'Managed by cpcv install-autostart.ps1 (one-shot)'
$nowWrapper = @"
:: Managed by cpcv install-autostart.ps1
@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "$nowScript" %*
"@
$watchWrapper = @"
:: Managed by cpcv install-autostart.ps1
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$guardianScript"
"@

# Validate every fixed-name item before stopping a process or removing a file.
# This makes an ownership collision fail closed without a partial uninstall.
if (-not (Test-CpcvCommandWrapperOwnership -Path $nowWrapperPath -ExpectedContent $nowWrapper)) {
    throw "Refusing to remove an unrelated command wrapper: $nowWrapperPath"
}
if (-not (Test-CpcvCommandWrapperOwnership -Path $watchWrapperPath -ExpectedContent $watchWrapper)) {
    throw "Refusing to remove an unrelated command wrapper: $watchWrapperPath"
}
if (-not (Test-CpcvShortcutOwnership -ShortcutPath $watchLnk -ScriptPath $guardianScript -WorkingDirectory $share -Description $watchDescription)) {
    throw "Refusing to remove an unrelated Startup shortcut: $watchLnk"
}
if (-not (Test-CpcvShortcutOwnership -ShortcutPath $nowLnk -ScriptPath $nowScript -WorkingDirectory $share -Description $nowDescription)) {
    throw "Refusing to remove an unrelated Start Menu shortcut: $nowLnk"
}

$active = @(Get-CpcvCheckoutProcesses)
foreach ($process in $active) {
    if ($PSCmdlet.ShouldProcess("PowerShell process $($process.ProcessId)", 'Stop cpcv process tree')) {
        Stop-CpcvProcessTree -ProcessId $process.ProcessId
    }
}

@($watchLnk, $nowLnk, $nowWrapperPath, $watchWrapperPath) |
    ForEach-Object { Remove-CpcvLocalItem -Path $_ }

$cfg = Get-CpcvConfig
if ($RemoveRemoteHelpers) {
    if ($cfg.ConfigError) { throw "Cannot remove remote helpers: $($cfg.ConfigError)" }
    $remoteDir = $cfg.RemoteDir.Trim('/')
    $remote = @"
set -eu
rm -f "`$HOME/.local/bin/cpcv-latest" "`$HOME/.local/bin/cpcv-xclip" "`$HOME/.local/bin/cpcv-wl-paste"
if [ -f "`$HOME/.config/cpcv/env" ] && grep -q '^export CPCV_DIR=' "`$HOME/.config/cpcv/env"; then
  rm -f "`$HOME/.config/cpcv/env"
fi
marker='# Managed by cpcv tmux plugin'
plugin="`$HOME/.local/lib/cpcv/tmux"
config="`$HOME/.config/cpcv/tmux-paste.conf"
config_dir="`$HOME/.config/cpcv"
owned_tmux_file() {
  [ -f "`$1" ] && ! [ -L "`$1" ] && grep -Fqx "`$marker" "`$1"
}
if ! [ -L "`$plugin" ]; then
  if owned_tmux_file "`$plugin/cpcv.tmux"; then
    rm -f "`$plugin/cpcv.tmux"
  fi
  if owned_tmux_file "`$plugin/tmux/scripts/cpcv-tmux-paste.sh"; then
    rm -f "`$plugin/tmux/scripts/cpcv-tmux-paste.sh"
  fi
  if owned_tmux_file "`$plugin/tmux/scripts/cpcv-tmux-common.sh"; then
    rm -f "`$plugin/tmux/scripts/cpcv-tmux-common.sh"
  fi
  if owned_tmux_file "`$plugin/tmux/scripts/cpcv-tmux-status.sh"; then
    rm -f "`$plugin/tmux/scripts/cpcv-tmux-status.sh"
  fi
  rmdir "`$plugin/tmux/scripts" "`$plugin/tmux" "`$plugin" 2>/dev/null || true
fi
if ! [ -L "`$config_dir" ] && owned_tmux_file "`$config"; then
  rm -f "`$config"
fi
"@
    if ($RemoveRemoteImages) { $remote += "`nrm -rf `"`$HOME/$remoteDir`"`n" }
    $target = "$($cfg.HostAlias): optional cpcv remote helpers"
    if ($PSCmdlet.ShouldProcess($target, $(if ($RemoveRemoteImages) { 'Remove helpers and configured image directory' } else { 'Remove helpers' }))) {
        $sshOpts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=3', '-o', 'ServerAliveCountMax=2')
        $result = Invoke-CpcvProcess -FilePath 'ssh' -Arguments ($sshOpts + @($cfg.HostAlias, $remote)) -Label 'ssh remove remote helpers'
        if (-not $result.Ok) { throw "Could not remove remote helpers: $(Protect-CpcvLogDetail $result.Detail)" }
        Write-Host "Removed optional remote helpers from $($cfg.HostAlias)."
    }
}

if ($RemoveLocalData) {
    $dataRoot = [IO.Path]::GetFullPath($cfg.DataRoot)
    $defaultRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'cpcv'))
    if ($dataRoot -ne $defaultRoot) {
        throw "Refusing to remove custom DataRoot '$dataRoot'. Remove it manually after verifying its contents."
    }
    if ($PSCmdlet.ShouldProcess($dataRoot, 'Remove all local cpcv screenshots, logs, and state')) {
        Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed local cpcv data at $dataRoot"
    }
}

if ($RemoveLocalConfig) {
    Remove-CpcvLocalItem -Path (Get-CpcvConfigPath)
}

if ($WhatIfPreference) {
    Write-Host 'No changes were made because -WhatIf was supplied.'
}
else {
    Write-Host 'cpcv automatic startup has been removed.'
    Write-Host 'Configuration, screenshots, logs, and remote images were preserved unless their explicit removal switches were supplied.'
}
