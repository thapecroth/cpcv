# Focused local-only tests for the Windows remote tmux helper. The process
# runner is stubbed, so this never starts SSH/SCP, changes a tmux server, or
# writes files outside the checked-in source tree.
$ErrorActionPreference = "Stop"

function Assert-CtrlCcvRemoteTmux([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "ctrl-ccv-core.ps1")
. (Join-Path $root "ctrl-ccv-remote.ps1")

$script:remoteTmuxCalls = [System.Collections.Generic.List[object]]::new()
$script:remoteTmuxScenario = "state-collision"
$script:remoteTmuxConfig = [pscustomobject]@{
    ConfigError = ""
    HostAlias = "safe-host"
    RemoteDir = "clipboard-images"
    CommandTimeoutSeconds = 35
}

function New-CtrlCcvRemoteTmuxTestProcessResult {
    param(
        [bool]$Ok = $true,
        [string]$StdOut = "",
        [string]$Detail = ""
    )
    return @{ Ok = $Ok; StdOut = $StdOut; Detail = $Detail; TimedOut = $false; ExitCode = if ($Ok) { 0 } else { 1 } }
}

function Get-CtrlCcvConfig { return $script:remoteTmuxConfig }

function Invoke-CtrlCcvProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$Label
    )

    [void]$script:remoteTmuxCalls.Add([pscustomobject]@{
        FilePath = $FilePath
        Arguments = @($Arguments | ForEach-Object { [string]$_ })
        TimeoutSeconds = $TimeoutSeconds
        Label = $Label
    })

    if ($FilePath -eq "ssh.exe") {
        Assert-CtrlCcvRemoteTmux (-not $Arguments[-1].Contains("`r")) "Remote SSH command retained a carriage return that can break POSIX shell syntax."
    }

    switch ($Label) {
        "ssh ctrl-ccv tmux line ending regression" {
            return New-CtrlCcvRemoteTmuxTestProcessResult
        }
        "ssh ctrl-ccv tmux status" {
            switch ($script:remoteTmuxScenario) {
                "state-collision" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=installed`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=running`nCTRL_CCV_OVERRIDE=none`nCTRL_CCV_BINDING=collision`n" }
                "state-cross-platform" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=installed`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=running`nCTRL_CCV_OVERRIDE=none`nCTRL_CCV_BINDING=managed`nCTRL_CCV_SECONDARY_BINDING=managed`n" }
                "apply-collision" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=installed`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=running`nCTRL_CCV_OVERRIDE=none`nCTRL_CCV_BINDING=collision`n" }
                "apply-secondary-collision" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=installed`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=running`nCTRL_CCV_OVERRIDE=none`nCTRL_CCV_BINDING=available`nCTRL_CCV_SECONDARY_BINDING=collision`n" }
                "apply-user-override" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=installed`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=running`nCTRL_CCV_OVERRIDE=user`nCTRL_CCV_BINDING=available`n" }
                "apply-success" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=installed`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=running`nCTRL_CCV_OVERRIDE=none`nCTRL_CCV_BINDING=available`n" }
                "apply-cross-platform" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=installed`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=running`nCTRL_CCV_OVERRIDE=none`nCTRL_CCV_BINDING=available`nCTRL_CCV_SECONDARY_BINDING=available`n" }
                "no-server" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=installed`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=stopped`nCTRL_CCV_OVERRIDE=unavailable`nCTRL_CCV_BINDING=unavailable`n" }
                "tmux-missing" { return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_TMUX=missing`nCTRL_CCV_PLUGIN=installed`nCTRL_CCV_SERVER=unavailable`nCTRL_CCV_OVERRIDE=unavailable`nCTRL_CCV_BINDING=unavailable`n" }
                default { throw "Unexpected status scenario: $script:remoteTmuxScenario" }
            }
        }
        "ssh ctrl-ccv tmux create staging" {
            return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "/tmp/ctrl-ccv-tmux.Abc123`n"
        }
        "scp ctrl-ccv tmux plugin sources" {
            if ($script:remoteTmuxScenario -eq "copy-failure") {
                return New-CtrlCcvRemoteTmuxTestProcessResult -Ok:$false -Detail "password=remote-test-secret"
            }
            return New-CtrlCcvRemoteTmuxTestProcessResult
        }
        "ssh ctrl-ccv tmux install plugin" {
            return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "installed\n"
        }
        "ssh ctrl-ccv tmux cleanup staging" {
            return New-CtrlCcvRemoteTmuxTestProcessResult
        }
        "ssh ctrl-ccv tmux apply binding" {
            if ($script:remoteTmuxScenario -in @("apply-success", "apply-cross-platform")) {
                return New-CtrlCcvRemoteTmuxTestProcessResult -StdOut "CTRL_CCV_APPLY=applied`n"
            }
            throw "Apply should not run for scenario: $script:remoteTmuxScenario"
        }
        default { throw "Unexpected process label: $Label" }
    }
}

function Reset-CtrlCcvRemoteTmuxTestCalls {
    $script:remoteTmuxCalls.Clear()
}

function Find-CtrlCcvRemoteTmuxTestCall {
    param([Parameter(Mandatory)][string]$Label)
    return @($script:remoteTmuxCalls | Where-Object { $_.Label -eq $Label } | Select-Object -Last 1)[0]
}

# CRLF source checkouts and lone-CR input must produce the same POSIX command
# as LF input. Preserve whitespace and SSH arguments outside the command.
$posixCommand = "if true; then`n  printf 'ready\n'`n`nelif false; then`n  :`nfi`n"
$lineEndingCommands = @(
    $posixCommand.Replace("`n", "`r`n"),
    $posixCommand.Replace("`n", "`r"),
    $posixCommand
)
foreach ($lineEndingCommand in $lineEndingCommands) {
    Reset-CtrlCcvRemoteTmuxTestCalls
    $lineEndingResult = Invoke-CtrlCcvRemoteTmuxSsh -Config $script:remoteTmuxConfig -RemoteCommand $lineEndingCommand -Label "ssh ctrl-ccv tmux line ending regression"
    Assert-CtrlCcvRemoteTmux $lineEndingResult.Ok "Line-ending normalization changed the transport result."
    Assert-CtrlCcvRemoteTmux ($script:remoteTmuxCalls.Count -eq 1) "Line-ending normalization invoked more than one process."
    $lineEndingCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux line ending regression"
    Assert-CtrlCcvRemoteTmux ($lineEndingCall.Arguments[-1] -ceq $posixCommand) "Remote command normalization changed LF layout, indentation, blank lines, or shell text."
    $expectedSshArguments = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2", "safe-host")
    Assert-CtrlCcvRemoteTmux ($lineEndingCall.Arguments.Count -eq ($expectedSshArguments.Count + 1)) "Line-ending normalization changed the SSH argument count."
    for ($argumentIndex = 0; $argumentIndex -lt $expectedSshArguments.Count; $argumentIndex++) {
        Assert-CtrlCcvRemoteTmux ($lineEndingCall.Arguments[$argumentIndex] -ceq $expectedSshArguments[$argumentIndex]) "Line-ending normalization changed the configured host or unattended SSH options."
    }
    Assert-CtrlCcvRemoteTmux ($lineEndingCall.FilePath -eq "ssh.exe" -and $lineEndingCall.TimeoutSeconds -eq 35) "Line-ending normalization changed the SSH executable or command timeout."
}

# State reads only narrow markers and keeps the transport as individual args.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "state-collision"
$state = Get-CtrlCcvRemoteTmuxState -Table prefix -Key v
Assert-CtrlCcvRemoteTmux $state.Ok "A successful remote status probe was not marked successful."
Assert-CtrlCcvRemoteTmux ($state.Connection -eq "Connected" -and $state.Tmux -eq "Installed" -and $state.Plugin -eq "Installed") "Remote tmux status markers were not parsed."
Assert-CtrlCcvRemoteTmux ($state.Server -eq "Running" -and $state.Table -eq "prefix" -and $state.Key -eq "v" -and $state.Override -eq "None" -and $state.Binding -eq "Collision") "Remote binding collision state was not parsed."
$statusCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux status"
Assert-CtrlCcvRemoteTmux ($statusCall.FilePath -eq "ssh.exe") "Remote status did not invoke Windows OpenSSH directly."
Assert-CtrlCcvRemoteTmux ($statusCall.Arguments -contains "BatchMode=yes") "Remote status did not use non-interactive SSH."
Assert-CtrlCcvRemoteTmux ($statusCall.Arguments -contains "safe-host") "Remote status did not pass the configured host as its own argument."
Assert-CtrlCcvRemoteTmux ($statusCall.Arguments[-1] -match "table='prefix'" -and $statusCall.Arguments[-1] -match "key='v'") "Remote status did not constrain the requested binding in its fixed command."
Assert-CtrlCcvRemoteTmux ($statusCall.Arguments -notcontains "cmd.exe" -and $statusCall.Arguments[-1] -notmatch '\.tmux\.conf') "Remote status unexpectedly invoked a local shell or inspected user tmux configuration."

# The paired cross-platform profile installs two bindings in one remote tmux
# server. It does not depend on, or claim to infer, the connected client OS.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "state-cross-platform"
$crossPlatformState = Get-CtrlCcvRemoteTmuxState -Table root -Key C-v -SecondaryTable root -SecondaryKey M-v
Assert-CtrlCcvRemoteTmux ($crossPlatformState.Ok -and $crossPlatformState.Table -eq "root" -and $crossPlatformState.Key -eq "C-v" -and $crossPlatformState.SecondaryTable -eq "root" -and $crossPlatformState.SecondaryKey -eq "M-v") "Paired cross-platform binding state did not retain both constrained slots."
Assert-CtrlCcvRemoteTmux ($crossPlatformState.Binding -eq "Managed" -and $crossPlatformState.SecondaryBinding -eq "Managed") "Paired cross-platform binding state did not parse both managed statuses."
$crossPlatformStatusCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux status"
Assert-CtrlCcvRemoteTmux ($crossPlatformStatusCall.Arguments[-1] -match "table='root'" -and $crossPlatformStatusCall.Arguments[-1] -match "key='C-v'" -and $crossPlatformStatusCall.Arguments[-1] -match "secondary_table='root'" -and $crossPlatformStatusCall.Arguments[-1] -match "secondary_key='M-v'" -and $crossPlatformStatusCall.Arguments[-1] -match 'secondary_enabled=1') "Paired cross-platform status did not constrain both binding slots in its fixed command."

# Reject values before any transport action can receive them.
$callsBeforeInvalidInput = $script:remoteTmuxCalls.Count
$invalidRejected = $false
try { Install-CtrlCcvRemoteTmuxPlugin -Table "prefix;touch" -Key v | Out-Null } catch { $invalidRejected = $true }
Assert-CtrlCcvRemoteTmux $invalidRejected "Unsafe tmux table input was accepted."
$invalidKeyRejected = $false
try { Install-CtrlCcvRemoteTmuxPlugin -Table prefix -Key "v;touch" | Out-Null } catch { $invalidKeyRejected = $true }
Assert-CtrlCcvRemoteTmux $invalidKeyRejected "Unsafe tmux key input was accepted."
$invalidRootRejected = $false
try { Install-CtrlCcvRemoteTmuxPlugin -Table root -Key v | Out-Null } catch { $invalidRootRejected = $true }
Assert-CtrlCcvRemoteTmux $invalidRootRejected "The root tmux table accepted a non-Ctrl-V binding."
$missingPairedBindingRejected = $false
try { Install-CtrlCcvRemoteTmuxPlugin -Table root -Key C-v -SecondaryTable root | Out-Null } catch { $missingPairedBindingRejected = $true }
Assert-CtrlCcvRemoteTmux $missingPairedBindingRejected "A partial paired tmux binding was accepted."
$unsafePairedBindingRejected = $false
try { Install-CtrlCcvRemoteTmuxPlugin -Table root -Key C-v -SecondaryTable root -SecondaryKey 'M-v;touch' | Out-Null } catch { $unsafePairedBindingRejected = $true }
Assert-CtrlCcvRemoteTmux $unsafePairedBindingRejected "An unsafe paired tmux binding was accepted."
$whitespacePairedBindingRejected = $false
try { Install-CtrlCcvRemoteTmuxPlugin -Table root -Key C-v -SecondaryTable ' ' -SecondaryKey ' ' | Out-Null } catch { $whitespacePairedBindingRejected = $true }
Assert-CtrlCcvRemoteTmux $whitespacePairedBindingRejected "Whitespace paired tmux binding syntax was accepted."
$wrongPairedBindingRejected = $false
try { Install-CtrlCcvRemoteTmuxPlugin -Table prefix -Key v -SecondaryTable root -SecondaryKey M-v | Out-Null } catch { $wrongPairedBindingRejected = $true }
Assert-CtrlCcvRemoteTmux $wrongPairedBindingRejected "A paired binding outside root/C-v plus root/M-v was accepted."
Assert-CtrlCcvRemoteTmux ($script:remoteTmuxCalls.Count -eq $callsBeforeInvalidInput) "Unsafe input reached the transport layer."

# A colon would be ambiguous in scp's host:path destination grammar. The UI
# supports custom ports and IPv6 through a normal SSH config alias instead.
Reset-CtrlCcvRemoteTmuxTestCalls
$originalHostAlias = $script:remoteTmuxConfig.HostAlias
$script:remoteTmuxConfig.HostAlias = "safe-host:2200"
$invalidHostState = Get-CtrlCcvRemoteTmuxState -Table prefix -Key v
Assert-CtrlCcvRemoteTmux (-not $invalidHostState.Ok -and $invalidHostState.Detail -match "SSH config alias") "Ambiguous SSH host syntax was accepted for a tmux deployment."
Assert-CtrlCcvRemoteTmux ($script:remoteTmuxCalls.Count -eq 0) "Ambiguous SSH host syntax reached the transport layer."
$script:remoteTmuxConfig.HostAlias = $originalHostAlias

# Install stages only the five ctrl-ccv plugin files, passes table/key separately
# to the remote installer, and removes the validated temporary directory.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "install-success"
$installed = Install-CtrlCcvRemoteTmuxPlugin -Table prefix -Key v
Assert-CtrlCcvRemoteTmux ($installed.Ok -and $installed.Installed -and $installed.CleanupOk -and $installed.NeedsStartupLine) "Remote tmux plugin installation did not report its successful scoped result."
$stageCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux create staging"
Assert-CtrlCcvRemoteTmux ($stageCall.Arguments[-1] -eq 'mktemp -d "${TMPDIR:-/tmp}/ctrl-ccv-tmux.XXXXXX"') "Remote tmux plugin staging was not confined to a uniquely prefixed mktemp directory."
$scpCall = Find-CtrlCcvRemoteTmuxTestCall -Label "scp ctrl-ccv tmux plugin sources"
Assert-CtrlCcvRemoteTmux ($scpCall.FilePath -eq "scp.exe" -and $scpCall.Arguments[-1] -eq "safe-host:/tmp/ctrl-ccv-tmux.Abc123/") "Remote tmux sources were not copied to the validated staging target."
$sourceArguments = @($scpCall.Arguments[$script:CtrlCcvRemoteTmuxSshOptions.Count..($scpCall.Arguments.Count - 2)])
$sourceLeaves = @($sourceArguments | ForEach-Object { [IO.Path]::GetFileName($_) })
$expectedLeaves = @("ctrl-ccv.tmux", "ctrl-ccv-tmux-paste.sh", "ctrl-ccv-tmux-common.sh", "ctrl-ccv-tmux-status.sh", "install-tmux-ctrl-ccv-plugin.sh")
Assert-CtrlCcvRemoteTmux (((@($sourceLeaves | Sort-Object) -join ",") -eq (@($expectedLeaves | Sort-Object) -join ","))) "Remote deployment copied files outside the ctrl-ccv tmux plugin set."
Assert-CtrlCcvRemoteTmux (@($sourceArguments | Where-Object { $_ -match 'ctrl-ccv-latest|xclip|wl-paste' }).Count -eq 0) "Remote deployment copied unrelated ctrl-ccv helpers."
$installCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux install plugin"
Assert-CtrlCcvRemoteTmux ($installCall.Arguments[-1] -match "--paste-table 'prefix'" -and $installCall.Arguments[-1] -match "--paste-key 'v'") "Remote installer did not receive the selected binding as constrained arguments."
Assert-CtrlCcvRemoteTmux ($installCall.Arguments[-1] -notmatch '\.tmux\.conf') "Remote installer command unexpectedly edits user tmux configuration."
$cleanupCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux cleanup staging"
Assert-CtrlCcvRemoteTmux ($cleanupCall.Arguments[-1] -eq "find -- '/tmp/ctrl-ccv-tmux.Abc123' -depth -mindepth 1 -delete && rmdir -- '/tmp/ctrl-ccv-tmux.Abc123'") "Remote staging cleanup did not target only the validated ctrl-ccv stage."

# The paired profile reaches the installer only through its two fixed
# arguments. The caller cannot turn a key name into shell syntax.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "install-cross-platform"
$crossPlatformInstalled = Install-CtrlCcvRemoteTmuxPlugin -Table root -Key C-v -SecondaryTable root -SecondaryKey M-v
Assert-CtrlCcvRemoteTmux ($crossPlatformInstalled.Ok -and $crossPlatformInstalled.Installed -and $crossPlatformInstalled.SecondaryTable -eq "root" -and $crossPlatformInstalled.SecondaryKey -eq "M-v") "Paired cross-platform plugin installation did not retain its managed second binding."
$crossPlatformInstallCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux install plugin"
Assert-CtrlCcvRemoteTmux ($crossPlatformInstallCall.Arguments[-1] -match "--paste-table 'root'" -and $crossPlatformInstallCall.Arguments[-1] -match "--paste-key 'C-v'" -and $crossPlatformInstallCall.Arguments[-1] -match "--paste-secondary-table 'root'" -and $crossPlatformInstallCall.Arguments[-1] -match "--paste-secondary-key 'M-v'") "Paired cross-platform installer did not receive both constrained binding pairs."

# A transport failure is redacted and still cleans up the validated stage.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "copy-failure"
$copyFailure = Install-CtrlCcvRemoteTmuxPlugin -Table root -Key C-v
Assert-CtrlCcvRemoteTmux (-not $copyFailure.Ok -and $copyFailure.Reason -eq "copy-failed" -and $copyFailure.Detail -notmatch "remote-test-secret" -and $copyFailure.CleanupOk) "Remote copy failure was not bounded, redacted, and cleaned up."
Assert-CtrlCcvRemoteTmux ($null -ne (Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux cleanup staging")) "Failed remote copy did not clean up its validated staging directory."

# Apply preflights a collision before deployment and does not mutate either the
# managed remote config or a running tmux server when another command owns it.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-collision"
$collision = Apply-CtrlCcvRemoteTmuxBinding -Table prefix -Key v
Assert-CtrlCcvRemoteTmux (-not $collision.Ok -and $collision.Reason -eq "binding-collision" -and $collision.NeedsStartupLine) "Apply did not surface an existing user binding collision."
Assert-CtrlCcvRemoteTmux ($null -eq (Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux create staging")) "Apply deployed a new config after preflight detected a binding collision."
Assert-CtrlCcvRemoteTmux ($null -eq (Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux apply binding")) "Apply touched tmux after detecting a user binding collision."

# A collision on either half of the paired profile is equally non-mutating.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-secondary-collision"
$secondaryCollision = Apply-CtrlCcvRemoteTmuxBinding -Table root -Key C-v -SecondaryTable root -SecondaryKey M-v
Assert-CtrlCcvRemoteTmux (-not $secondaryCollision.Ok -and $secondaryCollision.Reason -eq "binding-collision" -and $secondaryCollision.State.SecondaryBinding -eq "Collision") "Apply did not surface a collision on the paired Alt-V binding."
Assert-CtrlCcvRemoteTmux ($null -eq (Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux create staging") -and $null -eq (Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux apply binding")) "Apply changed remote files or tmux after a paired binding collision."

# Explicit @ctrl-ccv-paste-* values are user-owned tmux configuration. The UI must
# recognize that condition without staging a managed replacement or writing
# transient tmux options over it.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-user-override"
$override = Apply-CtrlCcvRemoteTmuxBinding -Table prefix -Key v
Assert-CtrlCcvRemoteTmux (-not $override.Ok -and $override.Reason -eq "user-override" -and $override.State.Override -eq "User") "Apply did not preserve an explicit user tmux override."
Assert-CtrlCcvRemoteTmux ($script:remoteTmuxCalls.Count -eq 1 -and $null -eq (Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux create staging")) "Apply changed remote files after detecting a user override."

# Plugin files may be prepared before tmux itself is installed. That is a
# successful saved configuration, but not an active binding or a misleading
# no-server result.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "tmux-missing"
$tmuxMissing = Apply-CtrlCcvRemoteTmuxBinding -Table prefix -Key v
Assert-CtrlCcvRemoteTmux ($tmuxMissing.Ok -and -not $tmuxMissing.Applied -and $tmuxMissing.Reason -eq "tmux-missing" -and $tmuxMissing.State.Tmux -eq "Missing") "Apply did not clearly distinguish a saved binding from a missing tmux installation."
Assert-CtrlCcvRemoteTmux ($null -eq (Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux apply binding")) "Apply attempted to reload a tmux server that is not installed."

# A non-colliding binding reaches the default tmux server without touching the
# user's persistent tmux configuration.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-success"
$applied = Apply-CtrlCcvRemoteTmuxBinding -Table root -Key C-v
Assert-CtrlCcvRemoteTmux ($applied.Ok -and $applied.Applied -and $applied.Reason -eq "applied" -and $applied.NeedsStartupLine) "Apply did not report a verified live binding."
$applyCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux apply binding"
Assert-CtrlCcvRemoteTmux ($applyCall.Arguments[-1] -match 'tmux run-shell "\$plugin"') "Apply did not reload the managed plugin on the live default tmux server."
Assert-CtrlCcvRemoteTmux ($applyCall.Arguments[-1] -notmatch '@ctrl-ccv-paste-table|@ctrl-ccv-paste-key|\.tmux\.conf|source-file') "Apply unexpectedly overrode, edited, or sourced user tmux configuration."

# A successful paired apply verifies both root-table shortcuts after the
# plugin reload, rather than accepting just one of the two as success.
Reset-CtrlCcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-cross-platform"
$crossPlatformApplied = Apply-CtrlCcvRemoteTmuxBinding -Table root -Key C-v -SecondaryTable root -SecondaryKey M-v
Assert-CtrlCcvRemoteTmux ($crossPlatformApplied.Ok -and $crossPlatformApplied.Applied -and $crossPlatformApplied.SecondaryTable -eq "root" -and $crossPlatformApplied.SecondaryKey -eq "M-v") "Paired cross-platform apply did not report both active bindings."
$crossPlatformApplyCall = Find-CtrlCcvRemoteTmuxTestCall -Label "ssh ctrl-ccv tmux apply binding"
Assert-CtrlCcvRemoteTmux ($crossPlatformApplyCall.Arguments[-1] -match "table='root'" -and $crossPlatformApplyCall.Arguments[-1] -match "key='C-v'" -and $crossPlatformApplyCall.Arguments[-1] -match "secondary_table='root'" -and $crossPlatformApplyCall.Arguments[-1] -match "secondary_key='M-v'" -and $crossPlatformApplyCall.Arguments[-1] -match 'secondary_enabled=1') "Paired cross-platform apply did not verify both constrained binding slots."

Write-Host "PASS: CRLF/lone-CR remote command normalization with LF and SSH arguments preserved; remote tmux state parsing, constrained staging/deployment, paired Windows Alt-V/macOS Ctrl-V bindings, cleanup, redaction, collision preflight, and non-disruptive default-server apply"
