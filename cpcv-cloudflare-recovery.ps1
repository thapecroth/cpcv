# Conservative recovery for legacy cloudflared Access token locks. This module
# never reads or changes token contents and never stops another SSH session.

function Test-CpcvCloudflareHostname {
    param([string]$Hostname)
    if (-not $Hostname -or $Hostname.Length -gt 253) { return $false }
    foreach ($part in $Hostname.Split('.')) {
        if ($part -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') { return $false }
    }
    return $true
}

function ConvertFrom-CpcvCloudflareProxyCommand {
    param([string]$ProxyCommand, [string]$ResolvedHostname)
    # Parse data rather than execute the ProxyCommand as a shell command. Keep
    # unsupported wrappers, listeners, service credentials and extra flags out.
    $pattern = '^\s*(?:"(?<exe>[^"\r\n]+)"|(?<exe>[^\s"\r\n]+))\s+access\s+(?:ssh|tcp)\s+--hostname(?:\s+|=)(?:"(?<host>[^"\r\n]+)"|(?<host>[^\s"\r\n]+))\s*$'
    $match = [regex]::Match($ProxyCommand, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    $executable = $match.Groups['exe'].Value
    if ($executable -match '[&|<>;`$%\r\n]' -or [IO.Path]::GetFileName($executable) -notmatch '^cloudflared(?:\.exe)?$') { return $null }
    if (-not [IO.Path]::IsPathRooted($executable) -and $executable -notmatch '^cloudflared(?:\.exe)?$') { return $null }
    $hostname = $match.Groups['host'].Value
    if ($hostname -eq '%h') { $hostname = $ResolvedHostname }
    if (-not (Test-CpcvCloudflareHostname $hostname)) { return $null }
    return @{ Executable = $executable; Hostname = $hostname.ToLowerInvariant() }
}

function Get-CpcvCloudflareProxyContext {
    param([System.Collections.IDictionary]$Config, [int]$TimeoutSeconds)
    if ($env:TUNNEL_SERVICE_TOKEN_ID -or $env:TUNNEL_SERVICE_TOKEN_SECRET) { return $null }
    $probe = Invoke-CpcvProcess -FilePath 'ssh' -Arguments (@('-G') + (Get-CpcvSshOptions) + @($Config.HostAlias)) -TimeoutSeconds $TimeoutSeconds -Label 'Cloudflare configuration discovery'
    if (-not $probe.Ok -or $probe.OutputTruncated) { return $null }
    $settings = @{}
    foreach ($line in ($probe.StdOut -split '\r?\n')) {
        if ($line -match '^(hostname|proxycommand|proxyjump)\s+(.+)$') { $settings[$matches[1]] = $matches[2].Trim() }
    }
    if ($settings.proxyjump -and $settings.proxyjump -ne 'none') { return $null }
    $parsed = ConvertFrom-CpcvCloudflareProxyCommand -ProxyCommand $settings.proxycommand -ResolvedHostname $settings.hostname
    if (-not $parsed) { return $null }
    if ([IO.Path]::IsPathRooted($parsed.Executable)) {
        $executable = [IO.Path]::GetFullPath($parsed.Executable)
    }
    else {
        $command = Get-Command $parsed.Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $executable = [IO.Path]::GetFullPath($command.Source)
    }
    $item = Get-Item -LiteralPath $executable -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Name -ine 'cloudflared.exe' -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $null }
    $profileDirectory = if ($env:HOME) { $env:HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { "$($env:HOMEDRIVE)$($env:HOMEPATH)" }
    if (-not $profileDirectory) { return $null }
    return @{ Executable = $executable; Hostname = $parsed.Hostname; CacheRoot = [IO.Path]::GetFullPath((Join-Path $profileDirectory '.cloudflared')) }
}

function Get-CpcvCloudflareAccessMetadata {
    param([string]$Hostname, [int]$TimeoutSeconds)
    if (-not (Test-CpcvCloudflareHostname $Hostname)) { return $null }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $currentUri = [Uri]("https://$Hostname/")
    for ($redirect = 0; $redirect -lt 4; $redirect++) {
        $remaining = ($TimeoutSeconds * 1000) - [int]$timer.ElapsedMilliseconds
        if ($remaining -lt 100) { return $null }
        $request = [Net.HttpWebRequest]::Create($currentUri)
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $false
        $request.Timeout = $remaining
        $request.ReadWriteTimeout = $remaining
        $request.UserAgent = 'cpcv-cloudflare-recovery'
        $response = $null
        $pending = $request.BeginGetResponse($null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($remaining)) {
            $request.Abort()
            $pending.AsyncWaitHandle.Close()
            return $null
        }
        try { $response = $request.EndGetResponse($pending) }
        catch [Net.WebException] {
            if ($null -eq $_.Exception.Response) { return $null }
            $response = $_.Exception.Response
        }
        finally { $pending.AsyncWaitHandle.Close() }
        try {
            $domain = [string]$response.Headers['CF-Access-Domain']
            $aud = [string]$response.Headers['CF-Access-Aud']
            $locationText = [string]$response.Headers['Location']
            $isLogin = $currentUri.AbsolutePath -match '^/cdn-cgi/access/login(?:/|$)'
            if ($isLogin) {
                foreach ($parameter in $currentUri.Query.TrimStart('?').Split('&')) {
                    $pair = $parameter.Split('=', 2)
                    if ($pair.Count -eq 2 -and $pair[0] -eq 'kid') { $aud = [Uri]::UnescapeDataString($pair[1]) }
                }
            }
            if ($domain -and $aud -and ($isLogin -or -not $locationText)) {
                # A wildcard app domain uses the same replacement as legacy
                # cloudflared's GenerateAppTokenFilePathFromURL.
                if ($domain -notmatch '^(?:\*\.)?[A-Za-z0-9][A-Za-z0-9.-]*$' -or $aud -notmatch '^[A-Fa-f0-9]{64}$') { return $null }
                if (-not (Test-CpcvCloudflareHostname $currentUri.Host)) { return $null }
                return @{ AppDomain = $domain; AppAUD = $aud; AuthDomain = $currentUri.Host }
            }
            if (-not $locationText -or $isLogin) { return $null }
            $nextUri = [Uri]::new($currentUri, $locationText)
            if ($nextUri.Scheme -ne 'https' -or $nextUri.UserInfo -or -not $nextUri.IsDefaultPort -or -not (Test-CpcvCloudflareHostname $nextUri.Host)) { return $null }
            if ($nextUri.Host -ne $Hostname -and $nextUri.Host -notlike '*.cloudflareaccess.com') { return $null }
            $currentUri = $nextUri
        }
        finally { if ($response) { $response.Close() } }
    }
    return $null
}

function Get-CpcvCloudflareProcesses {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'cloudflared.exe'" -OperationTimeoutSec 1 -ErrorAction Stop)
    foreach ($process in $processes) {
        if (-not $process.CommandLine -or -not $process.CreationDate) { throw 'Cloudflare process ownership is unavailable.' }
        [pscustomobject]@{ ProcessId = [int]$process.ProcessId; CommandLine = [string]$process.CommandLine; CreationTimeUtc = ([datetime]$process.CreationDate).ToUniversalTime() }
    }
}

function Test-CpcvCloudflareLockOwner {
    param([object[]]$Processes, [datetime]$LockTimeUtc)
    foreach ($process in $Processes) {
        $commandLine = [string]$process.CommandLine
        if (-not $commandLine -or -not $process.CreationTimeUtc) { return $true }
        # Tunnel daemons do not use Access token files. An unrecognized Access
        # operation can acquire them, so preserve its lock conservatively.
        if ($commandLine -match '(?i)\s+tunnel(?:\s|$)') { continue }
        if ($commandLine -notmatch '(?i)\s+access\s+(ssh|tcp)\s+') { return $true }
        if ($commandLine -match '(?i)(?:\s)(?:--url|--listener|-L)(?:[=\s]|$)') { return $true }
        # An Access proxy may wait for BOTH legacy token locks before starting
        # its ten-minute browser transfer. Give that entire flow a margin;
        # only substantially older stream processes can be ruled out safely.
        if ([datetime]$process.CreationTimeUtc -ge $LockTimeUtc.AddSeconds(-900)) { return $true }
    }
    return $false
}

function Initialize-CpcvCloudflareLockMover {
    if ('CpcvCloudflareLockMover' -as [type]) { return }
    # Rename through an open handle, so a replacement file cannot be moved
    # between validation and quarantine. No writable handles can be acquired
    # while the lock is held. OPEN_REPARSE_POINT also protects the leaf itself.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class CpcvCloudflareLockMover {
    [ThreadStatic] public static int LastError;
    [StructLayout(LayoutKind.Sequential)] struct FileInformation {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
        public System.Runtime.InteropServices.ComTypes.FILETIME Access;
        public System.Runtime.InteropServices.ComTypes.FILETIME Write;
        public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links;
        public uint IndexHigh; public uint IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, IntPtr information, uint size);
    public static bool Move(string path, string destination, long expectedWriteTicks, long expectedCreationTicks) {
        LastError = 0;
        using (SafeFileHandle handle = CreateFile(path, 0x80000000u | 0x10000u, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
            if (handle.IsInvalid) { LastError = Marshal.GetLastWin32Error(); return false; }
            FileInformation info;
            if (!GetFileInformationByHandle(handle, out info)) { LastError = Marshal.GetLastWin32Error(); return false; }
            if ((info.Attributes & (0x400u | 0x10u)) != 0 || info.SizeHigh != 0 || info.SizeLow != 0 || info.Links != 1) { LastError = -1; return false; }
            long write = ((long)info.Write.dwHighDateTime << 32) | (uint)info.Write.dwLowDateTime;
            long creation = ((long)info.Creation.dwHighDateTime << 32) | (uint)info.Creation.dwLowDateTime;
            if (DateTime.FromFileTimeUtc(write).Ticks != expectedWriteTicks || DateTime.FromFileTimeUtc(creation).Ticks != expectedCreationTicks) { LastError = -2; return false; }
            byte[] name = System.Text.Encoding.Unicode.GetBytes(destination);
            int nameOffset = IntPtr.Size == 8 ? 20 : 12;
            int bufferSize = nameOffset + name.Length + 2;
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try {
                for (int i = 0; i < bufferSize; i++) Marshal.WriteByte(buffer, i, 0);
                Marshal.WriteInt32(buffer, IntPtr.Size == 8 ? 16 : 8, name.Length);
                Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
                bool moved = SetFileInformationByHandle(handle, 3, buffer, (uint)bufferSize);
                if (!moved) LastError = Marshal.GetLastWin32Error();
                return moved;
            } finally { Marshal.FreeHGlobal(buffer); }
        }
    }
}
'@ -ErrorAction Stop
}

function Move-CpcvStaleCloudflareLocks {
    param($Context, $Metadata, [datetime]$NowUtc, [int]$MinimumAgeSeconds = 120, [datetime]$CreatedAfterUtc = [datetime]::MinValue, [scriptblock]$BeforeMove)
    if ($Metadata.AppDomain -notmatch '^(?:\*\.)?[A-Za-z0-9][A-Za-z0-9.-]*$' -or $Metadata.AppAUD -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-CpcvCloudflareHostname $Metadata.AuthDomain) -or $Metadata.AuthDomain -notlike '*.cloudflareaccess.com') { return @{ State = 'failed'; Count = 0 } }
    $domain = ([string]$Metadata.AppDomain).ToLowerInvariant()
    $hostname = ([string]$Context.Hostname).ToLowerInvariant()
    if ($domain.StartsWith('*.')) {
        if (-not $hostname.EndsWith($domain.Substring(1), [StringComparison]::Ordinal)) { return @{ State = 'failed'; Count = 0 } }
    }
    elseif ($domain -ne $hostname) { return @{ State = 'failed'; Count = 0 } }
    $root = [IO.Path]::GetFullPath($Context.CacheRoot).TrimEnd('\')
    $appDomain = ([string]$Metadata.AppDomain).Replace('*', '-')
    $names = @("$appDomain-$($Metadata.AppAUD)-token.lock", "$($Metadata.AuthDomain)-org-token.lock")
    $candidates = @()
    foreach ($name in ($names | Select-Object -Unique)) {
        $path = Join-Path $root $name
        $pathInfo = Get-CpcvConfigStoragePathInfo -Path $path
        if (-not $pathInfo.Exists) { continue }
        $item = Get-Item -LiteralPath $pathInfo.FullPath -Force -ErrorAction Stop
        if ($CreatedAfterUtc -ne [datetime]::MinValue -and ($item.CreationTimeUtc -lt $CreatedAfterUtc -or $item.LastWriteTimeUtc -lt $CreatedAfterUtc -or $item.LastWriteTimeUtc -gt $NowUtc.AddSeconds(1))) { continue }
        if ($item.Length -ne 0) { return @{ State = 'busy'; Count = 0 } }
        if (($NowUtc - $item.LastWriteTimeUtc).TotalSeconds -lt $MinimumAgeSeconds) { return @{ State = 'busy'; Count = 0 } }
        $candidates += [pscustomobject]@{ Path = $pathInfo.FullPath; WriteTime = $item.LastWriteTimeUtc; CreationTime = $item.CreationTimeUtc }
    }
    if ($candidates.Count -eq 0) { return @{ State = 'not-applicable'; Count = 0 } }
    $processes = @(Get-CpcvCloudflareProcesses)
    foreach ($candidate in $candidates) {
        if (Test-CpcvCloudflareLockOwner -Processes $processes -LockTimeUtc $candidate.WriteTime) { return @{ State = 'busy'; Count = 0 } }
    }
    Initialize-CpcvCloudflareLockMover
    $count = 0
    foreach ($candidate in $candidates) {
        # Recheck ancestry and active processes immediately before the handle
        # operation. Quarantine remains in the exact same validated directory.
        [void](Get-CpcvConfigStoragePathInfo -Path $candidate.Path)
        if (Test-CpcvCloudflareLockOwner -Processes @(Get-CpcvCloudflareProcesses) -LockTimeUtc $candidate.WriteTime) { return @{ State = 'busy'; Count = $count } }
        $destination = "$($candidate.Path).stale-cpcv-$([Guid]::NewGuid().ToString('N'))"
        [void](Get-CpcvConfigStoragePathInfo -Path $destination)
        if ($count -eq 0 -and $BeforeMove) { & $BeforeMove }
        if (-not [CpcvCloudflareLockMover]::Move($candidate.Path, $destination, $candidate.WriteTime.Ticks, $candidate.CreationTime.Ticks)) { return @{ State = 'busy'; Count = $count } }
        $count++
    }
    return @{ State = 'cleared'; Count = $count }
}

function Repair-CpcvCloudflareAccess {
    param([System.Collections.IDictionary]$Config, [string]$FailureKind)
    $result = @{ State = 'not-applicable'; Recovered = $false }
    if ($FailureKind -notin @('command-timeout', 'connect-timeout', 'proxy', 'authentication')) { return $result }
    if (-not $Config -or $Config.ConfigError -or -not $Config.DataRoot) { return $result }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $mutex = $null
    $acquired = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $mutex = [Threading.Mutex]::new($false, "Local\cpcv-CloudflareRecovery-$identity")
        try { $acquired = $mutex.WaitOne(0, $false) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { return @{ State = 'busy'; Recovered = $false } }
        $attemptPath = Join-Path $Config.DataRoot 'cloudflare-recovery-attempt.txt'
        $attemptInfo = Get-CpcvConfigStoragePathInfo -Path $attemptPath
        $now = [datetime]::UtcNow
        if ($attemptInfo.Exists) {
            $attemptItem = Get-Item -LiteralPath $attemptInfo.FullPath -Force -ErrorAction Stop
            if ($attemptItem.Length -gt 128) { return @{ State = 'failed'; Recovered = $false } }
            [datetime]$lastAttempt = [datetime]::MinValue
            $record = [IO.File]::ReadAllText($attemptInfo.FullPath).Trim() -split '\r?\n'
            if ($record.Count -gt 2 -or -not [datetime]::TryParseExact($record[0], 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$lastAttempt)) { return @{ State = 'failed'; Recovered = $false } }
            $pendingSignIn = $record.Count -eq 2 -and $record[1] -eq 'sign-in-required'
            if (($now - $lastAttempt.ToUniversalTime()).TotalSeconds -lt 600) { return @{ State = $(if ($pendingSignIn) { 'sign-in-required' } else { 'busy' }); Recovered = $false } }
        }
        # Invoke-CpcvProcess reserves up to nine seconds for killing a timed-out
        # child tree and draining output; include that in the total budget.
        $discoverySeconds = [Math]::Min(5, [int]$Config.CommandTimeoutSeconds - 10)
        if ($discoverySeconds -lt 1) { return $result }
        $context = Get-CpcvCloudflareProxyContext -Config $Config -TimeoutSeconds $discoverySeconds
        if (-not $context) { return $result }
        $metadataSeconds = [Math]::Min(7, [int]$Config.CommandTimeoutSeconds - [int][Math]::Ceiling($timer.Elapsed.TotalSeconds) - 10)
        if ($metadataSeconds -lt 1) { return $result }
        $metadata = Get-CpcvCloudflareAccessMetadata -Hostname $context.Hostname -TimeoutSeconds $metadataSeconds
        if (-not $metadata) { return $result }
        # Persist only after a candidate is eligible, immediately before the
        # first mutation. Fresh or unrelated locks must not extend cooldown.
        $persistAttempt = {
            [void](Initialize-CpcvConfigStorageDirectory -PathInfo $attemptInfo)
            [void](Get-CpcvConfigStoragePathInfo -Path $attemptPath)
            Set-CpcvAtomicText -Path $attemptPath -Value $now.ToString('o')
        }
        $locks = Move-CpcvStaleCloudflareLocks -Context $context -Metadata $metadata -NowUtc $now -BeforeMove $persistAttempt
        if ($locks.State -ne 'cleared') { return @{ State = [string]$locks.State; Recovered = $false } }
        $loginSeconds = [int]$Config.CommandTimeoutSeconds - [int][Math]::Ceiling($timer.Elapsed.TotalSeconds) - 13
        if ($loginSeconds -lt 1) { return @{ State = 'failed'; Recovered = $false } }
        $loginStartedUtc = [datetime]::UtcNow
        $login = Invoke-CpcvProcess -FilePath $context.Executable -Arguments @('access', 'login', "https://$($context.Hostname)") -TimeoutSeconds $loginSeconds -Label 'Cloudflare Access recovery'
        # A successful login prints the JWT. Only controlled state leaves here.
        if ($login.Ok) { return @{ State = 'recovered'; Recovered = $true } }
        if ($login.TimedOut -and $timer.Elapsed.TotalSeconds -lt ([int]$Config.CommandTimeoutSeconds - 1)) {
            # The owned, bounded login has already had its child tree stopped.
            # Clean only fresh empty locks in its creation window, and refuse
            # if another current authentication process could own either one.
            try { [void](Move-CpcvStaleCloudflareLocks -Context $context -Metadata $metadata -NowUtc ([datetime]::UtcNow) -MinimumAgeSeconds 0 -CreatedAfterUtc $loginStartedUtc.AddSeconds(-1)) } catch { }
        }
        if ($login.TimedOut -or "$($login.StdErr) $($login.StdOut)" -match '(?i)(waiting for login|browser window|please open|log in|login required|authentication required)') {
            [void](Get-CpcvConfigStoragePathInfo -Path $attemptPath)
            Set-CpcvAtomicText -Path $attemptPath -Value ($now.ToString('o') + "`nsign-in-required")
            return @{ State = 'sign-in-required'; Recovered = $false }
        }
        return @{ State = 'failed'; Recovered = $false }
    }
    catch { return @{ State = 'failed'; Recovered = $false } }
    finally {
        if ($mutex) {
            if ($acquired) { $mutex.ReleaseMutex() | Out-Null }
            $mutex.Dispose()
        }
    }
}
