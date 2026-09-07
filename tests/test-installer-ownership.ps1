# Safe local tests for ownership checks used by the Windows installers.
# All wrappers and shortcuts live under TEMP; no startup integration, uploader,
# clipboard, SSH host, or user data is touched.
$ErrorActionPreference = 'Stop'

function Assert-CpcvInstaller([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'cpcv-core.ps1')

$tempRoot = Join-Path $env:TEMP ("cpcv-installer-ownership-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $scriptPath = [IO.Path]::GetFullPath((Join-Path $root 'cpcv-guardian.ps1'))
    $wrapperPath = Join-Path $tempRoot 'cpcv-watch.cmd'
    $markedWrapper = @"
:: Managed by cpcv install-autostart.ps1
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$scriptPath"
"@
    Set-Content -LiteralPath $wrapperPath -Value $markedWrapper -Encoding ASCII
    Assert-CpcvInstaller (Test-CpcvCommandWrapperOwnership -Path $wrapperPath -ExpectedContent $markedWrapper) 'A marked exact wrapper was not recognized.'
    Set-Content -LiteralPath $wrapperPath -Value '@echo off`r`nnotepad.exe' -Encoding ASCII
    Assert-CpcvInstaller (-not (Test-CpcvCommandWrapperOwnership -Path $wrapperPath -ExpectedContent $markedWrapper)) 'An unrelated wrapper was accepted.'

    $shortcutPath = Join-Path $tempRoot 'cpcv-watch.lnk'
    $description = 'Managed by cpcv install-autostart.ps1 (guardian)'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -File `"$scriptPath`""
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = $description
    $shortcut.Save()
    Assert-CpcvInstaller (Test-CpcvShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $scriptPath -WorkingDirectory $root -Description $description) 'A marked exact shortcut was not recognized.'
    $shortcut.Description = 'Unrelated shortcut'
    $shortcut.Save()
    Assert-CpcvInstaller (-not (Test-CpcvShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $scriptPath -WorkingDirectory $root -Description $description)) 'An unrelated same-named shortcut was accepted.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host 'PASS: installer wrapper/shortcut ownership accepts only exact cpcv integration.'
