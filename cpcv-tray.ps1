<#
.SYNOPSIS
Shows a small Windows notification-area controller for cpcv.

.DESCRIPTION
This is deliberately a companion to the guardian rather than a second
watcher.  It only starts or stops processes whose exact -File argument points
to this checkout, and it reads the existing health and state files.

Run it from an STA PowerShell process, for example:
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\cpcv-tray.ps1
#>
[CmdletBinding()]
param(
    # Intended for tests and dot-sourcing.  It defines the helpers without
    # creating a notification icon or entering the Windows message loop.
    [switch]$NoRun,
    [ValidateRange(1, 60)]
    [int]$RefreshSeconds = 5
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "cpcv-core.ps1")

function Get-CpcvTrayProcessProbe {
    param([Parameter(Mandatory)][string]$ScriptPath)

    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.Name -in @("powershell.exe", "pwsh.exe") -and
                (Test-CpcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $ScriptPath)
            })
        return [pscustomobject]@{ Available = $true; Processes = $processes; Error = "" }
    }
    catch {
        # A status UI must never decide that a service is stopped merely
        # because process inspection was denied or unavailable.
        return [pscustomobject]@{ Available = $false; Processes = @(); Error = $_.Exception.Message }
    }
}

function Test-CpcvTrayShortcutOwnership {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    # Startup filenames are shared user resources. A matching filename alone
    # is never ownership: require the system PowerShell executable, this
    # checkout's exact -File
    # argument, its working directory, and either the current marker or the
    # documented legacy description from pre-marker installs.
    try {
        if (-not (Test-Path -LiteralPath $ShortcutPath)) { return $true }
        $item = Get-Item -LiteralPath $ShortcutPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $expectedTarget = [IO.Path]::GetFullPath((Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source))
        $actualTarget = [IO.Path]::GetFullPath([string]$shortcut.TargetPath)
        $expectedDirectory = [IO.Path]::GetFullPath($WorkingDirectory).TrimEnd('\\')
        $actualDirectory = if ($shortcut.WorkingDirectory) { [IO.Path]::GetFullPath([string]$shortcut.WorkingDirectory).TrimEnd('\\') } else { "" }
        $description = [string]$shortcut.Description
        $marked = $description -eq "Managed by cpcv install-tray.ps1"
        $legacy = $description -eq "cpcv status and controls"
        return ($actualTarget -ieq $expectedTarget -and
            (Test-CpcvProcessCommandLineForScript -CommandLine ([string]$shortcut.Arguments) -ScriptPath $ScriptPath) -and
            $actualDirectory -eq $expectedDirectory -and ($marked -or $legacy))
    }
    catch { return $false }
}

function Get-CpcvTrayLatestPath {
    param([Parameter(Mandatory)]$Config)

    try {
        if (-not (Test-Path -LiteralPath $Config.LastRemotePathFile)) { return "" }
        $path = (Get-Content -LiteralPath $Config.LastRemotePathFile -Raw -ErrorAction Stop).Trim()
        if (Test-CpcvRemotePath $path) { return $path }
    }
    catch { }
    return ""
}

function Get-CpcvTrayState {
    # cpcv-core.ps1 owns its script-scoped cached configuration. Calling
    # its public loader avoids depending on a caller's dot-sourcing scope.
    $cfg = Get-CpcvConfig
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-guardian.ps1"))
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-watch.ps1"))
    $guardianProbe = Get-CpcvTrayProcessProbe -ScriptPath $guardianScript
    $watchProbe = Get-CpcvTrayProcessProbe -ScriptPath $watchScript
    $guardians = @($guardianProbe.Processes)
    $watchers = @($watchProbe.Processes)

    $heartbeatInfo = $null
    $heartbeatAgeSeconds = $null
    if (Test-Path -LiteralPath $cfg.HeartbeatFile) {
        $heartbeatInfo = Get-CpcvHeartbeatInfo -Path $cfg.HeartbeatFile
        if ($heartbeatInfo) {
            $heartbeatAgeSeconds = [Math]::Max(0, ((Get-Date).ToUniversalTime() - $heartbeatInfo.Timestamp.UtcDateTime).TotalSeconds)
        }
    }

    $level = "Unknown"
    $summary = "Status is still loading"
    $detail = ""
    if ($cfg.ConfigError) {
        $level = "Error"
        $summary = "Configuration needs attention"
        $detail = $cfg.ConfigError
    }
    elseif (-not $guardianProbe.Available -or -not $watchProbe.Available) {
        $level = "Unknown"
        $summary = "Cannot inspect local processes"
        $detail = "The tray app will not start or stop processes until inspection works."
    }
    elseif ($guardians.Count -gt 1 -or $watchers.Count -gt 1) {
        $level = "Warning"
        $summary = "Duplicate cpcv process detected"
        $detail = "Use Restart service to stop only this checkout's duplicate processes."
    }
    elseif ($guardians.Count -eq 0 -and $watchers.Count -eq 0) {
        $level = "Stopped"
        $summary = "The cpcv service is stopped"
        $detail = "Start service to launch the guardian."
    }
    elseif ($guardians.Count -eq 0) {
        $level = "Warning"
        $summary = "Watcher is running without its guardian"
        $detail = "Restart service to restore watchdog protection."
    }
    elseif ($watchers.Count -eq 0) {
        $level = "Warning"
        $summary = "Guardian is waiting for the watcher"
        $detail = "The guardian should start it shortly; Restart service is safe if it does not."
    }
    elseif (-not $heartbeatInfo) {
        $level = "Warning"
        $summary = "Watcher heartbeat is missing or invalid"
        $detail = "The guardian should recover it."
    }
    elseif ($heartbeatInfo.ProcessId -ne [int]$watchers[0].ProcessId) {
        $level = "Warning"
        $summary = "Watcher heartbeat belongs to another process"
        $detail = "The guardian should recover it."
    }
    elseif ($heartbeatAgeSeconds -gt [double]$cfg.WatchdogStaleSeconds) {
        $level = "Warning"
        $summary = "Watcher heartbeat is stale"
        $detail = "The guardian should recover it; Restart service is safe if it persists."
    }
    else {
        $level = "Healthy"
        $summary = "cpcv is running"
        $detail = $heartbeatInfo.Status
    }

    $latestPath = Get-CpcvTrayLatestPath -Config $cfg
    return [pscustomobject]@{
        Level = $level
        Summary = $summary
        Detail = $detail
        Config = $cfg
        Guardians = $guardians
        Watchers = $watchers
        GuardianProbeAvailable = $guardianProbe.Available
        WatcherProbeAvailable = $watchProbe.Available
        Heartbeat = $heartbeatInfo
        HeartbeatAgeSeconds = $heartbeatAgeSeconds
        LatestPath = $latestPath
    }
}

function Get-CpcvTrayTooltip {
    param([Parameter(Mandatory)]$State)
    # NotifyIcon accepts at most 63 characters.  Do not put hosts, paths, or
    # log details in a system-wide hover tooltip.
    $text = "cpcv: $($State.Level) - $(ConvertTo-CpcvTrayDisplayText -Text $State.Summary -MaximumLength 42)"
    if ($text.Length -gt 63) { return $text.Substring(0, 60) + "..." }
    return $text
}

function ConvertTo-CpcvTrayDisplayText {
    param(
        [AllowNull()][string]$Text,
        [ValidateRange(24, 2048)][int]$MaximumLength = 280
    )

    # The status dashboard is intentionally a small, local summary. Never
    # turn a subprocess/configuration detail into an unbounded or credential-
    # bearing UI string, even if a future caller changes the state source.
    $safe = Protect-CpcvLogDetail $Text
    $safe = ($safe -replace '[\r\n\t]+', ' ').Trim()
    if ($safe.Length -gt $MaximumLength) { return $safe.Substring(0, $MaximumLength - 1) + [char]0x2026 }
    return $safe
}

function Get-CpcvTrayStatusStyle {
    param([Parameter(Mandatory)][string]$Level)

    switch ($Level) {
        "Healthy" { return [pscustomobject]@{ Accent = "#0F766E"; Surface = "#ECFDF5"; Foreground = "#115E59"; Badge = "Healthy" } }
        "Warning" { return [pscustomobject]@{ Accent = "#B45309"; Surface = "#FFFBEB"; Foreground = "#92400E"; Badge = "Needs attention" } }
        "Error" { return [pscustomobject]@{ Accent = "#B91C1C"; Surface = "#FEF2F2"; Foreground = "#991B1B"; Badge = "Action needed" } }
        "Stopped" { return [pscustomobject]@{ Accent = "#475569"; Surface = "#F1F5F9"; Foreground = "#334155"; Badge = "Stopped" } }
        default { return [pscustomobject]@{ Accent = "#4F46E5"; Surface = "#EEF2FF"; Foreground = "#3730A3"; Badge = "Checking" } }
    }
}

function Get-CpcvTrayRelativeTimeText {
    param([AllowNull()][object]$AgeSeconds)

    if ($null -eq $AgeSeconds) { return "Waiting for first heartbeat" }
    try { $seconds = [Math]::Max(0, [Math]::Round([double]$AgeSeconds)) }
    catch { return "Waiting for first heartbeat" }
    if ($seconds -lt 2) { return "Just now" }
    if ($seconds -lt 60) { return "$seconds seconds ago" }
    $minutes = [Math]::Floor($seconds / 60)
    if ($minutes -lt 60) { return "${minutes} min ago" }
    $hours = [Math]::Floor($minutes / 60)
    if ($hours -lt 24) { return "${hours} hr ago" }
    $days = [Math]::Floor($hours / 24)
    return "${days} day$($(if ($days -eq 1) { '' } else { 's' })) ago"
}

function Get-CpcvTrayGuidance {
    param([Parameter(Mandatory)]$State)

    switch ($State.Level) {
        "Healthy" { return "Take screenshots as usual. cpcv will upload new clipboard images automatically." }
        "Stopped" { return "Start automatic uploads to resume watching the image clipboard." }
        "Error" { return "Open settings, correct the local configuration, then start the service." }
        "Warning" { return "Use Repair service if this does not clear after the next health check." }
        default { return "Refresh status after local process inspection becomes available." }
    }
}

function Get-CpcvTrayColor {
    param([Parameter(Mandatory)][string]$Hex)
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

function Set-CpcvTrayButtonStyle {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [ValidateSet("Primary", "Secondary", "Quiet")][string]$Kind = "Secondary"
    )

    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    switch ($Kind) {
        "Primary" {
            $Button.BackColor = Get-CpcvTrayColor "#2563EB"
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = Get-CpcvTrayColor "#2563EB"
            $Button.FlatAppearance.MouseOverBackColor = Get-CpcvTrayColor "#1D4ED8"
            $Button.FlatAppearance.MouseDownBackColor = Get-CpcvTrayColor "#1E40AF"
        }
        "Quiet" {
            $Button.BackColor = Get-CpcvTrayColor "#F8FAFC"
            $Button.ForeColor = Get-CpcvTrayColor "#334155"
            $Button.FlatAppearance.BorderColor = Get-CpcvTrayColor "#CBD5E1"
            $Button.FlatAppearance.MouseOverBackColor = Get-CpcvTrayColor "#E2E8F0"
            $Button.FlatAppearance.MouseDownBackColor = Get-CpcvTrayColor "#CBD5E1"
        }
        default {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = Get-CpcvTrayColor "#1E3A5F"
            $Button.FlatAppearance.BorderColor = Get-CpcvTrayColor "#93C5FD"
            $Button.FlatAppearance.MouseOverBackColor = Get-CpcvTrayColor "#EFF6FF"
            $Button.FlatAppearance.MouseDownBackColor = Get-CpcvTrayColor "#DBEAFE"
        }
    }
}

function New-CpcvTrayMetricCard {
    param([Parameter(Mandatory)][string]$Title)

    $border = New-Object System.Windows.Forms.Panel
    $border.BackColor = Get-CpcvTrayColor "#D9E2F0"
    $border.Dock = [System.Windows.Forms.DockStyle]::Fill
    $border.Padding = New-Object System.Windows.Forms.Padding(1)

    $content = New-Object System.Windows.Forms.Panel
    $content.BackColor = [System.Drawing.Color]::White
    $content.Dock = [System.Windows.Forms.DockStyle]::Fill
    $content.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 10)
    $border.Controls.Add($content)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title.ToUpperInvariant()
    $titleLabel.AutoSize = $true
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $titleLabel.ForeColor = Get-CpcvTrayColor "#64748B"
    $titleLabel.Location = New-Object System.Drawing.Point(14, 12)
    $content.Controls.Add($titleLabel)

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.AutoEllipsis = $true
    $valueLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 13)
    $valueLabel.ForeColor = Get-CpcvTrayColor "#0F172A"
    $valueLabel.Location = New-Object System.Drawing.Point(14, 33)
    $valueLabel.Size = New-Object System.Drawing.Size(215, 26)
    $content.Controls.Add($valueLabel)

    $detailLabel = New-Object System.Windows.Forms.Label
    $detailLabel.AutoEllipsis = $true
    $detailLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $detailLabel.ForeColor = Get-CpcvTrayColor "#64748B"
    $detailLabel.Location = New-Object System.Drawing.Point(14, 62)
    $detailLabel.Size = New-Object System.Drawing.Size(215, 19)
    $content.Controls.Add($detailLabel)

    return [pscustomobject]@{ Container = $border; Value = $valueLabel; Detail = $detailLabel }
}

function Get-CpcvTrayIconAssetPath {
    # Keep branding with the checked-in source rather than a user profile or
    # configuration value. A custom icon must never become another input that
    # can point the tray at an arbitrary local file.
    return (Join-Path $PSScriptRoot "assets\windows\cpcv-tray.ico")
}

function Get-CpcvTrayLogoAssetPath {
    # The dashboard logo is also a checked-in project asset, not a configured
    # local path. That keeps the UI deterministic and avoids another
    # filesystem input in a process that starts at logon.
    return (Join-Path $PSScriptRoot "assets\windows\cpcv-logo.png")
}

function Get-CpcvTrayLogo {
    [CmdletBinding()]
    param(
        [string]$LogoPath = (Get-CpcvTrayLogoAssetPath)
    )

    $bitmap = $null
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($LogoPath) -or -not (Test-Path -LiteralPath $LogoPath -PathType Leaf)) { return $null }
        $item = Get-Item -LiteralPath $LogoPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            [IO.Path]::GetExtension($item.Name) -ine ".png" -or $item.Length -lt 128 -or $item.Length -gt 2MB) {
            return $null
        }

        # Clone the image before closing the stream so the dashboard neither
        # locks the checkout nor keeps a handle to a partially read asset.
        $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $source = [System.Drawing.Image]::FromStream($stream, $true, $true)
            try { $bitmap = [System.Drawing.Bitmap]::new($source) }
            finally { $source.Dispose() }
        }
        finally { $stream.Dispose() }
        if ($bitmap.Width -lt 32 -or $bitmap.Height -lt 32 -or $bitmap.Width -gt 2048 -or $bitmap.Height -gt 2048) {
            $bitmap.Dispose()
            return $null
        }
        return $bitmap
    }
    catch {
        if ($bitmap) { $bitmap.Dispose() }
        # The logo is cosmetic. A bad local asset must never stop the status
        # controller or disclose a raw GDI+/filesystem error in the UI.
        return $null
    }
}

function Get-CpcvTrayIcon {
    [CmdletBinding()]
    param(
        # This is overridable only so the local-only tests can exercise bad
        # assets without changing a real checkout. Production callers use the
        # project-local default above.
        [string]$IconPath = (Get-CpcvTrayIconAssetPath)
    )

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $fallback = [System.Drawing.SystemIcons]::Application
    }
    catch {
        throw "cpcv tray icons require the Windows System.Drawing assembly."
    }
    $fallbackResult = {
        param([string]$Reason)
        return [pscustomobject]@{
            Icon = $fallback
            OwnsIcon = $false
            IsFallback = $true
            Source = "Windows application icon"
            Reason = $Reason
        }
    }
    $icon = $null
    try {
        if ([string]::IsNullOrWhiteSpace($IconPath) -or -not (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
            return (& $fallbackResult "missing")
        }

        $item = Get-Item -LiteralPath $IconPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return (& $fallbackResult "unsafe-file")
        }
        # An ICO with the resolutions appropriate for the notification area is
        # normally tens of kilobytes. Bound it before GDI+ parses it, which
        # also prevents a corrupt local asset from delaying the tray at login.
        if ($item.Length -lt 6 -or $item.Length -gt 1MB -or [IO.Path]::GetExtension($item.Name) -ine ".ico") {
            return (& $fallbackResult "invalid-file")
        }

        $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            [byte[]]$header = [byte[]]::new(6)
            $offset = 0
            while ($offset -lt $header.Length) {
                $read = $stream.Read($header, $offset, $header.Length - $offset)
                if ($read -le 0) { break }
                $offset += $read
            }
        }
        finally {
            $stream.Dispose()
        }
        if ($offset -ne 6 -or $header[0] -ne 0 -or $header[1] -ne 0 -or $header[2] -ne 1 -or $header[3] -ne 0 -or ($header[4] -eq 0 -and $header[5] -eq 0)) {
            return (& $fallbackResult "invalid-header")
        }

        $icon = New-Object System.Drawing.Icon($item.FullName)
        if ($icon.Width -lt 16 -or $icon.Height -lt 16 -or $icon.Width -gt 512 -or $icon.Height -gt 512) {
            $icon.Dispose()
            $icon = $null
            return (& $fallbackResult "unsupported-size")
        }
        return [pscustomobject]@{
            Icon = $icon
            OwnsIcon = $true
            IsFallback = $false
            Source = "project asset"
            Reason = ""
        }
    }
    catch {
        if ($icon) { $icon.Dispose() }
        # Do not surface raw GDI+/filesystem error text: it could expose a
        # local path in a tray-facing surface or log. The system icon is a
        # reliable, dependency-free fallback.
        return (& $fallbackResult "unreadable")
    }
}

function Start-CpcvTrayGuardian {
    $cfg = Get-CpcvConfig
    if ($cfg.ConfigError) { throw $cfg.ConfigError }
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-guardian.ps1"))
    $probe = Get-CpcvTrayProcessProbe -ScriptPath $guardianScript
    if (-not $probe.Available) { throw "Cannot inspect local processes; refusing to start another guardian." }
    if ((@($probe.Processes)).Count -gt 0) { return $false }

    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $guardianScript)
    ) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    Write-CpcvLog "tray requested guardian start"
    return $true
}

function Stop-CpcvTrayService {
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-guardian.ps1"))
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-watch.ps1"))
    $guardianProbe = Get-CpcvTrayProcessProbe -ScriptPath $guardianScript
    $watchProbe = Get-CpcvTrayProcessProbe -ScriptPath $watchScript
    if (-not $guardianProbe.Available -or -not $watchProbe.Available) {
        throw "Cannot inspect local processes; refusing to stop anything."
    }

    # Stop the guardian first to prevent it from immediately replacing a
    # watcher that the user explicitly asked to stop.  Both lists are scoped
    # by the exact checkout path, never a filename-only match.
    foreach ($process in @($guardianProbe.Processes) + @($watchProbe.Processes)) {
        Stop-CpcvProcessTree -ProcessId ([int]$process.ProcessId)
    }
    Write-CpcvLog "tray requested service stop"
}

function Restart-CpcvTrayService {
    Stop-CpcvTrayService
    Start-Sleep -Milliseconds 500
    [void](Start-CpcvTrayGuardian)
    Write-CpcvLog "tray requested service restart"
}

function Start-CpcvTrayUpload {
    $cfg = Get-CpcvConfig
    if ($cfg.ConfigError) { throw $cfg.ConfigError }
    $nowScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-now.ps1"))
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $nowScript), "-Silent"
    ) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    Write-CpcvLog "tray requested one-shot clipboard upload"
}

function Copy-CpcvTrayLatestPath {
    param([Parameter(Mandatory)]$State)
    if ([string]::IsNullOrWhiteSpace($State.LatestPath) -or -not (Test-CpcvRemotePath $State.LatestPath)) {
        throw "There is no valid uploaded path to copy yet."
    }
    Set-Clipboard -Value $State.LatestPath
}

function Open-CpcvTrayLog {
    $path = (Get-CpcvConfig).LogFile
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Force -Path $path | Out-Null }
    Start-Process -FilePath "notepad.exe" -ArgumentList @(('"{0}"' -f $path)) | Out-Null
}

function Open-CpcvTrayConfig {
    $path = Get-CpcvConfigPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    if (-not (Test-Path -LiteralPath $path)) {
        $example = Join-Path $PSScriptRoot "cpcv.config.example.psd1"
        Copy-Item -LiteralPath $example -Destination $path -Force
    }
    Start-Process -FilePath "notepad.exe" -ArgumentList @(('"{0}"' -f $path)) | Out-Null
}

function Open-CpcvTrayDataFolder {
    $path = (Get-CpcvConfig).DataRoot
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    Start-Process -FilePath "explorer.exe" -ArgumentList @(('"{0}"' -f $path)) | Out-Null
}

function Show-CpcvTrayError {
    param([Parameter(Mandatory)][string]$Message)
    [void][System.Windows.Forms.MessageBox]::Show($Message, "cpcv", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
}

function Show-CpcvTrayStatusWindow {
    param(
        [Parameter(Mandatory)]$State,
        # TestMode exists solely for the local synthetic STA smoke test. It
        # preserves the real dialog/message-loop path without flashing a
        # status window onto the user's desktop during routine validation.
        [switch]$TestMode
    )

    # The normal tray startup path has already loaded these assemblies, but
    # this public helper is also useful from a direct STA PowerShell command.
    # Load them here so opening status does not depend on hidden caller state.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $windowIcon = Get-CpcvTrayIcon
    $logoImage = Get-CpcvTrayLogo
    $form = $null
    $tooltip = $null
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "cpcvTrayStatusDashboard"
        $form.Text = "cpcv status"
        $form.Icon = $windowIcon.Icon
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(840, 575)
        $form.MinimumSize = New-Object System.Drawing.Size(760, 545)
        $form.BackColor = Get-CpcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.KeyPreview = $true
        $form.MinimizeBox = $false
        $form.MaximizeBox = $false
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.BackColor = $form.BackColor
    $layout.Padding = New-Object System.Windows.Forms.Padding(24, 22, 24, 20)
    $layout.ColumnCount = 1
    $layout.RowCount = 5
    # The header includes a 20pt title plus a supporting line. Its bottom
    # margin needs real breathing room at 100% and high-DPI scale factors.
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 68)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 116)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 104)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 28)))
    $form.Controls.Add($layout)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $layout.Controls.Add($header, 0, 0)

    if ($logoImage) {
        $logo = New-Object System.Windows.Forms.PictureBox
        $logo.Name = "cpcvTrayBrandLogo"
        $logo.Image = $logoImage
        $logo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $logo.Size = New-Object System.Drawing.Size(48, 48)
        $logo.Location = New-Object System.Drawing.Point(0, 1)
        $header.Controls.Add($logo)
    }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "cpcv"
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 20)
    $title.ForeColor = Get-CpcvTrayColor "#0F172A"
    $title.Location = New-Object System.Drawing.Point($(if ($logoImage) { 58 } else { 0 }), 0)
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Clipboard image uploader"
    $subtitle.AutoSize = $true
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $subtitle.ForeColor = Get-CpcvTrayColor "#64748B"
    $subtitle.Location = New-Object System.Drawing.Point($(if ($logoImage) { 60 } else { 2 }), 34)
    $header.Controls.Add($subtitle)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Name = "cpcvTrayRefreshButton"
    $refreshButton.Text = "Refresh status"
    $refreshButton.Size = New-Object System.Drawing.Size(120, 34)
    $refreshButton.Location = New-Object System.Drawing.Point(672, 8)
    $refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    Set-CpcvTrayButtonStyle -Button $refreshButton -Kind Quiet
    $header.Controls.Add($refreshButton)

    $statusBanner = New-Object System.Windows.Forms.Panel
    $statusBanner.Name = "cpcvTrayStatusBanner"
    $statusBanner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusBanner.Padding = New-Object System.Windows.Forms.Padding(20, 17, 20, 14)
    $statusBanner.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $layout.Controls.Add($statusBanner, 0, 1)

    $statusDot = New-Object System.Windows.Forms.Label
    $statusDot.Text = [char]0x25CF
    $statusDot.AutoSize = $true
    $statusDot.Font = New-Object System.Drawing.Font("Segoe UI", 24)
    $statusDot.Location = New-Object System.Drawing.Point(20, 37)
    $statusBanner.Controls.Add($statusDot)

    $statusBadge = New-Object System.Windows.Forms.Label
    $statusBadge.AutoSize = $true
    $statusBadge.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $statusBadge.Padding = New-Object System.Windows.Forms.Padding(7, 4, 7, 4)
    $statusBadge.Location = New-Object System.Drawing.Point(62, 17)
    $statusBanner.Controls.Add($statusBadge)

    $statusSummary = New-Object System.Windows.Forms.Label
    $statusSummary.AutoEllipsis = $true
    $statusSummary.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
    $statusSummary.Location = New-Object System.Drawing.Point(62, 43)
    $statusSummary.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $statusSummary.Size = New-Object System.Drawing.Size(710, 28)
    $statusBanner.Controls.Add($statusSummary)

    $statusDetail = New-Object System.Windows.Forms.Label
    $statusDetail.AutoEllipsis = $true
    $statusDetail.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $statusDetail.Location = New-Object System.Drawing.Point(63, 75)
    $statusDetail.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $statusDetail.Size = New-Object System.Drawing.Size(708, 22)
    $statusBanner.Controls.Add($statusDetail)

    $metrics = New-Object System.Windows.Forms.TableLayoutPanel
    $metrics.Dock = [System.Windows.Forms.DockStyle]::Fill
    $metrics.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $metrics.ColumnCount = 3
    $metrics.RowCount = 1
    [void]$metrics.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$metrics.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$metrics.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 33.334)))
    $layout.Controls.Add($metrics, 0, 2)

    $serviceCard = New-CpcvTrayMetricCard -Title "Automatic uploads"
    $heartbeatCard = New-CpcvTrayMetricCard -Title "Last heartbeat"
    $latestCard = New-CpcvTrayMetricCard -Title "Latest image"
    $serviceCard.Container.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $heartbeatCard.Container.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
    $latestCard.Container.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $metrics.Controls.Add($serviceCard.Container, 0, 0)
    $metrics.Controls.Add($heartbeatCard.Container, 1, 0)
    $metrics.Controls.Add($latestCard.Container, 2, 0)

    $actionsBorder = New-Object System.Windows.Forms.Panel
    $actionsBorder.BackColor = Get-CpcvTrayColor "#D9E2F0"
    $actionsBorder.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionsBorder.Padding = New-Object System.Windows.Forms.Padding(1)
    $actionsBorder.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $layout.Controls.Add($actionsBorder, 0, 3)

    $actions = New-Object System.Windows.Forms.Panel
    $actions.BackColor = [System.Drawing.Color]::White
    $actions.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actions.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 15)
    $actionsBorder.Controls.Add($actions)

    $actionsTitle = New-Object System.Windows.Forms.Label
    $actionsTitle.Text = "Quick actions"
    $actionsTitle.AutoSize = $true
    $actionsTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
    $actionsTitle.ForeColor = Get-CpcvTrayColor "#0F172A"
    $actionsTitle.Location = New-Object System.Drawing.Point(20, 16)
    $actions.Controls.Add($actionsTitle)

    $actionsCaption = New-Object System.Windows.Forms.Label
    $actionsCaption.Text = "Manage this checkout only. The tray never starts a second uploader."
    $actionsCaption.AutoSize = $true
    $actionsCaption.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $actionsCaption.ForeColor = Get-CpcvTrayColor "#64748B"
    $actionsCaption.Location = New-Object System.Drawing.Point(20, 40)
    $actions.Controls.Add($actionsCaption)

    $uploadButton = New-Object System.Windows.Forms.Button
    $uploadButton.Name = "cpcvTrayUploadButton"
    $uploadButton.Text = "Upload clipboard image"
    $uploadButton.Size = New-Object System.Drawing.Size(206, 38)
    $uploadButton.Location = New-Object System.Drawing.Point(20, 69)
    Set-CpcvTrayButtonStyle -Button $uploadButton -Kind Primary
    $actions.Controls.Add($uploadButton)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Name = "cpcvTrayCopyButton"
    $copyButton.Size = New-Object System.Drawing.Size(178, 38)
    $copyButton.Location = New-Object System.Drawing.Point(236, 69)
    Set-CpcvTrayButtonStyle -Button $copyButton -Kind Secondary
    $actions.Controls.Add($copyButton)

    $serviceButton = New-Object System.Windows.Forms.Button
    $serviceButton.Name = "cpcvTrayServiceButton"
    $serviceButton.Size = New-Object System.Drawing.Size(184, 38)
    $serviceButton.Location = New-Object System.Drawing.Point(424, 69)
    Set-CpcvTrayButtonStyle -Button $serviceButton -Kind Secondary
    $actions.Controls.Add($serviceButton)

    $settingsButton = New-Object System.Windows.Forms.Button
    $settingsButton.Name = "cpcvTraySettingsButton"
    $settingsButton.Text = "Open settings"
    $settingsButton.Size = New-Object System.Drawing.Size(112, 30)
    $settingsButton.Location = New-Object System.Drawing.Point(20, 119)
    Set-CpcvTrayButtonStyle -Button $settingsButton -Kind Quiet
    $actions.Controls.Add($settingsButton)

    $logButton = New-Object System.Windows.Forms.Button
    $logButton.Name = "cpcvTrayLogButton"
    $logButton.Text = "Open log"
    $logButton.Size = New-Object System.Drawing.Size(92, 30)
    $logButton.Location = New-Object System.Drawing.Point(142, 119)
    Set-CpcvTrayButtonStyle -Button $logButton -Kind Quiet
    $actions.Controls.Add($logButton)

    $dataButton = New-Object System.Windows.Forms.Button
    $dataButton.Name = "cpcvTrayDataButton"
    $dataButton.Text = "Open data folder"
    $dataButton.Size = New-Object System.Drawing.Size(128, 30)
    $dataButton.Location = New-Object System.Drawing.Point(244, 119)
    Set-CpcvTrayButtonStyle -Button $dataButton -Kind Quiet
    $actions.Controls.Add($dataButton)

    $actionFeedback = New-Object System.Windows.Forms.Label
    $actionFeedback.AutoEllipsis = $true
    $actionFeedback.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $actionFeedback.ForeColor = Get-CpcvTrayColor "#475569"
    $actionFeedback.Location = New-Object System.Drawing.Point(20, 158)
    $actionFeedback.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $actionFeedback.Size = New-Object System.Drawing.Size(750, 20)
    $actions.Controls.Add($actionFeedback)

    $footer = New-Object System.Windows.Forms.Label
    $footer.Text = "Tip: take a screenshot as usual; cpcv reacts only to image clipboard entries."
    $footer.AutoEllipsis = $true
    $footer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $footer.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $footer.ForeColor = Get-CpcvTrayColor "#64748B"
    $footer.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($footer, 0, 4)

    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.AutoPopDelay = 10000
    $tooltip.SetToolTip($uploadButton, "Run one safe, asynchronous upload of the current clipboard image.")
    $tooltip.SetToolTip($serviceButton, "Only processes started from this checkout can be changed.")
    $tooltip.SetToolTip($copyButton, "Copy the most recent validated remote path without displaying it here.")

    $refreshDashboard = {
        param([Parameter(Mandatory)]$CurrentState)

        $style = Get-CpcvTrayStatusStyle -Level $CurrentState.Level
        $statusBanner.BackColor = Get-CpcvTrayColor $style.Surface
        $statusDot.ForeColor = Get-CpcvTrayColor $style.Accent
        $statusBadge.Text = $style.Badge.ToUpperInvariant()
        $statusBadge.BackColor = Get-CpcvTrayColor $style.Accent
        $statusBadge.ForeColor = [System.Drawing.Color]::White
        $statusSummary.Text = ConvertTo-CpcvTrayDisplayText -Text $CurrentState.Summary -MaximumLength 200
        $statusSummary.ForeColor = Get-CpcvTrayColor $style.Foreground
        $statusDetail.Text = ConvertTo-CpcvTrayDisplayText -Text $CurrentState.Detail -MaximumLength 260
        if ([string]::IsNullOrWhiteSpace($statusDetail.Text)) { $statusDetail.Text = Get-CpcvTrayGuidance -State $CurrentState }
        $statusDetail.ForeColor = Get-CpcvTrayColor $style.Foreground

        $guardianCount = (@($CurrentState.Guardians)).Count
        $watcherCount = (@($CurrentState.Watchers)).Count
        $serviceRunning = ($guardianCount -gt 0 -or $watcherCount -gt 0)
        $serviceCard.Value.Text = if ($CurrentState.Level -eq "Healthy") { "Running" } elseif ($serviceRunning) { "Needs attention" } else { "Stopped" }
        $serviceCard.Value.ForeColor = Get-CpcvTrayColor $style.Foreground
        $serviceCard.Detail.Text = "$guardianCount guardian; $watcherCount watcher"
        $heartbeatCard.Value.Text = Get-CpcvTrayRelativeTimeText -AgeSeconds $CurrentState.HeartbeatAgeSeconds
        $heartbeatCard.Detail.Text = if ($CurrentState.Heartbeat) { "Watcher: $($CurrentState.Heartbeat.Status)" } else { "No valid health record" }
        $hasLatestPath = (-not [string]::IsNullOrWhiteSpace($CurrentState.LatestPath) -and (Test-CpcvRemotePath $CurrentState.LatestPath))
        $latestCard.Value.Text = if ($hasLatestPath) { "Ready to copy" } else { "No upload yet" }
        $latestCard.Detail.Text = if ($hasLatestPath) { "Latest path is available locally" } else { "Upload an image to create one" }

        $uploadButton.Enabled = $CurrentState.Level -ne "Error"
        $copyButton.Enabled = $hasLatestPath
        $copyButton.Text = if ($hasLatestPath) { "Copy latest path" } else { "No upload path yet" }
        $serviceButton.Text = if (-not $serviceRunning) { "Start automatic uploads" } elseif ($CurrentState.Level -in @("Warning", "Unknown")) { "Repair service" } else { "Restart service" }
        $serviceButton.Enabled = ($CurrentState.Level -ne "Error" -and $CurrentState.GuardianProbeAvailable -and ((-not $serviceRunning) -or $CurrentState.WatcherProbeAvailable))
        $actionFeedback.Text = Get-CpcvTrayGuidance -State $CurrentState
        $form.Text = "cpcv status - $($style.Badge)"
    }.GetNewClosure()

    $refreshButton.Add_Click({
        try {
            $freshState = Get-CpcvTrayState
            & $refreshDashboard $freshState
        }
        catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $uploadButton.Add_Click({
        try {
            Start-CpcvTrayUpload
            $actionFeedback.Text = "Upload requested. Refresh status after the clipboard image is processed."
        }
        catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $copyButton.Add_Click({
        try {
            $currentState = Get-CpcvTrayState
            Copy-CpcvTrayLatestPath -State $currentState
            $actionFeedback.Text = "Latest upload path copied to the clipboard."
        }
        catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $serviceButton.Add_Click({
        try {
            $currentState = Get-CpcvTrayState
            $currentlyRunning = ((@($currentState.Guardians)).Count -gt 0 -or (@($currentState.Watchers)).Count -gt 0)
            if ($currentlyRunning) { Restart-CpcvTrayService } else { [void](Start-CpcvTrayGuardian) }
            Start-Sleep -Milliseconds 350
            & $refreshDashboard (Get-CpcvTrayState)
        }
        catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $settingsButton.Add_Click({ try { Open-CpcvTrayConfig } catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) } })
    $logButton.Add_Click({ try { Open-CpcvTrayLog } catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) } })
    $dataButton.Add_Click({ try { Open-CpcvTrayDataFolder } catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) } })

    $close = New-Object System.Windows.Forms.Button
    $close.Name = "cpcvTrayCloseButton"
    $close.Text = "Close"
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Size = New-Object System.Drawing.Size(92, 30)
    $close.Visible = $false
    $form.Controls.Add($close)
    $form.CancelButton = $close
    $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        & $refreshDashboard $State
        [void]$form.ShowDialog()
    }
    finally {
        if ($tooltip) { $tooltip.Dispose() }
        if ($form) { $form.Dispose() }
        if ($logoImage) { $logoImage.Dispose() }
        if ($windowIcon -and $windowIcon.OwnsIcon -and $windowIcon.Icon) { $windowIcon.Icon.Dispose() }
    }
}

function Start-CpcvTrayApplication {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
        throw "cpcv-tray.ps1 must be run with powershell.exe -STA. Use install-tray.ps1 to add a safe Startup shortcut."
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $mutex = New-Object System.Threading.Mutex($false, (Get-CpcvMutexName -Purpose "Tray"))
    if (-not $mutex.WaitOne(0, $false)) { return }
    $notify = $null
    $timer = $null
    $trayIconSelection = $null
    try {
        $script:CpcvTrayState = Get-CpcvTrayState
        $script:CpcvTrayLastLevel = ""
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $statusItem = $menu.Items.Add("Loading status...")
        $statusItem.Enabled = $false
        $showStatusItem = $menu.Items.Add("View status...")
        [void]$menu.Items.Add("-")
        $uploadItem = $menu.Items.Add("Upload current clipboard image")
        $copyItem = $menu.Items.Add("Copy latest upload path")
        [void]$menu.Items.Add("-")
        $startItem = $menu.Items.Add("Start service")
        $stopItem = $menu.Items.Add("Stop service")
        $restartItem = $menu.Items.Add("Restart service")
        [void]$menu.Items.Add("-")
        $logItem = $menu.Items.Add("Open log")
        $configItem = $menu.Items.Add("Open configuration")
        $dataItem = $menu.Items.Add("Open data folder")
        [void]$menu.Items.Add("-")
        $exitItem = $menu.Items.Add("Exit tray (service stays running)")

        $notify = New-Object System.Windows.Forms.NotifyIcon
        $trayIconSelection = Get-CpcvTrayIcon
        $notify.Icon = $trayIconSelection.Icon
        if ($trayIconSelection.IsFallback) {
            Write-CpcvLog "tray icon asset was unavailable or invalid; using the Windows application icon"
        }
        $notify.ContextMenuStrip = $menu
        $notify.Visible = $true
        $context = New-Object System.Windows.Forms.ApplicationContext

        $refreshUi = {
            $script:CpcvTrayState = Get-CpcvTrayState
            $state = $script:CpcvTrayState
            $statusItem.Text = "Status: $($state.Level) - $($state.Summary)"
            $notify.Text = Get-CpcvTrayTooltip -State $state
            $isRunning = ((@($state.Guardians)).Count -gt 0 -or (@($state.Watchers)).Count -gt 0)
            $startItem.Enabled = ($state.Level -ne "Error" -and $state.GuardianProbeAvailable -and -not $isRunning)
            $stopItem.Enabled = ($state.GuardianProbeAvailable -and $state.WatcherProbeAvailable -and $isRunning)
            $restartItem.Enabled = ($state.Level -ne "Error" -and $state.GuardianProbeAvailable -and $state.WatcherProbeAvailable)
            $copyItem.Enabled = (-not [string]::IsNullOrWhiteSpace($state.LatestPath) -and (Test-CpcvRemotePath $state.LatestPath))
            if ($script:CpcvTrayLastLevel -and $script:CpcvTrayLastLevel -ne $state.Level -and $state.Level -in @("Warning", "Error")) {
                $notify.BalloonTipTitle = "cpcv: $($state.Level)"
                $notify.BalloonTipText = $state.Summary
                $notify.ShowBalloonTip(3000)
            }
            $script:CpcvTrayLastLevel = $state.Level
        }

        $showStatusItem.Add_Click({ & $refreshUi; Show-CpcvTrayStatusWindow -State $script:CpcvTrayState })
        $uploadItem.Add_Click({ try { Start-CpcvTrayUpload; $notify.ShowBalloonTip(2000, "cpcv", "One-shot upload requested.", [System.Windows.Forms.ToolTipIcon]::Info) } catch { Show-CpcvTrayError $_.Exception.Message } })
        $copyItem.Add_Click({ try { Copy-CpcvTrayLatestPath -State $script:CpcvTrayState; $notify.ShowBalloonTip(1500, "cpcv", "Latest upload path copied.", [System.Windows.Forms.ToolTipIcon]::Info) } catch { Show-CpcvTrayError $_.Exception.Message } })
        $startItem.Add_Click({ try { [void](Start-CpcvTrayGuardian); & $refreshUi } catch { Show-CpcvTrayError $_.Exception.Message } })
        $stopItem.Add_Click({ try { Stop-CpcvTrayService; & $refreshUi } catch { Show-CpcvTrayError $_.Exception.Message } })
        $restartItem.Add_Click({ try { Restart-CpcvTrayService; & $refreshUi } catch { Show-CpcvTrayError $_.Exception.Message } })
        $logItem.Add_Click({ try { Open-CpcvTrayLog } catch { Show-CpcvTrayError $_.Exception.Message } })
        $configItem.Add_Click({ try { Open-CpcvTrayConfig } catch { Show-CpcvTrayError $_.Exception.Message } })
        $dataItem.Add_Click({ try { Open-CpcvTrayDataFolder } catch { Show-CpcvTrayError $_.Exception.Message } })
        $notify.Add_DoubleClick({ & $refreshUi; Show-CpcvTrayStatusWindow -State $script:CpcvTrayState })
        $exitItem.Add_Click({ $context.ExitThread() })

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = $RefreshSeconds * 1000
        $timer.Add_Tick({ & $refreshUi })
        & $refreshUi
        $timer.Start()
        [System.Windows.Forms.Application]::Run($context)
    }
    finally {
        if ($timer) { $timer.Stop(); $timer.Dispose() }
        if ($notify) { $notify.Visible = $false; $notify.Dispose() }
        if ($trayIconSelection -and $trayIconSelection.OwnsIcon -and $trayIconSelection.Icon) { $trayIconSelection.Icon.Dispose() }
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}

if (-not $NoRun) { Start-CpcvTrayApplication }
