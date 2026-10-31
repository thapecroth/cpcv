<#
.SYNOPSIS
Per-user setup bridge invoked only by the ctrl-ccv Windows installer.

.DESCRIPTION
Creates a minimal private configuration only for a first-time install, then
uses the existing ownership-safe ctrl-ccv installers to start the watcher and tray.
It never accepts passwords, keys, shell fragments, or arbitrary commands.
Existing configuration (including a CTRL_CCV_CONFIG override) is deliberately left
unchanged.
#>
[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$HostAlias = "",

    [string]$RemoteDir = "clipboard-images",

    [switch]$DeployRemoteHelpers,

    # The Inno Setup wizard passes a short-lived, local-only INI path here so
    # it can show a human-readable onboarding summary after the bootstrap
    # exits. This is intentionally status only: no SSH output, credentials,
    # or remote paths are written to it.
    [AllowEmptyString()]
    [string]$StatusFile = "",

    [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"

if (-not $IsWindows -and $env:OS -ne "Windows_NT") {
    throw "ctrl-ccv-installer.ps1 is for Windows only."
}

$script:CtrlCcvInstallerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$coreScript = Join-Path $script:CtrlCcvInstallerRoot "ctrl-ccv-core.ps1"
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    throw "The ctrl-ccv installer files are incomplete."
}
. $coreScript

function Test-CtrlCcvInstallerHostAlias {
    param([AllowEmptyString()][string]$Value)

    return ($Value -match '^[A-Za-z0-9][A-Za-z0-9._@:-]*$')
}

function Test-CtrlCcvInstallerRemoteDir {
    param([AllowEmptyString()][string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { return $false }
    if ($Value.StartsWith('/')) { return $false }
    if ($Value -match '(^|/)\.\.(/|$)') { return $false }
    return $true
}

function Test-CtrlCcvInstallerReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-CtrlCcvInstallerPrerequisites {
    foreach ($command in @("powershell.exe", "ssh.exe", "scp.exe")) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required Windows command was not found: $command"
        }
    }
}

function New-CtrlCcvInstallerInitialConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$InitialHostAlias,
        [Parameter(Mandatory)][string]$InitialRemoteDir
    )

    if (Test-Path -LiteralPath $ConfigPath) {
        return [pscustomobject]@{ Created = $false; Preserved = $true }
    }
    if (-not (Test-CtrlCcvInstallerHostAlias -Value $InitialHostAlias)) {
        throw "HostAlias must be an SSH alias, hostname, or user@host using only supported characters."
    }
    if (-not (Test-CtrlCcvInstallerRemoteDir -Value $InitialRemoteDir)) {
        throw "RemoteDir must be a relative POSIX path without '..'."
    }

    $configDirectory = Split-Path -LiteralPath $ConfigPath -Parent
    if (Test-CtrlCcvInstallerReparsePoint -Path $configDirectory) {
        throw "Refusing to create configuration in a reparse-point directory."
    }
    if (-not (Test-Path -LiteralPath $configDirectory)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }
    if (Test-CtrlCcvInstallerReparsePoint -Path $configDirectory) {
        throw "Refusing to create configuration in a reparse-point directory."
    }
    if (Test-CtrlCcvInstallerReparsePoint -Path $ConfigPath) {
        throw "Refusing to replace a reparse-point configuration file."
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        return [pscustomobject]@{ Created = $false; Preserved = $true }
    }

    # Values have already been constrained to a narrow ASCII allow-list, so
    # they cannot turn this data-only PowerShell configuration into code.
    $content = @"
@{
    HostAlias = "$InitialHostAlias"
    RemoteDir = "$InitialRemoteDir"
    RemoteHome = ""
}
"@.TrimStart()
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content + [Environment]::NewLine)
    $stream = $null
    try {
        # CreateNew fails if another process supplied configuration first. Do
        # not race to overwrite a user's private file.
        $stream = [IO.File]::Open($ConfigPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch [IO.IOException] {
        if (Test-Path -LiteralPath $ConfigPath) {
            return [pscustomobject]@{ Created = $false; Preserved = $true }
        }
        throw
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
    return [pscustomobject]@{ Created = $true; Preserved = $false }
}

function Get-CtrlCcvInstallerConfigurationState {
    $hasOverride = -not [string]::IsNullOrWhiteSpace($env:CTRL_CCV_CONFIG)
    $configPath = Get-CtrlCcvConfigPath
    if ($hasOverride -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "CTRL_CCV_CONFIG is set but does not point to an existing private configuration file. Repair or remove that override before installing."
    }
    if (Test-CtrlCcvInstallerReparsePoint -Path $configPath) {
        throw "Refusing to use a reparse-point configuration file."
    }
    return [pscustomobject]@{
        Path = $configPath
        HasOverride = $hasOverride
        Exists = (Test-Path -LiteralPath $configPath -PathType Leaf)
    }
}

function New-CtrlCcvInstallerStatus {
    # Keep every value deliberately short and predictable. The setup wizard
    # displays these values after the bootstrap has exited, so raw process
    # output must never cross this boundary.
    return [ordered]@{
        Result               = "Not started"
        Failure              = ""
        Configuration        = "Not checked"
        HostAlias             = ""
        RemoteDir             = ""
        LocalWatcher          = "Not started"
        Tray                  = "Not started"
        SshConnection         = "Not checked"
        RemoteTmux            = "Not checked"
        TmuxPlugin            = "Not checked"
        TmuxPluginRequested   = "No"
    }
}

function Write-CtrlCcvInstallerStatus {
    param(
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Status
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $directory = Split-Path -LiteralPath $fullPath -Parent
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
        if (Test-CtrlCcvInstallerReparsePoint -Path $directory) { return }
        if (Test-CtrlCcvInstallerReparsePoint -Path $fullPath) { return }

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("[ctrl-ccv]")
        foreach ($key in $Status.Keys) {
            # Status values are controlled above, but keep the file format
            # safe even if a future caller adds a different value.
            $value = ([string]$Status[$key] -replace '[\r\n=]', ' ').Trim()
            $lines.Add("$key=$value")
        }
        [IO.File]::WriteAllLines($fullPath, $lines, [Text.Encoding]::ASCII)
    }
    catch {
        # A missing status summary must not turn a completed local install
        # into a failure. Setup still receives the process exit status.
    }
}

function Get-CtrlCcvInstallerRemoteCapabilities {
    param([Parameter(Mandatory)][string]$Target)

    $state = [pscustomobject]@{
        Connection = "Needs SSH setup"
        Tmux       = "Unknown"
        Plugin     = "Unknown"
    }
    # This is a POSIX-shell-only diagnostic. It does not change the host,
    # accept host keys, or prompt for passwords: the local watcher also needs
    # a non-interactive SSH connection to operate reliably.
    $remoteCommand = @'
if command -v tmux >/dev/null 2>&1; then
  printf '%s\n' 'CTRL_CCV_TMUX=installed'
else
  printf '%s\n' 'CTRL_CCV_TMUX=missing'
fi
plugin="$HOME/.local/lib/ctrl-ccv/tmux/ctrl-ccv.tmux"
if [ -f "$plugin" ] && [ ! -L "$plugin" ] && grep -Fqx '# Managed by ctrl-ccv tmux plugin' "$plugin"; then
  printf '%s\n' 'CTRL_CCV_PLUGIN=installed'
else
  printf '%s\n' 'CTRL_CCV_PLUGIN=missing'
fi
'@.Trim()
    $sshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2")

    try {
        $probe = Invoke-CtrlCcvProcess -FilePath "ssh.exe" -Arguments ($sshOpts + @($Target, $remoteCommand)) -Label "ssh ctrl-ccv capability check"
        if (-not $probe.Ok) { return $state }

        $state.Connection = "Connected"
        foreach ($line in ([string]$probe.StdOut -split "`r?`n")) {
            switch ($line.Trim()) {
                "CTRL_CCV_TMUX=installed" { $state.Tmux = "Installed" }
                "CTRL_CCV_TMUX=missing" { $state.Tmux = "Not installed" }
                "CTRL_CCV_PLUGIN=installed" { $state.Plugin = "Already installed" }
                "CTRL_CCV_PLUGIN=missing" { $state.Plugin = "Not installed" }
            }
        }
    }
    catch {
        # The remote target is optional for the local service. Keep this
        # result non-fatal and let the onboarding UI explain what to fix.
    }
    return $state
}

$installerStatus = New-CtrlCcvInstallerStatus
$remoteHelpersInstalled = $false
$remoteHelpersWarning = $false

try {
    Assert-CtrlCcvInstallerPrerequisites
    $configuration = Get-CtrlCcvInstallerConfigurationState

    if ($PreflightOnly) {
        [pscustomobject]@{
            Ready = $true
            ExistingConfiguration = [bool]$configuration.Exists
            ConfigurationOverride = [bool]$configuration.HasOverride
        } | ConvertTo-Json -Compress
        return
    }

    if (-not $configuration.Exists) {
        $configurationResult = New-CtrlCcvInstallerInitialConfig -ConfigPath $configuration.Path -InitialHostAlias $HostAlias.Trim() -InitialRemoteDir $RemoteDir.Trim()
    }
    else {
        $configurationResult = [pscustomobject]@{ Created = $false; Preserved = $true }
    }

    # Re-read through ctrl-ccv's canonical parser before any Startup integration is
    # written. This makes malformed or externally supplied config fail closed.
    $validatedConfiguration = Get-CtrlCcvConfig
    if ($validatedConfiguration.ConfigError) {
        throw "ctrl-ccv configuration is not ready: $($validatedConfiguration.ConfigError)"
    }

    $installerStatus.Configuration = if ($configurationResult.Created) { "Created" } else { "Preserved" }
    $installerStatus.HostAlias = $validatedConfiguration.HostAlias
    $installerStatus.RemoteDir = $validatedConfiguration.RemoteDir
    $installerStatus.TmuxPluginRequested = if ($DeployRemoteHelpers) { "Yes" } else { "No" }

    $localInstaller = Join-Path $script:CtrlCcvInstallerRoot "install-autostart.ps1"
    $trayInstaller = Join-Path $script:CtrlCcvInstallerRoot "install-tray.ps1"
    $localUninstaller = Join-Path $script:CtrlCcvInstallerRoot "uninstall-autostart.ps1"
    $trayUninstaller = Join-Path $script:CtrlCcvInstallerRoot "uninstall-tray.ps1"
    if (@($localInstaller, $trayInstaller, $localUninstaller, $trayUninstaller) |
            Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }) {
        throw "The ctrl-ccv installer files are incomplete."
    }

    # Stop only this stable checkout's owned processes and integration before
    # starting the refreshed copy. The uninstallers validate every fixed-name
    # shortcut, wrapper, and command line first, so a portable-install collision
    # fails closed instead of being migrated or overwritten automatically.
    & $trayUninstaller -Confirm:$false *>&1 | Out-Null
    & $localUninstaller -Confirm:$false *>&1 | Out-Null

    # Keep child installer output out of the setup UI and process environment.
    # Local startup and the tray are complete before the separately optional
    # remote deployment is attempted, so a temporarily unreachable SSH host
    # cannot make Setup misreport a healthy local service as failed.
    & $localInstaller *>&1 | Out-Null
    $installerStatus.LocalWatcher = "Installed"
    & $trayInstaller -Confirm:$false *>&1 | Out-Null
    $installerStatus.Tray = "Installed"

    $remoteCapabilities = Get-CtrlCcvInstallerRemoteCapabilities -Target $validatedConfiguration.HostAlias
    $installerStatus.SshConnection = $remoteCapabilities.Connection
    $installerStatus.RemoteTmux = $remoteCapabilities.Tmux
    $installerStatus.TmuxPlugin = $remoteCapabilities.Plugin

    if ($DeployRemoteHelpers) {
        if ($remoteCapabilities.Connection -eq "Connected") {
            try {
                & $localInstaller -DeployRemoteHelpers *>&1 | Out-Null
                $remoteHelpersInstalled = $true
                $installerStatus.TmuxPlugin = "Installed by Setup"
            }
            catch {
                # Remote helpers are explicitly optional. Do not show raw SSH
                # output or turn a healthy local installation into a failure.
                $remoteHelpersWarning = $true
                $installerStatus.TmuxPlugin = "Could not install"
            }
        }
        else {
            $remoteHelpersWarning = $true
            $installerStatus.TmuxPlugin = "Not installed (SSH not connected)"
        }
    }
    elseif ($remoteCapabilities.Plugin -eq "Not installed") {
        $installerStatus.TmuxPlugin = "Not requested"
    }

    $installerStatus.Result = "Installed"
    [pscustomobject]@{
        Installed = $true
        CreatedConfiguration = [bool]$configurationResult.Created
        PreservedConfiguration = [bool]$configurationResult.Preserved
        RemoteHelpersRequested = [bool]$DeployRemoteHelpers
        RemoteHelpersInstalled = [bool]$remoteHelpersInstalled
        RemoteHelpersWarning = [bool]$remoteHelpersWarning
        SshConnection = $installerStatus.SshConnection
        RemoteTmux = $installerStatus.RemoteTmux
        TmuxPlugin = $installerStatus.TmuxPlugin
    } | ConvertTo-Json -Compress
}
catch {
    $installerStatus.Result = "Needs attention"
    $installerStatus.Failure = "Local setup did not complete. Check PowerShell, ssh.exe, scp.exe, and the ctrl-ccv connection settings."
    throw
}
finally {
    Write-CtrlCcvInstallerStatus -Path $StatusFile -Status $installerStatus
}
