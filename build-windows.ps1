<#
.SYNOPSIS
Builds clean portable and optional setup-executable Windows artifacts for ctrl-ccv.

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

function Invoke-CtrlCcvBuildGit {
    param([string[]]$Arguments)

    $output = & git.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    throw "git.exe is required to build a clean ctrl-ccv archive."
}

$repository = (Invoke-CtrlCcvBuildGit -Arguments @("-C", $PSScriptRoot, "rev-parse", "--show-toplevel") | Select-Object -Last 1).Trim()
$expectedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\\')
$actualRoot = [IO.Path]::GetFullPath($repository).TrimEnd('\\')
if ($actualRoot -ine $expectedRoot) {
    throw "build-windows.ps1 must be run from the ctrl-ccv repository root."
}

if (-not $AllowDirty) {
    $dirty = Invoke-CtrlCcvBuildGit -Arguments @("-C", $repository, "status", "--porcelain", "--untracked-files=no")
    if ($dirty.Count -gt 0) {
        throw "Refusing to build from modified tracked files. Commit or stash the changes first, or explicitly use -AllowDirty (the archive still contains HEAD only)."
    }
}

$revision = (Invoke-CtrlCcvBuildGit -Arguments @("-C", $repository, "rev-parse", "--short=12", "HEAD") | Select-Object -Last 1).Trim()
$version = (Invoke-CtrlCcvBuildGit -Arguments @("-C", $repository, "show", "HEAD:VERSION") | Select-Object -Last 1).Trim()
if ($version -notmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
    throw "Committed HEAD VERSION must contain stable SemVer."
}
$outputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputDirectory -PathType Leaf) {
    throw "OutputDirectory is a file, not a directory: $outputDirectory"
}
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$archiveFileName = "ctrl-ccv-windows-{0}.zip" -f $revision
if (-not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    if ($ReleaseTag -notmatch '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
        throw "ReleaseTag must be a stable SemVer tag such as v0.3.0."
    }
    if ($ReleaseTag -ne "v$version") {
        throw "ReleaseTag '$ReleaseTag' does not match VERSION '$version'."
    }
    $archiveFileName = "ctrl-ccv-{0}-windows.zip" -f $ReleaseTag
}

function Resolve-CtrlCcvInnoCompiler {
    param([AllowEmptyString()][string]$RequestedPath)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates.Add($RequestedPath)
    }
    foreach ($programFiles in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
            $candidates.Add((Join-Path $programFiles "Inno Setup 6\ISCC.exe"))
        }
    }
    # A Chocolatey PATH shim can report version 0.0.0.0 even when it launches
    # a current compiler. Prefer the real installation, then consider PATH.
    $fromPath = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($fromPath) { $candidates.Add($fromPath.Source) }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        # The compiler's file version is not reliably stamped on hosted
        # images. Compilation below is the compatibility check; prefer the
        # canonical Inno Setup installation over a package-manager PATH shim.
        return [IO.Path]::GetFullPath($candidate)
    }
    throw "Inno Setup compiler (ISCC.exe) was not found. Install Inno Setup 6.3+ or pass -InstallerCompiler."
}

function Test-CtrlCcvExecutableHeader {
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

[void](Invoke-CtrlCcvBuildGit -Arguments @("-C", $repository, "archive", "--format=zip", "--prefix=ctrl-ccv-windows/", "--output=$archivePath", "HEAD"))
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "git archive did not create the expected artifact: $archivePath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    foreach ($required in @(
        "ctrl-ccv-windows/README.md",
        "ctrl-ccv-windows/LICENSE",
        "ctrl-ccv-windows/ctrl-ccv-core.ps1",
        "ctrl-ccv-windows/ctrl-ccv-cloudflare-recovery.ps1",
        "ctrl-ccv-windows/ctrl-ccv-connection-check.ps1",
        "ctrl-ccv-windows/ctrl-ccv-remote.ps1",
        "ctrl-ccv-windows/ctrl-ccv-watch.ps1",
        "ctrl-ccv-windows/ctrl-ccv-guardian.ps1",
        "ctrl-ccv-windows/ctrl-ccv-tray.ps1",
        "ctrl-ccv-windows/install-autostart.ps1",
        "ctrl-ccv-windows/install-tray.ps1",
        "ctrl-ccv-windows/ctrl-ccv.config.example.psd1",
        "ctrl-ccv-windows/windows/installer/ctrl-ccv.iss",
        "ctrl-ccv-windows/windows/installer/ctrl-ccv-installer.ps1",
        "ctrl-ccv-windows/VERSION"
    )) {
        if ($names -notcontains $required) { throw "Build archive is missing required file: $required" }
    }

    # The tray degrades safely to a Windows system icon if these files are
    # absent or corrupt at runtime, but a release archive must carry the
    # checked-in branding. This catches the easy-to-miss case where an icon was
    # added locally but not committed before packaging.
    $branding = @(
        [pscustomobject]@{
            Path = "ctrl-ccv-windows/assets/windows/ctrl-ccv-tray.ico"
            MaximumBytes = 1MB
            Header = [byte[]]@(0, 0, 1, 0)
        },
        [pscustomobject]@{
            Path = "ctrl-ccv-windows/assets/windows/ctrl-ccv-logo.png"
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
        $_ -match '(^|/)(last-hash\.txt|last-remote-path\.txt|upload-status\.txt|watch\.heartbeat)$' -or
        $_ -match '(^|/)(ctrl-ccv\.config|config)\.psd1$' -or
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
    $compiler = Resolve-CtrlCcvInnoCompiler -RequestedPath $InstallerCompiler
    $installerBaseName = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
        "ctrl-ccv-windows-$revision-setup"
    }
    else {
        "ctrl-ccv-$ReleaseTag-windows-setup"
    }
    $installerPath = Join-Path $outputDirectory "$installerBaseName.exe"
    if (Test-Path -LiteralPath $installerPath) {
        throw "Refusing to overwrite an existing installer artifact: $installerPath"
    }

    $stage = Join-Path $outputDirectory (".ctrl-ccv-windows-installer-stage-{0}" -f [Guid]::NewGuid().ToString('N'))
    $stageRoot = Join-Path $stage "ctrl-ccv-windows"
    $safeStagePrefix = ([IO.Path]::GetFullPath($outputDirectory).TrimEnd('\') + '\')
    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $stage -Force
        if (-not (Test-Path -LiteralPath $stageRoot -PathType Container)) {
            throw "Installer staging did not produce the expected ctrl-ccv-windows root."
        }
        $installerScript = Join-Path $stageRoot "windows\installer\ctrl-ccv.iss"
        if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
            throw "Installer staging is missing windows\installer\ctrl-ccv.iss."
        }

        $compilerArguments = @(
            "/DCtrlCcvVersion=$version",
            "/DCtrlCcvSourceRoot=$stageRoot",
            "/DCtrlCcvOutputDir=$outputDirectory",
            "/DCtrlCcvOutputBaseName=$installerBaseName",
            $installerScript
        )
        & $compiler @compilerArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Inno Setup compiler failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-CtrlCcvExecutableHeader -Path $installerPath)) {
            throw "Inno Setup did not produce a valid ctrl-ccv Setup executable: $installerPath"
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
