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
. "$PSScriptRoot\imgpaste-core.ps1"

$cfg = Get-ImgPasteConfig
if ($cfg.ConfigError) {
    throw "$($cfg.ConfigError)`nCreate the file from '$PSScriptRoot\imgpaste.config.example.psd1' before installing."
}

foreach ($command in "powershell.exe", "ssh.exe", "scp.exe") {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command not found: $command" }
}

$bin = Join-Path $env:USERPROFILE ".local\bin"
$share = [IO.Path]::GetFullPath($PSScriptRoot)
$startup = [Environment]::GetFolderPath("Startup")
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$nowScript = Join-Path $share "imgpaste-now.ps1"
$guardianScript = Join-Path $share "imgpaste-guardian.ps1"
$nowWrapperPath = Join-Path $bin "imgpaste.cmd"
$watchWrapperPath = Join-Path $bin "imgpaste-watch.cmd"
$watchLnk = Join-Path $startup "imgpaste-watch.lnk"
$nowLnk = Join-Path $startMenu "ImgPaste Now.lnk"
$watchDescription = "Managed by imgpaste install-autostart.ps1 (guardian)"
$nowDescription = "Managed by imgpaste install-autostart.ps1 (one-shot)"

# Lightweight command wrappers deliberately point to this checkout/install
# root; the one-shot script needs its neighbouring core script.
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

# Fixed names are shared user resources. Validate every existing item before
# writing anything so an unrelated shortcut or wrapper is never overwritten.
if (-not (Test-ImgPasteCommandWrapperOwnership -Path $nowWrapperPath -ExpectedContent $nowWrapper -LegacyContent $legacyNowWrapper)) {
    throw "Refusing to replace an unrelated command wrapper: $nowWrapperPath"
}
if (-not (Test-ImgPasteCommandWrapperOwnership -Path $watchWrapperPath -ExpectedContent $watchWrapper -LegacyContent $legacyWatchWrapper)) {
    throw "Refusing to replace an unrelated command wrapper: $watchWrapperPath"
}
if (-not (Test-ImgPasteShortcutOwnership -ShortcutPath $watchLnk -ScriptPath $guardianScript -WorkingDirectory $share -Description $watchDescription -LegacyDescriptionPattern "Watch and upload clipboard images via SSH (*)")) {
    throw "Refusing to replace an unrelated Startup shortcut: $watchLnk"
}
if (-not (Test-ImgPasteShortcutOwnership -ShortcutPath $nowLnk -ScriptPath $nowScript -WorkingDirectory $share -Description $nowDescription -LegacyDescriptionPattern "Upload a clipboard image via SSH (*)")) {
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
        (Test-ImgPasteProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $guardianScript)
    }
if (-not $existing) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", $guardianScript) -WindowStyle Hidden
    Write-Host "Started imgpaste watchdog."
}
else {
    Write-Host "ImgPaste watchdog is already running."
}

function Install-ImgPasteRemoteHelpers {
    $sshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2")
    $stageResult = Invoke-ImgPasteProcess -FilePath "ssh" -Arguments ($sshOpts + @($cfg.HostAlias, "mktemp -d")) -Label "ssh create remote staging directory"
    if (-not $stageResult.Ok) { throw "Could not create remote staging directory: $(Protect-ImgPasteLogDetail $stageResult.Detail)" }
    $stage = ($stageResult.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
    if ($stage -notmatch '^/tmp/[A-Za-z0-9._-]+$') { throw "Remote staging path was unexpected; refusing to continue." }

    $files = @("imgpaste-latest.sh", "xclip-shim.sh", "wl-paste-shim.sh") | ForEach-Object { Join-Path $share $_ }
    foreach ($file in $files) { if (-not (Test-Path $file)) { throw "Missing helper: $file" } }
    $copy = Invoke-ImgPasteProcess -FilePath "scp" -Arguments ($sshOpts + $files + @("$($cfg.HostAlias):$stage/")) -Label "scp remote helpers"
    if (-not $copy.Ok) { throw "Could not copy remote helpers: $(Protect-ImgPasteLogDetail $copy.Detail)" }

    $remoteDir = $cfg.RemoteDir.Trim('/')
    $remote = @"
set -eu
stage='$stage'
mkdir -p "`$HOME/.local/bin" "`$HOME/.config/imgpaste" "`$HOME/$remoteDir"
install -m 755 "`$stage/imgpaste-latest.sh" "`$HOME/.local/bin/imgpaste-latest"
install -m 755 "`$stage/xclip-shim.sh" "`$HOME/.local/bin/imgpaste-xclip"
install -m 755 "`$stage/wl-paste-shim.sh" "`$HOME/.local/bin/imgpaste-wl-paste"
printf 'export IMGPASTE_DIR="%s"\n' "`$HOME/$remoteDir" > "`$HOME/.config/imgpaste/env"
rm -rf "`$stage"
echo "Installed optional helpers in `$HOME/.local/bin"
"@
    $install = Invoke-ImgPasteProcess -FilePath "ssh" -Arguments ($sshOpts + @($cfg.HostAlias, $remote)) -Label "ssh install remote helpers"
    if (-not $install.Ok) { throw "Could not install remote helpers: $(Protect-ImgPasteLogDetail $install.Detail)" }
    Write-Host $install.StdOut.Trim()
}

Write-Host "Local watcher installed for SSH target '$($cfg.HostAlias)'."
Write-Host "Screenshot/copy an image, wait about $($cfg.PollIntervalSeconds) seconds, then paste the reported remote path."
Write-Host "Config: $(Get-ImgPasteConfigPath)"
if ($DeployRemoteHelpers) {
    Install-ImgPasteRemoteHelpers
    Write-Host "Optional remote helpers installed. Add ~/.local/bin to PATH on the remote host if it is not already present."
}
else {
    Write-Host "Remote helpers were not changed. Re-run with -DeployRemoteHelpers to opt in."
}
