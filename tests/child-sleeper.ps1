param([Parameter(Mandatory)][string]$PidFile)

$PID | Set-Content -NoNewline -LiteralPath $PidFile
Start-Sleep -Seconds 30
