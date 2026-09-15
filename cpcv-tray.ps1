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
. (Join-Path $PSScriptRoot "cpcv-remote.ps1")

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

    # The path state file is written atomically only after a successful upload.
    # Its timestamp gives the tray a privacy-preserving answer to the practical
    # question "did my most recent image upload?" without putting a remote path
    # or host name in the notification area.
    $latestPath = Get-CpcvTrayLatestPath -Config $cfg
    $latestUploadAt = $null
    $latestUploadAgeSeconds = $null
    if (-not [string]::IsNullOrWhiteSpace($latestPath)) {
        try {
            $latestFile = Get-Item -LiteralPath $cfg.LastRemotePathFile -Force -ErrorAction Stop
            if (-not $latestFile.PSIsContainer -and (($latestFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                $latestUploadAt = [DateTimeOffset]::new($latestFile.LastWriteTimeUtc)
                $latestUploadAgeSeconds = [Math]::Max(0, ((Get-Date).ToUniversalTime() - $latestUploadAt.UtcDateTime).TotalSeconds)
            }
        }
        catch { }
    }
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
        LatestUploadAt = $latestUploadAt
        LatestUploadAgeSeconds = $latestUploadAgeSeconds
    }
}

function Get-CpcvTrayTooltip {
    param([Parameter(Mandatory)]$State)
    # NotifyIcon accepts at most 63 characters.  Do not put hosts, paths, or
    # log details in a system-wide hover tooltip.
    $latestUpload = Get-CpcvTrayLatestUploadText -State $State
    if ($State.Level -eq "Healthy" -and $latestUpload -match '^Uploaded ') {
        $text = "cpcv: Healthy - $latestUpload"
    }
    else {
        $text = "cpcv: $($State.Level) - $(ConvertTo-CpcvTrayDisplayText -Text $State.Summary -MaximumLength 42)"
    }
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

function Get-CpcvTrayLatestUploadText {
    param([Parameter(Mandatory)]$State)

    # Keep this label path-free: the remote path may reveal a user name or
    # project layout, while the timestamp is enough to confirm upload progress.
    if ([string]::IsNullOrWhiteSpace($State.LatestPath) -or -not (Test-CpcvRemotePath $State.LatestPath)) {
        return "No upload yet"
    }
    if ($null -eq $State.LatestUploadAgeSeconds) { return "Uploaded (time unknown)" }
    return "Uploaded $((Get-CpcvTrayRelativeTimeText -AgeSeconds $State.LatestUploadAgeSeconds).ToLowerInvariant())"
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

function Get-CpcvTrayRecentActivityText {
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateRange(1, 500)][int]$MaximumLines = 100,
        [ValidateRange(1024, 1048576)][int]$MaximumBytes = 65536
    )

    $path = [string]$Config.LogFile
    if ([string]::IsNullOrWhiteSpace($path)) { return "Recent activity is unavailable." }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "No local activity has been recorded yet." }

    $stream = $null
    $reader = $null
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return "Recent activity is unavailable because the log is not a regular file."
        }

        # Read only a bounded tail. The watcher can be writing at the same
        # time, so permit a shared read but never create or modify the log.
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $offset = [Math]::Max([int64]0, $stream.Length - [int64]$MaximumBytes)
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, $true)
        $text = $reader.ReadToEnd()
        if ($offset -gt 0) {
            # Discard the leading partial record after seeking into the file.
            $newline = $text.IndexOf("`n")
            if ($newline -ge 0) { $text = $text.Substring($newline + 1) }
        }
        $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last $MaximumLines)
        if ($lines.Count -eq 0) { return "No local activity has been recorded yet." }
        return (($lines | ForEach-Object {
            ConvertTo-CpcvTrayDisplayText -Text $_ -MaximumLength 1200
        }) -join [Environment]::NewLine)
    }
    catch {
        # Do not surface a file path or unbounded OS exception in a UI that is
        # routinely opened from the notification area.
        return "Recent activity is temporarily unavailable."
    }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Show-CpcvTrayRecentActivityWindow {
    param([switch]$TestMode)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = $null
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "cpcvTrayRecentActivityWindow"
        $form.Text = "cpcv recent activity"
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(760, 500)
        $form.MinimumSize = New-Object System.Drawing.Size(620, 400)
        $form.BackColor = Get-CpcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

        $title = New-Object System.Windows.Forms.Label
        $title.Name = "cpcvTrayRecentActivityTitle"
        $title.Text = "Recent activity"
        $title.AutoSize = $true
        $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 17)
        $title.ForeColor = Get-CpcvTrayColor "#0F172A"
        $title.Location = New-Object System.Drawing.Point(22, 18)
        $form.Controls.Add($title)

        $subtitle = New-Object System.Windows.Forms.Label
        $subtitle.Name = "cpcvTrayRecentActivitySubtitle"
        $subtitle.Text = "The latest 100 local records are shown here. Sensitive values are redacted."
        $subtitle.AutoSize = $true
        $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $subtitle.ForeColor = Get-CpcvTrayColor "#64748B"
        $subtitle.Location = New-Object System.Drawing.Point(24, 50)
        $form.Controls.Add($subtitle)

        $activity = New-Object System.Windows.Forms.TextBox
        $activity.Name = "cpcvTrayRecentActivityTextBox"
        $activity.Multiline = $true
        $activity.ReadOnly = $true
        $activity.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $activity.WordWrap = $false
        $activity.Font = New-Object System.Drawing.Font("Cascadia Mono", 9)
        $activity.BackColor = [System.Drawing.Color]::White
        $activity.ForeColor = Get-CpcvTrayColor "#1E293B"
        $activity.Location = New-Object System.Drawing.Point(24, 82)
        $activity.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $activity.Size = New-Object System.Drawing.Size(712, 352)
        $form.Controls.Add($activity)

        $refresh = New-Object System.Windows.Forms.Button
        $refresh.Name = "cpcvTrayRecentActivityRefreshButton"
        $refresh.Text = "Refresh"
        $refresh.Size = New-Object System.Drawing.Size(104, 32)
        $refresh.Location = New-Object System.Drawing.Point(520, 450)
        $refresh.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CpcvTrayButtonStyle -Button $refresh -Kind Secondary
        $form.Controls.Add($refresh)

        $close = New-Object System.Windows.Forms.Button
        $close.Name = "cpcvTrayRecentActivityCloseButton"
        $close.Text = "Close"
        $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $close.Size = New-Object System.Drawing.Size(104, 32)
        $close.Location = New-Object System.Drawing.Point(632, 450)
        $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CpcvTrayButtonStyle -Button $close -Kind Quiet
        $form.Controls.Add($close)
        $form.CancelButton = $close

        $reload = {
            $cfg = Get-CpcvConfig
            $activity.Text = Get-CpcvTrayRecentActivityText -Config $cfg
            $activity.SelectionStart = $activity.TextLength
            $activity.ScrollToCaret()
        }.GetNewClosure()
        $refresh.Add_Click({ & $reload })
        $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        & $reload
        [void]$form.ShowDialog()
    }
    finally {
        if ($form) { $form.Dispose() }
    }
}

function Add-CpcvTraySettingsField {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TableLayoutPanel]$Panel,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inputs,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()]$Value
    )

    $row = $Panel.RowCount
    $Panel.RowCount = $row + 1
    [void]$Panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::AutoSize)))

    $fieldLabel = New-Object System.Windows.Forms.Label
    $fieldLabel.Name = "cpcvTraySettings$($Key)Label"
    $fieldLabel.Text = $Label
    $fieldLabel.AutoSize = $true
    $fieldLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $fieldLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 14, 8)
    $fieldLabel.ForeColor = Get-CpcvTrayColor "#334155"
    $Panel.Controls.Add($fieldLabel, 0, $row)

    $input = New-Object System.Windows.Forms.TextBox
    $input.Name = "cpcvTraySettings$($Key)Input"
    $input.Text = [string]$Value
    $input.Dock = [System.Windows.Forms.DockStyle]::Fill
    $input.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    $input.MaxLength = 1024
    $Panel.Controls.Add($input, 1, $row)
    $Inputs[$Key] = $input
}

function Show-CpcvTraySettingsWindow {
    param([switch]$TestMode)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = $null
    try {
        $editable = Get-CpcvEditableConfig
        $inputs = [ordered]@{}
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "cpcvTraySettingsWindow"
        $form.Text = "cpcv settings"
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(800, 650)
        $form.MinimumSize = New-Object System.Drawing.Size(680, 560)
        $form.BackColor = Get-CpcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.KeyPreview = $true
        $form.Tag = $false

        $title = New-Object System.Windows.Forms.Label
        $title.Name = "cpcvTraySettingsTitle"
        $title.Text = "Settings"
        $title.AutoSize = $true
        $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 17)
        $title.ForeColor = Get-CpcvTrayColor "#0F172A"
        $title.Location = New-Object System.Drawing.Point(24, 18)
        $form.Controls.Add($title)

        $subtitle = New-Object System.Windows.Forms.Label
        $subtitle.Text = "Choose the SSH computer cpcv uses for automatic image uploads."
        $subtitle.AutoSize = $true
        $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $subtitle.ForeColor = Get-CpcvTrayColor "#64748B"
        $subtitle.Location = New-Object System.Drawing.Point(26, 49)
        $form.Controls.Add($subtitle)

        $notice = New-Object System.Windows.Forms.Label
        $notice.Name = "cpcvTraySettingsNotice"
        $notice.AutoSize = $false
        $notice.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $notice.ForeColor = Get-CpcvTrayColor "#334155"
        $notice.BackColor = Get-CpcvTrayColor "#EEF2FF"
        $notice.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
        $notice.Location = New-Object System.Drawing.Point(24, 78)
        $notice.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $notice.Size = New-Object System.Drawing.Size(752, 48)
        if (-not [string]::IsNullOrWhiteSpace([string]$editable.LoadError)) {
            $notice.Text = "The existing configuration could not be read. Enter valid settings below to repair it."
            $notice.BackColor = Get-CpcvTrayColor "#FEF2F2"
            $notice.ForeColor = Get-CpcvTrayColor "#991B1B"
        }
        elseif ($editable.HasEnvironmentOverrides) {
            $fieldOverrides = @($editable.EnvironmentOverrides | Where-Object { $_ -ne "CPCV_CONFIG" })
            $pathNotice = if ($editable.ConfigPathIsEnvironmentOverride) {
                " Settings are saving to the configuration location selected by CPCV_CONFIG."
            }
            else { "" }
            if ($fieldOverrides.Count -gt 0) {
                $notice.Text = "Saved values are overridden for this session by: $($fieldOverrides -join ', '). Remove those environment variables for saved values to take effect.$pathNotice"
            }
            else {
                $notice.Text = "This session uses the configuration location selected by CPCV_CONFIG. Saved settings will take effect from that location."
            }
            $notice.BackColor = Get-CpcvTrayColor "#FFFBEB"
            $notice.ForeColor = Get-CpcvTrayColor "#92400E"
        }
        else {
            $notice.Text = "Saved changes take effect after cpcv restarts its owned local service."
        }
        $form.Controls.Add($notice)

        $tabs = New-Object System.Windows.Forms.TabControl
        $tabs.Name = "cpcvTraySettingsTabs"
        $tabs.Location = New-Object System.Drawing.Point(24, 142)
        $tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $tabs.Size = New-Object System.Drawing.Size(752, 422)
        $form.Controls.Add($tabs)

        $connectionTab = New-Object System.Windows.Forms.TabPage
        $connectionTab.Name = "cpcvTraySettingsConnectionTab"
        $connectionTab.Text = "Connection"
        $connectionTab.Padding = New-Object System.Windows.Forms.Padding(18, 16, 18, 16)
        $connectionTab.BackColor = [System.Drawing.Color]::White
        $tabs.TabPages.Add($connectionTab)

        $connectionLayout = New-Object System.Windows.Forms.TableLayoutPanel
        $connectionLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
        $connectionLayout.AutoScroll = $true
        $connectionLayout.ColumnCount = 2
        $connectionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 205))) | Out-Null
        $connectionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
        $connectionTab.Controls.Add($connectionLayout)
        Add-CpcvTraySettingsField -Panel $connectionLayout -Inputs $inputs -Key "HostAlias" -Label "SSH computer or alias" -Value $editable.HostAlias
        Add-CpcvTraySettingsField -Panel $connectionLayout -Inputs $inputs -Key "RemoteDir" -Label "Remote image folder" -Value $editable.RemoteDir
        Add-CpcvTraySettingsField -Panel $connectionLayout -Inputs $inputs -Key "RemoteHome" -Label "Remote home (optional)" -Value $editable.RemoteHome
        Add-CpcvTraySettingsField -Panel $connectionLayout -Inputs $inputs -Key "PollIntervalSeconds" -Label "Upload interval (seconds)" -Value $editable.PollIntervalSeconds

        $connectionTip = New-Object System.Windows.Forms.Label
        $connectionTip.Name = "cpcvTraySettingsConnectionTip"
        $connectionTip.Text = "Use the same connection name that works with ssh <name>. Use an SSH config alias for custom ports, keys, or proxy rules."
        $connectionTip.AutoSize = $false
        $connectionTip.ForeColor = Get-CpcvTrayColor "#64748B"
        $connectionTip.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $connectionTip.Dock = [System.Windows.Forms.DockStyle]::Top
        $connectionTip.Height = 46
        $connectionTip.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
        $connectionLayout.RowCount = $connectionLayout.RowCount + 1
        [void]$connectionLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::AutoSize)))
        $connectionLayout.Controls.Add($connectionTip, 0, $connectionLayout.RowCount - 1)
        $connectionLayout.SetColumnSpan($connectionTip, 2)

        $advancedTab = New-Object System.Windows.Forms.TabPage
        $advancedTab.Name = "cpcvTraySettingsAdvancedTab"
        $advancedTab.Text = "Advanced"
        $advancedTab.Padding = New-Object System.Windows.Forms.Padding(18, 16, 18, 16)
        $advancedTab.BackColor = [System.Drawing.Color]::White
        $tabs.TabPages.Add($advancedTab)

        $advancedLayout = New-Object System.Windows.Forms.TableLayoutPanel
        $advancedLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
        $advancedLayout.AutoScroll = $true
        $advancedLayout.ColumnCount = 2
        $advancedLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 220))) | Out-Null
        $advancedLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
        $advancedTab.Controls.Add($advancedLayout)
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "DataRoot" -Label "Local data folder" -Value $editable.DataRoot
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "CommandTimeoutSeconds" -Label "Command timeout (seconds)" -Value $editable.CommandTimeoutSeconds
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxCommandOutputBytes" -Label "Max command output (bytes)" -Value $editable.MaxCommandOutputBytes
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "WatchdogCheckSeconds" -Label "Watchdog check (seconds)" -Value $editable.WatchdogCheckSeconds
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "WatchdogStaleSeconds" -Label "Watchdog stale after (seconds)" -Value $editable.WatchdogStaleSeconds
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxLogBytes" -Label "Max activity log (bytes)" -Value $editable.MaxLogBytes
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxCacheFiles" -Label "Max cached images" -Value $editable.MaxCacheFiles
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxCacheBytes" -Label "Max cache (bytes)" -Value $editable.MaxCacheBytes
        Add-CpcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxImageBytes" -Label "Max image (bytes)" -Value $editable.MaxImageBytes

        $feedback = New-Object System.Windows.Forms.Label
        $feedback.Name = "cpcvTraySettingsFeedback"
        $feedback.AutoEllipsis = $true
        $feedback.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $feedback.ForeColor = Get-CpcvTrayColor "#B91C1C"
        $feedback.Location = New-Object System.Drawing.Point(24, 576)
        $feedback.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $feedback.Size = New-Object System.Drawing.Size(500, 36)
        $form.Controls.Add($feedback)

        $save = New-Object System.Windows.Forms.Button
        $save.Name = "cpcvTraySettingsSaveButton"
        $save.Text = "Save and restart"
        $save.Size = New-Object System.Drawing.Size(132, 34)
        $save.Location = New-Object System.Drawing.Point(532, 580)
        $save.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CpcvTrayButtonStyle -Button $save -Kind Primary
        $form.Controls.Add($save)

        $close = New-Object System.Windows.Forms.Button
        $close.Name = "cpcvTraySettingsCloseButton"
        $close.Text = "Cancel"
        $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $close.Size = New-Object System.Drawing.Size(104, 34)
        $close.Location = New-Object System.Drawing.Point(672, 580)
        $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CpcvTrayButtonStyle -Button $close -Kind Quiet
        $form.Controls.Add($close)
        $form.CancelButton = $close

        $save.Add_Click({
            try {
                $draft = [ordered]@{}
                foreach ($key in @(
                    "HostAlias", "RemoteDir", "RemoteHome", "DataRoot",
                    "CommandTimeoutSeconds", "MaxCommandOutputBytes", "PollIntervalSeconds",
                    "WatchdogCheckSeconds", "WatchdogStaleSeconds", "MaxLogBytes",
                    "MaxCacheFiles", "MaxCacheBytes", "MaxImageBytes"
                )) {
                    $draft[$key] = $inputs[$key].Text.Trim()
                }
                [void](Save-CpcvConfig -Config $draft)
                try {
                    Restart-CpcvTrayService
                }
                catch {
                    $feedback.Text = "Settings were saved, but cpcv could not restart. Use the service controls after resolving the local error."
                    return
                }
                $form.Tag = $true
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.Close()
            }
            catch {
                $feedback.Text = ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message -MaximumLength 440
            }
        }.GetNewClosure())
        $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        [void]$form.ShowDialog()
        return [bool]$form.Tag
    }
    finally {
        if ($form) { $form.Dispose() }
    }
}

function Get-CpcvTrayTmuxStartupLine {
    # This is deliberately only shown and copied. The customer owns their
    # tmux startup file, and cpcv must not add or change a run-shell line.
    return "run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux"
}

function Resolve-CpcvTrayTmuxPathInsertionChoice {
    param(
        [Parameter(Mandatory)][ValidateSet("CrossPlatform", "Recommended", "Custom", "RawCtrlV")][string]$Mode,
        [AllowNull()][string]$CustomKey
    )

    switch ($Mode) {
        "CrossPlatform" {
            # This adds both root-table bindings to the same remote server;
            # tmux does not identify a client's OS. Windows users press Alt-V
            # (tmux M-v), while macOS users can press Ctrl-V (tmux C-v).
            return [pscustomobject]@{
                Table          = "root"
                Key            = "C-v"
                SecondaryTable = "root"
                SecondaryKey   = "M-v"
                Label          = "Windows Alt-V + macOS Ctrl-V"
            }
        }
        "Recommended" {
            return [pscustomobject]@{
                Table          = "prefix"
                Key            = "v"
                SecondaryTable = ""
                SecondaryKey   = ""
                Label          = "tmux prefix, then v"
            }
        }
        "Custom" {
            $key = if ($null -eq $CustomKey) { "" } else { $CustomKey.Trim() }
            if ($key -notmatch '^[a-z0-9]$') {
                throw "Choose one lowercase letter or number for the custom tmux prefix key."
            }
            return [pscustomobject]@{
                Table          = "prefix"
                Key            = $key
                SecondaryTable = ""
                SecondaryKey   = ""
                Label          = "tmux prefix, then $key"
            }
        }
        "RawCtrlV" {
            return [pscustomobject]@{
                Table          = "root"
                Key            = "C-v"
                SecondaryTable = ""
                SecondaryKey   = ""
                Label          = "raw Ctrl-V"
            }
        }
    }
}

function Get-CpcvTrayTmuxStateValue {
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Fallback = ""
    )

    if ($null -eq $State) { return $Fallback }
    if ($State -is [System.Collections.IDictionary]) {
        if ($State.Contains($Name) -and $null -ne $State[$Name]) { return [string]$State[$Name] }
        return $Fallback
    }
    $property = $State.PSObject.Properties[$Name]
    if ($null -ne $property -and $null -ne $property.Value) { return [string]$property.Value }
    return $Fallback
}

function Format-CpcvTrayTmuxState {
    param([AllowNull()][object]$State)

    if ($null -eq $State) { return "Remote setup has not been checked yet." }
    $connection = Get-CpcvTrayTmuxStateValue -State $State -Name "Connection" -Fallback "Unavailable"
    $tmux = Get-CpcvTrayTmuxStateValue -State $State -Name "Tmux" -Fallback "Unknown"
    $plugin = Get-CpcvTrayTmuxStateValue -State $State -Name "Plugin" -Fallback "Unknown"
    $server = Get-CpcvTrayTmuxStateValue -State $State -Name "Server" -Fallback "Unknown"
    $table = Get-CpcvTrayTmuxStateValue -State $State -Name "Table" -Fallback "Unknown"
    $key = Get-CpcvTrayTmuxStateValue -State $State -Name "Key" -Fallback "Unknown"
    $binding = Get-CpcvTrayTmuxStateValue -State $State -Name "Binding" -Fallback "Unknown"
    $secondaryTable = Get-CpcvTrayTmuxStateValue -State $State -Name "SecondaryTable"
    $secondaryKey = Get-CpcvTrayTmuxStateValue -State $State -Name "SecondaryKey"
    $secondaryBinding = Get-CpcvTrayTmuxStateValue -State $State -Name "SecondaryBinding" -Fallback "NotSelected"
    $override = Get-CpcvTrayTmuxStateValue -State $State -Name "Override" -Fallback "None"
    $detail = Get-CpcvTrayTmuxStateValue -State $State -Name "Detail"
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("SSH: $connection    tmux: $tmux    plugin: $plugin")
    [void]$lines.Add("Default server: $server    primary binding ($table/$key): $binding")
    if ($secondaryTable -and $secondaryKey) {
        [void]$lines.Add("Paired Windows Alt-V binding ($secondaryTable/$secondaryKey): $secondaryBinding")
    }
    if ($override -and $override -ne "None") {
        [void]$lines.Add("A user-owned @cpcv-paste-* option is active and takes precedence over this screen.")
    }
    if ($detail) {
        [void]$lines.Add((ConvertTo-CpcvTrayDisplayText -Text $detail -MaximumLength 480))
    }
    return ($lines -join [Environment]::NewLine)
}

function Start-CpcvTrayTmuxRemoteJob {
    <#
    .SYNOPSIS
    Starts one remote tmux action outside the WinForms UI thread.

    .DESCRIPTION
    The remote helpers intentionally use bounded, synchronous SSH/SCP process
    calls. They are safe to run in a non-interactive PowerShell job, but must
    not run inside a button event handler: an Apply can require several
    bounded remote calls. The child process reloads only this checkout's
    cpcv-core and cpcv-remote helpers, so it shares the saved configuration
    but cannot touch the tray's local uploader state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Check", "Apply")][string]$Operation,
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][string]$SecondaryTable,
        [AllowNull()][string]$SecondaryKey
    )

    $binding = Test-CpcvRemoteTmuxBinding -Table $Table -Key $Key -SecondaryTable $SecondaryTable -SecondaryKey $SecondaryKey
    $root = [IO.Path]::GetFullPath($PSScriptRoot)
    return Start-Job -Name ("cpcv-tmux-{0}" -f $Operation.ToLowerInvariant()) -ScriptBlock {
        param(
            [Parameter(Mandatory)][string]$CpcvRoot,
            [Parameter(Mandatory)][string]$CpcvOperation,
            [Parameter(Mandatory)][string]$CpcvTable,
            [Parameter(Mandatory)][string]$CpcvKey,
            [AllowNull()][string]$CpcvSecondaryTable,
            [AllowNull()][string]$CpcvSecondaryKey
        )

        $ErrorActionPreference = "Stop"
        . (Join-Path $CpcvRoot "cpcv-core.ps1")
        . (Join-Path $CpcvRoot "cpcv-remote.ps1")
        if ($CpcvOperation -eq "Check") {
            return Get-CpcvRemoteTmuxState -Table $CpcvTable -Key $CpcvKey -SecondaryTable $CpcvSecondaryTable -SecondaryKey $CpcvSecondaryKey
        }
        return Apply-CpcvRemoteTmuxBinding -Table $CpcvTable -Key $CpcvKey -SecondaryTable $CpcvSecondaryTable -SecondaryKey $CpcvSecondaryKey
    } -ArgumentList @($root, $Operation, $binding.Table, $binding.Key, $binding.SecondaryTable, $binding.SecondaryKey)
}

function Receive-CpcvTrayTmuxRemoteJob {
    <#
    .SYNOPSIS
    Reads a completed remote tmux job without blocking the UI thread.

    .DESCRIPTION
    A non-completed job returns Completed = $false. Terminal jobs are removed
    as soon as their final state has been collected, so opening the tmux
    window repeatedly cannot accumulate background-job records.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.Job]$Job)

    if ($Job.State -notin @("Completed", "Failed", "Stopped", "Disconnected")) {
        return [pscustomobject]@{ Completed = $false; Ok = $false; Result = $null; Detail = "" }
    }

    $records = @()
    $errors = @()
    try {
        $records = @(Receive-Job -Job $Job -ErrorAction SilentlyContinue -ErrorVariable +errors)
        $result = @($records | Where-Object {
            $null -ne $_ -and $null -ne $_.PSObject.Properties["Ok"]
        } | Select-Object -Last 1)[0]
        if ($null -ne $result) {
            return [pscustomobject]@{ Completed = $true; Ok = $true; Result = $result; Detail = "" }
        }

        $reason = ""
        if ($Job.ChildJobs.Count -gt 0 -and $null -ne $Job.ChildJobs[0].JobStateInfo.Reason) {
            $reason = [string]$Job.ChildJobs[0].JobStateInfo.Reason
        }
        if (-not [string]::IsNullOrWhiteSpace($reason)) {
            $detail = $reason
        }
        elseif ($errors.Count -gt 0) {
            $detail = [string]$errors[-1]
        }
        elseif ($Job.State -eq "Stopped") {
            $detail = "The remote tmux operation was cancelled."
        }
        else {
            $detail = "The remote tmux operation finished without a result."
        }
        return [pscustomobject]@{ Completed = $true; Ok = $false; Result = $null; Detail = $detail }
    }
    catch {
        return [pscustomobject]@{ Completed = $true; Ok = $false; Result = $null; Detail = $_.Exception.Message }
    }
    finally {
        try { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-CpcvTrayTmuxRemoteJob {
    <#
    .SYNOPSIS
    Stops only the dedicated job created for the currently open tmux dialog.
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Management.Automation.Job]$Job)

    if ($null -eq $Job) { return }
    try {
        if ($Job.State -notin @("Completed", "Failed", "Stopped", "Disconnected")) {
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
        }
    }
    catch { }
    try { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
}

function Show-CpcvTrayTmuxSetupWindow {
    param(
        # TestMode keeps the usual synthetic WinForms probe hidden. Its direct
        # transport branch preserves the existing deterministic stub tests;
        # UseAsyncWorker opts a probe into the production job/timer path.
        [switch]$TestMode,
        [switch]$UseAsyncWorker
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = $null
    $operationTimer = $null
    $operationState = $null
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "cpcvTrayTmuxSetupWindow"
        $form.Text = "cpcv tmux path insertion"
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(760, 700)
        $form.MinimumSize = New-Object System.Drawing.Size(780, 740)
        $form.BackColor = Get-CpcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.KeyPreview = $true
        $form.Tag = $false

        $title = New-Object System.Windows.Forms.Label
        $title.Name = "cpcvTrayTmuxTitle"
        $title.Text = "Tmux path insertion"
        $title.AutoSize = $true
        $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 17)
        $title.ForeColor = Get-CpcvTrayColor "#0F172A"
        $title.Location = New-Object System.Drawing.Point(24, 18)
        $form.Controls.Add($title)

        $subtitle = New-Object System.Windows.Forms.Label
        $subtitle.Name = "cpcvTrayTmuxSubtitle"
        $subtitle.Text = "Choose how the remote tmux server inserts cpcv's latest image path. This is separate from the local uploader settings."
        $subtitle.AutoSize = $false
        $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $subtitle.ForeColor = Get-CpcvTrayColor "#64748B"
        $subtitle.Location = New-Object System.Drawing.Point(26, 50)
        $subtitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $subtitle.Size = New-Object System.Drawing.Size(708, 32)
        $form.Controls.Add($subtitle)

        $notice = New-Object System.Windows.Forms.Label
        $notice.Name = "cpcvTrayTmuxNotice"
        $notice.Text = "Check is read-only. Apply installs or updates only cpcv-owned remote plugin and configuration files; it never edits ~/.tmux.conf or restarts your local uploader."
        $notice.AutoSize = $false
        $notice.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $notice.ForeColor = Get-CpcvTrayColor "#334155"
        $notice.BackColor = Get-CpcvTrayColor "#EEF2FF"
        $notice.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
        $notice.Location = New-Object System.Drawing.Point(24, 92)
        $notice.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $notice.Size = New-Object System.Drawing.Size(712, 50)
        $form.Controls.Add($notice)

        $choiceLabel = New-Object System.Windows.Forms.Label
        $choiceLabel.Text = "Path-insertion shortcut on the remote tmux server"
        $choiceLabel.AutoSize = $true
        $choiceLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
        $choiceLabel.ForeColor = Get-CpcvTrayColor "#0F172A"
        $choiceLabel.Location = New-Object System.Drawing.Point(24, 158)
        $form.Controls.Add($choiceLabel)

        $crossPlatform = New-Object System.Windows.Forms.RadioButton
        $crossPlatform.Name = "cpcvTrayTmuxCrossPlatformRadio"
        $crossPlatform.Text = "Recommended: Windows Alt-V + macOS Ctrl-V"
        $crossPlatform.AutoSize = $true
        $crossPlatform.Location = New-Object System.Drawing.Point(28, 187)
        $crossPlatform.Checked = $true
        $form.Controls.Add($crossPlatform)

        $crossPlatformHint = New-Object System.Windows.Forms.Label
        $crossPlatformHint.Name = "cpcvTrayTmuxCrossPlatformHint"
        $crossPlatformHint.Text = "Both shortcuts are installed for every connected client; tmux does not detect OS. On Windows, use Alt-V."
        $crossPlatformHint.AutoSize = $false
        $crossPlatformHint.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $crossPlatformHint.ForeColor = Get-CpcvTrayColor "#64748B"
        $crossPlatformHint.Location = New-Object System.Drawing.Point(50, 211)
        $crossPlatformHint.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $crossPlatformHint.Size = New-Object System.Drawing.Size(686, 19)
        $form.Controls.Add($crossPlatformHint)

        $recommended = New-Object System.Windows.Forms.RadioButton
        $recommended.Name = "cpcvTrayTmuxRecommendedRadio"
        $recommended.Text = "Alternative: tmux prefix, then v"
        $recommended.AutoSize = $true
        $recommended.Location = New-Object System.Drawing.Point(28, 237)
        $form.Controls.Add($recommended)

        $custom = New-Object System.Windows.Forms.RadioButton
        $custom.Name = "cpcvTrayTmuxCustomRadio"
        $custom.Text = "Custom: tmux prefix, then"
        $custom.AutoSize = $true
        $custom.Location = New-Object System.Drawing.Point(28, 266)
        $form.Controls.Add($custom)

        $customKey = New-Object System.Windows.Forms.TextBox
        $customKey.Name = "cpcvTrayTmuxCustomKeyInput"
        $customKey.Text = "v"
        $customKey.CharacterCasing = [System.Windows.Forms.CharacterCasing]::Lower
        $customKey.MaxLength = 1
        $customKey.Enabled = $false
        $customKey.Size = New-Object System.Drawing.Size(42, 25)
        $customKey.Location = New-Object System.Drawing.Point(214, 262)
        $customKey.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
        $form.Controls.Add($customKey)

        $customHint = New-Object System.Windows.Forms.Label
        $customHint.Text = "one lowercase letter or number"
        $customHint.AutoSize = $true
        $customHint.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $customHint.ForeColor = Get-CpcvTrayColor "#64748B"
        $customHint.Location = New-Object System.Drawing.Point(266, 266)
        $form.Controls.Add($customHint)

        $raw = New-Object System.Windows.Forms.RadioButton
        $raw.Name = "cpcvTrayTmuxRawRadio"
        $raw.Text = "Advanced: raw Ctrl-V"
        $raw.AutoSize = $true
        $raw.Location = New-Object System.Drawing.Point(28, 295)
        $form.Controls.Add($raw)

        $rawWarning = New-Object System.Windows.Forms.Label
        $rawWarning.Name = "cpcvTrayTmuxRawWarning"
        $rawWarning.Text = "Warning: this replaces ordinary Ctrl-V in the remote tmux server for every connected client. Warp and other terminals can capture Ctrl-V locally before tmux sees it, so choose this only when you have configured your terminal to forward it."
        $rawWarning.AutoSize = $false
        $rawWarning.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $rawWarning.ForeColor = Get-CpcvTrayColor "#92400E"
        $rawWarning.BackColor = Get-CpcvTrayColor "#FFFBEB"
        $rawWarning.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
        $rawWarning.Location = New-Object System.Drawing.Point(50, 322)
        $rawWarning.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $rawWarning.Size = New-Object System.Drawing.Size(686, 46)
        $rawWarning.Visible = $false
        $form.Controls.Add($rawWarning)

        $selection = New-Object System.Windows.Forms.Label
        $selection.Name = "cpcvTrayTmuxSelectionText"
        $selection.AutoSize = $false
        $selection.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8.5)
        $selection.ForeColor = Get-CpcvTrayColor "#3730A3"
        $selection.Location = New-Object System.Drawing.Point(28, 377)
        $selection.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $selection.Size = New-Object System.Drawing.Size(708, 22)
        $form.Controls.Add($selection)

        $statusLabel = New-Object System.Windows.Forms.Label
        $statusLabel.Text = "Remote tmux status"
        $statusLabel.AutoSize = $true
        $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
        $statusLabel.ForeColor = Get-CpcvTrayColor "#0F172A"
        $statusLabel.Location = New-Object System.Drawing.Point(24, 407)
        $form.Controls.Add($statusLabel)

        $status = New-Object System.Windows.Forms.TextBox
        $status.Name = "cpcvTrayTmuxStatusText"
        $status.ReadOnly = $true
        $status.Multiline = $true
        $status.WordWrap = $true
        $status.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $status.BackColor = [System.Drawing.Color]::White
        $status.ForeColor = Get-CpcvTrayColor "#334155"
        $status.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $status.Location = New-Object System.Drawing.Point(24, 431)
        $status.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $status.Size = New-Object System.Drawing.Size(712, 88)
        $status.Text = "Remote setup has not been checked yet."
        $form.Controls.Add($status)

        $startupLabel = New-Object System.Windows.Forms.Label
        $startupLabel.Text = "To load cpcv automatically when tmux starts, add this one user-owned line to your remote tmux config:"
        $startupLabel.AutoSize = $false
        $startupLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $startupLabel.ForeColor = Get-CpcvTrayColor "#475569"
        $startupLabel.Location = New-Object System.Drawing.Point(24, 530)
        $startupLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $startupLabel.Size = New-Object System.Drawing.Size(712, 20)
        $form.Controls.Add($startupLabel)

        $startupLine = New-Object System.Windows.Forms.TextBox
        $startupLine.Name = "cpcvTrayTmuxStartupLine"
        $startupLine.ReadOnly = $true
        $startupLine.Text = Get-CpcvTrayTmuxStartupLine
        $startupLine.Font = New-Object System.Drawing.Font("Consolas", 9)
        $startupLine.BackColor = [System.Drawing.Color]::White
        $startupLine.Location = New-Object System.Drawing.Point(24, 553)
        $startupLine.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $startupLine.Size = New-Object System.Drawing.Size(540, 26)
        $form.Controls.Add($startupLine)

        $copyStartup = New-Object System.Windows.Forms.Button
        $copyStartup.Name = "cpcvTrayTmuxCopyStartupButton"
        $copyStartup.Text = "Copy line"
        $copyStartup.Size = New-Object System.Drawing.Size(102, 28)
        $copyStartup.Location = New-Object System.Drawing.Point(574, 551)
        $copyStartup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CpcvTrayButtonStyle -Button $copyStartup -Kind Quiet
        $form.Controls.Add($copyStartup)

        $feedback = New-Object System.Windows.Forms.Label
        $feedback.Name = "cpcvTrayTmuxFeedback"
        $feedback.AutoSize = $false
        $feedback.AutoEllipsis = $true
        $feedback.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $feedback.ForeColor = Get-CpcvTrayColor "#475569"
        $feedback.Location = New-Object System.Drawing.Point(24, 588)
        $feedback.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $feedback.Size = New-Object System.Drawing.Size(348, 48)
        $form.Controls.Add($feedback)

        $check = New-Object System.Windows.Forms.Button
        $check.Name = "cpcvTrayTmuxCheckButton"
        $check.Text = "Check remote setup"
        $check.Size = New-Object System.Drawing.Size(142, 34)
        $check.Location = New-Object System.Drawing.Point(386, 650)
        $check.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CpcvTrayButtonStyle -Button $check -Kind Secondary
        $form.Controls.Add($check)

        $apply = New-Object System.Windows.Forms.Button
        $apply.Name = "cpcvTrayTmuxApplyButton"
        $apply.Text = "Install / apply"
        $apply.Size = New-Object System.Drawing.Size(126, 34)
        $apply.Location = New-Object System.Drawing.Point(536, 650)
        $apply.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CpcvTrayButtonStyle -Button $apply -Kind Primary
        $form.Controls.Add($apply)

        $close = New-Object System.Windows.Forms.Button
        $close.Name = "cpcvTrayTmuxCloseButton"
        $close.Text = "Close"
        # Keep Close active during a remote operation so the user can cancel
        # its dedicated background job and leave the dialog. It must not use a
        # DialogResult, which would close before that cleanup can run.
        $close.DialogResult = [System.Windows.Forms.DialogResult]::None
        $close.Size = New-Object System.Drawing.Size(82, 34)
        $close.Location = New-Object System.Drawing.Point(670, 650)
        $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CpcvTrayButtonStyle -Button $close -Kind Quiet
        $form.Controls.Add($close)
        $form.CancelButton = $close

        $getChoice = {
            $mode = if ($crossPlatform.Checked) { "CrossPlatform" } elseif ($recommended.Checked) { "Recommended" } elseif ($custom.Checked) { "Custom" } else { "RawCtrlV" }
            return Resolve-CpcvTrayTmuxPathInsertionChoice -Mode $mode -CustomKey $customKey.Text
        }.GetNewClosure()
        $syncChoice = {
            $customKey.Enabled = $custom.Checked
            $rawWarning.Visible = $raw.Checked
            $crossPlatformHint.Visible = $crossPlatform.Checked
            try {
                $choice = & $getChoice
                $selection.Text = "Selected: $($choice.Label)."
            }
            catch {
                $selection.Text = ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message -MaximumLength 240
            }
        }.GetNewClosure()
        $showState = {
            param([AllowNull()][object]$State)
            $status.Text = Format-CpcvTrayTmuxState -State $State
            $status.SelectionStart = 0
            $status.ScrollToCaret()
        }.GetNewClosure()
        $setBusy = {
            param([bool]$Busy)
            $check.Enabled = -not $Busy
            $apply.Enabled = -not $Busy
            $recommended.Enabled = -not $Busy
            $crossPlatform.Enabled = -not $Busy
            $custom.Enabled = -not $Busy
            $raw.Enabled = -not $Busy
            $customKey.Enabled = (-not $Busy -and $custom.Checked)
            $close.Text = if ($Busy) { "Cancel and close" } else { "Close" }
        }.GetNewClosure()
        $showOperationFailure = {
            param(
                [Parameter(Mandatory)]$Choice,
                [Parameter(Mandatory)][string]$Operation,
                [AllowEmptyString()][string]$Detail
            )

            $safeDetail = ConvertTo-CpcvTrayDisplayText -Text $Detail -MaximumLength 340
            $failureState = [pscustomobject]@{
                Ok = $false; Connection = "Unavailable"; Tmux = "Unknown"; Plugin = "Unknown"; Server = "Unknown"
                Table = $Choice.Table; Key = $Choice.Key; SecondaryTable = $Choice.SecondaryTable; SecondaryKey = $Choice.SecondaryKey
                Binding = "Unknown"; SecondaryBinding = if ($Choice.SecondaryTable) { "Unknown" } else { "NotSelected" }; Override = "Unknown"; Detail = $safeDetail
            }
            & $showState $failureState
            $feedback.ForeColor = Get-CpcvTrayColor "#B91C1C"
            $verb = if ($Operation -eq "Check") { "check the remote setup" } else { "finish the remote tmux operation" }
            $feedback.Text = if ($safeDetail) { "cpcv could not $verb. $safeDetail" } else { "cpcv could not $verb." }
        }.GetNewClosure()
        $renderCheck = {
            param([Parameter(Mandatory)]$State)

            & $showState $State
            $feedback.ForeColor = if ($State.Ok) { Get-CpcvTrayColor "#0F766E" } else { Get-CpcvTrayColor "#B91C1C" }
            $feedback.Text = if ($State.Ok) { "Remote setup checked. Apply remains an explicit action." } else { "cpcv could not check the remote setup. Review the status above." }
        }.GetNewClosure()
        $renderApply = {
            param(
                [Parameter(Mandatory)]$Result,
                [Parameter(Mandatory)]$Choice
            )

            $resultState = $Result.PSObject.Properties["State"]
            if ($null -ne $resultState -and $null -ne $resultState.Value) {
                & $showState $resultState.Value
            }
            else {
                $status.Text = "Selected: $($Choice.Label).`r`n" + (ConvertTo-CpcvTrayDisplayText -Text ([string]$Result.Detail) -MaximumLength 480)
            }
            if ($Result.Ok) {
                $form.Tag = $true
                $feedback.ForeColor = Get-CpcvTrayColor "#0F766E"
                $feedback.Text = if ($Result.Applied) {
                    "Applied now to the default tmux server. Copy the startup line so a future tmux server loads cpcv too."
                }
                elseif ($Result.Reason -eq "tmux-missing") {
                    "Saved the cpcv setting, but tmux is not installed on the SSH computer yet. Copy the startup line for after tmux is installed."
                }
                else {
                    "Saved the cpcv setting. No default tmux server was running to reload; copy the startup line for future servers."
                }
            }
            else {
                $feedback.ForeColor = Get-CpcvTrayColor "#B91C1C"
                $feedback.Text = ConvertTo-CpcvTrayDisplayText -Text ([string]$Result.Detail) -MaximumLength 340
            }
        }.GetNewClosure()
        $operationState = [ordered]@{
            Job = $null
            Operation = ""
            Choice = $null
            StartedAt = $null
        }
        $operationTimer = New-Object System.Windows.Forms.Timer
        $operationTimer.Interval = 150
        $operationTimer.Add_Tick({
            $job = $operationState.Job
            if ($null -eq $job) {
                $operationTimer.Stop()
                return
            }

            $completion = Receive-CpcvTrayTmuxRemoteJob -Job $job
            if (-not $completion.Completed) {
                if ($operationState.StartedAt -and ((Get-Date) - $operationState.StartedAt).TotalSeconds -ge 3) {
                    $verb = if ($operationState.Operation -eq "Check") { "Checking remote tmux setup" } else { "Installing and applying the remote tmux setting" }
                    $feedback.Text = "$verb... You can cancel and close this window while it is still working."
                }
                return
            }

            $operationTimer.Stop()
            $operation = [string]$operationState.Operation
            $choice = $operationState.Choice
            $operationState.Job = $null
            $operationState.Operation = ""
            $operationState.Choice = $null
            $operationState.StartedAt = $null
            & $setBusy $false
            if ($completion.Ok) {
                if ($operation -eq "Check") { & $renderCheck $completion.Result }
                else { & $renderApply $completion.Result $choice }
            }
            else {
                & $showOperationFailure $choice $operation $completion.Detail
            }
        }.GetNewClosure())
        $startAsyncOperation = {
            param([Parameter(Mandatory)][ValidateSet("Check", "Apply")][string]$Operation)

            try {
                $choice = & $getChoice
                & $setBusy $true
                $feedback.ForeColor = Get-CpcvTrayColor "#3730A3"
                $feedback.Text = if ($Operation -eq "Check") {
                    "Checking remote tmux setup..."
                }
                else {
                    "Installing and applying the remote tmux setting. This can take a few minutes..."
                }
                $operationState.Job = Start-CpcvTrayTmuxRemoteJob -Operation $Operation -Table $choice.Table -Key $choice.Key -SecondaryTable $choice.SecondaryTable -SecondaryKey $choice.SecondaryKey
                $operationState.Operation = $Operation
                $operationState.Choice = $choice
                $operationState.StartedAt = Get-Date
                $operationTimer.Start()
            }
            catch {
                $choiceForError = if ($null -ne $choice) { $choice } else { [pscustomobject]@{ Table = ""; Key = "" } }
                $operationState.Job = $null
                & $setBusy $false
                & $showOperationFailure $choiceForError $Operation $_.Exception.Message
            }
        }.GetNewClosure()

        $crossPlatform.Add_CheckedChanged({ if ($crossPlatform.Checked) { & $syncChoice } }.GetNewClosure())
        $recommended.Add_CheckedChanged({ if ($recommended.Checked) { & $syncChoice } }.GetNewClosure())
        $custom.Add_CheckedChanged({ if ($custom.Checked) { & $syncChoice } }.GetNewClosure())
        $raw.Add_CheckedChanged({ if ($raw.Checked) { & $syncChoice } }.GetNewClosure())
        $customKey.Add_TextChanged({ if ($custom.Checked) { & $syncChoice } }.GetNewClosure())
        $copyStartup.Add_Click({
            try {
                Set-Clipboard -Value $startupLine.Text
                $feedback.ForeColor = Get-CpcvTrayColor "#0F766E"
                $feedback.Text = "The startup line was copied. Add it to your own remote tmux configuration when you are ready."
            }
            catch {
                $feedback.ForeColor = Get-CpcvTrayColor "#B91C1C"
                $feedback.Text = ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message -MaximumLength 340
            }
        }.GetNewClosure())
        if ($TestMode -and -not $UseAsyncWorker) {
            # Keep synthetic UI probes deterministic and in-process. The real
            # dialog takes the asynchronous branch below.
            $check.Add_Click({
                try {
                    $choice = & $getChoice
                    & $setBusy $true
                    & $renderCheck (Get-CpcvRemoteTmuxState -Table $choice.Table -Key $choice.Key -SecondaryTable $choice.SecondaryTable -SecondaryKey $choice.SecondaryKey)
                }
                catch {
                    $choiceForError = if ($null -ne $choice) { $choice } else { [pscustomobject]@{ Table = ""; Key = "" } }
                    & $showOperationFailure $choiceForError "Check" $_.Exception.Message
                }
                finally { & $setBusy $false }
            }.GetNewClosure())
            $apply.Add_Click({
                try {
                    $choice = & $getChoice
                    & $setBusy $true
                    & $renderApply (Apply-CpcvRemoteTmuxBinding -Table $choice.Table -Key $choice.Key -SecondaryTable $choice.SecondaryTable -SecondaryKey $choice.SecondaryKey) $choice
                }
                catch {
                    $choiceForError = if ($null -ne $choice) { $choice } else { [pscustomobject]@{ Table = ""; Key = "" } }
                    & $showOperationFailure $choiceForError "Apply" $_.Exception.Message
                }
                finally { & $setBusy $false }
            }.GetNewClosure())
        }
        else {
            $check.Add_Click({ & $startAsyncOperation "Check" }.GetNewClosure())
            $apply.Add_Click({ & $startAsyncOperation "Apply" }.GetNewClosure())
        }
        $close.Add_Click({ $form.Close() }.GetNewClosure())
        $form.Add_FormClosing({
            if ($null -ne $operationState -and $null -ne $operationState.Job) {
                Stop-CpcvTrayTmuxRemoteJob -Job $operationState.Job
                $operationState.Job = $null
            }
        }.GetNewClosure())
        $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        & $syncChoice
        [void]$form.ShowDialog()
        return [bool]$form.Tag
    }
    finally {
        if ($operationTimer) { $operationTimer.Stop(); $operationTimer.Dispose() }
        if ($operationState -and $operationState.Job) { Stop-CpcvTrayTmuxRemoteJob -Job $operationState.Job }
        if ($form) { $form.Dispose() }
    }
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
    $settingsButton.Text = "Settings..."
    $settingsButton.Size = New-Object System.Drawing.Size(112, 30)
    $settingsButton.Location = New-Object System.Drawing.Point(20, 119)
    Set-CpcvTrayButtonStyle -Button $settingsButton -Kind Quiet
    $actions.Controls.Add($settingsButton)

    $logButton = New-Object System.Windows.Forms.Button
    $logButton.Name = "cpcvTrayLogButton"
    $logButton.Text = "View activity..."
    $logButton.Size = New-Object System.Drawing.Size(120, 30)
    $logButton.Location = New-Object System.Drawing.Point(142, 119)
    Set-CpcvTrayButtonStyle -Button $logButton -Kind Quiet
    $actions.Controls.Add($logButton)

    $dataButton = New-Object System.Windows.Forms.Button
    $dataButton.Name = "cpcvTrayDataButton"
    $dataButton.Text = "Open data folder"
    $dataButton.Size = New-Object System.Drawing.Size(128, 30)
    $dataButton.Location = New-Object System.Drawing.Point(272, 119)
    Set-CpcvTrayButtonStyle -Button $dataButton -Kind Quiet
    $actions.Controls.Add($dataButton)

    $tmuxButton = New-Object System.Windows.Forms.Button
    $tmuxButton.Name = "cpcvTrayTmuxButton"
    $tmuxButton.Text = "Tmux path insertion..."
    $tmuxButton.Size = New-Object System.Drawing.Size(182, 30)
    $tmuxButton.Location = New-Object System.Drawing.Point(410, 119)
    Set-CpcvTrayButtonStyle -Button $tmuxButton -Kind Quiet
    $actions.Controls.Add($tmuxButton)

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
    $tooltip.SetToolTip($tmuxButton, "Configure the optional cpcv path-insertion binding on the remote tmux server.")

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
        $latestCard.Value.Text = Get-CpcvTrayLatestUploadText -State $CurrentState
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
    $settingsButton.Add_Click({
        try {
            if (Show-CpcvTraySettingsWindow) { & $refreshDashboard (Get-CpcvTrayState) }
        }
        catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $tmuxButton.Add_Click({ try { Show-CpcvTrayTmuxSetupWindow } catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) } })
    $logButton.Add_Click({ try { Show-CpcvTrayRecentActivityWindow } catch { Show-CpcvTrayError (ConvertTo-CpcvTrayDisplayText -Text $_.Exception.Message) } })
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
        $logItem = $menu.Items.Add("View recent activity...")
        $configItem = $menu.Items.Add("Settings...")
        $tmuxItem = $menu.Items.Add("Configure tmux path insertion...")
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
            $latestUpload = Get-CpcvTrayLatestUploadText -State $state
            $statusItem.Text = if ($state.Level -eq "Healthy" -and $latestUpload -match '^Uploaded ') {
                "Status: Healthy - $latestUpload"
            }
            else {
                "Status: $($state.Level) - $($state.Summary)"
            }
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
        $logItem.Add_Click({ try { Show-CpcvTrayRecentActivityWindow } catch { Show-CpcvTrayError $_.Exception.Message } })
        $configItem.Add_Click({ try { if (Show-CpcvTraySettingsWindow) { & $refreshUi } } catch { Show-CpcvTrayError $_.Exception.Message } })
        $tmuxItem.Add_Click({ try { Show-CpcvTrayTmuxSetupWindow } catch { Show-CpcvTrayError $_.Exception.Message } })
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
