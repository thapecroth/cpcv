<#
.SYNOPSIS
Per-user setup bridge invoked only by the cpcv Windows installer.

.DESCRIPTION
Creates a minimal private configuration only for a first-time install, then
uses the existing ownership-safe cpcv installers to start the watcher and tray.
It never accepts passwords, keys, shell fragments, or arbitrary commands.
Existing configuration (including a CPCV_CONFIG override) is deliberately left
unchanged.
#>
[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$HostAlias = "",

    [string]$RemoteDir = "clipboard-images",

    [switch]$DeployRemoteHelpers,

    [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"

if (-not $IsWindows -and $env:OS -ne "Windows_NT") {
    throw "cpcv-installer.ps1 is for Windows only."
}

$script:CpcvInstallerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$coreScript = Join-Path $script:CpcvInstallerRoot "cpcv-core.ps1"
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    throw "The cpcv installer files are incomplete."
}
. $coreScript

function Test-CpcvInstallerHostAlias {
    param([AllowEmptyString()][string]$Value)

    return ($Value -match '^[A-Za-z0-9][A-Za-z0-9._@:-]*$')
}

function Test-CpcvInstallerRemoteDir {
    param([AllowEmptyString()][string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { return $false }
    if ($Value.StartsWith('/')) { return $false }
    if ($Value -match '(^|/)\.\.(/|$)') { return $false }
    return $true
}

function Test-CpcvInstallerReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-CpcvInstallerPrerequisites {
    foreach ($command in @("powershell.exe", "ssh.exe", "scp.exe")) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required Windows command was not found: $command"
        }
    }
}

function New-CpcvInstallerInitialConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$InitialHostAlias,
        [Parameter(Mandatory)][string]$InitialRemoteDir
    )

    if (Test-Path -LiteralPath $ConfigPath) {
        return [pscustomobject]@{ Created = $false; Preserved = $true }
    }
    if (-not (Test-CpcvInstallerHostAlias -Value $InitialHostAlias)) {
        throw "HostAlias must be an SSH alias, hostname, or user@host using only supported characters."
    }
    if (-not (Test-CpcvInstallerRemoteDir -Value $InitialRemoteDir)) {
        throw "RemoteDir must be a relative POSIX path without '..'."
    }

    $configDirectory = Split-Path -LiteralPath $ConfigPath -Parent
    if (Test-CpcvInstallerReparsePoint -Path $configDirectory) {
        throw "Refusing to create configuration in a reparse-point directory."
    }
    if (-not (Test-Path -LiteralPath $configDirectory)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }
    if (Test-CpcvInstallerReparsePoint -Path $configDirectory) {
        throw "Refusing to create configuration in a reparse-point directory."
    }
    if (Test-CpcvInstallerReparsePoint -Path $ConfigPath) {
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

function Get-CpcvInstallerConfigurationState {
    $hasOverride = -not [string]::IsNullOrWhiteSpace($env:CPCV_CONFIG)
    $configPath = Get-CpcvConfigPath
    if ($hasOverride -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "CPCV_CONFIG is set but does not point to an existing private configuration file. Repair or remove that override before installing."
    }
    if (Test-CpcvInstallerReparsePoint -Path $configPath) {
        throw "Refusing to use a reparse-point configuration file."
    }
    return [pscustomobject]@{
        Path = $configPath
        HasOverride = $hasOverride
        Exists = (Test-Path -LiteralPath $configPath -PathType Leaf)
    }
}

Assert-CpcvInstallerPrerequisites
$configuration = Get-CpcvInstallerConfigurationState

if ($PreflightOnly) {
    [pscustomobject]@{
        Ready = $true
        ExistingConfiguration = [bool]$configuration.Exists
        ConfigurationOverride = [bool]$configuration.HasOverride
    } | ConvertTo-Json -Compress
    return
}

if (-not $configuration.Exists) {
    $configurationResult = New-CpcvInstallerInitialConfig -ConfigPath $configuration.Path -InitialHostAlias $HostAlias.Trim() -InitialRemoteDir $RemoteDir.Trim()
}
else {
    $configurationResult = [pscustomobject]@{ Created = $false; Preserved = $true }
}

# Re-read through cpcv's canonical parser before any Startup integration is
# written. This makes malformed or externally supplied config fail closed.
$validatedConfiguration = Get-CpcvConfig
if ($validatedConfiguration.ConfigError) {
    throw "cpcv configuration is not ready: $($validatedConfiguration.ConfigError)"
}

$localInstaller = Join-Path $script:CpcvInstallerRoot "install-autostart.ps1"
$trayInstaller = Join-Path $script:CpcvInstallerRoot "install-tray.ps1"
$localUninstaller = Join-Path $script:CpcvInstallerRoot "uninstall-autostart.ps1"
$trayUninstaller = Join-Path $script:CpcvInstallerRoot "uninstall-tray.ps1"
if (@($localInstaller, $trayInstaller, $localUninstaller, $trayUninstaller) |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }) {
    throw "The cpcv installer files are incomplete."
}

# Stop only this stable checkout's owned processes and integration before
# starting the refreshed copy. The uninstallers validate every fixed-name
# shortcut, wrapper, and command line first, so a portable-install collision
# fails closed instead of being migrated or overwritten automatically.
& $trayUninstaller -Confirm:$false *>&1 | Out-Null
& $localUninstaller -Confirm:$false *>&1 | Out-Null

# Keep child installer output out of the setup UI and process environment. The
# scripts themselves own exact shortcut/process validation and raise on error.
# Local startup and the tray are complete before the separately optional remote
# deployment is attempted, so a temporarily unreachable SSH host cannot make
# Setup misreport a healthy local service as failed.
& $localInstaller *>&1 | Out-Null
& $trayInstaller -Confirm:$false *>&1 | Out-Null

$remoteHelpersInstalled = $false
$remoteHelpersWarning = $false
if ($DeployRemoteHelpers) {
    try {
        & $localInstaller -DeployRemoteHelpers *>&1 | Out-Null
        $remoteHelpersInstalled = $true
    }
    catch {
        # Remote helpers are explicitly optional. Do not show raw SSH output,
        # host details, or a false local-install failure in the Setup wizard.
        $remoteHelpersWarning = $true
    }
}

[pscustomobject]@{
    Installed = $true
    CreatedConfiguration = [bool]$configurationResult.Created
    PreservedConfiguration = [bool]$configurationResult.Preserved
    RemoteHelpersRequested = [bool]$DeployRemoteHelpers
    RemoteHelpersInstalled = [bool]$remoteHelpersInstalled
    RemoteHelpersWarning = [bool]$remoteHelpersWarning
} | ConvertTo-Json -Compress
