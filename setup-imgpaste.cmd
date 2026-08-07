@echo off
setlocal
echo imgpaste setup compatibility wrapper
echo Configure %%LOCALAPPDATA%%\imgpaste\config.psd1 first. See README.md.
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0install-autostart.ps1" %*
endlocal
