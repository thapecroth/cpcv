<#
.SYNOPSIS
Legacy compatibility entry point.

.DESCRIPTION
Use install-autostart.ps1 directly for new installations. This wrapper retains
the previous setup command while making optional remote helper changes explicit.
#>
[CmdletBinding()]
param([switch]$DeployRemoteHelpers)

Write-Warning "setup-cpcv.ps1 is a compatibility wrapper. Use install-autostart.ps1 for new installations."
& "$PSScriptRoot\install-autostart.ps1" -DeployRemoteHelpers:$DeployRemoteHelpers
