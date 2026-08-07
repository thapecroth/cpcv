<#
.SYNOPSIS
Legacy compatibility entry point for optional remote helper installation.
#>
[CmdletBinding()]
param([switch]$DeployRemoteHelpers)

Write-Warning "enable-auto-paste.ps1 is a compatibility wrapper. Use install-autostart.ps1 for new installations."
& "$PSScriptRoot\install-autostart.ps1" -DeployRemoteHelpers:$DeployRemoteHelpers
