@echo off
setlocal
echo ctrl-ccv setup compatibility wrapper
echo Configure %%LOCALAPPDATA%%\ctrl-ccv\config.psd1 first. See README.md.
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0install-autostart.ps1" %*
endlocal
