# Shared helpers for imgpaste. Configuration is local-only; see
# imgpaste.config.example.psd1 and README.md.

$script:ImgPasteRoot = $PSScriptRoot
$script:ImgPasteConfigPath = if ($env:IMGPASTE_CONFIG) {
    $env:IMGPASTE_CONFIG
}
else {
    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
    Join-Path $localAppData "imgpaste\config.psd1"
}

function Get-ImgPasteConfigPath { return $script:ImgPasteConfigPath }

function New-ImgPasteDefaultConfig {
    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
    $dataRoot = Join-Path $localAppData "imgpaste"
    return [ordered]@{
        HostAlias             = ""
        RemoteDir             = "clipboard-images"
        RemoteHome            = ""
        DataRoot              = $dataRoot
        LocalCache            = (Join-Path $dataRoot "cache")
        StateFile             = (Join-Path $dataRoot "last-hash.txt")
        LastRemotePathFile    = (Join-Path $dataRoot "last-remote-path.txt")
        LogFile               = (Join-Path $dataRoot "watch.log")
        HeartbeatFile         = (Join-Path $dataRoot "watch.heartbeat")
        CommandTimeoutSeconds = 35
        MaxCommandOutputBytes = 65536
        PollIntervalSeconds   = 2
        WatchdogCheckSeconds  = 15
        WatchdogStaleSeconds  = 120
        MaxLogBytes           = 1048576
        MaxCacheFiles         = 200
        MaxCacheBytes         = 268435456
        MaxImageBytes         = 52428800
        ConfigError           = ""
    }
}

function ConvertTo-ImgPasteStrictInteger {
    param([AllowNull()]$Value)

    # Do not rely on PowerShell's permissive casts here.  Values such as a
    # floating point number, Boolean, or malformed string should make the
    # configuration unusable instead of silently changing a watchdog limit.
    if ($Value -is [int]) { return [pscustomobject]@{ IsValid = $true; Value = [int]$Value } }
    if ($Value -is [long]) {
        if ($Value -ge [int]::MinValue -and $Value -le [int]::MaxValue) {
            return [pscustomobject]@{ IsValid = $true; Value = [int]$Value }
        }
        return [pscustomobject]@{ IsValid = $false; Value = 0 }
    }
    if ($Value -is [string] -and $Value -match '^-?\d+$') {
        [int]$parsed = 0
        if ([int]::TryParse($Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            return [pscustomobject]@{ IsValid = $true; Value = $parsed }
        }
    }
    return [pscustomobject]@{ IsValid = $false; Value = 0 }
}

function Test-ImgPasteConfigValue {
    param([System.Collections.IDictionary]$Config)
    if ($Config.HostAlias -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.HostAlias)) { return "HostAlias is required. Configure an SSH alias or user@host." }
    if ($Config.HostAlias -notmatch '^[A-Za-z0-9][A-Za-z0-9._@:-]*$') { return "HostAlias contains unsupported characters." }
    if ($Config.RemoteDir -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.RemoteDir) -or $Config.RemoteDir -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Config.RemoteDir.StartsWith('/') -or $Config.RemoteDir -match '(^|/)\.\.(/|$)') {
        return "RemoteDir must be a relative POSIX path without '..'."
    }
    if ($Config.RemoteHome -isnot [string]) { return "RemoteHome must be empty or an absolute POSIX path without '..'." }
    if ($Config.RemoteHome -and ($Config.RemoteHome -notmatch '^/[A-Za-z0-9._/-]*$' -or $Config.RemoteHome -match '(^|/)\.\.(/|$)')) {
        return "RemoteHome must be empty or an absolute POSIX path without '..'."
    }
    if ($Config.DataRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.DataRoot)) { return "DataRoot is required." }

    $numeric = @{}
    foreach ($rule in @(
        @{ Name = "CommandTimeoutSeconds"; Minimum = 1; Maximum = 600 },
        @{ Name = "MaxCommandOutputBytes"; Minimum = 1024; Maximum = 1048576 },
        @{ Name = "PollIntervalSeconds"; Minimum = 1; Maximum = 60 },
        @{ Name = "WatchdogCheckSeconds"; Minimum = 1; Maximum = 300 },
        @{ Name = "WatchdogStaleSeconds"; Minimum = 10; Maximum = 3600 },
        @{ Name = "MaxLogBytes"; Minimum = 65536; Maximum = 104857600 },
        @{ Name = "MaxCacheFiles"; Minimum = 0; Maximum = 10000 },
        @{ Name = "MaxCacheBytes"; Minimum = 8388608; Maximum = 1073741824 },
        @{ Name = "MaxImageBytes"; Minimum = 1048576; Maximum = 268435456 }
    )) {
        $converted = ConvertTo-ImgPasteStrictInteger -Value $Config[$rule.Name]
        if (-not $converted.IsValid) { return "$($rule.Name) must be a whole number." }
        $numeric[$rule.Name] = $converted.Value
        if ($converted.Value -lt $rule.Minimum -or $converted.Value -gt $rule.Maximum) {
            return "$($rule.Name) must be between $($rule.Minimum) and $($rule.Maximum)."
        }
    }

    # A single upload can run mkdir, scp, and the latest-link SSH command in
    # sequence.  Reject watchdog settings that would kill a healthy watcher
    # before all three hard command timeouts have had a chance to finish.
    $minimumStaleSeconds = ([int64]$numeric.CommandTimeoutSeconds * 3) + [int64]$numeric.WatchdogCheckSeconds
    if ([int64]$numeric.WatchdogStaleSeconds -lt $minimumStaleSeconds) {
        return "WatchdogStaleSeconds must be at least $minimumStaleSeconds to cover three command timeouts and one watchdog check."
    }
    if ([int64]$numeric.MaxImageBytes -gt [int64]$numeric.MaxCacheBytes) {
        return "MaxImageBytes cannot exceed MaxCacheBytes."
    }
    return ""
}

function Get-ImgPasteConfig {
    $cfg = New-ImgPasteDefaultConfig
    $allowed = @("HostAlias", "RemoteDir", "RemoteHome", "DataRoot", "CommandTimeoutSeconds", "MaxCommandOutputBytes", "PollIntervalSeconds", "WatchdogCheckSeconds", "WatchdogStaleSeconds", "MaxLogBytes", "MaxCacheFiles", "MaxCacheBytes", "MaxImageBytes")
    if (Test-Path -LiteralPath $script:ImgPasteConfigPath) {
        try {
            $loaded = Import-PowerShellDataFile -LiteralPath $script:ImgPasteConfigPath
            foreach ($key in $allowed) {
                if ($loaded.ContainsKey($key) -and $null -ne $loaded[$key]) { $cfg[$key] = $loaded[$key] }
            }
        }
        catch {
            $cfg.ConfigError = "Cannot read configuration '$script:ImgPasteConfigPath': $($_.Exception.Message)"
            return $cfg
        }
    }
    else {
        $cfg.ConfigError = "Configuration not found at '$script:ImgPasteConfigPath'. Copy imgpaste.config.example.psd1 there and set HostAlias."
        return $cfg
    }

    # Environment variables make automation and CI configuration possible without
    # storing a host name in the checkout. They intentionally override the file.
    if ($env:IMGPASTE_HOST_ALIAS) { $cfg.HostAlias = $env:IMGPASTE_HOST_ALIAS }
    if ($env:IMGPASTE_REMOTE_DIR) { $cfg.RemoteDir = $env:IMGPASTE_REMOTE_DIR }
    if ($env:IMGPASTE_REMOTE_HOME) { $cfg.RemoteHome = $env:IMGPASTE_REMOTE_HOME }

    $cfg.ConfigError = Test-ImgPasteConfigValue -Config $cfg
    if ($cfg.ConfigError) { return $cfg }
    foreach ($name in @("CommandTimeoutSeconds", "MaxCommandOutputBytes", "PollIntervalSeconds", "WatchdogCheckSeconds", "WatchdogStaleSeconds", "MaxLogBytes", "MaxCacheFiles", "MaxCacheBytes", "MaxImageBytes")) {
        $cfg[$name] = (ConvertTo-ImgPasteStrictInteger -Value $cfg[$name]).Value
    }
    $cfg.LocalCache = Join-Path $cfg.DataRoot "cache"
    $cfg.StateFile = Join-Path $cfg.DataRoot "last-hash.txt"
    $cfg.LastRemotePathFile = Join-Path $cfg.DataRoot "last-remote-path.txt"
    $cfg.LogFile = Join-Path $cfg.DataRoot "watch.log"
    $cfg.HeartbeatFile = Join-Path $cfg.DataRoot "watch.heartbeat"
    return $cfg
}

$script:ImgPasteConfig = Get-ImgPasteConfig

if (-not ("ImgPasteBoundedOutput" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

public sealed class ImgPasteBoundedOutput {
    private readonly int limit;
    private readonly StringBuilder text = new StringBuilder();
    private bool truncated;
    public ImgPasteBoundedOutput(int limit) { this.limit = limit; }
    public async Task PumpAsync(StreamReader reader) {
        char[] buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer, 0, buffer.Length)) > 0) {
            lock (text) {
                int remaining = limit - text.Length;
                if (remaining > 0) { text.Append(buffer, 0, Math.Min(remaining, count)); }
                if (count > remaining) { truncated = true; }
            }
        }
    }
    public string Text { get { lock (text) { return text.ToString(); } } }
    public bool Truncated { get { lock (text) { return truncated; } } }
}
'@
}

function Write-ImgPasteLog {
    param([string]$Message)
    $safeMessage = (Protect-ImgPasteLogDetail $Message) -replace '[\r\n]+', ' | '
    $outputLimit = ConvertTo-ImgPasteStrictInteger -Value $script:ImgPasteConfig.MaxCommandOutputBytes
    $maxDetailChars = if ($outputLimit.IsValid) { [Math]::Min(65536, [Math]::Max(1024, $outputLimit.Value)) } else { 65536 }
    if ($safeMessage.Length -gt $maxDetailChars) {
        $safeMessage = $safeMessage.Substring(0, $maxDetailChars) + " [message truncated]"
    }
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $safeMessage
    $dir = Split-Path $script:ImgPasteConfig.LogFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Rotate-ImgPasteLog
    Add-Content -LiteralPath $script:ImgPasteConfig.LogFile -Value $line -ErrorAction SilentlyContinue
}

function Rotate-ImgPasteLog {
    $cfg = $script:ImgPasteConfig
    $path = $cfg.LogFile
    try {
        if (-not (Test-Path $path) -or (Get-Item -LiteralPath $path).Length -lt [int64]$cfg.MaxLogBytes) { return }
        if (Test-Path "$path.3") { Remove-Item -LiteralPath "$path.3" -Force }
        for ($index = 2; $index -ge 1; $index--) {
            $from = "$path.$index"
            if (Test-Path $from) { Move-Item -LiteralPath $from -Destination "$path.$($index + 1)" -Force }
        }
        Move-Item -LiteralPath $path -Destination "$path.1" -Force
    }
    catch { }
}

function Set-ImgPasteAtomicText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Value)
    $directory = Split-Path $Path
    if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($temporary, $Value, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path $Path) {
            try { [IO.File]::Replace($temporary, $Path, $null, $true) }
            catch { Move-Item -LiteralPath $temporary -Destination $Path -Force }
        }
        else { Move-Item -LiteralPath $temporary -Destination $Path }
    }
    finally {
        if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Prune-ImgPasteCache {
    param([string[]]$KeepPath = @())

    $cfg = $script:ImgPasteConfig
    if (-not (Test-Path $cfg.LocalCache)) { return }
    try {
        $keep = @{}
        foreach ($path in $KeepPath) {
            if ($path) {
                try { $keep[[IO.Path]::GetFullPath($path)] = $true } catch { }
            }
        }
        $files = @(Get-ChildItem -LiteralPath $cfg.LocalCache -Filter "clip-*.png" -File | Sort-Object -Property @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $true })
        $protected = @($files | Where-Object { $keep.ContainsKey($_.FullName) })
        $removable = @($files | Where-Object { -not $keep.ContainsKey($_.FullName) })
        [int64]$retainedBytes = @($protected | Measure-Object -Property Length -Sum).Sum
        [int]$retainedCount = $protected.Count
        $toRemove = @()
        foreach ($file in $removable) {
            $exceedsFileCount = ([int]$cfg.MaxCacheFiles -gt 0 -and ($retainedCount + 1) -gt [int]$cfg.MaxCacheFiles)
            $exceedsByteCount = ($retainedBytes + [int64]$file.Length) -gt [int64]$cfg.MaxCacheBytes
            if ($exceedsFileCount -or $exceedsByteCount) {
                $toRemove += $file
            }
            else {
                $retainedCount++
                $retainedBytes += [int64]$file.Length
            }
        }
        $toRemove | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

function Update-ImgPasteHeartbeat {
    param([string]$Status = "running")
    $cfg = $script:ImgPasteConfig
    $dir = Split-Path $cfg.HeartbeatFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    try { Set-ImgPasteAtomicText -Path $cfg.HeartbeatFile -Value ("{0} pid={1} {2}" -f (Get-Date).ToString("o"), $PID, $Status) } catch { }
}

function Get-ImgPasteHeartbeatInfo {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $content = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        if ($content.Length -gt 512) { return $null }
        $match = [regex]::Match($content.Trim(), '^(?<timestamp>\d{4}-\d{2}-\d{2}T[^\s]+)\s+pid=(?<pid>[1-9]\d*)\s+(?<status>checking|idle failures=(?<failures>\d+))$')
        if (-not $match.Success) { return $null }
        [DateTimeOffset]$timestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($match.Groups['timestamp'].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$timestamp)) { return $null }
        [long]$processId = 0
        if (-not [long]::TryParse($match.Groups['pid'].Value, [ref]$processId) -or $processId -gt [int]::MaxValue) { return $null }
        return [pscustomobject]@{ Timestamp = $timestamp; ProcessId = [int]$processId; Status = $match.Groups['status'].Value }
    }
    catch { return $null }
}

function Test-ImgPasteHeartbeat {
    param([Parameter(Mandatory)][string]$Path, [int]$ExpectedProcessId = 0)
    $info = Get-ImgPasteHeartbeatInfo -Path $Path
    return ($null -ne $info -and ($ExpectedProcessId -eq 0 -or $info.ProcessId -eq $ExpectedProcessId))
}

function Protect-ImgPasteLogDetail {
    param([AllowNull()][string]$Detail)
    if ([string]::IsNullOrEmpty($Detail)) { return "" }
    $safe = $Detail -replace '(?i)https?://[^\s?]+\?[^\s]+', '[redacted URL query]'
    $safe = $safe -replace '(?i)(https?://)[^/\s:@]+:[^@\s/]+@', '$1[REDACTED]@'
    $safe = $safe -replace '(?im)^\s*(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\s*:\s*.*$', '$1: [REDACTED]'
    $keyValuePattern = '(?i)(?<![A-Za-z0-9])(["'']?(?:access[\s_-]*token|id[\s_-]*token|refresh[\s_-]*token|token|client[\s_-]*secret|api[\s_-]*key|password|passwd|pwd|private[\s_-]*key|secret)\b["'']?\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;}\]\r\n]+)'
    $safe = [regex]::Replace($safe, $keyValuePattern, '$1[REDACTED]')
    return ($safe -replace '(?i)\bBearer\s+[^\s,;]+', 'Bearer [REDACTED]')
}

function Sanitize-ImgPasteLog {
    $path = $script:ImgPasteConfig.LogFile
    if (-not (Test-Path $path)) { return }
    try {
        $original = Get-Content -Raw -LiteralPath $path -ErrorAction Stop
        $safe = Protect-ImgPasteLogDetail $original
        if ($safe -cne $original) { Set-Content -LiteralPath $path -Value $safe -NoNewline -ErrorAction Stop }
    }
    catch { }
}

function Get-ImgPasteRetryDelay {
    param([int]$FailureCount, [int]$IntervalSeconds = $script:ImgPasteConfig.PollIntervalSeconds)
    if ($FailureCount -le 0) { return $IntervalSeconds }
    return [Math]::Min(60, $IntervalSeconds * [Math]::Pow(2, [Math]::Min($FailureCount, 5)))
}

function Get-ImgPasteMutexName {
    param([Parameter(Mandatory)][string]$Purpose)
    try { $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $identity = "$env:USERDOMAIN-$env:USERNAME" }
    $safeIdentity = ($identity -replace '[^A-Za-z0-9._-]', '_')
    return "Local\ImgPaste-$Purpose-$safeIdentity"
}

function Test-ImgPasteProcessCommandLineForScript {
    param(
        [AllowNull()][string]$CommandLine,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    try { $fullPath = [IO.Path]::GetFullPath($ScriptPath) }
    catch { return $false }

    # The guardian must not act on another checkout merely because the command
    # line mentions the same filename.  Match a complete -File argument only.
    $escapedPath = [regex]::Escape($fullPath)
    $argumentPattern = '(?:"{0}"|{0})' -f $escapedPath
    $pattern = '(?i)(?:^|\s)-File(?:\s+|:)' + $argumentPattern + '(?=\s|$)'
    return [regex]::IsMatch($CommandLine, $pattern)
}

function ConvertTo-ImgPasteNormalizedText {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return (($Value -replace "`r`n", "`n").TrimEnd([char[]]"`r`n"))
}

function Test-ImgPasteCommandWrapperOwnership {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedContent,
        [string]$LegacyContent = ""
    )

    # A user-level command filename is shared across checkouts. Match the
    # whole bounded wrapper, including its managed marker/current script path,
    # before replacing or removing it. A precisely matching pre-marker wrapper
    # is accepted once so an existing installation can migrate safely.
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $item.Length -gt 16384) { return $false }
        $actual = ConvertTo-ImgPasteNormalizedText (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        $expected = ConvertTo-ImgPasteNormalizedText $ExpectedContent
        if ($actual -ceq $expected) { return $true }
        if ($LegacyContent) {
            return ($actual -ceq (ConvertTo-ImgPasteNormalizedText $LegacyContent))
        }
        return $false
    }
    catch { return $false }
}

function Test-ImgPasteShortcutOwnership {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Description,
        [string]$LegacyDescriptionPattern = ""
    )

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
        $descriptionMatches = ([string]$shortcut.Description -ceq $Description) -or
            ($LegacyDescriptionPattern -and ([string]$shortcut.Description -like $LegacyDescriptionPattern))
        return ($actualTarget -ieq $expectedTarget -and
            (Test-ImgPasteProcessCommandLineForScript -CommandLine ([string]$shortcut.Arguments) -ScriptPath $ScriptPath) -and
            $actualDirectory -eq $expectedDirectory -and $descriptionMatches)
    }
    catch { return $false }
}

function Get-ImgPasteRemotePath {
    param([Parameter(Mandatory)][string]$LeafName)
    $cfg = $script:ImgPasteConfig
    $relativePath = "$($cfg.RemoteDir.Trim('/'))/$LeafName"
    if ($cfg.RemoteHome) { return "$($cfg.RemoteHome.TrimEnd('/'))/$relativePath" }
    return "~/$relativePath"
}

function Test-ImgPasteRemotePath {
    param([AllowNull()][string]$Path)
    return ($Path -and $Path.Length -lt 4096 -and $Path -match '^(~|/)[A-Za-z0-9._/-]+$')
}

function Get-ImgPasteLastRemotePath {
    $cfg = $script:ImgPasteConfig
    if (Test-Path $cfg.LastRemotePathFile) {
        try {
            $path = (Get-Content -Raw -LiteralPath $cfg.LastRemotePathFile -ErrorAction Stop).Trim()
            if (Test-ImgPasteRemotePath $path) { return $path }
        }
        catch { }
    }
    return Get-ImgPasteRemotePath -LeafName "latest.png"
}

function ConvertTo-ImgPasteCommandArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Stop-ImgPasteProcessTree {
    param([int]$ProcessId)
    # SSH ProxyCommand processes are children of ssh; kill the whole tree.
    try { & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null } catch {}
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}

function Invoke-ImgPasteProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = $script:ImgPasteConfig.CommandTimeoutSeconds,
        [string]$Label = $FilePath
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-ImgPasteCommandArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw "Process did not start" }
        $limit = [int]$script:ImgPasteConfig.MaxCommandOutputBytes
        $stdoutSink = New-Object -TypeName ImgPasteBoundedOutput -ArgumentList ([Math]::Max(1024, $limit))
        $stderrSink = New-Object -TypeName ImgPasteBoundedOutput -ArgumentList ([Math]::Max(1024, $limit))
        $stdoutTask = $stdoutSink.PumpAsync($process.StandardOutput)
        $stderrTask = $stderrSink.PumpAsync($process.StandardError)
        $exited = $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
        if (-not $exited) {
            Stop-ImgPasteProcessTree -ProcessId $process.Id
            $process.WaitForExit(5000) | Out-Null
            $stdoutTask.Wait(2000) | Out-Null
            $stderrTask.Wait(2000) | Out-Null
            Write-ImgPasteLog "command timed out after ${TimeoutSeconds}s ($Label), pid=$($process.Id); killed process tree"
            return @{ Ok = $false; TimedOut = $true; ExitCode = $null; StdOut = $stdoutSink.Text; StdErr = $stderrSink.Text; OutputTruncated = ($stdoutSink.Truncated -or $stderrSink.Truncated); Detail = "Timed out after ${TimeoutSeconds}s; killed process tree." }
        }

        $process.WaitForExit()
        $stdoutTask.Wait(2000) | Out-Null
        $stderrTask.Wait(2000) | Out-Null
        $truncated = $stdoutSink.Truncated -or $stderrSink.Truncated
        $detail = (($stdoutSink.Text, $stderrSink.Text | Where-Object { $_ }) -join [Environment]::NewLine).Trim()
        if ($truncated) { $detail = "$detail`n[output truncated]" }
        return @{ Ok = ($process.ExitCode -eq 0); TimedOut = $false; ExitCode = $process.ExitCode; StdOut = $stdoutSink.Text; StdErr = $stderrSink.Text; OutputTruncated = $truncated; Detail = $detail }
    }
    catch {
        return @{ Ok = $false; TimedOut = $false; ExitCode = $null; StdOut = ""; StdErr = ""; OutputTruncated = $false; Detail = "Could not start ${Label}: $_" }
    }
    finally { if ($process) { $process.Dispose() } }
}

function Get-ClipboardImageBytes {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $img = [System.Windows.Forms.Clipboard]::GetImage()
    if ($null -eq $img) { return $null }
    $ms = New-Object System.IO.MemoryStream
    try { $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); return $ms.ToArray() }
    finally { $ms.Dispose(); $img.Dispose() }
}

function Get-BytesHash {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-ImgPasteClipboardHash {
    param([Parameter(Mandatory)][string]$ExpectedHash)

    # Checking again immediately before committing latest state keeps an upload
    # that was delayed by SSH from replacing a newer clipboard image (or text).
    try {
        $current = Get-ClipboardImageBytes
        if ($null -eq $current -or $current.Length -eq 0) { return $false }
        return ((Get-BytesHash -Bytes $current) -eq $ExpectedHash)
    }
    catch { return $false }
}

function Publish-ClipboardImage {
    param([switch]$CopyPath, [switch]$Force)

    # A hotkey and the watcher can fire together. Serialize the whole upload so
    # they never race over local state or publish conflicting latest links.
    $mutex = New-Object System.Threading.Mutex($false, (Get-ImgPasteMutexName -Purpose "Upload"))
    if (-not $mutex.WaitOne(0, $false)) { return @{ Ok = $false; Reason = "upload-in-progress"; Detail = "Another imgpaste upload is active." } }
    try { return Invoke-ImgPasteClipboardUpload -CopyPath:$CopyPath -Force:$Force }
    finally { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() }
}

function Invoke-ImgPasteClipboardUpload {
    param([switch]$CopyPath, [switch]$Force)

    $cfg = $script:ImgPasteConfig
    if ($cfg.ConfigError) { return @{ Ok = $false; Reason = "configuration-invalid"; Detail = $cfg.ConfigError } }
    if (-not (Test-Path $cfg.LocalCache)) { New-Item -ItemType Directory -Force -Path $cfg.LocalCache | Out-Null }
    $bytes = Get-ClipboardImageBytes
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return @{ Ok = $false; Reason = "no-image" } }
    if ([int64]$bytes.Length -gt [int64]$cfg.MaxImageBytes) {
        $detail = "Clipboard image is $($bytes.Length) bytes; MaxImageBytes is $($cfg.MaxImageBytes)."
        Write-ImgPasteLog "upload rejected: $detail"
        return @{ Ok = $false; Reason = "image-too-large"; Detail = $detail }
    }

    $hash = Get-BytesHash -Bytes $bytes
    $last = if (Test-Path $cfg.StateFile) { (Get-Content -Raw -LiteralPath $cfg.StateFile).Trim() } else { "" }
    if (-not $Force -and $hash -eq $last -and (Test-Path (Join-Path $cfg.LocalCache "latest.png"))) {
        $remotePath = Get-ImgPasteLastRemotePath
        if ($CopyPath) { Set-Clipboard -Value $remotePath }
        return @{ Ok = $true; Reason = "unchanged"; RemotePath = $remotePath; Hash = $hash }
    }

    # Content-addressing makes an interrupted retry reuse its cache entry
    # instead of producing one timestamped PNG per failed poll.
    $localFile = Join-Path $cfg.LocalCache "clip-$hash.png"
    $latestLocal = Join-Path $cfg.LocalCache "latest.png"
    Prune-ImgPasteCache -KeepPath $localFile
    [System.IO.File]::WriteAllBytes($localFile, $bytes)
    Prune-ImgPasteCache -KeepPath $localFile

    $hostAlias = $cfg.HostAlias
    $remoteDir = $cfg.RemoteDir.Trim('/')
    $base = [IO.Path]::GetFileName($localFile)
    $sshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2")

    $mkdir = Invoke-ImgPasteProcess -FilePath "ssh" -Arguments ($sshOpts + @($hostAlias, "mkdir -p `$HOME/$remoteDir")) -Label "ssh mkdir"
    if (-not $mkdir.Ok) {
        $detail = Protect-ImgPasteLogDetail $mkdir.Detail
        Write-ImgPasteLog "mkdir failed$($(if ($mkdir.TimedOut) { ' (timeout)' } else { '' })): $detail"
        Prune-ImgPasteCache -KeepPath $localFile
        return @{ Ok = $false; Reason = if ($mkdir.TimedOut) { "ssh-mkdir-timeout" } else { "ssh-mkdir-failed" }; Detail = $detail }
    }

    $scp = Invoke-ImgPasteProcess -FilePath "scp" -Arguments ($sshOpts + @($localFile, "${hostAlias}:$remoteDir/$base")) -Label "scp upload"
    if (-not $scp.Ok) {
        $detail = Protect-ImgPasteLogDetail $scp.Detail
        Write-ImgPasteLog "scp failed$($(if ($scp.TimedOut) { ' (timeout)' } else { '' })): $detail"
        Prune-ImgPasteCache -KeepPath $localFile
        return @{ Ok = $false; Reason = if ($scp.TimedOut) { "scp-timeout" } else { "scp-failed" }; Detail = $detail }
    }

    if (-not (Test-ImgPasteClipboardHash -ExpectedHash $hash)) {
        $detail = "Clipboard changed before the upload could update latest.png; leaving retry state unchanged."
        Write-ImgPasteLog "upload superseded: $detail"
        Prune-ImgPasteCache -KeepPath $localFile
        return @{ Ok = $false; Reason = "clipboard-changed"; Detail = $detail; Hash = $hash }
    }

    $remoteCmd = "ln -sfn $base `$HOME/$remoteDir/latest.png; readlink -f `$HOME/$remoteDir/$base 2>/dev/null || printf '%s\n' `$HOME/$remoteDir/$base"
    $remote = Invoke-ImgPasteProcess -FilePath "ssh" -Arguments ($sshOpts + @($hostAlias, $remoteCmd)) -Label "ssh update latest"
    if (-not $remote.Ok) {
        $detail = Protect-ImgPasteLogDetail $remote.Detail
        Write-ImgPasteLog "latest-link update failed$($(if ($remote.TimedOut) { ' (timeout)' } else { '' })): $detail"
        Prune-ImgPasteCache -KeepPath $localFile
        return @{ Ok = $false; Reason = if ($remote.TimedOut) { "ssh-latest-timeout" } else { "ssh-latest-failed" }; Detail = $detail; Hash = $hash }
    }
    $remotePath = ($remote.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($remotePath) { $remotePath = $remotePath.Trim() }
    if (-not (Test-ImgPasteRemotePath $remotePath)) {
        if ($remotePath) { Write-ImgPasteLog "remote path response was invalid; using configured fallback" }
        $remotePath = Get-ImgPasteRemotePath -LeafName $base
    }

    if (-not (Test-ImgPasteClipboardHash -ExpectedHash $hash)) {
        $detail = "Clipboard changed while the latest link was being updated; leaving retry state unchanged."
        Write-ImgPasteLog "upload superseded: $detail"
        Prune-ImgPasteCache -KeepPath $localFile
        return @{ Ok = $false; Reason = "clipboard-changed"; Detail = $detail; Hash = $hash }
    }

    Copy-Item -Force $localFile $latestLocal
    Set-ImgPasteAtomicText -Path $cfg.StateFile -Value $hash
    Set-ImgPasteAtomicText -Path $cfg.LastRemotePathFile -Value $remotePath
    Prune-ImgPasteCache -KeepPath $localFile
    Write-ImgPasteLog "uploaded $base -> $remotePath ($($bytes.Length) bytes)"
    if ($CopyPath) { Set-Clipboard -Value $remotePath; Write-ImgPasteLog "clipboard set to path text: $remotePath" }
    return @{ Ok = $true; Reason = "uploaded"; RemotePath = $remotePath; LocalFile = $localFile; Hash = $hash; Bytes = $bytes.Length }
}
