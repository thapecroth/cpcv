# One-shot: upload clipboard image without replacing it with a remote path.
param([switch]$Silent)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ctrl-ccv-core.ps1")

function Show-Toast {
    param([string]$Title, [string]$Body)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Body
        $notify.ShowBalloonTip(2500)
        Start-Sleep -Milliseconds 400
        $notify.Dispose()
    }
    catch { }
}

$result = Publish-ClipboardImage -Force
if (-not $result.Ok) {
    $msg = switch ([string]$result.Reason) {
        "no-image" { "No image on clipboard. Screenshot/copy an image first." }
        "clipboard-busy" { "Another app is using the clipboard. ctrl-ccv will retry shortly; keep the image copied until its upload is confirmed." }
        "upload-in-progress" { "An upload is already running. Open ctrl-ccv status to check its progress." }
        "clipboard-changed" { "The clipboard changed during upload. ctrl-ccv will check the newest image automatically." }
        "cloudflare-sign-in-required" { "Complete Cloudflare sign-in in your normal SSH workflow. ctrl-ccv will retry automatically." }
        "cloudflare-retry" { "The connection recovered. ctrl-ccv will retry the clipboard image automatically." }
        "image-too-large" { "The clipboard image exceeds the configured size limit. Copy a smaller image or review Settings." }
        { $_ -like "ssh-mkdir-*" } { "The SSH upload connection failed. Open ctrl-ccv status and Connection help; automatic retries remain active." }
        { $_ -like "scp-*" } { "The image transfer was not confirmed. ctrl-ccv will retry automatically; open status for details." }
        { $_ -like "ssh-latest-*" } { "The image transferred, but publication was not confirmed. ctrl-ccv will retry automatically." }
        default { "The upload was not confirmed. ctrl-ccv will retry automatically; open status and recent activity for details." }
    }
    if ($result.Reason -eq "configuration-invalid" -and $result.Detail) { $msg = "ctrl-ccv configuration error: $($result.Detail)" }
    if (-not $Silent) { Show-Toast "ctrl-ccv" $msg; Write-Host $msg }
    exit 1
}
if (-not $Silent) { Show-Toast "ctrl-ccv" "Image uploaded; clipboard image preserved."; Write-Host $result.RemotePath }
exit 0
