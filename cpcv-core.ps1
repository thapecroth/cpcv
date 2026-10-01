# Shared helpers for cpcv. Configuration is local-only; see
# cpcv.config.example.psd1 and README.md.

# A Windows PowerShell child launched by PowerShell 7 can inherit the newer
# host's module search path. Load the native configuration reader explicitly.
if ($PSVersionTable.PSVersion.Major -le 5 -and $env:OS -eq "Windows_NT") {
    Import-Module (Join-Path $PSHOME "Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1") -ErrorAction Stop
}

$script:CpcvRoot = $PSScriptRoot
$script:CpcvLocalAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
$script:CpcvDefaultConfigPath = Join-Path $script:CpcvLocalAppData "cpcv\config.psd1"
$script:CpcvConfigPath = if ($env:CPCV_CONFIG) {
    $env:CPCV_CONFIG
}
else {
    $script:CpcvDefaultConfigPath
}
$script:CpcvPersistedConfigFields = @(
    "HostAlias", "RemoteDir", "RemoteHome", "DataRoot", "CommandTimeoutSeconds",
    "MaxCommandOutputBytes", "PollIntervalSeconds", "WatchdogCheckSeconds",
    "WatchdogStaleSeconds", "MaxLogBytes", "MaxCacheFiles", "MaxCacheBytes",
    "MaxImageBytes"
)
$script:CpcvNumericConfigFields = @(
    "CommandTimeoutSeconds", "MaxCommandOutputBytes", "PollIntervalSeconds",
    "WatchdogCheckSeconds", "WatchdogStaleSeconds", "MaxLogBytes", "MaxCacheFiles",
    "MaxCacheBytes", "MaxImageBytes"
)

function Get-CpcvConfigPath { return $script:CpcvConfigPath }

function New-CpcvDefaultConfig {
    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
    $dataRoot = Join-Path $localAppData "cpcv"
    return [ordered]@{
        HostAlias             = ""
        RemoteDir             = "clipboard-images"
        RemoteHome            = ""
        DataRoot              = $dataRoot
        LocalCache            = (Join-Path $dataRoot "cache")
        StateFile             = (Join-Path $dataRoot "last-hash.txt")
        LastRemotePathFile    = (Join-Path $dataRoot "last-remote-path.txt")
        UploadStatusFile      = (Join-Path $dataRoot "upload-status.txt")
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

function ConvertTo-CpcvStrictInteger {
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

function Test-CpcvConfigValue {
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
        $converted = ConvertTo-CpcvStrictInteger -Value $Config[$rule.Name]
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

function Get-CpcvConfigStoragePathInfo {
    <#
    .SYNOPSIS
    Resolves the private configuration location without following reparse
    points.  Configuration is read at logon, so it must not be possible to
    redirect it through a symlink or junction to an unexpected location.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "The cpcv configuration path is empty."
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "The cpcv configuration path is not a valid Windows path."
    }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directory) -or [string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($fullPath))) {
        throw "The cpcv configuration path must name a file."
    }

    # Check every existing ancestor instead of merely the immediate parent:
    # a junction higher in the tree would otherwise redirect a later create.
    $currentDirectory = $directory
    while ($currentDirectory) {
        $directoryExists = $false
        try {
            $directoryAttributes = [IO.File]::GetAttributes($currentDirectory)
            $directoryExists = $true
        }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        if ($directoryExists) {
            # GetAttributes sees a dangling link too, unlike Test-Path.
            if (($directoryAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to use a reparse-point configuration directory."
            }
            $directoryItem = Get-Item -LiteralPath $currentDirectory -Force -ErrorAction Stop
            if (-not $directoryItem.PSIsContainer) {
                throw "The cpcv configuration parent is not a directory."
            }
        }
        $parent = [IO.Directory]::GetParent($currentDirectory)
        if ($null -eq $parent -or $parent.FullName -ieq $currentDirectory) { break }
        $currentDirectory = $parent.FullName
    }

    $exists = $false
    try {
        $fileAttributes = [IO.File]::GetAttributes($fullPath)
        $exists = $true
    }
    catch [IO.FileNotFoundException] { }
    catch [IO.DirectoryNotFoundException] { }
    if ($exists) {
        if (($fileAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use a reparse-point configuration file."
        }
        $fileItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if ($fileItem.PSIsContainer) {
            throw "The cpcv configuration path names a directory."
        }
    }

    return [pscustomobject]@{
        FullPath = $fullPath
        Directory = $directory
        Exists = [bool]$exists
    }
}

function Initialize-CpcvConfigStorageDirectory {
    param([Parameter(Mandatory)]$PathInfo)

    # Validate the existing tree before creating anything, then validate every
    # new component. This keeps the default first-run path safe as well as a
    # caller-supplied CPCV_CONFIG location.
    [void](Get-CpcvConfigStoragePathInfo -Path $PathInfo.FullPath)
    $toCreate = [System.Collections.Generic.List[string]]::new()
    $currentDirectory = $PathInfo.Directory
    while (-not (Test-Path -LiteralPath $currentDirectory)) {
        [void]$toCreate.Add($currentDirectory)
        $parent = [IO.Directory]::GetParent($currentDirectory)
        if ($null -eq $parent -or $parent.FullName -ieq $currentDirectory) {
            throw "Cannot create the cpcv configuration directory."
        }
        $currentDirectory = $parent.FullName
    }
    for ($index = $toCreate.Count - 1; $index -ge 0; $index--) {
        [void][IO.Directory]::CreateDirectory($toCreate[$index])
        $created = Get-Item -LiteralPath $toCreate[$index] -Force -ErrorAction Stop
        if (-not $created.PSIsContainer -or (($created.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing to create configuration in a reparse-point directory."
        }
    }
    return (Get-CpcvConfigStoragePathInfo -Path $PathInfo.FullPath)
}

function Get-CpcvPersistedConfigValues {
    $defaults = New-CpcvDefaultConfig
    $values = [ordered]@{}
    foreach ($key in $script:CpcvPersistedConfigFields) {
        $values[$key] = $defaults[$key]
    }

    $pathInfo = $null
    try {
        $pathInfo = Get-CpcvConfigStoragePathInfo -Path $script:CpcvConfigPath
    }
    catch {
        return [pscustomobject]@{
            Values = $values
            Path = $script:CpcvConfigPath
            Exists = $false
            LoadError = "Cannot read cpcv configuration: $($_.Exception.Message)"
        }
    }
    if (-not $pathInfo.Exists) {
        return [pscustomobject]@{
            Values = $values
            Path = $pathInfo.FullPath
            Exists = $false
            LoadError = ""
        }
    }

    try {
        # Import-PowerShellDataFile accepts only the constrained data-file
        # language. Do not dot-source a user configuration file.
        $pathInfo = Get-CpcvConfigStoragePathInfo -Path $pathInfo.FullPath
        $loaded = Import-PowerShellDataFile -LiteralPath $pathInfo.FullPath -ErrorAction Stop
        if ($loaded -isnot [System.Collections.IDictionary]) {
            throw "The configuration must contain a PowerShell data hashtable."
        }
        foreach ($key in $script:CpcvPersistedConfigFields) {
            if ($loaded.Contains($key) -and $null -ne $loaded[$key]) {
                $values[$key] = $loaded[$key]
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Values = $values
            Path = $pathInfo.FullPath
            Exists = $true
            LoadError = "Cannot read configuration '$($pathInfo.FullPath)': $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        Values = $values
        Path = $pathInfo.FullPath
        Exists = $true
        LoadError = ""
    }
}

function Get-CpcvConfig {
    $cfg = New-CpcvDefaultConfig
    $persisted = Get-CpcvPersistedConfigValues
    if ($persisted.LoadError) {
        $cfg.ConfigError = $persisted.LoadError
        return $cfg
    }
    if (-not $persisted.Exists) {
        $cfg.ConfigError = "Configuration not found at '$script:CpcvConfigPath'. Copy cpcv.config.example.psd1 there and set HostAlias."
        return $cfg
    }
    foreach ($key in $script:CpcvPersistedConfigFields) {
        $cfg[$key] = $persisted.Values[$key]
    }

    # Environment variables make automation and CI configuration possible without
    # storing a host name in the checkout. They intentionally override the file.
    if ($env:CPCV_HOST_ALIAS) { $cfg.HostAlias = $env:CPCV_HOST_ALIAS }
    if ($env:CPCV_REMOTE_DIR) { $cfg.RemoteDir = $env:CPCV_REMOTE_DIR }
    if ($env:CPCV_REMOTE_HOME) { $cfg.RemoteHome = $env:CPCV_REMOTE_HOME }

    $cfg.ConfigError = Test-CpcvConfigValue -Config $cfg
    if ($cfg.ConfigError) { return $cfg }
    foreach ($name in $script:CpcvNumericConfigFields) {
        $cfg[$name] = (ConvertTo-CpcvStrictInteger -Value $cfg[$name]).Value
    }
    $cfg.LocalCache = Join-Path $cfg.DataRoot "cache"
    $cfg.StateFile = Join-Path $cfg.DataRoot "last-hash.txt"
    $cfg.LastRemotePathFile = Join-Path $cfg.DataRoot "last-remote-path.txt"
    $cfg.UploadStatusFile = Join-Path $cfg.DataRoot "upload-status.txt"
    $cfg.LogFile = Join-Path $cfg.DataRoot "watch.log"
    $cfg.HeartbeatFile = Join-Path $cfg.DataRoot "watch.heartbeat"
    return $cfg
}

function ConvertTo-CpcvDataFileString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    # Single-quoted PowerShell strings are data-only when embedded quotes are
    # doubled. Values are independently validated before this is called; this
    # encoding is an additional boundary that prevents a configuration value
    # from breaking out into executable PowerShell syntax.
    return ("'" + $Value.Replace("'", "''") + "'")
}

function ConvertTo-CpcvConfigDataFile {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("@{")
    foreach ($key in $script:CpcvPersistedConfigFields) {
        if ($script:CpcvNumericConfigFields -contains $key) {
            $value = ([int]$Config[$key]).ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            $value = ConvertTo-CpcvDataFileString -Value ([string]$Config[$key])
        }
        [void]$lines.Add("    $key = $value")
    }
    [void]$lines.Add("}")
    return (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Write-CpcvConfigDataFileAtomically {
    param(
        [Parameter(Mandatory)]$PathInfo,
        [Parameter(Mandatory)][string]$Content
    )

    $pathInfo = Initialize-CpcvConfigStorageDirectory -PathInfo $PathInfo
    $temporary = Join-Path $pathInfo.Directory (".{0}.{1}.tmp" -f [IO.Path]::GetFileName($pathInfo.FullPath), [Guid]::NewGuid().ToString("N"))
    $backup = Join-Path $pathInfo.Directory (".{0}.{1}.bak" -f [IO.Path]::GetFileName($pathInfo.FullPath), [Guid]::NewGuid().ToString("N"))
    $committed = $false
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        # Re-check the final path after writing the temporary file. The write
        # never falls back to a delete-and-move sequence, which would lose
        # atomicity and make it easier to replace an unexpected target.
        $pathInfo = Get-CpcvConfigStoragePathInfo -Path $pathInfo.FullPath
        if ($pathInfo.Exists) {
            # File.Replace requires a concrete backup path on supported
            # Windows/.NET combinations. It remains in the same verified
            # directory and is removed only after a successful replacement.
            [IO.File]::Replace($temporary, $pathInfo.FullPath, $backup, $true)
        }
        else {
            [IO.File]::Move($temporary, $pathInfo.FullPath)
        }
        $committed = $true
    }
    finally {
        if (-not $committed -and [IO.File]::Exists($temporary)) {
            try { [IO.File]::Delete($temporary) } catch { }
        }
        if ($committed -and [IO.File]::Exists($backup)) {
            try { [IO.File]::Delete($backup) } catch { }
        }
    }
}

function Get-CpcvEditableConfig {
    <#
    .SYNOPSIS
    Returns the persisted, editable cpcv fields plus Settings UI metadata.

    .DESCRIPTION
    Environment overrides are deliberately reported but never folded into the
    returned values: saving Settings must change the file, not accidentally
    persist a transient CPCV_* override.
    #>
    $persisted = Get-CpcvPersistedConfigValues
    $result = [ordered]@{}
    foreach ($key in $script:CpcvPersistedConfigFields) {
        $result[$key] = $persisted.Values[$key]
    }

    $overrides = [System.Collections.Generic.List[string]]::new()
    # CPCV_CONFIG selects the backing file rather than overriding a field, but
    # it is still important to surface it: Settings must explain why the file
    # location differs from the normal per-user default.
    if ($env:CPCV_CONFIG) { [void]$overrides.Add("CPCV_CONFIG") }
    if ($env:CPCV_HOST_ALIAS) { [void]$overrides.Add("CPCV_HOST_ALIAS") }
    if ($env:CPCV_REMOTE_DIR) { [void]$overrides.Add("CPCV_REMOTE_DIR") }
    if ($env:CPCV_REMOTE_HOME) { [void]$overrides.Add("CPCV_REMOTE_HOME") }

    $loadError = [string]$persisted.LoadError
    if (-not $loadError -and $persisted.Exists) {
        # Surface invalid stored values to Settings without replacing them on
        # load. This preserves the user's other known fields so the form can
        # repair only the value that needs attention.
        $validationError = Test-CpcvConfigValue -Config $persisted.Values
        if ($validationError) { $loadError = $validationError }
    }
    $result["Path"] = $persisted.Path
    $result["Exists"] = [bool]$persisted.Exists
    $result["HasEnvironmentOverrides"] = ($overrides.Count -gt 0)
    $result["ConfigPathIsEnvironmentOverride"] = [bool]$env:CPCV_CONFIG
    $result["EnvironmentOverrides"] = @($overrides)
    $result["LoadError"] = $loadError
    return $result
}

function Save-CpcvConfig {
    <#
    .SYNOPSIS
    Validates and atomically saves editable cpcv configuration values.

    .DESCRIPTION
    The input may contain a subset of the known persisted fields. Missing
    values are retained from a safe existing file or supplied from current
    defaults. Derived local paths and ConfigError are never persisted.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $pathInfo = Get-CpcvConfigStoragePathInfo -Path $script:CpcvConfigPath
    $persisted = Get-CpcvPersistedConfigValues
    $candidate = [ordered]@{}
    foreach ($key in $script:CpcvPersistedConfigFields) {
        $candidate[$key] = $persisted.Values[$key]
    }

    $editableMetadataFields = @("Path", "Exists", "HasEnvironmentOverrides", "ConfigPathIsEnvironmentOverride", "EnvironmentOverrides", "LoadError")
    foreach ($inputKey in $Config.Keys) {
        $key = [string]$inputKey
        # Callers may pass a modified object returned by Get-CpcvEditableConfig
        # directly. Its read-only metadata is intentionally not persisted.
        if ($editableMetadataFields -contains $key) { continue }
        if ($script:CpcvPersistedConfigFields -notcontains $key) {
            throw "'$key' is not an editable cpcv configuration field."
        }
        $candidate[$key] = $Config[$inputKey]
    }

    $validationError = Test-CpcvConfigValue -Config $candidate
    if ($validationError) { throw $validationError }
    foreach ($key in $script:CpcvNumericConfigFields) {
        $candidate[$key] = (ConvertTo-CpcvStrictInteger -Value $candidate[$key]).Value
    }

    $content = ConvertTo-CpcvConfigDataFile -Config $candidate
    Write-CpcvConfigDataFileAtomically -PathInfo $pathInfo -Content $content

    # Keep this already-running process coherent with the saved file. The
    # canonical loader intentionally reapplies environment overrides here.
    $script:CpcvConfig = Get-CpcvConfig
    return (Get-CpcvEditableConfig)
}

$script:CpcvConfig = Get-CpcvConfig

. (Join-Path $PSScriptRoot "cpcv-cloudflare-recovery.ps1")

if (-not ("CpcvBoundedOutput" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

public sealed class CpcvBoundedOutput {
    private readonly int limit;
    private readonly StringBuilder text = new StringBuilder();
    private bool truncated;
    public CpcvBoundedOutput(int limit) { this.limit = limit; }
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

function Write-CpcvLog {
    param([string]$Message)
    $safeMessage = (Protect-CpcvLogDetail $Message) -replace '[\r\n]+', ' | '
    $outputLimit = ConvertTo-CpcvStrictInteger -Value $script:CpcvConfig.MaxCommandOutputBytes
    $maxDetailChars = if ($outputLimit.IsValid) { [Math]::Min(65536, [Math]::Max(1024, $outputLimit.Value)) } else { 65536 }
    if ($safeMessage.Length -gt $maxDetailChars) {
        $safeMessage = $safeMessage.Substring(0, $maxDetailChars) + " [message truncated]"
    }
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $safeMessage
    $dir = Split-Path $script:CpcvConfig.LogFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Rotate-CpcvLog
    Add-Content -LiteralPath $script:CpcvConfig.LogFile -Value $line -ErrorAction SilentlyContinue
}

function Rotate-CpcvLog {
    $cfg = $script:CpcvConfig
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

function Set-CpcvAtomicText {
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

function Prune-CpcvCache {
    param([string[]]$KeepPath = @())

    $cfg = $script:CpcvConfig
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

function Update-CpcvHeartbeat {
    param([string]$Status = "running")
    $cfg = $script:CpcvConfig
    $dir = Split-Path $cfg.HeartbeatFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    try { Set-CpcvAtomicText -Path $cfg.HeartbeatFile -Value ("{0} pid={1} {2}" -f (Get-Date).ToString("o"), $PID, $Status) } catch { }
}

function Get-CpcvHeartbeatInfo {
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
        [int]$failureCount = 0
        if ($match.Groups['failures'].Success -and -not [int]::TryParse($match.Groups['failures'].Value, [ref]$failureCount)) { return $null }
        return [pscustomobject]@{
            Timestamp = $timestamp
            ProcessId = [int]$processId
            Status = $match.Groups['status'].Value
            FailureCount = $failureCount
        }
    }
    catch { return $null }
}

function Get-CpcvUploadStatusFilePath {
    param([Parameter(Mandatory)]$Config)

    try {
        $path = [string]$Config.UploadStatusFile
        if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }
        if (-not [string]::IsNullOrWhiteSpace([string]$Config.DataRoot)) {
            return (Join-Path $Config.DataRoot "upload-status.txt")
        }
    }
    catch { }
    return ""
}

function ConvertTo-CpcvUploadStatusReason {
    param([AllowNull()][string]$Reason)

    # This status file is consumed by the notification-area UI.  It must carry
    # only a small, controlled reason token -- never command output, a host,
    # a path, or an exception message.
    switch ([string]$Reason) {
        "ssh-mkdir-timeout" { return "ssh-mkdir-timeout" }
        "ssh-mkdir-connect-timeout" { return "ssh-mkdir-connect-timeout" }
        "ssh-mkdir-auth-failed" { return "ssh-mkdir-auth-failed" }
        "ssh-mkdir-host-key-failed" { return "ssh-mkdir-host-key-failed" }
        "ssh-mkdir-host-not-found" { return "ssh-mkdir-host-not-found" }
        "ssh-mkdir-proxy-failed" { return "ssh-mkdir-proxy-failed" }
        "ssh-mkdir-remote-folder-failed" { return "ssh-mkdir-remote-folder-failed" }
        "ssh-mkdir-failed" { return "ssh-mkdir-failed" }
        "cloudflare-retry" { return "cloudflare-retry" }
        "cloudflare-sign-in-required" { return "cloudflare-sign-in-required" }
        "scp-timeout" { return "scp-timeout" }
        "scp-failed" { return "scp-failed" }
        "ssh-latest-timeout" { return "ssh-latest-timeout" }
        "ssh-latest-failed" { return "ssh-latest-failed" }
        "image-too-large" { return "image-too-large" }
        "clipboard-busy" { return "clipboard-busy" }
        "configuration-invalid" { return "configuration-invalid" }
        "upload-error" { return "upload-error" }
        default { return "upload-failed" }
    }
}

function Set-CpcvUploadStatus {
    param(
        [Parameter(Mandatory)][ValidateSet("succeeded", "failed")][string]$Result,
        [AllowNull()][string]$Reason = ""
    )

    $cfg = $script:CpcvConfig
    if (-not $cfg -or $cfg.ConfigError) { return }
    $path = Get-CpcvUploadStatusFilePath -Config $cfg
    if ([string]::IsNullOrWhiteSpace($path)) { return }

    try {
        $value = "{0} result={1}" -f (Get-Date).ToUniversalTime().ToString("o"), $Result
        if ($Result -eq "failed") {
            $value += " reason=$(ConvertTo-CpcvUploadStatusReason -Reason $Reason)"
        }
        Set-CpcvAtomicText -Path $path -Value $value
    }
    catch {
        # Upload-status is an observability aid.  A local state-write failure
        # must not hide or replace the real upload result.
    }
}

function Update-CpcvUploadStatusFromResult {
    param([Parameter(Mandatory)]$UploadResult)

    try {
        $ok = [bool]$UploadResult.Ok
        $reason = [string]$UploadResult.Reason
        if ($ok -and $reason -in @("uploaded", "unchanged")) {
            Set-CpcvUploadStatus -Result "succeeded"
        }
        elseif (-not $ok -and $reason -notin @("no-image", "upload-in-progress", "clipboard-changed")) {
            Set-CpcvUploadStatus -Result "failed" -Reason $reason
        }
    }
    catch {
        # Keep the uploader's return contract independent of this optional
        # status surface.
    }
}

function Get-CpcvUploadStatusInfo {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $content = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        if ($content.Length -gt 512) { return $null }
        $match = [regex]::Match($content.Trim(), '^(?<timestamp>\d{4}-\d{2}-\d{2}T[^\s]+)\s+result=(?<result>succeeded|failed)(?: reason=(?<reason>[a-z0-9-]{1,64}))?$')
        if (-not $match.Success) { return $null }
        [DateTimeOffset]$timestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($match.Groups['timestamp'].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$timestamp)) { return $null }
        $result = $match.Groups['result'].Value
        $reason = $match.Groups['reason'].Value
        if (($result -eq "failed" -and [string]::IsNullOrWhiteSpace($reason)) -or ($result -eq "succeeded" -and -not [string]::IsNullOrWhiteSpace($reason))) { return $null }
        return [pscustomobject]@{ Timestamp = $timestamp; Result = $result; Reason = $reason }
    }
    catch { return $null }
}

function Test-CpcvHeartbeat {
    param([Parameter(Mandatory)][string]$Path, [int]$ExpectedProcessId = 0)
    $info = Get-CpcvHeartbeatInfo -Path $Path
    return ($null -ne $info -and ($ExpectedProcessId -eq 0 -or $info.ProcessId -eq $ExpectedProcessId))
}

function Protect-CpcvLogDetail {
    param([AllowNull()][string]$Detail)
    if ([string]::IsNullOrEmpty($Detail)) { return "" }
    $safe = $Detail -replace '(?i)https?://[^\s?]+\?[^\s]+', '[redacted URL query]'
    $safe = $safe -replace '(?i)(https?://)[^/\s:@]+:[^@\s/]+@', '$1[REDACTED]@'
    $safe = $safe -replace '(?im)^\s*(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\s*:\s*.*$', '$1: [REDACTED]'
    $keyValuePattern = '(?i)(?<![A-Za-z0-9])(["'']?(?:access[\s_-]*token|id[\s_-]*token|refresh[\s_-]*token|token|client[\s_-]*secret|api[\s_-]*key|password|passwd|pwd|private[\s_-]*key|secret)\b["'']?\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;}\]\r\n]+)'
    $safe = [regex]::Replace($safe, $keyValuePattern, '$1[REDACTED]')
    return ($safe -replace '(?i)\bBearer\s+[^\s,;]+', 'Bearer [REDACTED]')
}

function Sanitize-CpcvLog {
    $path = $script:CpcvConfig.LogFile
    if (-not (Test-Path $path)) { return }
    try {
        $original = Get-Content -Raw -LiteralPath $path -ErrorAction Stop
        $safe = Protect-CpcvLogDetail $original
        if ($safe -cne $original) { Set-Content -LiteralPath $path -Value $safe -NoNewline -ErrorAction Stop }
    }
    catch { }
}

function Get-CpcvRetryDelay {
    param([int]$FailureCount, [int]$IntervalSeconds = $script:CpcvConfig.PollIntervalSeconds)
    if ($FailureCount -le 0) { return $IntervalSeconds }
    return [Math]::Min(60, $IntervalSeconds * [Math]::Pow(2, [Math]::Min($FailureCount, 5)))
}

function Get-CpcvMutexName {
    param([Parameter(Mandatory)][string]$Purpose)
    try { $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $identity = "$env:USERDOMAIN-$env:USERNAME" }
    $safeIdentity = ($identity -replace '[^A-Za-z0-9._-]', '_')
    return "Local\Cpcv-$Purpose-$safeIdentity"
}

function Test-CpcvProcessCommandLineForScript {
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

function ConvertTo-CpcvNormalizedText {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return (($Value -replace "`r`n", "`n").TrimEnd([char[]]"`r`n"))
}

function Test-CpcvCommandWrapperOwnership {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedContent
    )

    # A user-level command filename is shared across checkouts. Match the
    # whole bounded wrapper, including its managed marker/current script path,
    # before replacing or removing it.
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $item.Length -gt 16384) { return $false }
        $actual = ConvertTo-CpcvNormalizedText (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        $expected = ConvertTo-CpcvNormalizedText $ExpectedContent
        return ($actual -ceq $expected)
    }
    catch { return $false }
}

function Test-CpcvShortcutOwnership {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Description
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
        return ($actualTarget -ieq $expectedTarget -and
            (Test-CpcvProcessCommandLineForScript -CommandLine ([string]$shortcut.Arguments) -ScriptPath $ScriptPath) -and
            $actualDirectory -eq $expectedDirectory -and
            ([string]$shortcut.Description -ceq $Description))
    }
    catch { return $false }
}

function Get-CpcvRemotePath {
    param([Parameter(Mandatory)][string]$LeafName)
    $cfg = $script:CpcvConfig
    $relativePath = "$($cfg.RemoteDir.Trim('/'))/$LeafName"
    if ($cfg.RemoteHome) { return "$($cfg.RemoteHome.TrimEnd('/'))/$relativePath" }
    return "~/$relativePath"
}

function Test-CpcvRemotePath {
    param([AllowNull()][string]$Path)
    return ($Path -and $Path.Length -lt 4096 -and $Path -match '^(~|/)[A-Za-z0-9._/-]+$')
}

function Get-CpcvLastRemotePath {
    $cfg = $script:CpcvConfig
    if (Test-Path $cfg.LastRemotePathFile) {
        try {
            $path = (Get-Content -Raw -LiteralPath $cfg.LastRemotePathFile -ErrorAction Stop).Trim()
            if (Test-CpcvRemotePath $path) { return $path }
        }
        catch { }
    }
    return Get-CpcvRemotePath -LeafName "latest.png"
}

function ConvertTo-CpcvCommandArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Stop-CpcvProcessTree {
    param([int]$ProcessId)
    # SSH ProxyCommand processes are children of ssh; kill the whole tree.
    try { & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null } catch {}
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}

function Invoke-CpcvProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = $script:CpcvConfig.CommandTimeoutSeconds,
        [string]$Label = $FilePath
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-CpcvCommandArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $started = $false
    try {
        if (-not $process.Start()) { throw "Process did not start" }
        $started = $true
        $limit = [int]$script:CpcvConfig.MaxCommandOutputBytes
        $stdoutSink = New-Object -TypeName CpcvBoundedOutput -ArgumentList ([Math]::Max(1024, $limit))
        $stderrSink = New-Object -TypeName CpcvBoundedOutput -ArgumentList ([Math]::Max(1024, $limit))
        $stdoutTask = $stdoutSink.PumpAsync($process.StandardOutput)
        $stderrTask = $stderrSink.PumpAsync($process.StandardError)
        $exited = $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
        if (-not $exited) {
            Stop-CpcvProcessTree -ProcessId $process.Id
            $process.WaitForExit(5000) | Out-Null
            $stdoutTask.Wait(2000) | Out-Null
            $stderrTask.Wait(2000) | Out-Null
            Write-CpcvLog "command timed out after ${TimeoutSeconds}s ($Label), pid=$($process.Id); killed process tree"
            # Keep the useful connection/proxy diagnostic on a timeout without
            # placing private subprocess output in the generic timeout log.
            $detail = "Timed out after ${TimeoutSeconds}s; killed process tree."
            $diagnostic = Protect-CpcvLogDetail (($stderrSink.Text, $stdoutSink.Text | Where-Object { $_ }) -join [Environment]::NewLine)
            if ($diagnostic) { $detail += [Environment]::NewLine + $diagnostic }
            $detailTruncated = $detail.Length -gt $limit
            if ($detailTruncated) { $detail = $detail.Substring(0, $limit) }
            return @{ Ok = $false; TimedOut = $true; ExitCode = $null; StdOut = $stdoutSink.Text; StdErr = $stderrSink.Text; OutputTruncated = ($stdoutSink.Truncated -or $stderrSink.Truncated -or $detailTruncated); Detail = $detail }
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
        $failure = Protect-CpcvLogDetail ([string]$_.Exception.Message)
        # A failure in output capture or waiting can happen after Start succeeds.
        # Do not leave that owned SSH/proxy tree behind while the watcher retries.
        if ($started) {
            try {
                if (-not $process.HasExited) {
                    Stop-CpcvProcessTree -ProcessId $process.Id
                    [void]$process.WaitForExit(5000)
                }
            }
            catch { }
        }
        return @{ Ok = $false; TimedOut = $false; ExitCode = $null; StdOut = ""; StdErr = ""; OutputTruncated = $false; Detail = "Could not $(if ($started) { 'complete' } else { 'start' }) ${Label}: $failure" }
    }
    finally { if ($process) { $process.Dispose() } }
}

function Test-CpcvClipboardBusyException {
    param([AllowNull()][System.Exception]$Exception)

    # PowerShell wraps failures from static .NET calls. Match the specific
    # Windows clipboard-open HRESULT, rather than a localized message or every
    # ExternalException (which can also mean an image conversion failure).
    for ($depth = 0; $null -ne $Exception -and $depth -lt 16; $depth++) {
        if ($Exception -is [System.Runtime.InteropServices.ExternalException] -and $Exception.HResult -eq -2147221040) {
            return $true # CLIPBRD_E_CANT_OPEN (0x800401D0)
        }
        $Exception = $Exception.InnerException
    }
    return $false
}

function Get-CpcvClipboardImageBytesOnce {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $img = [System.Windows.Forms.Clipboard]::GetImage()
    if ($null -eq $img) { return $null }
    $ms = New-Object System.IO.MemoryStream
    try { $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); return $ms.ToArray() }
    finally { $ms.Dispose(); $img.Dispose() }
}

function Get-ClipboardImageBytes {
    # Clipboard owners can briefly hold the clipboard while publishing a new
    # screenshot. Add only two short waits; a persistent lock is retried by the
    # watcher, without entering the transport-failure backoff.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { return Get-CpcvClipboardImageBytesOnce }
        catch {
            if (-not (Test-CpcvClipboardBusyException -Exception $_.Exception) -or $attempt -eq 3) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Get-BytesHash {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-CpcvClipboardHash {
    param([Parameter(Mandatory)][string]$ExpectedHash)

    # Checking again immediately before committing latest state keeps an upload
    # that was delayed by SSH from replacing a newer clipboard image (or text).
    # An unavailable clipboard is not evidence that its contents changed.
    # Propagate read failures to the uploader's controlled error contract while
    # preserving the retry state and the user's clipboard.
    $current = Get-ClipboardImageBytes
    if ($null -eq $current -or $current.Length -eq 0) { return $false }
    return ((Get-BytesHash -Bytes $current) -eq $ExpectedHash)
}

function Publish-ClipboardImage {
    param([switch]$CopyPath, [switch]$Force)

    # A hotkey and the watcher can fire together. Serialize the whole upload so
    # they never race over local state or publish conflicting latest links.
    $mutex = New-Object System.Threading.Mutex($false, (Get-CpcvMutexName -Purpose "Upload"))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0, $false) }
        catch [System.Threading.AbandonedMutexException] {
            # Windows grants ownership when an earlier uploader died while
            # holding the mutex. Recover that ownership and release it below.
            $acquired = $true
        }
        if (-not $acquired) { return @{ Ok = $false; Reason = "upload-in-progress"; Detail = "Another cpcv upload is active." } }
        try {
            $result = Invoke-CpcvClipboardUpload -CopyPath:$CopyPath -Force:$Force
            Update-CpcvUploadStatusFromResult -UploadResult $result
            return $result
        }
        catch {
            if (Test-CpcvClipboardBusyException -Exception $_.Exception) {
                $result = @{ Ok = $false; Reason = "clipboard-busy"; Detail = "Windows clipboard is temporarily busy. cpcv will retry automatically without changing it." }
            }
            else {
                Write-CpcvLog "upload error: $(Protect-CpcvLogDetail ([string]$_))"
                $result = @{ Ok = $false; Reason = "upload-error"; Detail = "A local error prevented cpcv from confirming the upload. View recent activity for a redacted diagnostic; cpcv will retry automatically." }
            }
            Update-CpcvUploadStatusFromResult -UploadResult $result
            return $result
        }
    }
    finally {
        try { if ($acquired) { $mutex.ReleaseMutex() | Out-Null } }
        finally { $mutex.Dispose() }
    }
}

function Get-CpcvSshOptions {
    <#
    .SYNOPSIS
    Returns the fixed, unattended SSH options used by cpcv uploads.

    .DESCRIPTION
    Keep this in the core so the uploader and a customer-requested connection
    check have exactly the same SSH behavior.  The caller supplies only a
    validated HostAlias and a fixed remote command; no UI text or shell
    fragments are accepted here.
    #>
    return @(
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "ConnectionAttempts=1",
        "-o", "ServerAliveInterval=3",
        "-o", "ServerAliveCountMax=2"
    )
}

function Get-CpcvSshConnectionFailureKind {
    <#
    .SYNOPSIS
    Converts private SSH output into a small, display-safe diagnostic token.

    .DESCRIPTION
    SSH, a ProxyCommand, or an access tunnel can print a host name, URL, or
    credential-like material.  This function intentionally consumes that
    output only in memory and returns a controlled category.  The category is
    suitable for an upload-status file or tray UI; the raw output remains in
    the bounded, redacted local activity log only.
    #>
    param([Parameter(Mandatory)]$ProcessResult)

    if ([bool]$ProcessResult.Ok) { return "connected" }
    if ([bool]$ProcessResult.TimedOut) { return "command-timeout" }

    $detail = @(
        [string]$ProcessResult.StdErr,
        [string]$ProcessResult.StdOut,
        [string]$ProcessResult.Detail
    ) -join "`n"

    # Check the most actionable, observed connection-stage signatures first.
    # A banner timeout can come from SSH itself or from a configured tunnel;
    # neither raw implementation detail belongs in customer-facing state.
    if ($detail -match '(?i)(timed out during banner exchange|banner exchange.*timed out|connection timed out|connection timeout|operation timed out)') {
        return "connect-timeout"
    }
    if ($detail -match '(?i)(host key verification failed|remote host identification has changed|host key .*changed)') {
        return "host-key"
    }
    # Do not treat every "Permission denied" message as an SSH sign-in
    # failure.  The initial mkdir can itself be rejected by the remote file
    # system, and that needs different customer guidance.
    if ($detail -match '(?i)(permission denied\s*\((?:publickey|keyboard-interactive|password|gssapi-with-mic)[^)]*\)|permission denied,\s*please try again|sign_and_send_pubkey|agent refused|too many authentication failures|no supported authentication methods available|access denied\s*(?:\((?:publickey|keyboard-interactive|password|gssapi-with-mic)[^)]*\)|(?:for|by)\s+(?:user|authentication)))') {
        return "authentication"
    }
    if ($detail -match '(?i)(could not resolve hostname|name or service not known|nodename nor servname)') {
        return "host-not-found"
    }
    if ($detail -match '(?i)(proxycommand|proxy command).*(not found|failed|exited|error)') {
        return "proxy"
    }
    return "connection-failed"
}

function Get-CpcvSshConnectionCheckPresentation {
    <#
    .SYNOPSIS
    Returns the controlled customer-facing text for an SSH check result.

    .DESCRIPTION
    The process that checks the connection and the tray process deliberately
    exchange only FailureKind.  Keeping every visible string here ensures a
    child-process error, hostname, path, proxy URL, or credential can never
    become UI text by accident.
    #>
    param([AllowNull()][string]$FailureKind)

    switch ([string]$FailureKind) {
        "connected" {
            return [pscustomobject]@{
                Ok = $true; FailureKind = "connected"; Summary = "Unattended SSH check passed"
                Detail = "cpcv started a new unattended SSH process using its upload settings and did not change any remote files."
                NextStep = "Retry the clipboard upload. This confirms the connection step only."
            }
        }
        "connect-timeout" {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "connect-timeout"; Summary = "Unattended SSH check timed out"
                Detail = "The SSH greeting did not arrive before cpcv's connection deadline. No image was uploaded."
                NextStep = "Check your network and SSH proxy or tunnel, then test again. An already-open terminal session can still work."
            }
        }
        "authentication" {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "authentication"; Summary = "Unattended SSH sign-in needs attention"
                Detail = "cpcv could not complete a no-prompt sign-in. It cannot answer a password, passphrase, approval, security-key touch, or one-time-code prompt."
                NextStep = "Complete any required approval in your normal SSH workflow, then make an approved unattended key or SSH agent available to cpcv and test again."
            }
        }
        "host-key" {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "host-key"; Summary = "SSH server identity needs review"
                Detail = "cpcv did not bypass SSH host-key protection. No image was uploaded."
                NextStep = "Review the server identity in your normal SSH workflow, then test again."
            }
        }
        "host-not-found" {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "host-not-found"; Summary = "SSH connection name was not found"
                Detail = "cpcv could not resolve the configured SSH connection. No image was uploaded."
                NextStep = "Open Settings and confirm the SSH connection name matches your normal SSH configuration."
            }
        }
        "proxy" {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "proxy"; Summary = "SSH proxy or tunnel needs attention"
                Detail = "An unattended SSH process could not start through its configured proxy or tunnel. No image was uploaded."
                NextStep = "Make sure the SSH proxy or tunnel is installed, signed in if required, and available to new processes, then test again."
            }
        }
        "command-timeout" {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "command-timeout"; Summary = "SSH check timed out"
                Detail = "cpcv stopped the unattended SSH check before it completed. No image was uploaded."
                NextStep = "Check your network and SSH connection, then test again."
            }
        }
        "configuration" {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "configuration"; Summary = "Connection settings need attention"
                Detail = "cpcv could not start an SSH check until its local settings are corrected."
                NextStep = "Open Settings and correct the SSH connection name, then test again."
            }
        }
        "connection-failed" {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "connection-failed"; Summary = "Unattended SSH check failed"
                Detail = "cpcv could not complete an unattended SSH check. No image was uploaded."
                NextStep = "Open Settings to confirm the connection name, then check the redacted activity and test again."
            }
        }
        default {
            return [pscustomobject]@{
                Ok = $false; FailureKind = "check-unavailable"; Summary = "Connection check could not run"
                Detail = "cpcv could not complete the local connection check. No image was uploaded."
                NextStep = "Open Settings to confirm the connection name, then try the check again."
            }
        }
    }
}

function Get-CpcvSshConnectionCheckResult {
    <#
    .SYNOPSIS
    Performs a read-only unattended SSH reachability check for the tray assistant.

    .DESCRIPTION
    The command starts a new non-interactive SSH process with the same
    connection shape used by uploads, followed by POSIX `true`. It does not
    upload an image or create/change a remote file. A user's SSH configuration
    may still multiplex an existing transport, so the check never claims to
    force a new network handshake. Only controlled fields leave this function,
    so a caller cannot accidentally put raw SSH/ProxyCommand output into the
    notification-area UI.
    #>
    # The long-running watcher keeps this canonical configuration object
    # coherent after Settings saves. Reuse it for the check so the diagnostic
    # runs with the same runtime values as the uploader; fall back only for a
    # direct caller that loaded this function unusually.
    $cfg = $script:CpcvConfig
    if ($null -eq $cfg) { $cfg = Get-CpcvConfig }
    if ($cfg.ConfigError) {
        return (Get-CpcvSshConnectionCheckPresentation -FailureKind "configuration")
    }

    $probe = Invoke-CpcvProcess -FilePath "ssh" -Arguments ((Get-CpcvSshOptions) + @($cfg.HostAlias, "true")) -Label "ssh connection check"
    $kind = Get-CpcvSshConnectionFailureKind -ProcessResult $probe
    $result = Get-CpcvSshConnectionCheckPresentation -FailureKind $kind
    Write-CpcvLog "ssh connection check result=$($result.FailureKind)"
    return $result
}

function Get-CpcvSshMkdirFailureReason {
    <#
    .SYNOPSIS
    Maps an initial upload SSH failure to a controlled status token.

    .DESCRIPTION
    Only the first SSH stage can distinguish a connection-start problem from
    later transfer/finalization failures.  Unknown output retains the legacy
    generic token for compatibility and privacy.
    #>
    param([Parameter(Mandatory)]$ProcessResult)

    if ([bool]$ProcessResult.TimedOut) { return "ssh-mkdir-timeout" }
    $detail = @(
        [string]$ProcessResult.StdErr,
        [string]$ProcessResult.StdOut,
        [string]$ProcessResult.Detail
    ) -join "`n"
    if ($detail -match '(?i)(mkdir:.*permission denied|cannot create directory.*permission denied|mkdir:.*read-only file system)') {
        return "ssh-mkdir-remote-folder-failed"
    }
    switch (Get-CpcvSshConnectionFailureKind -ProcessResult $ProcessResult) {
        "connect-timeout" { return "ssh-mkdir-connect-timeout" }
        "authentication" { return "ssh-mkdir-auth-failed" }
        "host-key" { return "ssh-mkdir-host-key-failed" }
        "host-not-found" { return "ssh-mkdir-host-not-found" }
        "proxy" { return "ssh-mkdir-proxy-failed" }
        default { return "ssh-mkdir-failed" }
    }
}

function Update-CpcvUploadHeartbeat {
    # A tray/hotkey upload also uses this core. Only the watcher that already
    # owns the health record may refresh it; writing another PID would make the
    # guardian mistake a healthy watcher for a corrupt or duplicate service.
    try {
        $path = [string]$script:CpcvConfig.HeartbeatFile
        if (-not $path) { return }
        $heartbeat = Get-CpcvHeartbeatInfo -Path $path
        if ($heartbeat -and $heartbeat.ProcessId -eq $PID) {
            Update-CpcvHeartbeat -Status "checking"
        }
    }
    catch { }
}

function Get-CpcvUploadTransportFailure {
    param(
        [Parameter(Mandatory)]$ProcessResult,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Stage,
        [string]$Hash = ""
    )

    $detail = Protect-CpcvLogDetail ([string]$ProcessResult.Detail)
    Write-CpcvLog "$Stage failed$($(if ($ProcessResult.TimedOut) { ' (timeout)' } else { '' })): $detail"
    $kind = Get-CpcvSshConnectionFailureKind -ProcessResult $ProcessResult
    if ($kind -in @("command-timeout", "connect-timeout", "proxy", "authentication")) {
        # Every transport stage starts a new SSH connection, so a later SCP or
        # latest-link connection can need the same recovery as the initial mkdir.
        # Leave publication/hash state alone and use the next ordinary attempt
        # to recheck the clipboard after recovery, rather than retrying in place.
        Update-CpcvUploadHeartbeat
        try {
            $recovery = Repair-CpcvCloudflareAccess -Config $script:CpcvConfig -FailureKind $kind
            if ($recovery.State -eq "recovered") {
                $Reason = "cloudflare-retry"
                $detail = "Cloudflare sign-in was refreshed; the next upload attempt will retry automatically."
            }
            elseif ($recovery.State -eq "sign-in-required") {
                $Reason = "cloudflare-sign-in-required"
                $detail = "Complete Cloudflare sign-in in your normal SSH workflow; cpcv will retry automatically."
            }
        }
        catch {
            Write-CpcvLog "Cloudflare Access recovery unavailable; normal upload retry preserved"
        }
    }
    $result = @{ Ok = $false; Reason = $Reason; Detail = $detail }
    if ($Hash) { $result.Hash = $Hash }
    return $result
}

function Invoke-CpcvClipboardUpload {
    param([switch]$CopyPath, [switch]$Force)

    $cfg = $script:CpcvConfig
    if ($cfg.ConfigError) { return @{ Ok = $false; Reason = "configuration-invalid"; Detail = $cfg.ConfigError } }
    if (-not (Test-Path $cfg.LocalCache)) { New-Item -ItemType Directory -Force -Path $cfg.LocalCache | Out-Null }
    $bytes = Get-ClipboardImageBytes
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return @{ Ok = $false; Reason = "no-image" } }
    if ([int64]$bytes.Length -gt [int64]$cfg.MaxImageBytes) {
        $detail = "Clipboard image is $($bytes.Length) bytes; MaxImageBytes is $($cfg.MaxImageBytes)."
        Write-CpcvLog "upload rejected: $detail"
        return @{ Ok = $false; Reason = "image-too-large"; Detail = $detail }
    }

    $hash = Get-BytesHash -Bytes $bytes
    $last = if (Test-Path $cfg.StateFile) { (Get-Content -Raw -LiteralPath $cfg.StateFile).Trim() } else { "" }
    if (-not $Force -and $hash -eq $last -and (Test-Path (Join-Path $cfg.LocalCache "latest.png"))) {
        $remotePath = Get-CpcvLastRemotePath
        if ($CopyPath) { Set-Clipboard -Value $remotePath }
        return @{ Ok = $true; Reason = "unchanged"; RemotePath = $remotePath; Hash = $hash }
    }

    # Content-addressing makes an interrupted retry reuse its cache entry
    # instead of producing one timestamped PNG per failed poll.
    $localFile = Join-Path $cfg.LocalCache "clip-$hash.png"
    $latestLocal = Join-Path $cfg.LocalCache "latest.png"
    Prune-CpcvCache -KeepPath $localFile
    [System.IO.File]::WriteAllBytes($localFile, $bytes)
    Prune-CpcvCache -KeepPath $localFile

    $hostAlias = $cfg.HostAlias
    $remoteDir = $cfg.RemoteDir.Trim('/')
    $base = [IO.Path]::GetFileName($localFile)
    $sshOpts = Get-CpcvSshOptions

    Update-CpcvUploadHeartbeat
    $mkdir = Invoke-CpcvProcess -FilePath "ssh" -Arguments ($sshOpts + @($hostAlias, "mkdir -p `$HOME/$remoteDir")) -Label "ssh mkdir"
    if (-not $mkdir.Ok) {
        $reason = Get-CpcvSshMkdirFailureReason -ProcessResult $mkdir
        $failure = Get-CpcvUploadTransportFailure -ProcessResult $mkdir -Reason $reason -Stage "mkdir"
        Prune-CpcvCache -KeepPath $localFile
        return $failure
    }

    Update-CpcvUploadHeartbeat
    $scp = Invoke-CpcvProcess -FilePath "scp" -Arguments ($sshOpts + @($localFile, "${hostAlias}:$remoteDir/$base")) -Label "scp upload"
    if (-not $scp.Ok) {
        $reason = if ($scp.TimedOut) { "scp-timeout" } else { "scp-failed" }
        $failure = Get-CpcvUploadTransportFailure -ProcessResult $scp -Reason $reason -Stage "scp"
        Prune-CpcvCache -KeepPath $localFile
        return $failure
    }

    if (-not (Test-CpcvClipboardHash -ExpectedHash $hash)) {
        $detail = "Clipboard changed before the upload could update latest.png; leaving retry state unchanged."
        Write-CpcvLog "upload superseded: $detail"
        Prune-CpcvCache -KeepPath $localFile
        return @{ Ok = $false; Reason = "clipboard-changed"; Detail = $detail; Hash = $hash }
    }

    # Verify that latest really names this image before emitting the success
    # marker. A failed ln or an existing directory at latest.png must not be
    # hidden by a subsequent successful readlink/printf command.
    $remoteCmd = 'ln -sfn {0} "$HOME/{1}/latest.png" && test "$(readlink "$HOME/{1}/latest.png")" = "{0}" && {{ cpcv_path=$(readlink -f "$HOME/{1}/{0}" 2>/dev/null) || cpcv_path="$HOME/{1}/{0}"; printf ''CPCV_UPLOAD_OK %s\n'' "$cpcv_path"; }}' -f $base, $remoteDir
    Update-CpcvUploadHeartbeat
    $remote = Invoke-CpcvProcess -FilePath "ssh" -Arguments ($sshOpts + @($hostAlias, $remoteCmd)) -Label "ssh update latest"
    if (-not $remote.Ok) {
        $reason = if ($remote.TimedOut) { "ssh-latest-timeout" } else { "ssh-latest-failed" }
        $failure = Get-CpcvUploadTransportFailure -ProcessResult $remote -Reason $reason -Stage "latest-link update" -Hash $hash
        Prune-CpcvCache -KeepPath $localFile
        return $failure
    }
    $acknowledgments = @(([string]$remote.StdOut -split "`r?`n") | Where-Object { $_ -cmatch '^CPCV_UPLOAD_OK ' })
    $remotePath = if ($acknowledgments.Count -eq 1) { $acknowledgments[0].Substring(15).Trim() } else { "" }
    if ($remote.OutputTruncated -or -not (Test-CpcvRemotePath $remotePath) -or [IO.Path]::GetFileName($remotePath) -cne $base) {
        $detail = "The remote image publication could not be verified; leaving retry state unchanged."
        Write-CpcvLog "latest-link update failed: $detail"
        Prune-CpcvCache -KeepPath $localFile
        return @{ Ok = $false; Reason = "ssh-latest-failed"; Detail = $detail; Hash = $hash }
    }

    if (-not (Test-CpcvClipboardHash -ExpectedHash $hash)) {
        $detail = "Clipboard changed while the latest link was being updated; leaving retry state unchanged."
        Write-CpcvLog "upload superseded: $detail"
        Prune-CpcvCache -KeepPath $localFile
        return @{ Ok = $false; Reason = "clipboard-changed"; Detail = $detail; Hash = $hash }
    }

    Copy-Item -Force $localFile $latestLocal
    Set-CpcvAtomicText -Path $cfg.StateFile -Value $hash
    Set-CpcvAtomicText -Path $cfg.LastRemotePathFile -Value $remotePath
    Prune-CpcvCache -KeepPath $localFile
    Write-CpcvLog "uploaded $base -> $remotePath ($($bytes.Length) bytes)"
    if ($CopyPath) { Set-Clipboard -Value $remotePath; Write-CpcvLog "clipboard set to path text: $remotePath" }
    return @{ Ok = $true; Reason = "uploaded"; RemotePath = $remotePath; LocalFile = $localFile; Hash = $hash; Bytes = $bytes.Length }
}
