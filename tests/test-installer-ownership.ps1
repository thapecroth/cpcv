# Safe local tests for ownership checks used by the Windows installers.
# All wrappers and shortcuts live under TEMP; no startup integration, uploader,
# clipboard, SSH host, or user data is touched.
$ErrorActionPreference = 'Stop'

function Assert-CtrlCcvInstaller([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ctrl-ccv-core.ps1')

$tempRoot = Join-Path $env:TEMP ("ctrl-ccv-installer-ownership-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $scriptPath = [IO.Path]::GetFullPath((Join-Path $root 'ctrl-ccv-guardian.ps1'))
    $wrapperPath = Join-Path $tempRoot 'ctrl-ccv-watch.cmd'
    $markedWrapper = @"
:: Managed by ctrl-ccv install-autostart.ps1
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$scriptPath"
"@
    Set-Content -LiteralPath $wrapperPath -Value $markedWrapper -Encoding ASCII
    Assert-CtrlCcvInstaller (Test-CtrlCcvCommandWrapperOwnership -Path $wrapperPath -ExpectedContent $markedWrapper) 'A marked exact wrapper was not recognized.'
    Set-Content -LiteralPath $wrapperPath -Value '@echo off`r`nnotepad.exe' -Encoding ASCII
    Assert-CtrlCcvInstaller (-not (Test-CtrlCcvCommandWrapperOwnership -Path $wrapperPath -ExpectedContent $markedWrapper)) 'An unrelated wrapper was accepted.'

    $shortcutPath = Join-Path $tempRoot 'ctrl-ccv-watch.lnk'
    $description = 'Managed by ctrl-ccv install-autostart.ps1 (guardian)'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -File `"$scriptPath`""
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = $description
    $shortcut.Save()
    Assert-CtrlCcvInstaller (Test-CtrlCcvShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $scriptPath -WorkingDirectory $root -Description $description) 'A marked exact shortcut was not recognized.'
    $shortcut.Description = 'Unrelated shortcut'
    $shortcut.Save()
    Assert-CtrlCcvInstaller (-not (Test-CtrlCcvShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $scriptPath -WorkingDirectory $root -Description $description)) 'An unrelated same-named shortcut was accepted.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host 'PASS: installer wrapper/shortcut ownership accepts only exact ctrl-ccv integration.'
