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
. "$PSScriptRoot\cpcv-core.ps1"

$cfg = Get-CpcvConfig
if ($cfg.ConfigError) {
    throw "$($cfg.ConfigError)`nCreate the file from '$PSScriptRoot\cpcv.config.example.psd1' before installing."
}

foreach ($command in "powershell.exe", "ssh.exe", "scp.exe") {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command not found: $command" }
}

$bin = Join-Path $env:USERPROFILE ".local\bin"
$share = [IO.Path]::GetFullPath($PSScriptRoot)
$startup = [Environment]::GetFolderPath("Startup")
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$nowScript = Join-Path $share "cpcv-now.ps1"
$guardianScript = Join-Path $share "cpcv-guardian.ps1"
$nowWrapperPath = Join-Path $bin "cpcv.cmd"
$watchWrapperPath = Join-Path $bin "cpcv-watch.cmd"
$watchLnk = Join-Path $startup "cpcv-watch.lnk"
$nowLnk = Join-Path $startMenu "Cpcv Now.lnk"
$watchDescription = "Managed by cpcv install-autostart.ps1 (guardian)"
$nowDescription = "Managed by cpcv install-autostart.ps1 (one-shot)"

# Lightweight command wrappers deliberately point to this checkout/install
# root; the one-shot script needs its neighbouring core script.
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

# Fixed names are shared user resources. Validate every existing item before
# writing anything so an unrelated shortcut or wrapper is never overwritten.
if (-not (Test-CpcvCommandWrapperOwnership -Path $nowWrapperPath -ExpectedContent $nowWrapper)) {
    throw "Refusing to replace an unrelated command wrapper: $nowWrapperPath"
}
if (-not (Test-CpcvCommandWrapperOwnership -Path $watchWrapperPath -ExpectedContent $watchWrapper)) {
    throw "Refusing to replace an unrelated command wrapper: $watchWrapperPath"
}
if (-not (Test-CpcvShortcutOwnership -ShortcutPath $watchLnk -ScriptPath $guardianScript -WorkingDirectory $share -Description $watchDescription)) {
    throw "Refusing to replace an unrelated Startup shortcut: $watchLnk"
}
if (-not (Test-CpcvShortcutOwnership -ShortcutPath $nowLnk -ScriptPath $nowScript -WorkingDirectory $share -Description $nowDescription)) {
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
        (Test-CpcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $guardianScript)
    }
if (-not $existing) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $guardianScript)) -WindowStyle Hidden
    Write-Host "Started cpcv watchdog."
}
else {
    Write-Host "Cpcv watchdog is already running."
}

function Install-CpcvRemoteHelpers {
    $sshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2")
    $stageResult = Invoke-CpcvProcess -FilePath "ssh" -Arguments ($sshOpts + @($cfg.HostAlias, "mktemp -d")) -Label "ssh create remote staging directory"
    if (-not $stageResult.Ok) { throw "Could not create remote staging directory: $(Protect-CpcvLogDetail $stageResult.Detail)" }
    $stage = ($stageResult.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
    if ($stage -notmatch '^/tmp/[A-Za-z0-9._-]+$') { throw "Remote staging path was unexpected; refusing to continue." }

    $files = @(
        "cpcv-latest.sh",
        "xclip-shim.sh",
        "wl-paste-shim.sh",
        "cpcv.tmux",
        "tmux\scripts\cpcv-tmux-paste.sh",
        "tmux\scripts\cpcv-tmux-common.sh",
        "tmux\scripts\cpcv-tmux-status.sh",
        "remote\install-tmux-cpcv-plugin.sh"
    ) | ForEach-Object { Join-Path $share $_ }
    foreach ($file in $files) { if (-not (Test-Path $file)) { throw "Missing helper: $file" } }
    $copy = Invoke-CpcvProcess -FilePath "scp" -Arguments ($sshOpts + $files + @("$($cfg.HostAlias):$stage/")) -Label "scp remote helpers"
    if (-not $copy.Ok) { throw "Could not copy remote helpers: $(Protect-CpcvLogDetail $copy.Detail)" }

    $remoteDir = $cfg.RemoteDir.Trim('/')
    $remote = @"
set -eu
stage='$stage'
mkdir -p "`$HOME/.local/bin" "`$HOME/.config/cpcv" "`$HOME/$remoteDir"
install -m 755 "`$stage/cpcv-latest.sh" "`$HOME/.local/bin/cpcv-latest"
install -m 755 "`$stage/xclip-shim.sh" "`$HOME/.local/bin/cpcv-xclip"
install -m 755 "`$stage/wl-paste-shim.sh" "`$HOME/.local/bin/cpcv-wl-paste"
printf 'export CPCV_DIR="%s"\n' "`$HOME/$remoteDir" > "`$HOME/.config/cpcv/env"
/usr/bin/env bash "`$stage/install-tmux-cpcv-plugin.sh" --remote-dir "$remoteDir"
rm -rf "`$stage"
echo "Installed optional helpers in `$HOME/.local/bin"
"@
    $install = Invoke-CpcvProcess -FilePath "ssh" -Arguments ($sshOpts + @($cfg.HostAlias, $remote)) -Label "ssh install remote helpers"
    if (-not $install.Ok) { throw "Could not install remote helpers: $(Protect-CpcvLogDetail $install.Detail)" }
    Write-Host $install.StdOut.Trim()
}

Write-Host "Local watcher installed for SSH target '$($cfg.HostAlias)'."
Write-Host "Screenshot/copy an image, wait about $($cfg.PollIntervalSeconds) seconds, then use the tmux cpcv paste binding on the SSH host."
Write-Host "Config: $(Get-CpcvConfigPath)"
if ($DeployRemoteHelpers) {
    Install-CpcvRemoteHelpers
    Write-Host "Optional remote helpers and tmux plugin were installed. Add ~/.local/bin to PATH and the printed run-shell line to tmux on the remote host."
}
else {
    Write-Host "Remote helpers were not changed. Re-run with -DeployRemoteHelpers to opt in."
}
