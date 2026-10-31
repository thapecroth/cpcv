<#
.SYNOPSIS
Remote-only tmux plugin helpers for the Windows ctrl-ccv client.

.DESCRIPTION
This file deliberately assumes ctrl-ccv-core.ps1 has already been dot-sourced.
It reuses its bounded process runner and configured SSH target, but never
installs local wrappers, restarts the local service, or edits user-owned
remote shell or tmux configuration files.
#>

if (-not (Get-Command Invoke-CtrlCcvProcess -ErrorAction SilentlyContinue) -or
    -not (Get-Command Get-CtrlCcvConfig -ErrorAction SilentlyContinue) -or
    -not (Get-Command Protect-CtrlCcvLogDetail -ErrorAction SilentlyContinue)) {
    throw "ctrl-ccv-remote.ps1 requires ctrl-ccv-core.ps1 to be loaded first."
}

$script:CtrlCcvRemoteTmuxMarker = "# Managed by ctrl-ccv tmux plugin"
$script:CtrlCcvRemoteTmuxSshOptions = @(
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=8",
    "-o", "ConnectionAttempts=1",
    "-o", "ServerAliveInterval=3",
    "-o", "ServerAliveCountMax=2"
)

function Test-CtrlCcvRemoteTmuxBinding {
    <#
    .SYNOPSIS
    Validates the intentionally small UI-facing binding vocabulary.

    .DESCRIPTION
    tmux itself supports many key names, but this shared Windows surface keeps
    its vocabulary intentionally small: a one-character prefix key, the raw
    Ctrl-V opt-in, or the paired cross-platform preset. Keeping the vocabulary
    small also means no user-provided shell syntax is ever embedded in a
    remote command.
    #>
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][string]$SecondaryTable,
        [AllowNull()][string]$SecondaryKey
    )

    if ($Table -notin @("prefix", "root")) {
        throw "Tmux table must be 'prefix' or 'root'."
    }
    if ($Key -notmatch '^(?:[a-z0-9]|C-v)$') {
        throw "Tmux key must be one lowercase alphanumeric key or C-v."
    }
    if ($Table -eq "root" -and $Key -ne "C-v") {
        throw "The root table is reserved for the explicit raw Ctrl-V binding."
    }

    # Empty is the only omission spelling. Whitespace must be rejected by the
    # exact paired-profile check instead of silently becoming a different
    # binding request.
    $hasSecondaryTable = -not [string]::IsNullOrEmpty($SecondaryTable)
    $hasSecondaryKey = -not [string]::IsNullOrEmpty($SecondaryKey)
    if ($hasSecondaryTable -ne $hasSecondaryKey) {
        throw "A secondary tmux binding requires both its table and key."
    }

    $secondaryTableValue = ""
    $secondaryKeyValue = ""
    if ($hasSecondaryTable) {
        # This pair is intentionally narrow. It is the one cross-platform
        # profile ctrl-ccv supports: macOS uses raw Ctrl-V and Windows uses Alt-V
        # (the tmux key name M-v). tmux installs both bindings; it never tries
        # to infer which client operating system is attached.
        if ($Table -ne "root" -or $Key -ne "C-v" -or $SecondaryTable -ne "root" -or $SecondaryKey -ne "M-v") {
            throw "The secondary tmux binding is only supported with root/C-v plus root/M-v."
        }
        $secondaryTableValue = "root"
        $secondaryKeyValue = "M-v"
    }

    return [pscustomobject]@{
        Table          = $Table
        Key            = $Key
        SecondaryTable = $secondaryTableValue
        SecondaryKey   = $secondaryKeyValue
        HasSecondary   = $hasSecondaryTable
    }
}

function Get-CtrlCcvRemoteTmuxRuntimeConfig {
    $cfg = Get-CtrlCcvConfig
    if ($null -eq $cfg -or -not [string]::IsNullOrWhiteSpace([string]$cfg.ConfigError)) {
        $detail = if ($null -eq $cfg) { "ctrl-ccv configuration is unavailable." } else { [string]$cfg.ConfigError }
        throw $detail
    }
    # Keep the value unambiguous when it is used as the host half of an scp
    # destination. Custom ports, IPv6 literals, ProxyJump, and other complex
    # connection details belong in a normal SSH config alias. The supported
    # forms here deliberately mirror the Settings guidance: `host` or
    # `user@host`.
    if ([string]$cfg.HostAlias -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*(?:@[A-Za-z0-9][A-Za-z0-9._-]*)?$') {
        throw "ctrl-ccv SSH connection name is invalid. Use an SSH config alias or user@host."
    }
    if ([string]$cfg.RemoteDir -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
        ([string]$cfg.RemoteDir).StartsWith('/') -or
        ([string]$cfg.RemoteDir -match '(^|/)\.\.(/|$)')) {
        throw "ctrl-ccv remote image folder is invalid."
    }
    return $cfg
}

function ConvertTo-CtrlCcvRemoteTmuxPosixArgument {
    param([Parameter(Mandatory)][string]$Value)

    # Every caller has already used a narrower field-specific validation. This
    # guard makes the remote command construction auditable as well: values are
    # ordinary POSIX path/name characters wrapped as a single shell argument.
    if ($Value -notmatch '^[A-Za-z0-9._/@:+-]+$') {
        throw "Remote tmux command contains unsupported characters."
    }
    return "'$Value'"
}

function Get-CtrlCcvRemoteTmuxSafeDetail {
    param([AllowNull()][string]$Detail)

    $safe = Protect-CtrlCcvLogDetail -Detail $Detail
    $safe = ($safe -replace '[\r\n\t]+', ' ').Trim()
    if ($safe.Length -gt 360) { return $safe.Substring(0, 359) + [char]0x2026 }
    return $safe
}

function New-CtrlCcvRemoteTmuxResult {
    param(
        [bool]$Ok,
        [Parameter(Mandatory)][string]$Reason,
        [AllowEmptyString()][string]$Detail = "",
        [string]$Table = "",
        [string]$Key = "",
        [string]$SecondaryTable = "",
        [string]$SecondaryKey = "",
        [bool]$Installed = $false,
        [bool]$Applied = $false,
        [AllowNull()][object]$CleanupOk = $null,
        [AllowNull()][object]$State = $null
    )

    return [pscustomobject]@{
        Ok               = $Ok
        Reason           = $Reason
        Detail           = $Detail
        Table            = $Table
        Key              = $Key
        SecondaryTable   = $SecondaryTable
        SecondaryKey     = $SecondaryKey
        Installed        = $Installed
        Applied          = $Applied
        CleanupOk        = $CleanupOk
        # ctrl-ccv will never inspect or edit the user-owned ~/.tmux.conf, so a
        # live apply cannot prove that the plugin will load after the server is
        # restarted. The caller should always show the one-time run-shell line.
        NeedsStartupLine = $true
        State            = $State
    }
}

function Invoke-CtrlCcvRemoteTmuxSsh {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [Parameter(Mandatory)][string]$Label
    )

    # PowerShell here-strings inherit the source file's Windows line endings.
    # POSIX shells can interpret a carriage return as part of an `if`/`elif`
    # token, so normalize every command at the shared SSH transport boundary.
    $posixCommand = $RemoteCommand.Replace("`r`n", "`n").Replace("`r", "`n")
    return Invoke-CtrlCcvProcess -FilePath "ssh.exe" `
        -Arguments ($script:CtrlCcvRemoteTmuxSshOptions + @([string]$Config.HostAlias, $posixCommand)) `
        -TimeoutSeconds ([int]$Config.CommandTimeoutSeconds) -Label $Label
}

function Invoke-CtrlCcvRemoteTmuxScp {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$SourcePaths,
        [Parameter(Mandatory)][string]$StagePath
    )

    $destination = "{0}:{1}/" -f $Config.HostAlias, $StagePath
    return Invoke-CtrlCcvProcess -FilePath "scp.exe" `
        -Arguments ($script:CtrlCcvRemoteTmuxSshOptions + $SourcePaths + @($destination)) `
        -TimeoutSeconds ([int]$Config.CommandTimeoutSeconds) -Label "scp ctrl-ccv tmux plugin sources"
}

function Get-CtrlCcvRemoteTmuxPluginSources {
    $relativePaths = @(
        "ctrl-ccv.tmux",
        "tmux\scripts\ctrl-ccv-tmux-paste.sh",
        "tmux\scripts\ctrl-ccv-tmux-common.sh",
        "tmux\scripts\ctrl-ccv-tmux-status.sh",
        "remote\install-tmux-ctrl-ccv-plugin.sh"
    )
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in $relativePaths) {
        $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $relativePath))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required ctrl-ccv tmux source is missing: $relativePath"
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Required ctrl-ccv tmux source is not a regular file: $relativePath"
        }
        [void]$paths.Add($item.FullName)
    }
    return @($paths.ToArray())
}

function Get-CtrlCcvRemoteTmuxState {
    <#
    .SYNOPSIS
    Reads the configured remote target's tmux/plugin/binding state.

    .DESCRIPTION
    The command emits a narrow, machine-readable set of CTRL_CCV_* markers. It
    does not write remote files, reload tmux, or inspect ~/.tmux.conf.
    #>
    [CmdletBinding()]
    param(
        [string]$Table = "prefix",
        [string]$Key = "v",
        [AllowNull()][string]$SecondaryTable,
        [AllowNull()][string]$SecondaryKey
    )

    $binding = Test-CtrlCcvRemoteTmuxBinding -Table $Table -Key $Key -SecondaryTable $SecondaryTable -SecondaryKey $SecondaryKey
    $state = [ordered]@{
        Ok               = $false
        Connection       = "Unavailable"
        Tmux             = "Unknown"
        Plugin           = "Unknown"
        Server           = "Unknown"
        Table            = $binding.Table
        Key              = $binding.Key
        SecondaryTable   = $binding.SecondaryTable
        SecondaryKey     = $binding.SecondaryKey
        Override         = "Unknown"
        Binding          = "Unknown"
        SecondaryBinding = if ($binding.HasSecondary) { "Unknown" } else { "NotSelected" }
        Detail           = ""
    }

    try {
        $cfg = Get-CtrlCcvRemoteTmuxRuntimeConfig
        $tableArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $binding.Table
        $keyArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $binding.Key
        # Use fixed, harmless values when no paired shortcut was selected so
        # the command format remains static and auditable. The shell only
        # probes these slots when secondary_enabled is 1.
        $secondaryTableArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $(if ($binding.HasSecondary) { $binding.SecondaryTable } else { "root" })
        $secondaryKeyArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $(if ($binding.HasSecondary) { $binding.SecondaryKey } else { "M-v" })
        $secondaryEnabledArgument = if ($binding.HasSecondary) { "1" } else { "0" }
    }
    catch {
        $state["Detail"] = Get-CtrlCcvRemoteTmuxSafeDetail -Detail $_.Exception.Message
        return [pscustomobject]$state
    }

    $template = @'
set -eu
table=__CTRL_CCV_TABLE__
key=__CTRL_CCV_KEY__
secondary_table=__CTRL_CCV_SECONDARY_TABLE__
secondary_key=__CTRL_CCV_SECONDARY_KEY__
secondary_enabled=__CTRL_CCV_SECONDARY_ENABLED__
plugin="$HOME/.local/lib/ctrl-ccv/tmux/ctrl-ccv.tmux"

binding_status() {
  ctrl_ccv_requested_table=$1
  ctrl_ccv_requested_key=$2
  ctrl_ccv_binding=$(tmux list-keys -T "$ctrl_ccv_requested_table" 2>/dev/null | awk -v table="$ctrl_ccv_requested_table" -v key="$ctrl_ccv_requested_key" '$1 == "bind-key" && $2 == "-T" && $3 == table && $4 == key { print; exit }' || true)
  if [ -z "$ctrl_ccv_binding" ]; then
    printf '%s' available
  elif printf '%s\n' "$ctrl_ccv_binding" | grep -Fq 'CTRL_CCV_TMUX_PLUGIN=1' || \
       printf '%s\n' "$ctrl_ccv_binding" | grep -Fq 'CTRL_CCV_TMUX_COMPAT=1' || \
       { [ "$ctrl_ccv_requested_table" = root ] && [ "$ctrl_ccv_requested_key" = C-v ] && printf '%s\n' "$ctrl_ccv_binding" | grep -Fq 'ctrl-ccv-latest --pane'; }; then
    printf '%s' managed
  else
    printf '%s' collision
  fi
}

if command -v tmux >/dev/null 2>&1; then
  tmux_state=installed
  printf '%s\n' 'CTRL_CCV_TMUX=installed'
else
  tmux_state=missing
  printf '%s\n' 'CTRL_CCV_TMUX=missing'
fi

if [ -f "$plugin" ] && [ ! -L "$plugin" ] && grep -Fqx '# Managed by ctrl-ccv tmux plugin' "$plugin"; then
  printf '%s\n' 'CTRL_CCV_PLUGIN=installed'
else
  printf '%s\n' 'CTRL_CCV_PLUGIN=missing'
fi

if [ "$tmux_state" = installed ] && tmux has-session >/dev/null 2>&1; then
  printf '%s\n' 'CTRL_CCV_SERVER=running'
  configured_table=$(tmux show-options -gqv @ctrl-ccv-paste-table 2>/dev/null || true)
  configured_key=$(tmux show-options -gqv @ctrl-ccv-paste-key 2>/dev/null || true)
  if [ -n "$configured_table" ] || [ -n "$configured_key" ]; then
    printf '%s\n' 'CTRL_CCV_OVERRIDE=user'
  else
    printf '%s\n' 'CTRL_CCV_OVERRIDE=none'
  fi
  printf 'CTRL_CCV_BINDING=%s\n' "$(binding_status "$table" "$key")"
  if [ "$secondary_enabled" = 1 ]; then
    printf 'CTRL_CCV_SECONDARY_BINDING=%s\n' "$(binding_status "$secondary_table" "$secondary_key")"
  else
    printf '%s\n' 'CTRL_CCV_SECONDARY_BINDING=not-selected'
  fi
elif [ "$tmux_state" = installed ]; then
  printf '%s\n' 'CTRL_CCV_SERVER=stopped'
  printf '%s\n' 'CTRL_CCV_OVERRIDE=unavailable'
  printf '%s\n' 'CTRL_CCV_BINDING=unavailable'
  if [ "$secondary_enabled" = 1 ]; then
    printf '%s\n' 'CTRL_CCV_SECONDARY_BINDING=unavailable'
  else
    printf '%s\n' 'CTRL_CCV_SECONDARY_BINDING=not-selected'
  fi
else
  printf '%s\n' 'CTRL_CCV_SERVER=unavailable'
  printf '%s\n' 'CTRL_CCV_OVERRIDE=unavailable'
  printf '%s\n' 'CTRL_CCV_BINDING=unavailable'
  if [ "$secondary_enabled" = 1 ]; then
    printf '%s\n' 'CTRL_CCV_SECONDARY_BINDING=unavailable'
  else
    printf '%s\n' 'CTRL_CCV_SECONDARY_BINDING=not-selected'
  fi
fi
'@
    $remoteCommand = $template.Replace("__CTRL_CCV_TABLE__", $tableArgument).
        Replace("__CTRL_CCV_KEY__", $keyArgument).
        Replace("__CTRL_CCV_SECONDARY_TABLE__", $secondaryTableArgument).
        Replace("__CTRL_CCV_SECONDARY_KEY__", $secondaryKeyArgument).
        Replace("__CTRL_CCV_SECONDARY_ENABLED__", $secondaryEnabledArgument)

    try {
        $probe = Invoke-CtrlCcvRemoteTmuxSsh -Config $cfg -RemoteCommand $remoteCommand -Label "ssh ctrl-ccv tmux status"
    }
    catch {
        $state["Detail"] = Get-CtrlCcvRemoteTmuxSafeDetail -Detail $_.Exception.Message
        return [pscustomobject]$state
    }
    if (-not $probe.Ok) {
        $state["Detail"] = Get-CtrlCcvRemoteTmuxSafeDetail -Detail ([string]$probe.Detail)
        return [pscustomobject]$state
    }

    $state["Ok"] = $true
    $state["Connection"] = "Connected"
    foreach ($line in (([string]$probe.StdOut) -split "`r?`n")) {
        switch ($line.Trim()) {
            "CTRL_CCV_TMUX=installed" { $state["Tmux"] = "Installed" }
            "CTRL_CCV_TMUX=missing" { $state["Tmux"] = "Missing" }
            "CTRL_CCV_PLUGIN=installed" { $state["Plugin"] = "Installed" }
            "CTRL_CCV_PLUGIN=missing" { $state["Plugin"] = "Missing" }
            "CTRL_CCV_SERVER=running" { $state["Server"] = "Running" }
            "CTRL_CCV_SERVER=stopped" { $state["Server"] = "Stopped" }
            "CTRL_CCV_SERVER=unavailable" { $state["Server"] = "Unavailable" }
            "CTRL_CCV_OVERRIDE=user" { $state["Override"] = "User" }
            "CTRL_CCV_OVERRIDE=none" { $state["Override"] = "None" }
            "CTRL_CCV_OVERRIDE=unavailable" { $state["Override"] = "Unavailable" }
            "CTRL_CCV_BINDING=managed" { $state["Binding"] = "Managed" }
            "CTRL_CCV_BINDING=available" { $state["Binding"] = "Available" }
            "CTRL_CCV_BINDING=collision" { $state["Binding"] = "Collision" }
            "CTRL_CCV_BINDING=unavailable" { $state["Binding"] = "Unavailable" }
            "CTRL_CCV_SECONDARY_BINDING=managed" { $state["SecondaryBinding"] = "Managed" }
            "CTRL_CCV_SECONDARY_BINDING=available" { $state["SecondaryBinding"] = "Available" }
            "CTRL_CCV_SECONDARY_BINDING=collision" { $state["SecondaryBinding"] = "Collision" }
            "CTRL_CCV_SECONDARY_BINDING=unavailable" { $state["SecondaryBinding"] = "Unavailable" }
            "CTRL_CCV_SECONDARY_BINDING=not-selected" { $state["SecondaryBinding"] = "NotSelected" }
        }
    }
    return [pscustomobject]$state
}

function Install-CtrlCcvRemoteTmuxPlugin {
    <#
    .SYNOPSIS
    Stages and installs only ctrl-ccv-owned remote tmux plugin files.

    .DESCRIPTION
    The remote installer owns ~/.local/lib/ctrl-ccv/tmux and
    ~/.config/ctrl-ccv/tmux-paste.conf. This function never creates wrappers,
    touches the local watcher, or modifies ~/.tmux.conf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][string]$SecondaryTable,
        [AllowNull()][string]$SecondaryKey
    )

    $binding = Test-CtrlCcvRemoteTmuxBinding -Table $Table -Key $Key -SecondaryTable $SecondaryTable -SecondaryKey $SecondaryKey
    try {
        $cfg = Get-CtrlCcvRemoteTmuxRuntimeConfig
        $remoteDir = ([string]$cfg.RemoteDir).Trim('/')
        $remoteDirArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $remoteDir
        $tableArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $binding.Table
        $keyArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $binding.Key
        $secondaryInstallerArguments = ""
        if ($binding.HasSecondary) {
            $secondaryTableArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $binding.SecondaryTable
            $secondaryKeyArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $binding.SecondaryKey
            $secondaryInstallerArguments = " --paste-secondary-table $secondaryTableArgument --paste-secondary-key $secondaryKeyArgument"
        }
    }
    catch {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "configuration-invalid" `
            -Detail (Get-CtrlCcvRemoteTmuxSafeDetail -Detail $_.Exception.Message) -Table $binding.Table -Key $binding.Key `
            -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
    }

    $stage = ""
    $cleanupOk = $null
    $cleanupDetail = ""
    $operation = $null
    try {
        try {
            $stageResult = Invoke-CtrlCcvRemoteTmuxSsh -Config $cfg -RemoteCommand 'mktemp -d "${TMPDIR:-/tmp}/ctrl-ccv-tmux.XXXXXX"' -Label "ssh ctrl-ccv tmux create staging"
        }
        catch {
            $stageResult = @{ Ok = $false; Detail = $_.Exception.Message }
        }
        if (-not $stageResult.Ok) {
            $operation = New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "stage-failed" `
                -Detail (Get-CtrlCcvRemoteTmuxSafeDetail -Detail ([string]$stageResult.Detail)) -Table $binding.Table -Key $binding.Key `
                -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
        }
        else {
            $stageLine = ([string]$stageResult.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
            $stage = ([string]$stageLine).Trim()
            if ($stage -notmatch '^/(?:[A-Za-z0-9_-]+/)*ctrl-ccv-tmux\.[A-Za-z0-9]{6}$') {
                $stage = ""
                $operation = New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "invalid-stage" `
                    -Detail "The SSH computer returned an unsafe temporary directory." -Table $binding.Table -Key $binding.Key `
                    -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
            }
            else {
                try {
                    $sources = Get-CtrlCcvRemoteTmuxPluginSources
                }
                catch {
                    $operation = New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "source-missing" `
                        -Detail (Get-CtrlCcvRemoteTmuxSafeDetail -Detail $_.Exception.Message) -Table $binding.Table -Key $binding.Key `
                        -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
                }
                if ($null -eq $operation) {
                    try {
                        $copy = Invoke-CtrlCcvRemoteTmuxScp -Config $cfg -SourcePaths $sources -StagePath $stage
                    }
                    catch {
                        $copy = @{ Ok = $false; Detail = $_.Exception.Message }
                    }
                    if (-not $copy.Ok) {
                        $operation = New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "copy-failed" `
                            -Detail (Get-CtrlCcvRemoteTmuxSafeDetail -Detail ([string]$copy.Detail)) -Table $binding.Table -Key $binding.Key `
                            -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
                    }
                    else {
                        $stageArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $stage
                        $installerArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value "$stage/install-tmux-ctrl-ccv-plugin.sh"
                        $template = @'
set -eu
CTRL_CCV_STAGE_DIR=__CTRL_CCV_STAGE__ /usr/bin/env bash __CTRL_CCV_INSTALLER__ --remote-dir __CTRL_CCV_REMOTE_DIR__ --paste-table __CTRL_CCV_TABLE__ --paste-key __CTRL_CCV_KEY____CTRL_CCV_SECONDARY_ARGS__
'@
                        $remoteCommand = $template.Replace("__CTRL_CCV_STAGE__", $stageArgument).
                            Replace("__CTRL_CCV_INSTALLER__", $installerArgument).
                            Replace("__CTRL_CCV_REMOTE_DIR__", $remoteDirArgument).
                            Replace("__CTRL_CCV_TABLE__", $tableArgument).
                            Replace("__CTRL_CCV_KEY__", $keyArgument).
                            Replace("__CTRL_CCV_SECONDARY_ARGS__", $secondaryInstallerArguments).Trim()
                        try {
                            $install = Invoke-CtrlCcvRemoteTmuxSsh -Config $cfg -RemoteCommand $remoteCommand -Label "ssh ctrl-ccv tmux install plugin"
                        }
                        catch {
                            $install = @{ Ok = $false; Detail = $_.Exception.Message }
                        }
                        if (-not $install.Ok) {
                            $operation = New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "install-failed" `
                                -Detail (Get-CtrlCcvRemoteTmuxSafeDetail -Detail ([string]$install.Detail)) -Table $binding.Table -Key $binding.Key `
                                -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
                        }
                        else {
                            $operation = New-CtrlCcvRemoteTmuxResult -Ok:$true -Reason "installed" `
                                -Detail "ctrl-ccv tmux plugin files and binding settings were installed on the SSH computer." `
                                -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true
                        }
                    }
                }
            }
        }
    }
    finally {
        if ($stage) {
            try {
                $stageArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $stage
                # The stage name is validated as a fresh ctrl-ccv-tmux.XXXXXX
                # directory. Delete its known contents, then remove just that
                # directory; never issue a broad recursive rm command.
                $cleanupCommand = "find -- $stageArgument -depth -mindepth 1 -delete && rmdir -- $stageArgument"
                $cleanup = Invoke-CtrlCcvRemoteTmuxSsh -Config $cfg -RemoteCommand $cleanupCommand -Label "ssh ctrl-ccv tmux cleanup staging"
                $cleanupOk = [bool]$cleanup.Ok
                if (-not $cleanupOk) { $cleanupDetail = Get-CtrlCcvRemoteTmuxSafeDetail -Detail ([string]$cleanup.Detail) }
            }
            catch {
                $cleanupOk = $false
                $cleanupDetail = Get-CtrlCcvRemoteTmuxSafeDetail -Detail $_.Exception.Message
            }
        }
    }

    if ($null -eq $operation) {
        $operation = New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "unexpected-failure" `
            -Detail "ctrl-ccv could not finish the remote tmux operation." -Table $binding.Table -Key $binding.Key `
            -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
    }
    if ($stage) {
        $operation.CleanupOk = $cleanupOk
        if (-not $cleanupOk -and $operation.Ok) {
            $operation.Ok = $false
            $operation.Reason = "cleanup-failed"
            $operation.Detail = "Plugin files were installed, but ctrl-ccv could not remove its temporary remote staging directory$($(if ($cleanupDetail) { ": $cleanupDetail" } else { "." }))"
        }
    }
    return $operation
}

function Apply-CtrlCcvRemoteTmuxBinding {
    <#
    .SYNOPSIS
    Installs the plugin settings and applies them to the default running tmux server.

    .DESCRIPTION
    A default-server apply is intentionally non-disruptive: it does not restart
    tmux or any pane. Servers using a non-default tmux socket remain a manual
    action, and ~/.tmux.conf remains user-owned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][string]$SecondaryTable,
        [AllowNull()][string]$SecondaryKey
    )

    $binding = Test-CtrlCcvRemoteTmuxBinding -Table $Table -Key $Key -SecondaryTable $SecondaryTable -SecondaryKey $SecondaryKey

    # Do not deploy a new managed config over a slot which is already owned by
    # another command. Likewise, explicit @ctrl-ccv-paste-* options belong to the
    # user's tmux configuration, not this UI. Both checks deliberately happen
    # before staging or reloading anything.
    $preflight = Get-CtrlCcvRemoteTmuxState -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
    if (-not $preflight.Ok) {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "status-failed" -Detail $preflight.Detail `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -State $preflight
    }
    if ($preflight.Override -eq "User") {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "user-override" `
            -Detail "Your tmux configuration explicitly sets a ctrl-ccv paste option. Manage that binding in your tmux configuration instead." `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -State $preflight
    }
    if ($preflight.Binding -eq "Collision" -or $preflight.SecondaryBinding -eq "Collision") {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "binding-collision" `
            -Detail "One of the requested tmux bindings is already owned by another command. Choose a different ctrl-ccv binding." `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -State $preflight
    }

    $installed = Install-CtrlCcvRemoteTmuxPlugin -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
    if (-not $installed.Ok) {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason $installed.Reason -Detail $installed.Detail `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$installed.Installed -CleanupOk $installed.CleanupOk
    }

    # The first preflight prevents an avoidable mutation; this second one
    # protects a binding that appeared while the plugin files were staged.
    $state = Get-CtrlCcvRemoteTmuxState -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey
    if (-not $state.Ok) {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "status-failed" -Detail $state.Detail `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
    }
    if ($state.Override -eq "User") {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "user-override" `
            -Detail "Your tmux configuration explicitly sets a ctrl-ccv paste option. ctrl-ccv left that user-owned binding unchanged." `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
    }
    if ($state.Binding -eq "Collision" -or $state.SecondaryBinding -eq "Collision") {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "binding-collision" `
            -Detail "One of the requested tmux bindings is already owned by another command. ctrl-ccv left it unchanged." `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
    }
    if ($state.Tmux -eq "Missing") {
        return New-CtrlCcvRemoteTmuxResult -Ok:$true -Reason "tmux-missing" `
            -Detail "Plugin settings were saved, but tmux is not installed on the SSH computer yet." `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -Applied:$false -CleanupOk $installed.CleanupOk -State $state
    }
    if ($state.Tmux -ne "Installed" -or $state.Plugin -ne "Installed") {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "remote-not-ready" `
            -Detail "The SSH computer does not have a ready ctrl-ccv tmux plugin." `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
    }
    if ($state.Server -ne "Running") {
        return New-CtrlCcvRemoteTmuxResult -Ok:$true -Reason "no-running-server" `
            -Detail "Plugin settings were saved. Start or attach to the default tmux server, then apply the binding again." `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -Applied:$false -CleanupOk $installed.CleanupOk -State $state
    }

    try {
        $cfg = Get-CtrlCcvRemoteTmuxRuntimeConfig
        $tableArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $binding.Table
        $keyArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $binding.Key
        $secondaryTableArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $(if ($binding.HasSecondary) { $binding.SecondaryTable } else { "root" })
        $secondaryKeyArgument = ConvertTo-CtrlCcvRemoteTmuxPosixArgument -Value $(if ($binding.HasSecondary) { $binding.SecondaryKey } else { "M-v" })
        $secondaryEnabledArgument = if ($binding.HasSecondary) { "1" } else { "0" }
    }
    catch {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "configuration-invalid" `
            -Detail (Get-CtrlCcvRemoteTmuxSafeDetail -Detail $_.Exception.Message) `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
    }

    $template = @'
set -eu
table=__CTRL_CCV_TABLE__
key=__CTRL_CCV_KEY__
secondary_table=__CTRL_CCV_SECONDARY_TABLE__
secondary_key=__CTRL_CCV_SECONDARY_KEY__
secondary_enabled=__CTRL_CCV_SECONDARY_ENABLED__
plugin="$HOME/.local/lib/ctrl-ccv/tmux/ctrl-ccv.tmux"

binding_status() {
  ctrl_ccv_requested_table=$1
  ctrl_ccv_requested_key=$2
  ctrl_ccv_binding=$(tmux list-keys -T "$ctrl_ccv_requested_table" 2>/dev/null | awk -v table="$ctrl_ccv_requested_table" -v key="$ctrl_ccv_requested_key" '$1 == "bind-key" && $2 == "-T" && $3 == table && $4 == key { print; exit }' || true)
  if [ -n "$ctrl_ccv_binding" ] && printf '%s\n' "$ctrl_ccv_binding" | grep -Fq 'CTRL_CCV_TMUX_PLUGIN=1'; then
    printf '%s' managed
  elif [ -n "$ctrl_ccv_binding" ]; then
    printf '%s' collision
  else
    printf '%s' missing
  fi
}

if ! command -v tmux >/dev/null 2>&1; then
  printf '%s\n' 'CTRL_CCV_APPLY=tmux-missing'
  exit 0
fi
if ! tmux has-session >/dev/null 2>&1; then
  printf '%s\n' 'CTRL_CCV_APPLY=no-server'
  exit 0
fi
if [ ! -f "$plugin" ] || [ -L "$plugin" ] || ! grep -Fqx '# Managed by ctrl-ccv tmux plugin' "$plugin"; then
  printf '%s\n' 'CTRL_CCV_APPLY=plugin-missing'
  exit 0
fi

tmux run-shell "$plugin"
primary_status=$(binding_status "$table" "$key")
secondary_status=not-selected
if [ "$secondary_enabled" = 1 ]; then
  secondary_status=$(binding_status "$secondary_table" "$secondary_key")
fi
if [ "$primary_status" = managed ] && { [ "$secondary_enabled" = 0 ] || [ "$secondary_status" = managed ]; }; then
  printf '%s\n' 'CTRL_CCV_APPLY=applied'
elif [ "$primary_status" = collision ] || [ "$secondary_status" = collision ]; then
  printf '%s\n' 'CTRL_CCV_APPLY=collision'
else
  printf '%s\n' 'CTRL_CCV_APPLY=missing'
fi
'@
    $remoteCommand = $template.Replace("__CTRL_CCV_TABLE__", $tableArgument).
        Replace("__CTRL_CCV_KEY__", $keyArgument).
        Replace("__CTRL_CCV_SECONDARY_TABLE__", $secondaryTableArgument).
        Replace("__CTRL_CCV_SECONDARY_KEY__", $secondaryKeyArgument).
        Replace("__CTRL_CCV_SECONDARY_ENABLED__", $secondaryEnabledArgument)
    try {
        $apply = Invoke-CtrlCcvRemoteTmuxSsh -Config $cfg -RemoteCommand $remoteCommand -Label "ssh ctrl-ccv tmux apply binding"
    }
    catch {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "apply-failed" `
            -Detail (Get-CtrlCcvRemoteTmuxSafeDetail -Detail $_.Exception.Message) `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
    }
    if (-not $apply.Ok) {
        return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "apply-failed" `
            -Detail (Get-CtrlCcvRemoteTmuxSafeDetail -Detail ([string]$apply.Detail)) `
            -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
    }

    $applyLine = ([string]$apply.StdOut -split "`r?`n" | Where-Object { $_ -match '^CTRL_CCV_APPLY=' } | Select-Object -Last 1)
    $applyMarker = ([string]$applyLine).Trim()
    switch ($applyMarker) {
        "CTRL_CCV_APPLY=applied" {
            return New-CtrlCcvRemoteTmuxResult -Ok:$true -Reason "applied" `
                -Detail "The ctrl-ccv binding is active in the default tmux server." `
                -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -Applied:$true -CleanupOk $installed.CleanupOk -State $state
        }
        "CTRL_CCV_APPLY=no-server" {
            return New-CtrlCcvRemoteTmuxResult -Ok:$true -Reason "no-running-server" `
                -Detail "Plugin settings were saved, but the default tmux server stopped before ctrl-ccv could apply them." `
                -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
        }
        "CTRL_CCV_APPLY=tmux-missing" {
            return New-CtrlCcvRemoteTmuxResult -Ok:$true -Reason "tmux-missing" `
                -Detail "Plugin settings were saved, but tmux is not installed on the SSH computer yet." `
                -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
        }
        "CTRL_CCV_APPLY=plugin-missing" {
            return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "remote-not-ready" `
                -Detail "The ctrl-ccv tmux plugin was not ready when ctrl-ccv tried to reload it." `
                -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
        }
        "CTRL_CCV_APPLY=collision" {
            return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "binding-collision" `
                -Detail "One of the requested tmux bindings is already owned by another command. Choose a different ctrl-ccv binding." `
                -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
        }
        default {
            return New-CtrlCcvRemoteTmuxResult -Ok:$false -Reason "apply-unverified" `
                -Detail "ctrl-ccv could not verify the requested tmux binding after reload." `
                -Table $binding.Table -Key $binding.Key -SecondaryTable $binding.SecondaryTable -SecondaryKey $binding.SecondaryKey -Installed:$true -CleanupOk $installed.CleanupOk -State $state
        }
    }
}
