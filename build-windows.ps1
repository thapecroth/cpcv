<#
.SYNOPSIS
Builds a clean, portable Windows source archive for cpcv.

.DESCRIPTION
The Windows runtime is intentionally transparent PowerShell rather than a
wrapped executable. This command creates a ZIP directly from the committed
Git tree, so it cannot accidentally include a local SSH configuration, cache,
logs, screenshots, or other ignored workstation state.

The archive is suitable for private distribution to another Windows machine
with PowerShell and the built-in OpenSSH client. It is not an installer and
does not change the local uploader, Startup shortcuts, clipboard, or remote
SSH host.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "build"),
    [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

function Invoke-CpcvBuildGit {
    param([string[]]$Arguments)

    $output = & git.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    throw "git.exe is required to build a clean cpcv archive."
}

$repository = (Invoke-CpcvBuildGit -Arguments @("-C", $PSScriptRoot, "rev-parse", "--show-toplevel") | Select-Object -Last 1).Trim()
$expectedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\\')
$actualRoot = [IO.Path]::GetFullPath($repository).TrimEnd('\\')
if ($actualRoot -ine $expectedRoot) {
    throw "build-windows.ps1 must be run from the cpcv repository root."
}

if (-not $AllowDirty) {
    $dirty = Invoke-CpcvBuildGit -Arguments @("-C", $repository, "status", "--porcelain", "--untracked-files=no")
    if ($dirty.Count -gt 0) {
        throw "Refusing to build from modified tracked files. Commit or stash the changes first, or explicitly use -AllowDirty (the archive still contains HEAD only)."
    }
}

$revision = (Invoke-CpcvBuildGit -Arguments @("-C", $repository, "rev-parse", "--short=12", "HEAD") | Select-Object -Last 1).Trim()
$outputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputDirectory -PathType Leaf) {
    throw "OutputDirectory is a file, not a directory: $outputDirectory"
}
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$archivePath = Join-Path $outputDirectory ("cpcv-windows-{0}.zip" -f $revision)
if (Test-Path -LiteralPath $archivePath) {
    throw "Refusing to overwrite an existing build artifact: $archivePath"
}

[void](Invoke-CpcvBuildGit -Arguments @("-C", $repository, "archive", "--format=zip", "--prefix=cpcv-windows/", "--output=$archivePath", "HEAD"))
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "git archive did not create the expected artifact: $archivePath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    foreach ($required in @(
        "cpcv-windows/README.md",
        "cpcv-windows/LICENSE",
        "cpcv-windows/cpcv-core.ps1",
        "cpcv-windows/cpcv-watch.ps1",
        "cpcv-windows/cpcv-guardian.ps1",
        "cpcv-windows/cpcv-tray.ps1",
        "cpcv-windows/install-autostart.ps1",
        "cpcv-windows/install-tray.ps1",
        "cpcv-windows/cpcv.config.example.psd1"
    )) {
        if ($names -notcontains $required) { throw "Build archive is missing required file: $required" }
    }

    # The tray degrades safely to a Windows system icon if these files are
    # absent or corrupt at runtime, but a release archive must carry the
    # checked-in branding. This catches the easy-to-miss case where an icon was
    # added locally but not committed before packaging.
    $branding = @(
        [pscustomobject]@{
            Path = "cpcv-windows/assets/windows/cpcv-tray.ico"
            MaximumBytes = 1MB
            Header = [byte[]]@(0, 0, 1, 0)
        },
        [pscustomobject]@{
            Path = "cpcv-windows/assets/windows/cpcv-logo.png"
            MaximumBytes = 4MB
            Header = [byte[]]@(137, 80, 78, 71, 13, 10, 26, 10)
        }
    )
    foreach ($asset in $branding) {
        $entries = @($zip.Entries | Where-Object { $_.FullName -eq $asset.Path })
        if ($entries.Count -ne 1) { throw "Build archive is missing required branded asset: $($asset.Path)" }
        $entry = $entries[0]
        if ($entry.Length -lt $asset.Header.Length -or $entry.Length -gt [int64]$asset.MaximumBytes) {
            throw "Branded asset has an unsafe size in the build archive: $($asset.Path)"
        }
        $stream = $entry.Open()
        try {
            [byte[]]$header = [byte[]]::new($asset.Header.Length)
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
        if ($offset -ne $asset.Header.Length) { throw "Cannot read branded asset header from the build archive: $($asset.Path)" }
        for ($index = 0; $index -lt $asset.Header.Length; $index++) {
            if ($header[$index] -ne $asset.Header[$index]) { throw "Branded asset has an unexpected file signature in the build archive: $($asset.Path)" }
        }
    }

    $forbidden = @($names | Where-Object {
        $_ -match '(^|/)\.git(/|$)' -or
        $_ -match '(^|/)cache(/|$)' -or
        $_ -match '(^|/)(last-hash\.txt|last-remote-path\.txt|watch\.heartbeat)$' -or
        $_ -match '(^|/)(cpcv\.config|config)\.psd1$' -or
        $_ -match '\.log(?:\.\d+)?$'
    })
    if ($forbidden.Count -gt 0) {
        throw "Build archive unexpectedly contains local/generated state: $($forbidden -join ', ')"
    }
}
finally {
    $zip.Dispose()
}

$size = (Get-Item -LiteralPath $archivePath).Length
[pscustomobject]@{
    Artifact = $archivePath
    Revision = $revision
    Bytes = $size
    Source = "committed Git HEAD"
}
