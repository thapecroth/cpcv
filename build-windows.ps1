<#
.SYNOPSIS
Builds clean portable and optional setup-executable Windows artifacts for cpcv.

.DESCRIPTION
The portable archive is intentionally transparent PowerShell. With
-IncludeInstaller, a standard Inno Setup wizard is compiled from the same clean
Git export. Neither operation changes the local uploader, Startup shortcuts,
clipboard, or remote SSH host.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "build"),
    [string]$ReleaseTag,
    [switch]$AllowDirty,
    [switch]$IncludeInstaller,
    [string]$InstallerCompiler
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
$version = (Invoke-CpcvBuildGit -Arguments @("-C", $repository, "show", "HEAD:VERSION") | Select-Object -Last 1).Trim()
if ($version -notmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
    throw "Committed HEAD VERSION must contain stable SemVer."
}
$outputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputDirectory -PathType Leaf) {
    throw "OutputDirectory is a file, not a directory: $outputDirectory"
}
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$archiveFileName = "cpcv-windows-{0}.zip" -f $revision
if (-not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    if ($ReleaseTag -notmatch '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
        throw "ReleaseTag must be a stable SemVer tag such as v0.3.0."
    }
    if ($ReleaseTag -ne "v$version") {
        throw "ReleaseTag '$ReleaseTag' does not match VERSION '$version'."
    }
    $archiveFileName = "cpcv-{0}-windows.zip" -f $ReleaseTag
}

function Resolve-CpcvInnoCompiler {
    param([AllowEmptyString()][string]$RequestedPath)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates.Add($RequestedPath)
    }
    $fromPath = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($fromPath) { $candidates.Add($fromPath.Source) }
    foreach ($programFiles in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
            $candidates.Add((Join-Path $programFiles "Inno Setup 6\ISCC.exe"))
        }
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $resolved = [IO.Path]::GetFullPath($candidate)
        $versionText = (Get-Item -LiteralPath $resolved).VersionInfo.FileVersion
        $versionMatch = [regex]::Match([string]$versionText, '\d+(?:\.\d+){1,3}')
        if (-not $versionMatch.Success) {
            throw "Cannot determine the Inno Setup compiler version at '$resolved'."
        }
        if ([version]$versionMatch.Value -lt [version]'6.3') {
            throw "Inno Setup 6.3 or later is required; found $($versionMatch.Value) at '$resolved'."
        }
        return $resolved
    }
    throw "Inno Setup 6.3 or later compiler (ISCC.exe) was not found. Install Inno Setup 6.3+ or pass -InstallerCompiler."
}

function Test-CpcvExecutableHeader {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 128KB) { return $false }
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        [byte[]]$header = [byte[]]::new(2)
        if ($stream.Read($header, 0, $header.Length) -ne $header.Length) { return $false }
        return ($header[0] -eq [byte][char]'M' -and $header[1] -eq [byte][char]'Z')
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

$archivePath = Join-Path $outputDirectory $archiveFileName
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
        "cpcv-windows/cpcv.config.example.psd1",
        "cpcv-windows/windows/installer/cpcv.iss",
        "cpcv-windows/windows/installer/cpcv-installer.ps1",
        "cpcv-windows/VERSION"
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

$installerPath = $null
if ($IncludeInstaller) {
    $compiler = Resolve-CpcvInnoCompiler -RequestedPath $InstallerCompiler
    $installerBaseName = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
        "cpcv-windows-$revision-setup"
    }
    else {
        "cpcv-$ReleaseTag-windows-setup"
    }
    $installerPath = Join-Path $outputDirectory "$installerBaseName.exe"
    if (Test-Path -LiteralPath $installerPath) {
        throw "Refusing to overwrite an existing installer artifact: $installerPath"
    }

    $stage = Join-Path $outputDirectory (".cpcv-windows-installer-stage-{0}" -f [Guid]::NewGuid().ToString('N'))
    $stageRoot = Join-Path $stage "cpcv-windows"
    $safeStagePrefix = ([IO.Path]::GetFullPath($outputDirectory).TrimEnd('\') + '\')
    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $stage -Force
        if (-not (Test-Path -LiteralPath $stageRoot -PathType Container)) {
            throw "Installer staging did not produce the expected cpcv-windows root."
        }
        $installerScript = Join-Path $stageRoot "windows\installer\cpcv.iss"
        if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
            throw "Installer staging is missing windows\installer\cpcv.iss."
        }

        $compilerArguments = @(
            "/DCpcvVersion=$version",
            "/DCpcvSourceRoot=$stageRoot",
            "/DCpcvOutputDir=$outputDirectory",
            "/DCpcvOutputBaseName=$installerBaseName",
            $installerScript
        )
        & $compiler @compilerArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Inno Setup compiler failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-CpcvExecutableHeader -Path $installerPath)) {
            throw "Inno Setup did not produce a valid cpcv Setup executable: $installerPath"
        }
    }
    finally {
        if (Test-Path -LiteralPath $stage) {
            $resolvedStage = [IO.Path]::GetFullPath($stage)
            if (-not $resolvedStage.StartsWith($safeStagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove an installer staging directory outside OutputDirectory."
            }
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
}

$size = (Get-Item -LiteralPath $archivePath).Length
[pscustomobject]@{
    Artifact = $archivePath
    InstallerArtifact = $installerPath
    Revision = $revision
    Bytes = $size
    Source = if ($IncludeInstaller) { "committed Git HEAD (portable ZIP and Inno Setup EXE)" } else { "committed Git HEAD (portable ZIP)" }
}
