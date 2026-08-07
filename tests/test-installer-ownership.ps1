# Safe local tests for ownership checks used by the Windows installers.
# All wrappers and shortcuts live under TEMP; no startup integration, uploader,
# clipboard, SSH host, or user data is touched.
$ErrorActionPreference = 'Stop'

function Assert-ImgPasteInstaller([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'imgpaste-core.ps1')

$tempRoot = Join-Path $env:TEMP ("imgpaste-installer-ownership-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $scriptPath = [IO.Path]::GetFullPath((Join-Path $root 'imgpaste-guardian.ps1'))
    $wrapperPath = Join-Path $tempRoot 'imgpaste-watch.cmd'
    $markedWrapper = @"
:: Managed by imgpaste install-autostart.ps1
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$scriptPath"
"@
    $legacyWrapper = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$scriptPath"
"@
    Set-Content -LiteralPath $wrapperPath -Value $markedWrapper -Encoding ASCII
    Assert-ImgPasteInstaller (Test-ImgPasteCommandWrapperOwnership -Path $wrapperPath -ExpectedContent $markedWrapper -LegacyContent $legacyWrapper) 'A marked exact wrapper was not recognized.'
    Set-Content -LiteralPath $wrapperPath -Value $legacyWrapper -Encoding ASCII
    Assert-ImgPasteInstaller (Test-ImgPasteCommandWrapperOwnership -Path $wrapperPath -ExpectedContent $markedWrapper -LegacyContent $legacyWrapper) 'A precise legacy wrapper was not recognized for safe migration.'
    Set-Content -LiteralPath $wrapperPath -Value '@echo off`r`nnotepad.exe' -Encoding ASCII
    Assert-ImgPasteInstaller (-not (Test-ImgPasteCommandWrapperOwnership -Path $wrapperPath -ExpectedContent $markedWrapper -LegacyContent $legacyWrapper)) 'An unrelated wrapper was accepted.'

    $shortcutPath = Join-Path $tempRoot 'imgpaste-watch.lnk'
    $description = 'Managed by imgpaste install-autostart.ps1 (guardian)'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -File `"$scriptPath`""
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = $description
    $shortcut.Save()
    Assert-ImgPasteInstaller (Test-ImgPasteShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $scriptPath -WorkingDirectory $root -Description $description -LegacyDescriptionPattern 'Watch and upload clipboard images via SSH (*)') 'A marked exact shortcut was not recognized.'
    $shortcut.Description = 'Watch and upload clipboard images via SSH (legacy-host)'
    $shortcut.Save()
    Assert-ImgPasteInstaller (Test-ImgPasteShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $scriptPath -WorkingDirectory $root -Description $description -LegacyDescriptionPattern 'Watch and upload clipboard images via SSH (*)') 'A precise legacy shortcut was not recognized for safe migration.'
    $shortcut.Description = 'Unrelated shortcut'
    $shortcut.Save()
    Assert-ImgPasteInstaller (-not (Test-ImgPasteShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $scriptPath -WorkingDirectory $root -Description $description -LegacyDescriptionPattern 'Watch and upload clipboard images via SSH (*)')) 'An unrelated same-named shortcut was accepted.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host 'PASS: installer wrapper/shortcut ownership accepts only exact current or known legacy imgpaste integration.'
