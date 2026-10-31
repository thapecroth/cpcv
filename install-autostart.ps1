<#
.SYNOPSIS
Installs the local Windows watcher for the configured SSH target.

.DESCRIPTION
This script only creates local wrappers, shortcuts, and the watchdog by
default. Pass -DeployRemoteHelpers to explicitly install optional POSIX helper
scripts on the configured SSH host.
#>
[CmdletBinding()]
param(
    [switch]$DeployRemoteHelpers
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\ctrl-ccv-core.ps1"

$cfg = Get-CtrlCcvConfig
if ($cfg.ConfigError) {
    throw "$($cfg.ConfigError)`nCreate the file from '$PSScriptRoot\ctrl-ccv.config.example.psd1' before installing."
}

foreach ($command in "powershell.exe", "ssh.exe", "scp.exe") {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command not found: $command" }
}

$bin = Join-Path $env:USERPROFILE ".local\bin"
$share = [IO.Path]::GetFullPath($PSScriptRoot)
$startup = [Environment]::GetFolderPath("Startup")
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$nowScript = Join-Path $share "ctrl-ccv-now.ps1"
$guardianScript = Join-Path $share "ctrl-ccv-guardian.ps1"
$nowWrapperPath = Join-Path $bin "ctrl-ccv.cmd"
$watchWrapperPath = Join-Path $bin "ctrl-ccv-watch.cmd"
$watchLnk = Join-Path $startup "ctrl-ccv-watch.lnk"
$nowLnk = Join-Path $startMenu "ctrl-ccv Now.lnk"
$watchDescription = "Managed by ctrl-ccv install-autostart.ps1 (guardian)"
$nowDescription = "Managed by ctrl-ccv install-autostart.ps1 (one-shot)"

# Lightweight command wrappers deliberately point to this checkout/install
# root; the one-shot script needs its neighbouring core script.
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

# Fixed names are shared user resources. Validate every existing item before
# writing anything so an unrelated shortcut or wrapper is never overwritten.
if (-not (Test-CtrlCcvCommandWrapperOwnership -Path $nowWrapperPath -ExpectedContent $nowWrapper)) {
    throw "Refusing to replace an unrelated command wrapper: $nowWrapperPath"
}
if (-not (Test-CtrlCcvCommandWrapperOwnership -Path $watchWrapperPath -ExpectedContent $watchWrapper)) {
    throw "Refusing to replace an unrelated command wrapper: $watchWrapperPath"
}
if (-not (Test-CtrlCcvShortcutOwnership -ShortcutPath $watchLnk -ScriptPath $guardianScript -WorkingDirectory $share -Description $watchDescription)) {
    throw "Refusing to replace an unrelated Startup shortcut: $watchLnk"
}
if (-not (Test-CtrlCcvShortcutOwnership -ShortcutPath $nowLnk -ScriptPath $nowScript -WorkingDirectory $share -Description $nowDescription)) {
    throw "Refusing to replace an unrelated Start Menu shortcut: $nowLnk"
}

New-Item -ItemType Directory -Force -Path $bin, $startMenu | Out-Null
$nowWrapper | Set-Content -LiteralPath $nowWrapperPath -Encoding ASCII
$watchWrapper | Set-Content -LiteralPath $watchWrapperPath -Encoding ASCII

$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($watchLnk)
$sc.TargetPath = "powershell.exe"
$sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$guardianScript`""
$sc.WorkingDirectory = $share
$sc.WindowStyle = 7
$sc.Description = $watchDescription
$sc.Save()

$sc2 = $wsh.CreateShortcut($nowLnk)
$sc2.TargetPath = "powershell.exe"
$sc2.Arguments = "-NoProfile -STA -ExecutionPolicy RemoteSigned -File `"$nowScript`""
$sc2.WorkingDirectory = $share
$sc2.Description = $nowDescription
$sc2.Save()

$existing = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -in @("powershell.exe", "pwsh.exe") -and
        (Test-CtrlCcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $guardianScript)
    }
if (-not $existing) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $guardianScript)) -WindowStyle Hidden
    Write-Host "Started ctrl-ccv watchdog."
}
else {
    Write-Host "ctrl-ccv watchdog is already running."
}

function Install-CtrlCcvRemoteHelpers {
    $sshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2")
    $stageResult = Invoke-CtrlCcvProcess -FilePath "ssh" -Arguments ($sshOpts + @($cfg.HostAlias, "mktemp -d")) -Label "ssh create remote staging directory"
    if (-not $stageResult.Ok) { throw "Could not create remote staging directory: $(Protect-CtrlCcvLogDetail $stageResult.Detail)" }
    $stage = ($stageResult.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
    if ($stage -notmatch '^/tmp/[A-Za-z0-9._-]+$') { throw "Remote staging path was unexpected; refusing to continue." }

    $files = @(
        "ctrl-ccv-latest.sh",
        "xclip-shim.sh",
        "wl-paste-shim.sh",
        "ctrl-ccv.tmux",
        "tmux\scripts\ctrl-ccv-tmux-paste.sh",
        "tmux\scripts\ctrl-ccv-tmux-common.sh",
        "tmux\scripts\ctrl-ccv-tmux-status.sh",
        "remote\install-tmux-ctrl-ccv-plugin.sh"
    ) | ForEach-Object { Join-Path $share $_ }
    foreach ($file in $files) { if (-not (Test-Path $file)) { throw "Missing helper: $file" } }
    $copy = Invoke-CtrlCcvProcess -FilePath "scp" -Arguments ($sshOpts + $files + @("$($cfg.HostAlias):$stage/")) -Label "scp remote helpers"
    if (-not $copy.Ok) { throw "Could not copy remote helpers: $(Protect-CtrlCcvLogDetail $copy.Detail)" }

    $remoteDir = $cfg.RemoteDir.Trim('/')
    $remote = @"
set -eu
stage='$stage'
mkdir -p "`$HOME/.local/bin" "`$HOME/.config/ctrl-ccv" "`$HOME/$remoteDir"
install -m 755 "`$stage/ctrl-ccv-latest.sh" "`$HOME/.local/bin/ctrl-ccv-latest"
install -m 755 "`$stage/xclip-shim.sh" "`$HOME/.local/bin/ctrl-ccv-xclip"
install -m 755 "`$stage/wl-paste-shim.sh" "`$HOME/.local/bin/ctrl-ccv-wl-paste"
printf 'export CTRL_CCV_DIR="%s"\n' "`$HOME/$remoteDir" > "`$HOME/.config/ctrl-ccv/env"
/usr/bin/env bash "`$stage/install-tmux-ctrl-ccv-plugin.sh" --remote-dir "$remoteDir"
rm -rf "`$stage"
echo "Installed optional helpers in `$HOME/.local/bin"
"@
    $install = Invoke-CtrlCcvProcess -FilePath "ssh" -Arguments ($sshOpts + @($cfg.HostAlias, $remote)) -Label "ssh install remote helpers"
    if (-not $install.Ok) { throw "Could not install remote helpers: $(Protect-CtrlCcvLogDetail $install.Detail)" }
    Write-Host $install.StdOut.Trim()
}

Write-Host "Local watcher installed for SSH target '$($cfg.HostAlias)'."
Write-Host "Screenshot/copy an image, wait about $($cfg.PollIntervalSeconds) seconds, then use the tmux ctrl-ccv paste binding on the SSH host."
Write-Host "Config: $(Get-CtrlCcvConfigPath)"
if ($DeployRemoteHelpers) {
    Install-CtrlCcvRemoteHelpers
    Write-Host "Optional remote helpers and tmux plugin were installed. Add ~/.local/bin to PATH and the printed run-shell line to tmux on the remote host."
}
else {
    Write-Host "Remote helpers were not changed. Re-run with -DeployRemoteHelpers to opt in."
}
