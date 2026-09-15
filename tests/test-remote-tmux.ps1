# Focused local-only tests for the Windows remote tmux helper. The process
# runner is stubbed, so this never starts SSH/SCP, changes a tmux server, or
# writes files outside the checked-in source tree.
$ErrorActionPreference = "Stop"

function Assert-CpcvRemoteTmux([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "cpcv-core.ps1")
. (Join-Path $root "cpcv-remote.ps1")

$script:remoteTmuxCalls = [System.Collections.Generic.List[object]]::new()
$script:remoteTmuxScenario = "state-collision"
$script:remoteTmuxConfig = [pscustomobject]@{
    ConfigError = ""
    HostAlias = "safe-host"
    RemoteDir = "clipboard-images"
    CommandTimeoutSeconds = 35
}

function New-CpcvRemoteTmuxTestProcessResult {
    param(
        [bool]$Ok = $true,
        [string]$StdOut = "",
        [string]$Detail = ""
    )
    return @{ Ok = $Ok; StdOut = $StdOut; Detail = $Detail; TimedOut = $false; ExitCode = if ($Ok) { 0 } else { 1 } }
}

function Get-CpcvConfig { return $script:remoteTmuxConfig }

function Invoke-CpcvProcess {
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

    switch ($Label) {
        "ssh cpcv tmux status" {
            switch ($script:remoteTmuxScenario) {
                "state-collision" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=installed`nCPCV_PLUGIN=installed`nCPCV_SERVER=running`nCPCV_OVERRIDE=none`nCPCV_BINDING=collision`n" }
                "state-cross-platform" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=installed`nCPCV_PLUGIN=installed`nCPCV_SERVER=running`nCPCV_OVERRIDE=none`nCPCV_BINDING=managed`nCPCV_SECONDARY_BINDING=managed`n" }
                "apply-collision" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=installed`nCPCV_PLUGIN=installed`nCPCV_SERVER=running`nCPCV_OVERRIDE=none`nCPCV_BINDING=collision`n" }
                "apply-secondary-collision" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=installed`nCPCV_PLUGIN=installed`nCPCV_SERVER=running`nCPCV_OVERRIDE=none`nCPCV_BINDING=available`nCPCV_SECONDARY_BINDING=collision`n" }
                "apply-user-override" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=installed`nCPCV_PLUGIN=installed`nCPCV_SERVER=running`nCPCV_OVERRIDE=user`nCPCV_BINDING=available`n" }
                "apply-success" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=installed`nCPCV_PLUGIN=installed`nCPCV_SERVER=running`nCPCV_OVERRIDE=none`nCPCV_BINDING=available`n" }
                "apply-cross-platform" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=installed`nCPCV_PLUGIN=installed`nCPCV_SERVER=running`nCPCV_OVERRIDE=none`nCPCV_BINDING=available`nCPCV_SECONDARY_BINDING=available`n" }
                "no-server" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=installed`nCPCV_PLUGIN=installed`nCPCV_SERVER=stopped`nCPCV_OVERRIDE=unavailable`nCPCV_BINDING=unavailable`n" }
                "tmux-missing" { return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_TMUX=missing`nCPCV_PLUGIN=installed`nCPCV_SERVER=unavailable`nCPCV_OVERRIDE=unavailable`nCPCV_BINDING=unavailable`n" }
                default { throw "Unexpected status scenario: $script:remoteTmuxScenario" }
            }
        }
        "ssh cpcv tmux create staging" {
            return New-CpcvRemoteTmuxTestProcessResult -StdOut "/tmp/cpcv-tmux.Abc123`n"
        }
        "scp cpcv tmux plugin sources" {
            if ($script:remoteTmuxScenario -eq "copy-failure") {
                return New-CpcvRemoteTmuxTestProcessResult -Ok:$false -Detail "password=remote-test-secret"
            }
            return New-CpcvRemoteTmuxTestProcessResult
        }
        "ssh cpcv tmux install plugin" {
            return New-CpcvRemoteTmuxTestProcessResult -StdOut "installed\n"
        }
        "ssh cpcv tmux cleanup staging" {
            return New-CpcvRemoteTmuxTestProcessResult
        }
        "ssh cpcv tmux apply binding" {
            if ($script:remoteTmuxScenario -in @("apply-success", "apply-cross-platform")) {
                return New-CpcvRemoteTmuxTestProcessResult -StdOut "CPCV_APPLY=applied`n"
            }
            throw "Apply should not run for scenario: $script:remoteTmuxScenario"
        }
        default { throw "Unexpected process label: $Label" }
    }
}

function Reset-CpcvRemoteTmuxTestCalls {
    $script:remoteTmuxCalls.Clear()
}

function Find-CpcvRemoteTmuxTestCall {
    param([Parameter(Mandatory)][string]$Label)
    return @($script:remoteTmuxCalls | Where-Object { $_.Label -eq $Label } | Select-Object -Last 1)[0]
}

# State reads only narrow markers and keeps the transport as individual args.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "state-collision"
$state = Get-CpcvRemoteTmuxState -Table prefix -Key v
Assert-CpcvRemoteTmux $state.Ok "A successful remote status probe was not marked successful."
Assert-CpcvRemoteTmux ($state.Connection -eq "Connected" -and $state.Tmux -eq "Installed" -and $state.Plugin -eq "Installed") "Remote tmux status markers were not parsed."
Assert-CpcvRemoteTmux ($state.Server -eq "Running" -and $state.Table -eq "prefix" -and $state.Key -eq "v" -and $state.Override -eq "None" -and $state.Binding -eq "Collision") "Remote binding collision state was not parsed."
$statusCall = Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux status"
Assert-CpcvRemoteTmux ($statusCall.FilePath -eq "ssh.exe") "Remote status did not invoke Windows OpenSSH directly."
Assert-CpcvRemoteTmux ($statusCall.Arguments -contains "BatchMode=yes") "Remote status did not use non-interactive SSH."
Assert-CpcvRemoteTmux ($statusCall.Arguments -contains "safe-host") "Remote status did not pass the configured host as its own argument."
Assert-CpcvRemoteTmux ($statusCall.Arguments[-1] -match "table='prefix'" -and $statusCall.Arguments[-1] -match "key='v'") "Remote status did not constrain the requested binding in its fixed command."
Assert-CpcvRemoteTmux ($statusCall.Arguments -notcontains "cmd.exe" -and $statusCall.Arguments[-1] -notmatch '\.tmux\.conf') "Remote status unexpectedly invoked a local shell or inspected user tmux configuration."

# The paired cross-platform profile installs two bindings in one remote tmux
# server. It does not depend on, or claim to infer, the connected client OS.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "state-cross-platform"
$crossPlatformState = Get-CpcvRemoteTmuxState -Table root -Key C-v -SecondaryTable root -SecondaryKey M-v
Assert-CpcvRemoteTmux ($crossPlatformState.Ok -and $crossPlatformState.Table -eq "root" -and $crossPlatformState.Key -eq "C-v" -and $crossPlatformState.SecondaryTable -eq "root" -and $crossPlatformState.SecondaryKey -eq "M-v") "Paired cross-platform binding state did not retain both constrained slots."
Assert-CpcvRemoteTmux ($crossPlatformState.Binding -eq "Managed" -and $crossPlatformState.SecondaryBinding -eq "Managed") "Paired cross-platform binding state did not parse both managed statuses."
$crossPlatformStatusCall = Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux status"
Assert-CpcvRemoteTmux ($crossPlatformStatusCall.Arguments[-1] -match "table='root'" -and $crossPlatformStatusCall.Arguments[-1] -match "key='C-v'" -and $crossPlatformStatusCall.Arguments[-1] -match "secondary_table='root'" -and $crossPlatformStatusCall.Arguments[-1] -match "secondary_key='M-v'" -and $crossPlatformStatusCall.Arguments[-1] -match 'secondary_enabled=1') "Paired cross-platform status did not constrain both binding slots in its fixed command."

# Reject values before any transport action can receive them.
$callsBeforeInvalidInput = $script:remoteTmuxCalls.Count
$invalidRejected = $false
try { Install-CpcvRemoteTmuxPlugin -Table "prefix;touch" -Key v | Out-Null } catch { $invalidRejected = $true }
Assert-CpcvRemoteTmux $invalidRejected "Unsafe tmux table input was accepted."
$invalidKeyRejected = $false
try { Install-CpcvRemoteTmuxPlugin -Table prefix -Key "v;touch" | Out-Null } catch { $invalidKeyRejected = $true }
Assert-CpcvRemoteTmux $invalidKeyRejected "Unsafe tmux key input was accepted."
$invalidRootRejected = $false
try { Install-CpcvRemoteTmuxPlugin -Table root -Key v | Out-Null } catch { $invalidRootRejected = $true }
Assert-CpcvRemoteTmux $invalidRootRejected "The root tmux table accepted a non-Ctrl-V binding."
$missingPairedBindingRejected = $false
try { Install-CpcvRemoteTmuxPlugin -Table root -Key C-v -SecondaryTable root | Out-Null } catch { $missingPairedBindingRejected = $true }
Assert-CpcvRemoteTmux $missingPairedBindingRejected "A partial paired tmux binding was accepted."
$unsafePairedBindingRejected = $false
try { Install-CpcvRemoteTmuxPlugin -Table root -Key C-v -SecondaryTable root -SecondaryKey 'M-v;touch' | Out-Null } catch { $unsafePairedBindingRejected = $true }
Assert-CpcvRemoteTmux $unsafePairedBindingRejected "An unsafe paired tmux binding was accepted."
$whitespacePairedBindingRejected = $false
try { Install-CpcvRemoteTmuxPlugin -Table root -Key C-v -SecondaryTable ' ' -SecondaryKey ' ' | Out-Null } catch { $whitespacePairedBindingRejected = $true }
Assert-CpcvRemoteTmux $whitespacePairedBindingRejected "Whitespace paired tmux binding syntax was accepted."
$wrongPairedBindingRejected = $false
try { Install-CpcvRemoteTmuxPlugin -Table prefix -Key v -SecondaryTable root -SecondaryKey M-v | Out-Null } catch { $wrongPairedBindingRejected = $true }
Assert-CpcvRemoteTmux $wrongPairedBindingRejected "A paired binding outside root/C-v plus root/M-v was accepted."
Assert-CpcvRemoteTmux ($script:remoteTmuxCalls.Count -eq $callsBeforeInvalidInput) "Unsafe input reached the transport layer."

# A colon would be ambiguous in scp's host:path destination grammar. The UI
# supports custom ports and IPv6 through a normal SSH config alias instead.
Reset-CpcvRemoteTmuxTestCalls
$originalHostAlias = $script:remoteTmuxConfig.HostAlias
$script:remoteTmuxConfig.HostAlias = "safe-host:2200"
$invalidHostState = Get-CpcvRemoteTmuxState -Table prefix -Key v
Assert-CpcvRemoteTmux (-not $invalidHostState.Ok -and $invalidHostState.Detail -match "SSH config alias") "Ambiguous SSH host syntax was accepted for a tmux deployment."
Assert-CpcvRemoteTmux ($script:remoteTmuxCalls.Count -eq 0) "Ambiguous SSH host syntax reached the transport layer."
$script:remoteTmuxConfig.HostAlias = $originalHostAlias

# Install stages only the five cpcv plugin files, passes table/key separately
# to the remote installer, and removes the validated temporary directory.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "install-success"
$installed = Install-CpcvRemoteTmuxPlugin -Table prefix -Key v
Assert-CpcvRemoteTmux ($installed.Ok -and $installed.Installed -and $installed.CleanupOk -and $installed.NeedsStartupLine) "Remote tmux plugin installation did not report its successful scoped result."
$stageCall = Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux create staging"
Assert-CpcvRemoteTmux ($stageCall.Arguments[-1] -eq 'mktemp -d "${TMPDIR:-/tmp}/cpcv-tmux.XXXXXX"') "Remote tmux plugin staging was not confined to a uniquely prefixed mktemp directory."
$scpCall = Find-CpcvRemoteTmuxTestCall -Label "scp cpcv tmux plugin sources"
Assert-CpcvRemoteTmux ($scpCall.FilePath -eq "scp.exe" -and $scpCall.Arguments[-1] -eq "safe-host:/tmp/cpcv-tmux.Abc123/") "Remote tmux sources were not copied to the validated staging target."
$sourceArguments = @($scpCall.Arguments[$script:CpcvRemoteTmuxSshOptions.Count..($scpCall.Arguments.Count - 2)])
$sourceLeaves = @($sourceArguments | ForEach-Object { [IO.Path]::GetFileName($_) })
$expectedLeaves = @("cpcv.tmux", "cpcv-tmux-paste.sh", "cpcv-tmux-common.sh", "cpcv-tmux-status.sh", "install-tmux-cpcv-plugin.sh")
Assert-CpcvRemoteTmux (((@($sourceLeaves | Sort-Object) -join ",") -eq (@($expectedLeaves | Sort-Object) -join ","))) "Remote deployment copied files outside the cpcv tmux plugin set."
Assert-CpcvRemoteTmux (@($sourceArguments | Where-Object { $_ -match 'cpcv-latest|xclip|wl-paste' }).Count -eq 0) "Remote deployment copied unrelated cpcv helpers."
$installCall = Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux install plugin"
Assert-CpcvRemoteTmux ($installCall.Arguments[-1] -match "--paste-table 'prefix'" -and $installCall.Arguments[-1] -match "--paste-key 'v'") "Remote installer did not receive the selected binding as constrained arguments."
Assert-CpcvRemoteTmux ($installCall.Arguments[-1] -notmatch '\.tmux\.conf') "Remote installer command unexpectedly edits user tmux configuration."
$cleanupCall = Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux cleanup staging"
Assert-CpcvRemoteTmux ($cleanupCall.Arguments[-1] -eq "find -- '/tmp/cpcv-tmux.Abc123' -depth -mindepth 1 -delete && rmdir -- '/tmp/cpcv-tmux.Abc123'") "Remote staging cleanup did not target only the validated cpcv stage."

# The paired profile reaches the installer only through its two fixed
# arguments. The caller cannot turn a key name into shell syntax.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "install-cross-platform"
$crossPlatformInstalled = Install-CpcvRemoteTmuxPlugin -Table root -Key C-v -SecondaryTable root -SecondaryKey M-v
Assert-CpcvRemoteTmux ($crossPlatformInstalled.Ok -and $crossPlatformInstalled.Installed -and $crossPlatformInstalled.SecondaryTable -eq "root" -and $crossPlatformInstalled.SecondaryKey -eq "M-v") "Paired cross-platform plugin installation did not retain its managed second binding."
$crossPlatformInstallCall = Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux install plugin"
Assert-CpcvRemoteTmux ($crossPlatformInstallCall.Arguments[-1] -match "--paste-table 'root'" -and $crossPlatformInstallCall.Arguments[-1] -match "--paste-key 'C-v'" -and $crossPlatformInstallCall.Arguments[-1] -match "--paste-secondary-table 'root'" -and $crossPlatformInstallCall.Arguments[-1] -match "--paste-secondary-key 'M-v'") "Paired cross-platform installer did not receive both constrained binding pairs."

# A transport failure is redacted and still cleans up the validated stage.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "copy-failure"
$copyFailure = Install-CpcvRemoteTmuxPlugin -Table root -Key C-v
Assert-CpcvRemoteTmux (-not $copyFailure.Ok -and $copyFailure.Reason -eq "copy-failed" -and $copyFailure.Detail -notmatch "remote-test-secret" -and $copyFailure.CleanupOk) "Remote copy failure was not bounded, redacted, and cleaned up."
Assert-CpcvRemoteTmux ($null -ne (Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux cleanup staging")) "Failed remote copy did not clean up its validated staging directory."

# Apply preflights a collision before deployment and does not mutate either the
# managed remote config or a running tmux server when another command owns it.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-collision"
$collision = Apply-CpcvRemoteTmuxBinding -Table prefix -Key v
Assert-CpcvRemoteTmux (-not $collision.Ok -and $collision.Reason -eq "binding-collision" -and $collision.NeedsStartupLine) "Apply did not surface an existing user binding collision."
Assert-CpcvRemoteTmux ($null -eq (Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux create staging")) "Apply deployed a new config after preflight detected a binding collision."
Assert-CpcvRemoteTmux ($null -eq (Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux apply binding")) "Apply touched tmux after detecting a user binding collision."

# A collision on either half of the paired profile is equally non-mutating.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-secondary-collision"
$secondaryCollision = Apply-CpcvRemoteTmuxBinding -Table root -Key C-v -SecondaryTable root -SecondaryKey M-v
Assert-CpcvRemoteTmux (-not $secondaryCollision.Ok -and $secondaryCollision.Reason -eq "binding-collision" -and $secondaryCollision.State.SecondaryBinding -eq "Collision") "Apply did not surface a collision on the paired Alt-V binding."
Assert-CpcvRemoteTmux ($null -eq (Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux create staging") -and $null -eq (Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux apply binding")) "Apply changed remote files or tmux after a paired binding collision."

# Explicit @cpcv-paste-* values are user-owned tmux configuration. The UI must
# recognize that condition without staging a managed replacement or writing
# transient tmux options over it.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-user-override"
$override = Apply-CpcvRemoteTmuxBinding -Table prefix -Key v
Assert-CpcvRemoteTmux (-not $override.Ok -and $override.Reason -eq "user-override" -and $override.State.Override -eq "User") "Apply did not preserve an explicit user tmux override."
Assert-CpcvRemoteTmux ($script:remoteTmuxCalls.Count -eq 1 -and $null -eq (Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux create staging")) "Apply changed remote files after detecting a user override."

# Plugin files may be prepared before tmux itself is installed. That is a
# successful saved configuration, but not an active binding or a misleading
# no-server result.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "tmux-missing"
$tmuxMissing = Apply-CpcvRemoteTmuxBinding -Table prefix -Key v
Assert-CpcvRemoteTmux ($tmuxMissing.Ok -and -not $tmuxMissing.Applied -and $tmuxMissing.Reason -eq "tmux-missing" -and $tmuxMissing.State.Tmux -eq "Missing") "Apply did not clearly distinguish a saved binding from a missing tmux installation."
Assert-CpcvRemoteTmux ($null -eq (Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux apply binding")) "Apply attempted to reload a tmux server that is not installed."

# A non-colliding binding reaches the default tmux server without touching the
# user's persistent tmux configuration.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-success"
$applied = Apply-CpcvRemoteTmuxBinding -Table root -Key C-v
Assert-CpcvRemoteTmux ($applied.Ok -and $applied.Applied -and $applied.Reason -eq "applied" -and $applied.NeedsStartupLine) "Apply did not report a verified live binding."
$applyCall = Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux apply binding"
Assert-CpcvRemoteTmux ($applyCall.Arguments[-1] -match 'tmux run-shell "\$plugin"') "Apply did not reload the managed plugin on the live default tmux server."
Assert-CpcvRemoteTmux ($applyCall.Arguments[-1] -notmatch '@cpcv-paste-table|@cpcv-paste-key|\.tmux\.conf|source-file') "Apply unexpectedly overrode, edited, or sourced user tmux configuration."

# A successful paired apply verifies both root-table shortcuts after the
# plugin reload, rather than accepting just one of the two as success.
Reset-CpcvRemoteTmuxTestCalls
$script:remoteTmuxScenario = "apply-cross-platform"
$crossPlatformApplied = Apply-CpcvRemoteTmuxBinding -Table root -Key C-v -SecondaryTable root -SecondaryKey M-v
Assert-CpcvRemoteTmux ($crossPlatformApplied.Ok -and $crossPlatformApplied.Applied -and $crossPlatformApplied.SecondaryTable -eq "root" -and $crossPlatformApplied.SecondaryKey -eq "M-v") "Paired cross-platform apply did not report both active bindings."
$crossPlatformApplyCall = Find-CpcvRemoteTmuxTestCall -Label "ssh cpcv tmux apply binding"
Assert-CpcvRemoteTmux ($crossPlatformApplyCall.Arguments[-1] -match "table='root'" -and $crossPlatformApplyCall.Arguments[-1] -match "key='C-v'" -and $crossPlatformApplyCall.Arguments[-1] -match "secondary_table='root'" -and $crossPlatformApplyCall.Arguments[-1] -match "secondary_key='M-v'" -and $crossPlatformApplyCall.Arguments[-1] -match 'secondary_enabled=1') "Paired cross-platform apply did not verify both constrained binding slots."

Write-Host "PASS: remote tmux state parsing, constrained staging/deployment, paired Windows Alt-V/macOS Ctrl-V bindings, cleanup, redaction, collision preflight, and non-disruptive default-server apply"
