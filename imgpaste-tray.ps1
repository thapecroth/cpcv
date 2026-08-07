<#
.SYNOPSIS
Shows a small Windows notification-area controller for imgpaste.

.DESCRIPTION
This is deliberately a companion to the guardian rather than a second
watcher.  It only starts or stops processes whose exact -File argument points
to this checkout, and it reads the existing health and state files.

Run it from an STA PowerShell process, for example:
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\imgpaste-tray.ps1
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
. (Join-Path $PSScriptRoot "imgpaste-core.ps1")

function Get-ImgPasteTrayProcessProbe {
    param([Parameter(Mandatory)][string]$ScriptPath)

    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.Name -in @("powershell.exe", "pwsh.exe") -and
                (Test-ImgPasteProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $ScriptPath)
            })
        return [pscustomobject]@{ Available = $true; Processes = $processes; Error = "" }
    }
    catch {
        # A status UI must never decide that a service is stopped merely
        # because process inspection was denied or unavailable.
        return [pscustomobject]@{ Available = $false; Processes = @(); Error = $_.Exception.Message }
    }
}

function Test-ImgPasteTrayShortcutOwnership {
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
        $marked = $description -eq "Managed by imgpaste install-tray.ps1"
        $legacy = $description -eq "imgpaste status and controls"
        return ($actualTarget -ieq $expectedTarget -and
            (Test-ImgPasteProcessCommandLineForScript -CommandLine ([string]$shortcut.Arguments) -ScriptPath $ScriptPath) -and
            $actualDirectory -eq $expectedDirectory -and ($marked -or $legacy))
    }
    catch { return $false }
}

function Get-ImgPasteTrayLatestPath {
    param([Parameter(Mandatory)]$Config)

    try {
        if (-not (Test-Path -LiteralPath $Config.LastRemotePathFile)) { return "" }
        $path = (Get-Content -LiteralPath $Config.LastRemotePathFile -Raw -ErrorAction Stop).Trim()
        if (Test-ImgPasteRemotePath $path) { return $path }
    }
    catch { }
    return ""
}

function Get-ImgPasteTrayState {
    # imgpaste-core.ps1 owns its script-scoped cached configuration. Calling
    # its public loader avoids depending on a caller's dot-sourcing scope.
    $cfg = Get-ImgPasteConfig
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-guardian.ps1"))
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-watch.ps1"))
    $guardianProbe = Get-ImgPasteTrayProcessProbe -ScriptPath $guardianScript
    $watchProbe = Get-ImgPasteTrayProcessProbe -ScriptPath $watchScript
    $guardians = @($guardianProbe.Processes)
    $watchers = @($watchProbe.Processes)

    $heartbeatInfo = $null
    $heartbeatAgeSeconds = $null
    if (Test-Path -LiteralPath $cfg.HeartbeatFile) {
        $heartbeatInfo = Get-ImgPasteHeartbeatInfo -Path $cfg.HeartbeatFile
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
        $summary = "Duplicate imgpaste process detected"
        $detail = "Use Restart service to stop only this checkout's duplicate processes."
    }
    elseif ($guardians.Count -eq 0 -and $watchers.Count -eq 0) {
        $level = "Stopped"
        $summary = "The imgpaste service is stopped"
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
        $summary = "imgpaste is running"
        $detail = $heartbeatInfo.Status
    }

    $latestPath = Get-ImgPasteTrayLatestPath -Config $cfg
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

function Get-ImgPasteTrayTooltip {
    param([Parameter(Mandatory)]$State)
    # NotifyIcon accepts at most 63 characters.  Do not put hosts, paths, or
    # log details in a system-wide hover tooltip.
    $text = "imgpaste: $($State.Level) - $($State.Summary)"
    if ($text.Length -gt 63) { return $text.Substring(0, 60) + "..." }
    return $text
}

function Start-ImgPasteTrayGuardian {
    $cfg = Get-ImgPasteConfig
    if ($cfg.ConfigError) { throw $cfg.ConfigError }
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-guardian.ps1"))
    $probe = Get-ImgPasteTrayProcessProbe -ScriptPath $guardianScript
    if (-not $probe.Available) { throw "Cannot inspect local processes; refusing to start another guardian." }
    if ((@($probe.Processes)).Count -gt 0) { return $false }

    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $guardianScript)
    ) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    Write-ImgPasteLog "tray requested guardian start"
    return $true
}

function Stop-ImgPasteTrayService {
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-guardian.ps1"))
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-watch.ps1"))
    $guardianProbe = Get-ImgPasteTrayProcessProbe -ScriptPath $guardianScript
    $watchProbe = Get-ImgPasteTrayProcessProbe -ScriptPath $watchScript
    if (-not $guardianProbe.Available -or -not $watchProbe.Available) {
        throw "Cannot inspect local processes; refusing to stop anything."
    }

    # Stop the guardian first to prevent it from immediately replacing a
    # watcher that the user explicitly asked to stop.  Both lists are scoped
    # by the exact checkout path, never a filename-only match.
    foreach ($process in @($guardianProbe.Processes) + @($watchProbe.Processes)) {
        Stop-ImgPasteProcessTree -ProcessId ([int]$process.ProcessId)
    }
    Write-ImgPasteLog "tray requested service stop"
}

function Restart-ImgPasteTrayService {
    Stop-ImgPasteTrayService
    Start-Sleep -Milliseconds 500
    [void](Start-ImgPasteTrayGuardian)
    Write-ImgPasteLog "tray requested service restart"
}

function Start-ImgPasteTrayUpload {
    $cfg = Get-ImgPasteConfig
    if ($cfg.ConfigError) { throw $cfg.ConfigError }
    $nowScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-now.ps1"))
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $nowScript), "-Silent"
    ) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    Write-ImgPasteLog "tray requested one-shot clipboard upload"
}

function Copy-ImgPasteTrayLatestPath {
    param([Parameter(Mandatory)]$State)
    if ([string]::IsNullOrWhiteSpace($State.LatestPath) -or -not (Test-ImgPasteRemotePath $State.LatestPath)) {
        throw "There is no valid uploaded path to copy yet."
    }
    Set-Clipboard -Value $State.LatestPath
}

function Open-ImgPasteTrayLog {
    $path = (Get-ImgPasteConfig).LogFile
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Force -Path $path | Out-Null }
    Start-Process -FilePath "notepad.exe" -ArgumentList @(('"{0}"' -f $path)) | Out-Null
}

function Open-ImgPasteTrayConfig {
    $path = Get-ImgPasteConfigPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    if (-not (Test-Path -LiteralPath $path)) {
        $example = Join-Path $PSScriptRoot "imgpaste.config.example.psd1"
        Copy-Item -LiteralPath $example -Destination $path -Force
    }
    Start-Process -FilePath "notepad.exe" -ArgumentList @(('"{0}"' -f $path)) | Out-Null
}

function Open-ImgPasteTrayDataFolder {
    $path = (Get-ImgPasteConfig).DataRoot
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    Start-Process -FilePath "explorer.exe" -ArgumentList @(('"{0}"' -f $path)) | Out-Null
}

function Show-ImgPasteTrayError {
    param([Parameter(Mandatory)][string]$Message)
    [void][System.Windows.Forms.MessageBox]::Show($Message, "imgpaste", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
}

function Show-ImgPasteTrayStatusWindow {
    param([Parameter(Mandatory)]$State)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "imgpaste status"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(600, 330)
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.FormBorderStyle = "FixedDialog"

    $text = New-Object System.Windows.Forms.TextBox
    $text.Multiline = $true
    $text.ReadOnly = $true
    $text.WordWrap = $true
    $text.ScrollBars = "Vertical"
    $text.BorderStyle = "None"
    $text.BackColor = [System.Drawing.SystemColors]::Window
    $text.Location = New-Object System.Drawing.Point(18, 18)
    $text.Size = New-Object System.Drawing.Size(548, 220)
    $heartbeat = if ($State.Heartbeat) {
        "PID $($State.Heartbeat.ProcessId); $($State.Heartbeat.Status); $([Math]::Round($State.HeartbeatAgeSeconds, 1)) seconds ago"
    } else { "not available" }
    $text.Text = @"
Status: $($State.Level)
$($State.Summary)

Detail: $($State.Detail)
Guardian processes: $((@($State.Guardians)).Count)
Watcher processes: $((@($State.Watchers)).Count)
Heartbeat: $heartbeat
Latest uploaded path: $($State.LatestPath)
Data folder: $($State.Config.DataRoot)
"@
    $form.Controls.Add($text)

    $restart = New-Object System.Windows.Forms.Button
    $restart.Text = "Restart service"
    $restart.Location = New-Object System.Drawing.Point(18, 252)
    $restart.Size = New-Object System.Drawing.Size(130, 30)
    $restart.Add_Click({
        try { Restart-ImgPasteTrayService; $form.Close() }
        catch { Show-ImgPasteTrayError $_.Exception.Message }
    })
    $form.Controls.Add($restart)

    $log = New-Object System.Windows.Forms.Button
    $log.Text = "Open log"
    $log.Location = New-Object System.Drawing.Point(158, 252)
    $log.Size = New-Object System.Drawing.Size(100, 30)
    $log.Add_Click({ try { Open-ImgPasteTrayLog } catch { Show-ImgPasteTrayError $_.Exception.Message } })
    $form.Controls.Add($log)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = "Close"
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Location = New-Object System.Drawing.Point(466, 252)
    $close.Size = New-Object System.Drawing.Size(100, 30)
    $form.Controls.Add($close)
    $form.CancelButton = $close
    [void]$form.ShowDialog()
    $form.Dispose()
}

function Start-ImgPasteTrayApplication {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
        throw "imgpaste-tray.ps1 must be run with powershell.exe -STA. Use install-tray.ps1 to add a safe Startup shortcut."
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $mutex = New-Object System.Threading.Mutex($false, (Get-ImgPasteMutexName -Purpose "Tray"))
    if (-not $mutex.WaitOne(0, $false)) { return }
    $notify = $null
    $timer = $null
    try {
        $script:ImgPasteTrayState = Get-ImgPasteTrayState
        $script:ImgPasteTrayLastLevel = ""
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $statusItem = $menu.Items.Add("Loading status...")
        $statusItem.Enabled = $false
        [void]$menu.Items.Add("-")
        $uploadItem = $menu.Items.Add("Upload clipboard image now")
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
        $exitItem = $menu.Items.Add("Exit tray")

        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Application
        $notify.ContextMenuStrip = $menu
        $notify.Visible = $true
        $context = New-Object System.Windows.Forms.ApplicationContext

        $refreshUi = {
            $script:ImgPasteTrayState = Get-ImgPasteTrayState
            $state = $script:ImgPasteTrayState
            $statusItem.Text = "Status: $($state.Level) - $($state.Summary)"
            $notify.Text = Get-ImgPasteTrayTooltip -State $state
            $isRunning = ((@($state.Guardians)).Count -gt 0 -or (@($state.Watchers)).Count -gt 0)
            $startItem.Enabled = ($state.Level -ne "Error" -and $state.GuardianProbeAvailable -and -not $isRunning)
            $stopItem.Enabled = ($state.GuardianProbeAvailable -and $state.WatcherProbeAvailable -and $isRunning)
            $restartItem.Enabled = ($state.Level -ne "Error" -and $state.GuardianProbeAvailable -and $state.WatcherProbeAvailable)
            $copyItem.Enabled = (-not [string]::IsNullOrWhiteSpace($state.LatestPath) -and (Test-ImgPasteRemotePath $state.LatestPath))
            if ($script:ImgPasteTrayLastLevel -and $script:ImgPasteTrayLastLevel -ne $state.Level -and $state.Level -in @("Warning", "Error")) {
                $notify.BalloonTipTitle = "imgpaste: $($state.Level)"
                $notify.BalloonTipText = $state.Summary
                $notify.ShowBalloonTip(3000)
            }
            $script:ImgPasteTrayLastLevel = $state.Level
        }

        $uploadItem.Add_Click({ try { Start-ImgPasteTrayUpload; $notify.ShowBalloonTip(2000, "imgpaste", "One-shot upload requested.", [System.Windows.Forms.ToolTipIcon]::Info) } catch { Show-ImgPasteTrayError $_.Exception.Message } })
        $copyItem.Add_Click({ try { Copy-ImgPasteTrayLatestPath -State $script:ImgPasteTrayState; $notify.ShowBalloonTip(1500, "imgpaste", "Latest upload path copied.", [System.Windows.Forms.ToolTipIcon]::Info) } catch { Show-ImgPasteTrayError $_.Exception.Message } })
        $startItem.Add_Click({ try { [void](Start-ImgPasteTrayGuardian); & $refreshUi } catch { Show-ImgPasteTrayError $_.Exception.Message } })
        $stopItem.Add_Click({ try { Stop-ImgPasteTrayService; & $refreshUi } catch { Show-ImgPasteTrayError $_.Exception.Message } })
        $restartItem.Add_Click({ try { Restart-ImgPasteTrayService; & $refreshUi } catch { Show-ImgPasteTrayError $_.Exception.Message } })
        $logItem.Add_Click({ try { Open-ImgPasteTrayLog } catch { Show-ImgPasteTrayError $_.Exception.Message } })
        $configItem.Add_Click({ try { Open-ImgPasteTrayConfig } catch { Show-ImgPasteTrayError $_.Exception.Message } })
        $dataItem.Add_Click({ try { Open-ImgPasteTrayDataFolder } catch { Show-ImgPasteTrayError $_.Exception.Message } })
        $notify.Add_DoubleClick({ & $refreshUi; Show-ImgPasteTrayStatusWindow -State $script:ImgPasteTrayState })
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
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}

if (-not $NoRun) { Start-ImgPasteTrayApplication }
