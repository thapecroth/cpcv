# End-to-end Windows upload-pipeline test using isolated local executables.
#
# This deliberately does not contact an SSH host, modify the real clipboard,
# or touch the configured cpcv data directory. It does exercise the real
# PNG/cache/hash path, process launcher, SSH/SCP argument construction, fake
# remote copy/latest update, retry state, and copy-path result end to end.
$ErrorActionPreference = "Stop"

function Assert-CpcvE2E([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "cpcv-core.ps1")

$tempRoot = Join-Path $env:TEMP ("cpcv-e2e-{0}" -f [Guid]::NewGuid())
$originalPath = $env:PATH
$originalRemoteRoot = $env:CPCV_E2E_REMOTE_ROOT
$originalLogPath = $env:CPCV_E2E_LOG_PATH
$originalFailure = $env:CPCV_E2E_FAILURE
$originalConfig = $script:CpcvConfig
try {
    $bin = Join-Path $tempRoot "bin"
    $remoteRoot = Join-Path $tempRoot "remote"
    $logPath = Join-Path $tempRoot "fake-openssh.log"
    New-Item -ItemType Directory -Force -Path $bin, $remoteRoot | Out-Null

    # Compile two small local executables named ssh.exe and scp.exe. They
    # mimic only the exact harmless commands this test sends and record argv
    # as NUL-delimited fields. This proves that cpcv passes each value as
    # an argument rather than creating a local shell command.
    $fakeOpenSsh = @'
using System;
using System.Diagnostics;
using System.IO;

public static class FakeOpenSsh {
    private static void Log(string executable, string[] args) {
        string log = Environment.GetEnvironmentVariable("CPCV_E2E_LOG_PATH");
        File.AppendAllText(log, executable + "\n" + String.Join("\0", args) + "\n");
    }

    public static int Main(string[] args) {
        string root = Environment.GetEnvironmentVariable("CPCV_E2E_REMOTE_ROOT");
        string executable = Path.GetFileName(Process.GetCurrentProcess().MainModule.FileName).ToLowerInvariant();
        if (String.IsNullOrEmpty(root) || (executable != "ssh.exe" && executable != "scp.exe")) {
            Console.Error.WriteLine("invalid isolated e2e harness invocation");
            return 64;
        }
        Log(executable, args);
        string failure = Environment.GetEnvironmentVariable("CPCV_E2E_FAILURE") ?? "";
        if (failure == executable || failure == "all") {
            Console.Error.WriteLine("simulated local transport failure");
            return 255;
        }

        string directory = Path.Combine(root, "clipboard-images");
        if (executable == "scp.exe") {
            if (args.Length < 2) { return 65; }
            string source = args[args.Length - 2];
            string destination = args[args.Length - 1];
            string leaf = Path.GetFileName(destination.Replace('/', Path.DirectorySeparatorChar));
            if (!leaf.StartsWith("clip-", StringComparison.Ordinal) || !leaf.EndsWith(".png", StringComparison.Ordinal)) { return 66; }
            Directory.CreateDirectory(directory);
            File.Copy(source, Path.Combine(directory, leaf), true);
            return 0;
        }

        if (args.Length < 1) { return 65; }
        string command = args[args.Length - 1];
        if (command.StartsWith("mkdir -p ", StringComparison.Ordinal)) {
            Directory.CreateDirectory(directory);
            return 0;
        }
        if (command.StartsWith("ln -sfn ", StringComparison.Ordinal)) {
            string[] fields = command.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 3) { return 67; }
            string leaf = fields[2];
            string source = Path.Combine(directory, leaf);
            if (!File.Exists(source)) { return 68; }
            File.Copy(source, Path.Combine(directory, "latest.png"), true);
            Console.WriteLine("/e2e-home/clipboard-images/" + leaf);
            return 0;
        }
        return 69;
    }
}
'@
    $fakeExecutable = Join-Path $bin "fake-openssh.exe"
    Add-Type -TypeDefinition $fakeOpenSsh -OutputAssembly $fakeExecutable -OutputType ConsoleApplication
    Copy-Item -LiteralPath $fakeExecutable -Destination (Join-Path $bin "ssh.exe")
    Copy-Item -LiteralPath $fakeExecutable -Destination (Join-Path $bin "scp.exe")

    $env:CPCV_E2E_REMOTE_ROOT = $remoteRoot
    $env:CPCV_E2E_LOG_PATH = $logPath
    $env:CPCV_E2E_FAILURE = ""
    $env:PATH = "$bin;$originalPath"

    $script:CpcvConfig = @{
        HostAlias = "e2e-host"; RemoteDir = "clipboard-images"; RemoteHome = "/e2e-home"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); LogFile = (Join-Path $tempRoot "watch.log")
        HeartbeatFile = (Join-Path $tempRoot "watch.heartbeat"); CommandTimeoutSeconds = 5; MaxCommandOutputBytes = 65536
        PollIntervalSeconds = 2; WatchdogCheckSeconds = 15; WatchdogStaleSeconds = 60
        MaxLogBytes = 65536; MaxCacheFiles = 10; MaxCacheBytes = 8388608; MaxImageBytes = 1048576; ConfigError = ""
    }

    # A minimal valid PNG is enough to exercise content hashing/cache names.
    $script:e2eBytes = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLw8QAAAABJRU5ErkJggg==")
    $script:e2eClipboardValue = "image-clipboard-preserved"
    function Get-ClipboardImageBytes { return $script:e2eBytes }
    function Test-CpcvClipboardHash { param([string]$ExpectedHash) return ((Get-BytesHash -Bytes $script:e2eBytes) -eq $ExpectedHash) }
    function Set-Clipboard { param([string]$Value) $script:e2eClipboardValue = $Value }

    $first = Publish-ClipboardImage -Force
    Assert-CpcvE2E $first.Ok "The isolated first upload failed: $($first.Reason) $($first.Detail)"
    Assert-CpcvE2E ($first.Reason -eq "uploaded") "The first upload did not report uploaded."
    Assert-CpcvE2E ($first.RemotePath -match '^/e2e-home/clipboard-images/clip-[a-f0-9]{64}\.png$') "The returned remote path was unsafe or unexpected."
    Assert-CpcvE2E ($script:e2eClipboardValue -eq "image-clipboard-preserved") "An automatic upload replaced the image clipboard with text."
    Assert-CpcvE2E (Test-Path -LiteralPath $first.LocalFile) "The local cache file was not retained."

    $remoteFile = Join-Path $remoteRoot ("clipboard-images\" + [IO.Path]::GetFileName($first.LocalFile))
    $latestFile = Join-Path $remoteRoot "clipboard-images\latest.png"
    Assert-CpcvE2E (Test-Path -LiteralPath $remoteFile) "The isolated SCP destination was not created."
    Assert-CpcvE2E (Test-Path -LiteralPath $latestFile) "The isolated latest.png update was not created."
    Assert-CpcvE2E ((Get-FileHash -LiteralPath $remoteFile -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $first.LocalFile -Algorithm SHA256).Hash) "The uploaded remote bytes differ from the local cached PNG."
    Assert-CpcvE2E ((Get-FileHash -LiteralPath $latestFile -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $remoteFile -Algorithm SHA256).Hash) "latest.png does not match the uploaded PNG."

    $watchSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\cpcv-watch.ps1") -Raw
    $nowSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\cpcv-now.ps1") -Raw
    Assert-CpcvE2E ($watchSource -notmatch 'Publish-ClipboardImage\s+-CopyPath') "The automatic watcher still requests clipboard text replacement."
    Assert-CpcvE2E ($nowSource -notmatch 'Publish-ClipboardImage\s+-CopyPath') "The one-shot uploader still requests clipboard text replacement."

    $operations = Get-Content -LiteralPath $logPath
    Assert-CpcvE2E ($operations.Count -eq 6) "Expected three isolated process invocations (six log lines), found $($operations.Count)."
    Assert-CpcvE2E ($operations[0] -eq "ssh.exe" -and $operations[2] -eq "scp.exe" -and $operations[4] -eq "ssh.exe") "The upload did not invoke SSH, SCP, then SSH in order."
    $argv = @($operations | Where-Object { $_ -ne "ssh.exe" -and $_ -ne "scp.exe" } | ForEach-Object { $_ -split [char]0 })
    Assert-CpcvE2E ($argv -contains "e2e-host") "The expected generic host argument was not passed to the isolated transport."
    Assert-CpcvE2E ($argv -contains "mkdir -p `$HOME/clipboard-images") "mkdir was not passed as one fixed remote command argument."
    Assert-CpcvE2E ($argv -notcontains "cmd.exe") "The upload pipeline unexpectedly invoked a local shell."

    # A locally simulated transport failure must return, leave state retryable,
    # and recover cleanly once transport is restored.
    $script:e2eBytes = $script:e2eBytes + [byte]0
    $env:CPCV_E2E_FAILURE = "ssh.exe"
    $failed = Publish-ClipboardImage -Force
    Assert-CpcvE2E (-not $failed.Ok -and $failed.Reason -eq "ssh-mkdir-failed") "A failed SSH mkdir was not surfaced as a retryable upload failure."
    $env:CPCV_E2E_FAILURE = ""
    $recovered = Publish-ClipboardImage -Force
    Assert-CpcvE2E ($recovered.Ok -and $recovered.Reason -eq "uploaded") "The upload did not recover after the isolated transport failure."
    Assert-CpcvE2E ((Get-Content -LiteralPath $script:CpcvConfig.LastRemotePathFile -Raw).Trim() -eq $recovered.RemotePath) "Recovered upload did not commit latest-path state."
}
finally {
    $env:PATH = $originalPath
    $env:CPCV_E2E_REMOTE_ROOT = $originalRemoteRoot
    $env:CPCV_E2E_LOG_PATH = $originalLogPath
    $env:CPCV_E2E_FAILURE = $originalFailure
    $script:CpcvConfig = $originalConfig
    Remove-Item -Path Function:\Get-ClipboardImageBytes -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Test-CpcvClipboardHash -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Set-Clipboard -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "PASS: isolated Windows end-to-end upload, argv-safe local SSH/SCP transport, remote latest update, failure, and recovery"
