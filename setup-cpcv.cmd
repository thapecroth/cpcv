@echo off
setlocal
echo cpcv setup compatibility wrapper
echo Configure %%LOCALAPPDATA%%\cpcv\config.psd1 first. See README.md.
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0install-autostart.ps1" %*
endlocal
