# Starts a long-running child for the process-tree timeout test. This script
# intentionally keeps its own process alive after launching the child so the
# core hard-timeout wrapper has a real parent/child tree to terminate.
param(
    [Parameter(Mandatory)][string]$ChildScript,
    [Parameter(Mandatory)][string]$PidFile
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $ChildScript -PathType Leaf)) { throw "Missing test child script." }

# Start-Process joins an argument array into one command line on Windows.
# Quote the two filesystem arguments explicitly so this helper works from an
# extracted archive whose path contains spaces.
$childArguments = '-NoProfile -File "{0}" -PidFile "{1}"' -f $ChildScript, $PidFile
Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList $childArguments | Out-Null
Start-Sleep -Seconds 30
