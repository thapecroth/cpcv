# Static safety checks for the checked-in Inno Setup source and bootstrap.
# The CI workflow separately compiles the wizard on a Windows runner; this
# test stays local-only and does not change Startup, configuration, or SSH.
$ErrorActionPreference = 'Stop'

function Assert-CpcvInstallerPackage([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
$issPath = Join-Path $root 'windows\installer\cpcv.iss'
$bootstrapPath = Join-Path $root 'windows\installer\cpcv-installer.ps1'
$buildPath = Join-Path $root 'build-windows.ps1'
foreach ($path in @($issPath, $bootstrapPath, $buildPath)) {
    Assert-CpcvInstallerPackage (Test-Path -LiteralPath $path -PathType Leaf) "Missing Windows installer packaging file: $path"
}

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($bootstrapPath, [ref]$tokens, [ref]$parseErrors)
Assert-CpcvInstallerPackage ($parseErrors.Count -eq 0) 'The installer bootstrap does not parse as PowerShell.'

$iss = Get-Content -LiteralPath $issPath -Raw
$bootstrap = Get-Content -LiteralPath $bootstrapPath -Raw
$build = Get-Content -LiteralPath $buildPath -Raw

foreach ($required in @(
    'PrivilegesRequired=lowest',
    'DefaultDirName={localappdata}\Programs\cpcv',
    'DisableDirPage=yes',
    'Flags: unchecked',
    'Install optional cpcv tmux helpers on my SSH host',
    '-ExecutionPolicy RemoteSigned',
    'uninstall-tray.ps1',
    'uninstall-autostart.ps1',
    'cpcv-installer.ps1'
)) {
    Assert-CpcvInstallerPackage ($iss.Contains($required)) "Inno Setup source is missing required safe behavior: $required"
}

foreach ($forbidden in @('ExecutionPolicy Bypass', '-RemoveLocalData', '-RemoveLocalConfig', 'RemoveRemoteHelpers', 'PrivilegesRequiredOverridesAllowed=')) {
    Assert-CpcvInstallerPackage (-not $iss.Contains($forbidden)) "Inno Setup source must not include destructive/default behavior: $forbidden"
}

foreach ($required in @(
    'Test-CpcvInstallerHostAlias',
    'Test-CpcvInstallerRemoteDir',
    'CreateNew',
    'CPCV_CONFIG',
    'uninstall-autostart.ps1',
    'uninstall-tray.ps1',
    'install-autostart.ps1',
    'install-tray.ps1',
    'DeployRemoteHelpers'
)) {
    Assert-CpcvInstallerPackage ($bootstrap.Contains($required)) "Installer bootstrap is missing required behavior: $required"
}
Assert-CpcvInstallerPackage ($bootstrap -notmatch '(?i)invoke-expression|executionpolicy\s+bypass') 'Installer bootstrap must not use dynamic evaluation or execution-policy bypass.'
$localInstallIndex = $bootstrap.IndexOf('& $localInstaller *>&1 | Out-Null')
$trayInstallIndex = $bootstrap.IndexOf('& $trayInstaller -Confirm:$false *>&1 | Out-Null')
$remoteHelperIndex = $bootstrap.IndexOf('& $localInstaller -DeployRemoteHelpers *>&1 | Out-Null')
Assert-CpcvInstallerPackage ($localInstallIndex -ge 0 -and $trayInstallIndex -gt $localInstallIndex -and $remoteHelperIndex -gt $trayInstallIndex) 'Optional remote helpers must run only after the local watcher and tray are ready.'
Assert-CpcvInstallerPackage ($bootstrap.Contains('RemoteHelpersWarning')) 'Optional remote-helper failure must not be reported as a local install failure.'

foreach ($required in @(
    '[switch]$IncludeInstaller',
    'Resolve-CpcvInnoCompiler',
    'Expand-Archive',
    'Test-CpcvExecutableHeader',
    'show", "HEAD:VERSION',
    'CpcvOutputBaseName'
)) {
    Assert-CpcvInstallerPackage ($build.Contains($required)) "Windows build script is missing installer packaging behavior: $required"
}

Write-Host 'PASS: Windows setup wizard is per-user, non-destructive, validated, and wired into clean-tree packaging.'
