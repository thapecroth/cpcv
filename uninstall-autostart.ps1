<#
.SYNOPSIS
Removes ctrl-ccv's local startup integration and optional helpers.

.DESCRIPTION
By default this removes only the current user's ctrl-ccv Startup and Start
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
. "$PSScriptRoot\ctrl-ccv-core.ps1"

if ($RemoveRemoteImages -and -not $RemoveRemoteHelpers) {
    throw '-RemoveRemoteImages requires -RemoveRemoteHelpers so the remote target is explicit.'
}

function Remove-CtrlCcvLocalItem {
    param([Parameter(Mandatory)][string]$Path)
    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Remove')) {
        Remove-Item -LiteralPath $Path -Force
        Write-Host "Removed $Path"
    }
}

function Get-CtrlCcvCheckoutProcesses {
    $guardian = Join-Path ([IO.Path]::GetFullPath($PSScriptRoot)) 'ctrl-ccv-guardian.ps1'
    $watch = Join-Path ([IO.Path]::GetFullPath($PSScriptRoot)) 'ctrl-ccv-watch.ps1'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('powershell.exe', 'pwsh.exe') -and
            ((Test-CtrlCcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $guardian) -or
             (Test-CtrlCcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $watch))
        }
}

$startup = [Environment]::GetFolderPath('Startup')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$bin = Join-Path $env:USERPROFILE '.local\bin'
$share = [IO.Path]::GetFullPath($PSScriptRoot)
$nowScript = Join-Path $share 'ctrl-ccv-now.ps1'
$guardianScript = Join-Path $share 'ctrl-ccv-guardian.ps1'
$nowWrapperPath = Join-Path $bin 'ctrl-ccv.cmd'
$watchWrapperPath = Join-Path $bin 'ctrl-ccv-watch.cmd'
$watchLnk = Join-Path $startup 'ctrl-ccv-watch.lnk'
$nowLnk = Join-Path $startMenu 'ctrl-ccv Now.lnk'
$watchDescription = 'Managed by ctrl-ccv install-autostart.ps1 (guardian)'
$nowDescription = 'Managed by ctrl-ccv install-autostart.ps1 (one-shot)'
$nowWrapper = @"
:: Managed by ctrl-ccv install-autostart.ps1
@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "$nowScript" %*
"@
$watchWrapper = @"
:: Managed by ctrl-ccv install-autostart.ps1
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$guardianScript"
"@

# Validate every fixed-name item before stopping a process or removing a file.
# This makes an ownership collision fail closed without a partial uninstall.
if (-not (Test-CtrlCcvCommandWrapperOwnership -Path $nowWrapperPath -ExpectedContent $nowWrapper)) {
    throw "Refusing to remove an unrelated command wrapper: $nowWrapperPath"
}
if (-not (Test-CtrlCcvCommandWrapperOwnership -Path $watchWrapperPath -ExpectedContent $watchWrapper)) {
    throw "Refusing to remove an unrelated command wrapper: $watchWrapperPath"
}
if (-not (Test-CtrlCcvShortcutOwnership -ShortcutPath $watchLnk -ScriptPath $guardianScript -WorkingDirectory $share -Description $watchDescription)) {
    throw "Refusing to remove an unrelated Startup shortcut: $watchLnk"
}
if (-not (Test-CtrlCcvShortcutOwnership -ShortcutPath $nowLnk -ScriptPath $nowScript -WorkingDirectory $share -Description $nowDescription)) {
    throw "Refusing to remove an unrelated Start Menu shortcut: $nowLnk"
}

$active = @(Get-CtrlCcvCheckoutProcesses)
foreach ($process in $active) {
    if ($PSCmdlet.ShouldProcess("PowerShell process $($process.ProcessId)", 'Stop ctrl-ccv process tree')) {
        Stop-CtrlCcvProcessTree -ProcessId $process.ProcessId
    }
}

@($watchLnk, $nowLnk, $nowWrapperPath, $watchWrapperPath) |
    ForEach-Object { Remove-CtrlCcvLocalItem -Path $_ }

$cfg = Get-CtrlCcvConfig
if ($RemoveRemoteHelpers) {
    if ($cfg.ConfigError) { throw "Cannot remove remote helpers: $($cfg.ConfigError)" }
    $remoteDir = $cfg.RemoteDir.Trim('/')
    $remote = @"
set -eu
rm -f "`$HOME/.local/bin/ctrl-ccv-latest" "`$HOME/.local/bin/ctrl-ccv-xclip" "`$HOME/.local/bin/ctrl-ccv-wl-paste"
if [ -f "`$HOME/.config/ctrl-ccv/env" ] && grep -q '^export CTRL_CCV_DIR=' "`$HOME/.config/ctrl-ccv/env"; then
  rm -f "`$HOME/.config/ctrl-ccv/env"
fi
marker='# Managed by ctrl-ccv tmux plugin'
plugin="`$HOME/.local/lib/ctrl-ccv/tmux"
config="`$HOME/.config/ctrl-ccv/tmux-paste.conf"
config_dir="`$HOME/.config/ctrl-ccv"
owned_tmux_file() {
  [ -f "`$1" ] && ! [ -L "`$1" ] && grep -Fqx "`$marker" "`$1"
}
if ! [ -L "`$plugin" ]; then
  if owned_tmux_file "`$plugin/ctrl-ccv.tmux"; then
    rm -f "`$plugin/ctrl-ccv.tmux"
  fi
  if owned_tmux_file "`$plugin/tmux/scripts/ctrl-ccv-tmux-paste.sh"; then
    rm -f "`$plugin/tmux/scripts/ctrl-ccv-tmux-paste.sh"
  fi
  if owned_tmux_file "`$plugin/tmux/scripts/ctrl-ccv-tmux-common.sh"; then
    rm -f "`$plugin/tmux/scripts/ctrl-ccv-tmux-common.sh"
  fi
  if owned_tmux_file "`$plugin/tmux/scripts/ctrl-ccv-tmux-status.sh"; then
    rm -f "`$plugin/tmux/scripts/ctrl-ccv-tmux-status.sh"
  fi
  rmdir "`$plugin/tmux/scripts" "`$plugin/tmux" "`$plugin" 2>/dev/null || true
fi
if ! [ -L "`$config_dir" ] && owned_tmux_file "`$config"; then
  rm -f "`$config"
fi
"@
    if ($RemoveRemoteImages) { $remote += "`nrm -rf `"`$HOME/$remoteDir`"`n" }
    $target = "$($cfg.HostAlias): optional ctrl-ccv remote helpers"
    if ($PSCmdlet.ShouldProcess($target, $(if ($RemoveRemoteImages) { 'Remove helpers and configured image directory' } else { 'Remove helpers' }))) {
        $sshOpts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=3', '-o', 'ServerAliveCountMax=2')
        $result = Invoke-CtrlCcvProcess -FilePath 'ssh' -Arguments ($sshOpts + @($cfg.HostAlias, $remote)) -Label 'ssh remove remote helpers'
        if (-not $result.Ok) { throw "Could not remove remote helpers: $(Protect-CtrlCcvLogDetail $result.Detail)" }
        Write-Host "Removed optional remote helpers from $($cfg.HostAlias)."
    }
}

if ($RemoveLocalData) {
    $dataRoot = [IO.Path]::GetFullPath($cfg.DataRoot)
    $defaultRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ctrl-ccv'))
    if ($dataRoot -ne $defaultRoot) {
        throw "Refusing to remove custom DataRoot '$dataRoot'. Remove it manually after verifying its contents."
    }
    if ($PSCmdlet.ShouldProcess($dataRoot, 'Remove all local ctrl-ccv screenshots, logs, and state')) {
        Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed local ctrl-ccv data at $dataRoot"
    }
}

if ($RemoveLocalConfig) {
    Remove-CtrlCcvLocalItem -Path (Get-CtrlCcvConfigPath)
}

if ($WhatIfPreference) {
    Write-Host 'No changes were made because -WhatIf was supplied.'
}
else {
    Write-Host 'ctrl-ccv automatic startup has been removed.'
    Write-Host 'Configuration, screenshots, logs, and remote images were preserved unless their explicit removal switches were supplied.'
}
