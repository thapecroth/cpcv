// Native macOS menu-bar companion for cpcv.
//
// It is intentionally separate from the uploader. Local uploader actions use
// cpcv-macos-ctl.sh; remote tmux setup uses the project-owned helper with a
// fixed action and validated argument array. No status value is ever passed to
// a shell: Process receives a fixed executable and an argument array.

import AppKit
import Darwin
import Foundation

private let maximumControlOutput = 65_536
private let controlTimeout: TimeInterval = 8
private let doctorControlTimeout: TimeInterval = 3_300
private let settingsControlTimeout: TimeInterval = 20
// An apply performs several individually bounded SSH/SCP calls (preflight,
// staging, install, optional reload, and verification), so its outer bound is
// intentionally longer than a single controller action.
private let tmuxSetupControlTimeout: TimeInterval = 120
private let tmuxStartupLine = "run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux"

struct CpcvStatus: Decodable {
    let version: String?
    let mode: String?
    let pid: Int?
    let updatedAt: String?
    let state: String?
    let lastSuccessAt: String?
    let lastError: String?
    let activeChildPgid: Int?
    let capabilities: [String]?
    // These optional additions keep the tray compatible with an older
    // controller while enabling local-only copy/open conveniences when a
    // newer controller offers them.
    let latestPath: String?
    let lastRemotePath: String?
    let logFile: String?
    let doctorOverall: String?
    let doctorSummary: String?
    let doctorUpdatedAt: String?
}

struct DoctorCheck: Decodable {
    let id: String
    let status: String
    let message: String
}

struct DoctorReport: Decodable {
    let version: String
    let overall: String
    let updatedAt: String
    let summary: String
    let checks: [DoctorCheck]
    let repairs: [String]
}

private struct SettingsForm: Decodable {
    var hostAlias: String
    var remoteDir: String
    var remoteHome: String
    var pollIntervalSeconds: Int
}

private enum TmuxBindingMode {
    case crossPlatform
    case recommended
    case custom
    case rawControlV
}

private struct TmuxBindingDraft {
    let mode: TmuxBindingMode
    let customKey: String
}

private struct TmuxBinding: Equatable {
    let table: String
    let key: String
    let secondaryTable: String?
    let secondaryKey: String?

    var displayName: String {
        if secondaryTable != nil && secondaryKey != nil {
            return "macOS Ctrl-V and Windows Alt-V"
        }
        table == "root" ? "raw Ctrl-V" : "tmux prefix, then \(key)"
    }
}

private enum TmuxBindingError: LocalizedError {
    case invalidCustomKey

    var errorDescription: String? {
        switch self {
        case .invalidCustomKey:
            return "Choose exactly one lowercase letter or digit for a custom prefix binding."
        }
    }
}

private func validatedTmuxBinding(_ draft: TmuxBindingDraft) throws -> TmuxBinding {
    switch draft.mode {
    case .crossPlatform:
        // This pair is intentionally exact. On macOS, Ctrl-V normally reaches
        // the terminal while Cmd-V remains ordinary paste. On Windows, Warp
        // can consume Ctrl-V locally, so Alt-V arrives at tmux as M-v.
        return TmuxBinding(table: "root", key: "C-v", secondaryTable: "root", secondaryKey: "M-v")
    case .recommended:
        return TmuxBinding(table: "prefix", key: "v", secondaryTable: nil, secondaryKey: nil)
    case .rawControlV:
        return TmuxBinding(table: "root", key: "C-v", secondaryTable: nil, secondaryKey: nil)
    case .custom:
        let key = draft.customKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: "^[a-z0-9]$", options: .regularExpression) != nil else {
            throw TmuxBindingError.invalidCustomKey
        }
        return TmuxBinding(table: "prefix", key: key, secondaryTable: nil, secondaryKey: nil)
    }
}

private struct TmuxRemoteSetupResult: Decodable {
    let ok: Bool
    let action: String
    let tmux: String
    let plugin: String
    let server: String
    let binding: String
    let secondaryBinding: String?
    let override: String
    let applied: Bool
    let runtime: String
    let detail: String
    let startupLine: String?
}

struct ControlResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

final class OutputCollector {
    private let lock = NSLock()
    private let maximum: Int
    private var bytes = Data()

    init(maximum: Int) { self.maximum = maximum }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard bytes.count < maximum else { return }
        bytes.append(chunk.prefix(maximum - bytes.count))
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: bytes, encoding: .utf8) ?? "[non-UTF-8 control output]"
    }
}

/// Runs only the project-owned local controller with fixed action names.
/// It executes the controller directly, never through a shell. Reads continue
/// after the cap so an unexpected controller cannot deadlock the menu bar
/// process by writing excessive output.
func runControl(controlPath: String, arguments: [String], timeout: TimeInterval = controlTimeout) -> ControlResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: controlPath)
    task.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    task.standardOutput = stdout
    task.standardError = stderr

    let output = OutputCollector(maximum: maximumControlOutput)
    let errors = OutputCollector(maximum: maximumControlOutput)
    let readers = DispatchGroup()
    func drain(_ handle: FileHandle, into collector: OutputCollector) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readers.leave() }
            while true {
                let data = handle.availableData
                if data.isEmpty { return }
                collector.append(data)
            }
        }
    }

    let finished = DispatchSemaphore(value: 0)
    // Set this before launch: a very fast `status` command may otherwise exit
    // before its handler is installed and be falsely reported as a timeout.
    task.terminationHandler = { _ in finished.signal() }
    do {
        try task.run()
    } catch {
        return ControlResult(exitCode: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
    }
    drain(stdout.fileHandleForReading, into: output)
    drain(stderr.fileHandleForReading, into: errors)

    let didTimeout = finished.wait(timeout: .now() + timeout) == .timedOut
    if didTimeout && task.isRunning {
        // The controller is executed directly. Its native upload mode handles
        // SIGTERM by killing its active SSH/SCP process tree before exiting.
        task.terminate()
        _ = finished.wait(timeout: .now() + 2)
    }
    stdout.fileHandleForWriting.closeFile()
    stderr.fileHandleForWriting.closeFile()
    _ = readers.wait(timeout: .now() + 2)
    return ControlResult(exitCode: task.terminationStatus, stdout: output.text(), stderr: errors.text(), timedOut: didTimeout)
}

func redactForDisplay(_ value: String, limit: Int = 500) -> String {
    var safe = value.replacingOccurrences(of: "(?i)(https?://)[^/\\s:@]+:[^@\\s/]+@", with: "$1[REDACTED]@", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "(?i)https?://[^\\s?]+\\?[^\\s]+", with: "[redacted URL query]", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "(?im)^\\s*(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\\s*:\\s*.*$", with: "$1: [REDACTED]", options: .regularExpression)
    let keyValuePattern = #"(?i)(?<![A-Za-z0-9])([\"']?(?:access[\s_-]*token|id[\s_-]*token|refresh[\s_-]*token|token|client[\s_-]*secret|api[\s_-]*key|password|passwd|pwd|private[\s_-]*key|secret)\b[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}\]\r\n]+)"#
    safe = safe.replacingOccurrences(of: keyValuePattern, with: "$1[REDACTED]", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "(?i)\\bBearer\\s+[^\\s,;]+", with: "Bearer [REDACTED]", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
    if safe.count > limit { return String(safe.prefix(limit)) + " …" }
    return safe
}

private func statusSymbol(for state: String) -> String {
    switch state {
    case "healthy", "running", "checking": return "checkmark.circle.fill"
    case "uploading": return "arrow.triangle.2.circlepath"
    case "stopped": return "stop.circle.fill"
    case "backoff", "error", "failed", "unhealthy", "configuration-invalid", "not-installed", "ownership-conflict", "needs-attention": return "exclamationmark.triangle.fill"
    default: return "questionmark.circle"
    }
}

private struct TrayPresentation {
    let title: String
    let iconState: String
    let pauseTitle: String?
    let doctorTitle: String
    let needsAttention: Bool
}

private func friendlyError(_ value: String?) -> String {
    switch value?.lowercased() ?? "" {
    case "ssh-mkdir-timeout", "scp-timeout", "ssh-latest-timeout": return "SSH server timed out"
    case "ssh-mkdir-failed": return "Cannot prepare the remote folder"
    case "scp-failed": return "Image upload failed"
    case "ssh-latest-failed": return "Cannot update the latest image"
    case "image-too-large": return "Clipboard image is too large"
    case "configuration-invalid": return "Invalid settings"
    case "watcher-start-failed": return "Uploader did not start"
    case "": return "Unknown problem"
    default: return redactForDisplay(value ?? "Unknown problem", limit: 80)
    }
}

private func relativeUpload(_ value: String?, now: Date) -> String? {
    guard let value, let date = ISO8601DateFormatter().date(from: value) else { return nil }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 15 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3_600 { return "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
    return "\(seconds / 86_400)d ago"
}

private func recentActivityMessage(status: CpcvStatus?, diagnosticText: String,
                                   diagnosticReadFailed: Bool, now: Date = Date()) -> String {
    var lines: [String] = []
    if let success = status?.lastSuccessAt {
        lines.append("Last successful upload: \(relativeUpload(success, now: now) ?? success)")
    } else {
        lines.append("No successful upload has been recorded yet.")
    }
    if let latest = status?.latestPath ?? status?.lastRemotePath {
        lines.append("Latest remote image: \(redactForDisplay(latest, limit: 360))")
    }
    if let error = status?.lastError, !error.isEmpty {
        lines.append("Last error: \(friendlyError(error))")
    }
    let diagnostic = diagnosticText.trimmingCharacters(in: .whitespacesAndNewlines)
    if diagnosticReadFailed {
        lines.append("The diagnostic log could not be read. The upload summary above is still current.")
    } else if diagnostic.isEmpty {
        lines.append("No diagnostic log entries. That is normal while uploads are working.")
    } else {
        lines.append("Diagnostic activity:\n\(redactForDisplay(diagnostic, limit: 2_500))")
    }
    return lines.joined(separator: "\n\n")
}

private func trayPresentation(state rawState: String?, lastError: String?, lastSuccessAt: String?,
                              doctorOverall: String?, doctorSummary: String?, now: Date = Date()) -> TrayPresentation {
    let state = rawState?.lowercased() ?? "unknown"
    let paused = state == "stopped"
    let running = ["healthy", "running", "checking", "uploading", "backoff"].contains(state)
    let doctorFailed = doctorOverall?.lowercased() == "needs-attention"
    let needsAttention = doctorFailed || ["backoff", "error", "failed", "unhealthy", "configuration-invalid", "not-installed", "ownership-conflict", "unknown"].contains(state)

    let title: String
    let iconState: String
    if state == "uploading" {
        title = "Uploading…"
        iconState = "uploading"
    } else if doctorFailed {
        title = "Needs attention · \(redactForDisplay(doctorSummary ?? "Repair check failed", limit: 90))"
        iconState = "needs-attention"
    } else {
        switch state {
        case "healthy", "running", "checking":
            title = relativeUpload(lastSuccessAt, now: now).map { "Ready · Uploaded \($0)" } ?? "Ready · Waiting for an image"
            iconState = "healthy"
        case "backoff":
            title = "Needs attention · \(friendlyError(lastError))"
            iconState = "needs-attention"
        case "stopped":
            title = "Paused"
            iconState = "stopped"
        case "configuration-invalid":
            title = "Needs attention · Invalid settings"
            iconState = "needs-attention"
        case "not-installed":
            title = "Needs attention · Uploader not installed"
            iconState = "needs-attention"
        case "ownership-conflict":
            title = "Needs attention · Service ownership conflict"
            iconState = "needs-attention"
        case "error", "failed", "unhealthy":
            title = "Needs attention · \(friendlyError(lastError))"
            iconState = "needs-attention"
        default:
            title = "Needs attention · Status unavailable"
            iconState = "needs-attention"
        }
    }
    return TrayPresentation(title: title, iconState: iconState,
                            pauseTitle: paused ? "Resume Automatic Uploads" : (running ? "Pause Automatic Uploads" : nil),
                            doctorTitle: needsAttention ? "Repair cpcv…" : "Check & Repair…",
                            needsAttention: needsAttention)
}

private func refreshInterval(state: String?, actionInFlight: Bool) -> TimeInterval {
    actionInFlight || state?.lowercased() == "uploading" ? 1 : 4
}

private func tmuxSetupMessage(_ result: TmuxRemoteSetupResult) -> String {
    let tmuxDescription: String
    switch result.tmux {
    case "installed": tmuxDescription = "tmux is installed on the remote host."
    case "missing": tmuxDescription = "tmux is not installed on the remote host."
    default: tmuxDescription = "The remote tmux availability is unknown."
    }
    let pluginDescription: String
    switch result.plugin {
    case "installed": pluginDescription = "The cpcv-owned plugin files are installed."
    case "missing": pluginDescription = "The cpcv plugin files have not been installed yet."
    case "unverified": pluginDescription = "A cpcv plugin path exists but is not safe for cpcv to replace."
    default: pluginDescription = "The cpcv plugin file state is unknown."
    }
    let serverDescription: String
    switch result.server {
    case "running": serverDescription = "A default tmux server is running."
    case "stopped": serverDescription = "No default tmux server is running; a saved setting will apply when one starts."
    case "unavailable": serverDescription = "No tmux server can be checked until tmux is installed."
    default: serverDescription = "The default tmux server state is unknown."
    }
    let bindingDescription: String
    switch result.binding {
    case "managed": bindingDescription = "The checked cpcv binding is owned by cpcv."
    case "available": bindingDescription = "The selected binding is available for cpcv."
    case "collision": bindingDescription = result.applied
        ? "The active binding belongs to another command; cpcv files were saved but the binding needs attention."
        : "The active binding belongs to another command; no files were changed."
    case "pending": bindingDescription = "The binding will be checked when a tmux server is running."
    case "invalid": bindingDescription = "The active tmux binding configuration is invalid."
    case "unavailable": bindingDescription = "The binding cannot be checked without tmux."
    default: bindingDescription = "The binding state is unknown."
    }

    var lines = [tmuxDescription, pluginDescription, serverDescription, bindingDescription]
    switch result.secondaryBinding {
    case nil, "none": break
    case "managed": lines.append("The Windows Alt-V (tmux M-v) binding is owned by cpcv.")
    case "available": lines.append("The Windows Alt-V (tmux M-v) binding is available for cpcv.")
    case "collision": lines.append("The Windows Alt-V (tmux M-v) binding belongs to another command.")
    case "pending": lines.append("The Windows Alt-V (tmux M-v) binding will be checked when a tmux server is running.")
    case "invalid": lines.append("The Windows Alt-V (tmux M-v) binding configuration is invalid.")
    case "unavailable": lines.append("The Windows Alt-V (tmux M-v) binding cannot be checked without tmux.")
    default: lines.append("The Windows Alt-V (tmux M-v) binding state is unknown.")
    }
    if result.action == "status" {
        let scope = (result.override == "explicit" || result.override == "invalid")
            ? "This checks an explicit user-owned cpcv tmux setting; the selection above cannot take effect until that setting is managed."
            : "This checks the selection shown above; it does not infer a previously saved cpcv binding from tmux-paste.conf."
        lines.insert(scope, at: 0)
    }
    if result.override == "explicit" {
        lines.append("Your explicit @cpcv-paste-table or @cpcv-paste-key tmux option takes priority over this UI selection.")
        if result.detail == "user-override", !result.applied {
            lines.append("No cpcv remote files were changed. Manage or remove that user-owned tmux setting yourself before applying a UI selection.")
        } else if result.detail == "user-override" {
            lines.append("The cpcv remote files were saved, but manage or remove that user-owned tmux setting before applying the binding again.")
        } else if result.action == "apply" {
            lines.append("The UI selection was saved in cpcv's remote configuration, but it is not the active binding while that explicit option exists.")
        } else {
            lines.append("Manage or remove that user-owned tmux setting yourself before applying a UI selection.")
        }
    } else if result.override == "invalid" {
        if result.detail == "user-override", !result.applied {
            lines.append("No cpcv remote files were changed. An explicit cpcv tmux option is invalid and must be fixed in your user-owned tmux configuration.")
        } else if result.detail == "user-override" {
            lines.append("The cpcv remote files were saved, but an explicit cpcv tmux option is invalid and must be fixed in your user-owned tmux configuration.")
        } else {
            lines.append("An explicit cpcv tmux option is invalid and must be fixed in your user-owned tmux configuration.")
        }
    }
    if result.action == "apply" {
        switch result.runtime {
        case "reloaded": lines.append("The running default tmux server was reloaded now.")
        case "saved-next-server": lines.append("The configuration was saved for the next tmux server.")
        case "saved-reload-needed": lines.append("The configuration was saved, but the running tmux server was not reloaded.")
        case "reload-failed": lines.append("The configuration was saved, but its active binding still needs attention.")
        default: lines.append(result.ok ? "The remote configuration was saved." : "The remote configuration was not applied.")
        }
    }
    return lines.joined(separator: "\n\n")
}

private func runTraySelfTest() -> Int32 {
    let fixture = """
    Authorization: Bearer authorization-secret
    Proxy-Authorization: Basic proxy-secret
    X-Api-Key: header-key-secret
    Cookie: session=cookie-secret
    password=plain-password
    proxy_password=underscored-password
    client_secret: "oauth-client-secret"
    api_key=api-key-secret
    private-key = private-key-secret
    Bearer loose-bearer-token
    https://user:basic-url-password@example.test/path
    https://example.test/callback?token=url-query-secret
    """
    let redacted = redactForDisplay(fixture, limit: 8_192)
    let retainedSecret = ["authorization-secret", "proxy-secret", "header-key-secret", "cookie-secret", "plain-password", "underscored-password", "oauth-client-secret", "api-key-secret", "private-key-secret", "loose-bearer-token", "basic-url-password", "url-query-secret"].contains { redacted.contains($0) }
    guard !retainedSecret else {
        fputs("tray self-test redaction failed\n", stderr)
        return 1
    }
    guard statusSymbol(for: "healthy") == "checkmark.circle.fill",
          statusSymbol(for: "uploading") == "arrow.triangle.2.circlepath",
          statusSymbol(for: "backoff") == "exclamationmark.triangle.fill" else {
        fputs("tray self-test status symbols failed\n", stderr)
        return 1
    }
    let now = Date(timeIntervalSince1970: 10_000)
    let recent = ISO8601DateFormatter().string(from: now.addingTimeInterval(-120))
    let ready = trayPresentation(state: "healthy", lastError: nil, lastSuccessAt: recent,
                                 doctorOverall: "healthy", doctorSummary: nil, now: now)
    let stopped = trayPresentation(state: "stopped", lastError: nil, lastSuccessAt: nil,
                                   doctorOverall: nil, doctorSummary: nil, now: now)
    let broken = trayPresentation(state: "healthy", lastError: nil, lastSuccessAt: recent,
                                  doctorOverall: "needs-attention", doctorSummary: "SSH server is unreachable", now: now)
    let invalid = trayPresentation(state: "configuration-invalid", lastError: "configuration-invalid", lastSuccessAt: nil,
                                   doctorOverall: nil, doctorSummary: nil, now: now)
    let activityStatus = CpcvStatus(version: "1", mode: "watch", pid: 1, updatedAt: recent, state: "healthy",
                                        lastSuccessAt: recent, lastError: nil, activeChildPgid: nil, capabilities: nil,
                                        latestPath: "/home/me/clipboard-images/latest.png", lastRemotePath: nil,
                                        logFile: nil, doctorOverall: nil, doctorSummary: nil, doctorUpdatedAt: nil)
    let activity = recentActivityMessage(status: activityStatus, diagnosticText: "", diagnosticReadFailed: false, now: now)
    guard ready.title == "Ready · Uploaded 2m ago", ready.pauseTitle == "Pause Automatic Uploads", !ready.needsAttention,
          stopped.title == "Paused", stopped.pauseTitle == "Resume Automatic Uploads",
          broken.title == "Needs attention · SSH server is unreachable", broken.doctorTitle == "Repair cpcv…",
          invalid.pauseTitle == nil, invalid.needsAttention,
          activity.contains("Last successful upload: 2m ago"),
          activity.contains("No diagnostic log entries. That is normal while uploads are working."),
          refreshInterval(state: "healthy", actionInFlight: false) == 4,
          refreshInterval(state: "uploading", actionInFlight: false) == 1 else {
        fputs("tray self-test menu presentation failed\n", stderr)
        return 1
    }
    guard let settings = try? validatedSettingsForm(hostAlias: "me@work-server", remoteDir: "images/clipboard",
                                                     remoteHome: "/srv/cpcv", pollIntervalText: "5"),
          settings.hostAlias == "me@work-server", settings.remoteDir == "images/clipboard",
          settings.remoteHome == "/srv/cpcv", settings.pollIntervalSeconds == 5,
          (try? validatedSettingsForm(hostAlias: "host;unsafe", remoteDir: "images", remoteHome: "", pollIntervalText: "2")) == nil,
          (try? validatedSettingsForm(hostAlias: "host", remoteDir: "../images", remoteHome: "", pollIntervalText: "2")) == nil,
          (try? validatedSettingsForm(hostAlias: "host", remoteDir: "images", remoteHome: "/tmp/../unsafe", pollIntervalText: "2")) == nil,
          (try? validatedSettingsForm(hostAlias: "host", remoteDir: "images", remoteHome: "", pollIntervalText: "61")) == nil else {
        fputs("tray self-test settings validation failed\n", stderr)
        return 1
    }
    guard let crossPlatformBinding = try? validatedTmuxBinding(TmuxBindingDraft(mode: .crossPlatform, customKey: "")),
          let recommendedBinding = try? validatedTmuxBinding(TmuxBindingDraft(mode: .recommended, customKey: "")),
          let customBinding = try? validatedTmuxBinding(TmuxBindingDraft(mode: .custom, customKey: "7")),
          let rawBinding = try? validatedTmuxBinding(TmuxBindingDraft(mode: .rawControlV, customKey: "")),
          crossPlatformBinding.table == "root", crossPlatformBinding.key == "C-v",
          crossPlatformBinding.secondaryTable == "root", crossPlatformBinding.secondaryKey == "M-v",
          recommendedBinding.table == "prefix", recommendedBinding.key == "v",
          customBinding.table == "prefix", customBinding.key == "7",
          rawBinding.table == "root", rawBinding.key == "C-v",
          (try? validatedTmuxBinding(TmuxBindingDraft(mode: .custom, customKey: "C-v"))) == nil else {
        fputs("tray self-test tmux binding validation failed\n", stderr)
        return 1
    }
    let tmuxResult = TmuxRemoteSetupResult(ok: true, action: "apply", tmux: "installed", plugin: "installed",
                                            server: "running", binding: "managed", secondaryBinding: "none", override: "none", applied: true,
                                            runtime: "reloaded", detail: "reloaded", startupLine: tmuxStartupLine)
    let tmuxOverride = TmuxRemoteSetupResult(ok: true, action: "status", tmux: "installed", plugin: "installed",
                                              server: "running", binding: "managed", secondaryBinding: "none", override: "explicit", applied: false,
                                              runtime: "checked", detail: "checked", startupLine: tmuxStartupLine)
    let tmuxBlocked = TmuxRemoteSetupResult(ok: false, action: "apply", tmux: "installed", plugin: "installed",
                                             server: "running", binding: "managed", secondaryBinding: "none", override: "explicit", applied: false,
                                             runtime: "not-applied", detail: "user-override", startupLine: tmuxStartupLine)
    let tmuxSaved = TmuxRemoteSetupResult(ok: true, action: "apply", tmux: "installed", plugin: "installed",
                                           server: "stopped", binding: "pending", secondaryBinding: "pending", override: "none", applied: true,
                                           runtime: "saved-next-server", detail: "saved-next-server", startupLine: tmuxStartupLine)
    let tmuxDual = TmuxRemoteSetupResult(ok: true, action: "apply", tmux: "installed", plugin: "installed",
                                          server: "running", binding: "managed", secondaryBinding: "managed", override: "none", applied: true,
                                          runtime: "reloaded", detail: "reloaded", startupLine: tmuxStartupLine)
    guard tmuxSetupMessage(tmuxResult).contains("reloaded now"),
          tmuxSetupMessage(tmuxOverride).contains("takes priority"),
          tmuxSetupMessage(tmuxBlocked).contains("No cpcv remote files were changed"),
          tmuxSetupMessage(tmuxSaved).contains("next tmux server"),
          tmuxSetupMessage(tmuxDual).contains("Windows Alt-V"),
          tmuxStartupLine == "run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux" else {
        fputs("tray self-test tmux setup presentation failed\n", stderr)
        return 1
    }
    print("PASS: macOS tray redaction self-test")
    return 0
}

func isSafeRemotePath(_ value: String?) -> Bool {
    guard let value = value, value.count < 4096 else { return false }
    return value.range(of: "^(~|/)[A-Za-z0-9._/-]+$", options: .regularExpression) != nil
}

private enum SettingsFormError: LocalizedError {
    case invalidHost
    case invalidRemoteFolder
    case invalidRemoteHome
    case invalidInterval

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Enter an SSH host or alias using letters, numbers, dots, dashes, underscores, @, or : only."
        case .invalidRemoteFolder:
            return "Enter a relative folder name without spaces, an opening slash, or .. segments."
        case .invalidRemoteHome:
            return "Remote home is optional. If set, it must be an absolute path without spaces or .. segments."
        case .invalidInterval:
            return "Upload interval must be a whole number from 1 to 60 seconds."
        }
    }
}

private func hasUnsafeSettingsCharacters(_ value: String, maximumLength: Int) -> Bool {
    value.isEmpty || value.utf8.count > maximumLength || value.contains("\0") || value.contains("\n") || value.contains("\r")
}

private func validatedSettingsForm(hostAlias: String, remoteDir: String, remoteHome: String,
                                   pollIntervalText: String) throws -> SettingsForm {
    let host = hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hasUnsafeSettingsCharacters(host, maximumLength: 255),
          host.range(of: "^[A-Za-z0-9][A-Za-z0-9._@:-]*$", options: .regularExpression) != nil else {
        throw SettingsFormError.invalidHost
    }
    let folder = remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hasUnsafeSettingsCharacters(folder, maximumLength: 1_024), !folder.hasPrefix("/"),
          folder.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil,
          folder.range(of: "(^|/)\\.\\.(/|$)", options: .regularExpression) == nil else {
        throw SettingsFormError.invalidRemoteFolder
    }
    let home = remoteHome.trimmingCharacters(in: .whitespacesAndNewlines)
    guard home.isEmpty || (!hasUnsafeSettingsCharacters(home, maximumLength: 1_024) &&
                           home.range(of: "^/[A-Za-z0-9._/-]*$", options: .regularExpression) != nil &&
                           home.range(of: "(^|/)\\.\\.(/|$)", options: .regularExpression) == nil) else {
        throw SettingsFormError.invalidRemoteHome
    }
    let intervalValue = pollIntervalText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard intervalValue.range(of: "^[0-9]{1,2}$", options: .regularExpression) != nil,
          let interval = Int(intervalValue), (1...60).contains(interval) else {
        throw SettingsFormError.invalidInterval
    }
    return SettingsForm(hostAlias: host, remoteDir: folder, remoteHome: home, pollIntervalSeconds: interval)
}

private final class SettingsFormView: NSView {
    private let hostField = NSTextField()
    private let folderField = NSTextField()
    private let homeField = NSTextField()
    private let intervalField = NSTextField()
    private let intervalStepper = NSStepper()

    init(settings: SettingsForm) {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 250))
        hostField.stringValue = settings.hostAlias
        folderField.stringValue = settings.remoteDir
        homeField.stringValue = settings.remoteHome
        intervalField.stringValue = String(settings.pollIntervalSeconds)
        intervalField.alignment = .right
        intervalField.setAccessibilityLabel("Upload interval in seconds")
        intervalStepper.minValue = 1
        intervalStepper.maxValue = 60
        intervalStepper.increment = 1
        intervalStepper.integerValue = min(60, max(1, settings.pollIntervalSeconds))
        intervalStepper.target = self
        intervalStepper.action = #selector(changeInterval(_:))

        hostField.placeholderString = "e.g. work-server or me@example.com"
        folderField.placeholderString = "clipboard-images"
        homeField.placeholderString = "Leave blank for the SSH account home folder"
        hostField.setAccessibilityLabel("SSH target host")
        folderField.setAccessibilityLabel("Remote folder")
        homeField.setAccessibilityLabel("Optional remote home")

        [hostField, folderField, homeField].forEach {
            $0.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        intervalField.widthAnchor.constraint(equalToConstant: 58).isActive = true

        let introduction = NSTextField(wrappingLabelWithString: "Choose where copied images are uploaded. Changes are checked before they are saved.")
        introduction.textColor = .secondaryLabelColor
        introduction.maximumNumberOfLines = 2
        introduction.preferredMaxLayoutWidth = 450

        let intervalControl = NSStackView(views: [intervalField, intervalStepper, NSTextField(labelWithString: "seconds")])
        intervalControl.orientation = .horizontal
        intervalControl.alignment = .centerY
        intervalControl.spacing = 8

        let grid = NSGridView(views: [
            [settingsLabel("SSH target"), hostField],
            [settingsLabel("Remote folder"), folderField],
            [settingsLabel("Remote home (optional)"), homeField],
            [settingsLabel("Upload interval"), intervalControl]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 1).yPlacement = .center
        grid.row(at: 2).yPlacement = .center
        grid.row(at: 3).yPlacement = .center
        grid.columnSpacing = 14
        grid.rowSpacing = 10

        let hint = NSTextField(wrappingLabelWithString: "Leave Remote home blank to use ~/. It sets the displayed fallback path before the first upload.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 450

        let content = NSStackView(views: [introduction, grid, hint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func values() -> (hostAlias: String, remoteDir: String, remoteHome: String, pollIntervalText: String) {
        (hostField.stringValue, folderField.stringValue, homeField.stringValue, intervalField.stringValue)
    }

    @objc private func changeInterval(_ sender: NSStepper) {
        intervalField.integerValue = sender.integerValue
    }

    private func settingsLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 142).isActive = true
        return label
    }
}

private final class TmuxSetupFormView: NSView {
    private let crossPlatformButton = NSButton(radioButtonWithTitle: "Cross-platform — Ctrl-V on macOS, Alt-V on Windows", target: nil, action: nil)
    private let recommendedButton = NSButton(radioButtonWithTitle: "Portable — tmux prefix, then v", target: nil, action: nil)
    private let customButton = NSButton(radioButtonWithTitle: "Custom — tmux prefix, then", target: nil, action: nil)
    private let rawButton = NSButton(radioButtonWithTitle: "Advanced — raw Ctrl-V only", target: nil, action: nil)
    private let customKeyField = NSTextField()
    private let copyStartupButton = NSButton(title: "Copy Startup Line", target: nil, action: nil)
    private let rawWarning = NSTextField(wrappingLabelWithString: "Raw Ctrl-V replaces ordinary terminal paste in the remote tmux server. The cross-platform preset also binds Windows Alt-V (tmux M-v), because Warp can capture Ctrl-V locally before tmux sees it.")

    init(draft: TmuxBindingDraft, status: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 540, height: status == nil ? 330 : 590))
        crossPlatformButton.target = self
        crossPlatformButton.action = #selector(changeMode(_:))
        recommendedButton.target = self
        recommendedButton.action = #selector(changeMode(_:))
        customButton.target = self
        customButton.action = #selector(changeMode(_:))
        rawButton.target = self
        rawButton.action = #selector(changeMode(_:))
        crossPlatformButton.setAccessibilityLabel("Cross-platform macOS Control V and Windows Alt V binding")
        recommendedButton.setAccessibilityLabel("Portable tmux prefix then v binding")
        customButton.setAccessibilityLabel("Custom tmux prefix binding")
        rawButton.setAccessibilityLabel("Advanced raw Control V binding")

        customKeyField.stringValue = draft.customKey
        customKeyField.placeholderString = "key"
        customKeyField.alignment = .center
        customKeyField.maximumNumberOfLines = 1
        customKeyField.setAccessibilityLabel("Custom tmux prefix key")
        customKeyField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        copyStartupButton.target = self
        copyStartupButton.action = #selector(copyStartupLine)
        copyStartupButton.setAccessibilityLabel("Copy remote tmux startup line")

        switch draft.mode {
        case .crossPlatform: crossPlatformButton.state = .on
        case .recommended: recommendedButton.state = .on
        case .custom: customButton.state = .on
        case .rawControlV: rawButton.state = .on
        }

        rawWarning.textColor = .systemOrange
        rawWarning.maximumNumberOfLines = 3
        rawWarning.preferredMaxLayoutWidth = 520
        rawWarning.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let introduction = NSTextField(wrappingLabelWithString: "Choose the remote tmux path-insertion shortcut. This is separate from uploader Settings: saving changes only cpcv-owned remote plugin files and never edits ~/.tmux.conf.")
        introduction.textColor = .secondaryLabelColor
        introduction.maximumNumberOfLines = 3
        introduction.preferredMaxLayoutWidth = 520

        let customRow = NSStackView(views: [customButton, customKeyField])
        customRow.orientation = .horizontal
        customRow.alignment = .centerY
        customRow.spacing = 8

        var views: [NSView] = [introduction, crossPlatformButton, recommendedButton, customRow, rawButton, rawWarning]
        if let status, !status.isEmpty {
            let statusLabel = NSTextField(wrappingLabelWithString: status)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.maximumNumberOfLines = 12
            statusLabel.preferredMaxLayoutWidth = 520
            views.append(NSBox.separator())
            views.append(statusLabel)
        }
        let startupLabel = NSTextField(wrappingLabelWithString: "Startup line (copy this into your own remote tmux config):\n\(tmuxStartupLine)")
        startupLabel.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        startupLabel.maximumNumberOfLines = 2
        startupLabel.preferredMaxLayoutWidth = 520
        views.append(startupLabel)
        views.append(copyStartupButton)

        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateMode()
    }

    required init?(coder: NSCoder) { nil }

    func draft() -> TmuxBindingDraft {
        if crossPlatformButton.state == .on { return TmuxBindingDraft(mode: .crossPlatform, customKey: customKeyField.stringValue) }
        if customButton.state == .on { return TmuxBindingDraft(mode: .custom, customKey: customKeyField.stringValue) }
        if rawButton.state == .on { return TmuxBindingDraft(mode: .rawControlV, customKey: customKeyField.stringValue) }
        return TmuxBindingDraft(mode: .recommended, customKey: customKeyField.stringValue)
    }

    @objc private func changeMode(_ sender: NSButton) {
        crossPlatformButton.state = sender === crossPlatformButton ? .on : .off
        recommendedButton.state = sender === recommendedButton ? .on : .off
        customButton.state = sender === customButton ? .on : .off
        rawButton.state = sender === rawButton ? .on : .off
        updateMode()
    }

    private func updateMode() {
        customKeyField.isEnabled = customButton.state == .on
        rawWarning.isHidden = rawButton.state != .on && crossPlatformButton.state != .on
    }

    @objc private func copyStartupLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tmuxStartupLine, forType: .string)
        copyStartupButton.title = "Startup Line Copied"
        copyStartupButton.isEnabled = false
    }
}

@main
final class CpcvTray: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controlPath = ""
    private var tmuxHelperPath = ""
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusMenuItem: NSMenuItem!
    private var copyLatestMenuItem: NSMenuItem!
    private var pauseMenuItem: NSMenuItem!
    private var doctorMenuItem: NSMenuItem!
    private var settingsMenuItem: NSMenuItem!
    private var tmuxSetupMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!
    private var openLogMenuItem: NSMenuItem!
    private var statusDetailsMenuItem: NSMenuItem!
    private var timer: Timer?
    private var currentStatus: CpcvStatus?
    private var currentSummary = "Checking…"
    private var statusRefreshInFlight = false
    private var doctorInFlight = false
    private var serviceActionInFlight = false
    private var settingsInFlight = false
    private var tmuxSetupInFlight = false
    private var activityIndicator: NSProgressIndicator?

    static func main() {
        if CommandLine.arguments.dropFirst().first == "self-test" {
            exit(runTraySelfTest())
        }
        let app = NSApplication.shared
        let delegate = CpcvTray()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        guard let rootIndex = arguments.firstIndex(of: "--root"), rootIndex + 1 < arguments.count else {
            showFatalConfiguration("The launcher did not provide the cpcv checkout path.")
            return
        }
        let root = arguments[rootIndex + 1]
        controlPath = URL(fileURLWithPath: root).appendingPathComponent("macos/cpcv-macos-ctl.sh").path
        tmuxHelperPath = URL(fileURLWithPath: root).appendingPathComponent("macos/deploy-remote-tmux-cpcv-plugin.sh").path
        guard FileManager.default.isExecutableFile(atPath: controlPath) else {
            showFatalConfiguration("Cannot find an executable macOS controller at \(controlPath). Install the macOS uploader first.")
            return
        }
        buildMenu()
        refreshStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        statusItem.button?.image = statusImage(for: "unknown")
        statusItem.button?.toolTip = "cpcv: checking local service"
        if let button = statusItem.button {
            let indicator = NSProgressIndicator(frame: NSRect(x: 4, y: 3, width: 16, height: 16))
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isIndeterminate = true
            indicator.isDisplayedWhenStopped = false
            indicator.isHidden = true
            indicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            button.addSubview(indicator)
            activityIndicator = indicator
        }

        menu = NSMenu()
        menu.delegate = self
        statusMenuItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        copyLatestMenuItem = NSMenuItem(title: "Copy Last Image Path", action: #selector(copyLatestPath), keyEquivalent: "")
        copyLatestMenuItem.target = self
        copyLatestMenuItem.image = menuImage("doc.on.doc", description: "Copy")
        copyLatestMenuItem.isEnabled = false
        menu.addItem(copyLatestMenuItem)

        pauseMenuItem = NSMenuItem(title: "Pause Automatic Uploads", action: #selector(toggleAutomaticUploads), keyEquivalent: "")
        pauseMenuItem.target = self
        pauseMenuItem.image = menuImage("pause.circle", description: "Pause")
        menu.addItem(pauseMenuItem)
        menu.addItem(.separator())

        doctorMenuItem = NSMenuItem(title: "Check & Repair…", action: #selector(runDoctorAction), keyEquivalent: "")
        doctorMenuItem.target = self
        doctorMenuItem.image = menuImage("wrench", description: "Repair")
        menu.addItem(doctorMenuItem)

        settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        settingsMenuItem.image = menuImage("gearshape", description: "Settings")
        menu.addItem(settingsMenuItem)

        tmuxSetupMenuItem = NSMenuItem(title: "Configure tmux path insertion…", action: #selector(openTmuxSetup), keyEquivalent: "")
        tmuxSetupMenuItem.target = self
        tmuxSetupMenuItem.image = menuImage("keyboard", description: "Tmux path insertion")
        tmuxSetupMenuItem.isEnabled = FileManager.default.isExecutableFile(atPath: tmuxHelperPath)
        menu.addItem(tmuxSetupMenuItem)

        let troubleshootingItem = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        troubleshootingItem.image = menuImage("ellipsis.circle", description: "Troubleshooting")
        let troubleshootingMenu = NSMenu(title: "Troubleshooting")
        restartMenuItem = NSMenuItem(title: "Restart Uploader", action: #selector(restartService), keyEquivalent: "")
        restartMenuItem.target = self
        restartMenuItem.image = menuImage("arrow.clockwise", description: "Restart")
        troubleshootingMenu.addItem(restartMenuItem)

        openLogMenuItem = NSMenuItem(title: "View Recent Activity…", action: #selector(viewLog), keyEquivalent: "")
        openLogMenuItem.target = self
        openLogMenuItem.image = menuImage("doc.text.magnifyingglass", description: "Activity")
        troubleshootingMenu.addItem(openLogMenuItem)

        statusDetailsMenuItem = NSMenuItem(title: "Status Details…", action: #selector(showStatus), keyEquivalent: "")
        statusDetailsMenuItem.target = self
        statusDetailsMenuItem.image = menuImage("info.circle", description: "Status")
        troubleshootingMenu.addItem(statusDetailsMenuItem)
        troubleshootingItem.submenu = troubleshootingMenu
        menu.addItem(troubleshootingItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Menu Bar App", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refreshStatus() }

    private func scheduleNextRefresh(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in self?.refreshStatus() }
    }

    private func refreshStatus() {
        guard !controlPath.isEmpty, !statusRefreshInFlight else { return }
        statusRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = runControl(controlPath: self.controlPath, arguments: ["status"])
            let status: CpcvStatus?
            if !result.timedOut, result.exitCode == 0, let data = result.stdout.data(using: .utf8) {
                status = try? JSONDecoder().decode(CpcvStatus.self, from: data)
            } else {
                status = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.statusRefreshInFlight = false
                self.apply(status: status, result: result)
                self.scheduleNextRefresh(after: refreshInterval(state: status?.state,
                                                                actionInFlight: self.doctorInFlight || self.serviceActionInFlight || self.settingsInFlight))
            }
        }
    }

    private func apply(status: CpcvStatus?, result: ControlResult) {
        currentStatus = status
        let state = status?.state?.lowercased() ?? "unknown"
        let presentation: TrayPresentation
        if let status {
            presentation = trayPresentation(state: status.state, lastError: status.lastError,
                                            lastSuccessAt: status.lastSuccessAt,
                                            doctorOverall: status.doctorOverall,
                                            doctorSummary: status.doctorSummary)
        } else if result.timedOut {
            presentation = TrayPresentation(title: "Needs attention · Status check timed out",
                                            iconState: "needs-attention", pauseTitle: nil,
                                            doctorTitle: "Repair cpcv…", needsAttention: true)
        } else {
            presentation = TrayPresentation(title: "Needs attention · Status unavailable",
                                            iconState: "needs-attention", pauseTitle: nil,
                                            doctorTitle: "Repair cpcv…", needsAttention: true)
        }
        let busy = doctorInFlight || serviceActionInFlight || settingsInFlight
        currentSummary = doctorInFlight ? "Checking and repairing…" : (serviceActionInFlight ? "Updating automatic uploads…" : (settingsInFlight ? "Updating settings…" : presentation.title))
        updateIndicator(state: busy ? "uploading" : presentation.iconState, summary: currentSummary)

        pauseMenuItem.title = presentation.pauseTitle ?? "Automatic Uploads Unavailable"
        pauseMenuItem.image = menuImage(state == "stopped" ? "play.circle" : "pause.circle",
                                        description: state == "stopped" ? "Resume" : "Pause")
        pauseMenuItem.isHidden = presentation.pauseTitle == nil
        pauseMenuItem.isEnabled = !busy && ((state == "stopped" && supports("start")) || (state != "stopped" && supports("stop")))
        doctorMenuItem.title = presentation.doctorTitle
        doctorMenuItem.isEnabled = (status == nil || supports("doctor")) && !busy
        settingsMenuItem.isEnabled = (status == nil || supports("settings-read")) && !busy
        tmuxSetupMenuItem.isEnabled = FileManager.default.isExecutableFile(atPath: tmuxHelperPath) && !tmuxSetupInFlight
        restartMenuItem.isEnabled = supports("restart") && !busy
        openLogMenuItem.isEnabled = supports("logs")
        statusDetailsMenuItem.isEnabled = status != nil
        let latest = status?.latestPath ?? status?.lastRemotePath
        copyLatestMenuItem.isEnabled = isSafeRemotePath(latest) && !busy
    }

    private func supports(_ action: String) -> Bool {
        guard let status = currentStatus else { return false }
        // Older controllers predate capabilities but support the conservative
        // service/status set. New optional actions must opt in explicitly.
        if let capabilities = status.capabilities { return capabilities.contains(action) }
        return ["status", "start", "stop", "restart", "logs"].contains(action)
    }

    private func menuImage(_ symbol: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: description)?.withSymbolConfiguration(configuration)
    }

    private func statusImage(for state: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: statusSymbol(for: state), accessibilityDescription: "cpcv \(state)")?.withSymbolConfiguration(configuration)
    }

    private func updateIndicator(state: String, summary: String) {
        statusMenuItem.title = summary
        statusMenuItem.image = statusImage(for: state)
        statusItem.button?.toolTip = "cpcv: \(summary)"
        statusItem.button?.setAccessibilityLabel("cpcv: \(summary)")
        if state == "uploading", let activityIndicator = activityIndicator {
            statusItem.button?.image = nil
            activityIndicator.isHidden = false
            activityIndicator.startAnimation(nil)
        } else {
            activityIndicator?.stopAnimation(nil)
            activityIndicator?.isHidden = true
            statusItem.button?.image = statusImage(for: state)
        }
    }

    private func invoke(_ action: String, busySummary: String? = nil, timeout: TimeInterval = controlTimeout) {
        guard !controlPath.isEmpty, !settingsInFlight else { return }
        if let busySummary {
            serviceActionInFlight = true
            currentSummary = busySummary
            updateIndicator(state: "uploading", summary: currentSummary)
            copyLatestMenuItem.isEnabled = false
            pauseMenuItem.isEnabled = false
            doctorMenuItem.isEnabled = false
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = runControl(controlPath: self.controlPath, arguments: [action], timeout: timeout)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if busySummary != nil { self.serviceActionInFlight = false }
                if result.timedOut || result.exitCode != 0 {
                    let detail = result.timedOut ? "The local control command timed out." : redactForDisplay(result.stderr.isEmpty ? result.stdout : result.stderr)
                    self.showAlert(title: "cpcv action failed", message: detail, style: .warning)
                }
                self.refreshStatus()
            }
        }
    }

    private func doctorCheckName(_ id: String) -> String {
        switch id {
        case "configuration": return "Settings"
        case "local-service": return "Automatic uploads"
        case "ssh": return "SSH server"
        case "clock-sync": return "Clock synchronization"
        case "remote-directory": return "Remote folder"
        case "codex-bridge": return "Codex image paste"
        default: return "cpcv"
        }
    }

    private func showDoctorReport(_ report: DoctorReport) {
        let labels = ["pass": "OK", "repaired": "Repaired", "failed": "Problem", "skipped": "Skipped"]
        var lines = [redactForDisplay(report.summary, limit: 240), ""]
        for check in report.checks {
            let label = labels[check.status] ?? check.status.capitalized
            lines.append("\(doctorCheckName(check.id)): \(label) — \(redactForDisplay(check.message, limit: 180))")
        }
        let title: String
        let style: NSAlert.Style
        switch report.overall {
        case "healthy": title = "cpcv is ready"; style = .informational
        case "repaired": title = "cpcv repaired"; style = .informational
        default: title = "cpcv needs attention"; style = .warning
        }
        showAlert(title: title, message: lines.joined(separator: "\n"), style: style)
    }

    @objc private func runDoctorAction() {
        guard !controlPath.isEmpty, !doctorInFlight, !settingsInFlight else { return }
        doctorInFlight = true
        currentSummary = "Checking and repairing…"
        updateIndicator(state: "uploading", summary: currentSummary)
        copyLatestMenuItem.isEnabled = false
        pauseMenuItem.isEnabled = false
        doctorMenuItem.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = runControl(controlPath: self.controlPath, arguments: ["doctor"], timeout: doctorControlTimeout)
            let report: DoctorReport?
            if let data = result.stdout.data(using: .utf8) {
                report = try? JSONDecoder().decode(DoctorReport.self, from: data)
            } else {
                report = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.doctorInFlight = false
                if let report {
                    self.showDoctorReport(report)
                } else {
                    let detail = result.timedOut ? "The repair check timed out." : redactForDisplay(result.stderr.isEmpty ? result.stdout : result.stderr)
                    self.showAlert(title: "cpcv repair failed", message: detail.isEmpty ? "No diagnostic report was returned." : detail, style: .warning)
                }
                self.refreshStatus()
            }
        }
    }

    @objc private func showStatus() {
        var lines = ["Status: \(currentSummary)"]
        if let status = currentStatus {
            if let updated = status.updatedAt { lines.append("Updated: \(updated)") }
            if let success = status.lastSuccessAt { lines.append("Last successful upload: \(success)") }
            if let latest = status.latestPath ?? status.lastRemotePath { lines.append("Latest upload path: \(latest)") }
            if let child = status.activeChildPgid { lines.append("Active child process group: \(child)") }
            if let error = status.lastError, !error.isEmpty { lines.append("Last error: \(redactForDisplay(error))") }
            if let doctor = status.doctorSummary, let updated = status.doctorUpdatedAt {
                lines.append("Last repair check: \(updated) — \(redactForDisplay(doctor))")
            }
        }
        showAlert(title: "cpcv status", message: lines.joined(separator: "\n"), style: .informational)
    }

    @objc private func toggleAutomaticUploads() {
        let stopped = currentStatus?.state?.lowercased() == "stopped"
        invoke(stopped ? "start" : "stop", busySummary: stopped ? "Resuming automatic uploads…" : "Pausing automatic uploads…")
    }

    @objc private func restartService() { invoke("restart", busySummary: "Restarting uploader…") }

    @objc private func copyLatestPath() {
        let latest = currentStatus?.latestPath ?? currentStatus?.lastRemotePath
        guard let latest = latest, isSafeRemotePath(latest) else {
            showAlert(title: "cpcv", message: "There is no valid uploaded path to copy yet.", style: .warning)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latest, forType: .string)
    }

    @objc private func viewLog() {
        // `logs` is deliberately a controller action rather than assuming a
        // default DataRoot. It supports custom config locations too.
        guard !controlPath.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = runControl(controlPath: self.controlPath, arguments: ["logs"])
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let text = result.stdout.isEmpty ? result.stderr : result.stdout
                let message = recentActivityMessage(status: self.currentStatus, diagnosticText: text,
                                                    diagnosticReadFailed: result.timedOut || result.exitCode != 0)
                self.showAlert(title: "cpcv recent activity", message: message, style: .informational)
            }
        }
    }

    private func beginSettingsOperation(_ summary: String) {
        settingsInFlight = true
        currentSummary = summary
        updateIndicator(state: "uploading", summary: summary)
        copyLatestMenuItem.isEnabled = false
        pauseMenuItem.isEnabled = false
        doctorMenuItem.isEnabled = false
        settingsMenuItem.isEnabled = false
    }

    private func showSettingsReadFailure(_ result: ControlResult) {
        let alert = NSAlert()
        alert.messageText = "Unable to open Settings"
        let detail = result.timedOut
            ? "Reading local settings timed out."
            : redactForDisplay(result.stderr.isEmpty ? result.stdout : result.stderr, limit: 400)
        alert.informativeText = detail.isEmpty
            ? "The local settings file could not be read."
            : detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Advanced JSON…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { invoke("config") }
    }

    private func presentSettings(_ initial: SettingsForm) {
        var values = initial
        while true {
            let form = SettingsFormView(settings: values)
            let alert = NSAlert()
            alert.messageText = "cpcv Settings"
            alert.informativeText = "Use Advanced JSON only for uncommon settings not shown here."
            alert.alertStyle = .informational
            alert.accessoryView = form
            alert.addButton(withTitle: "Save Settings")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Advanced JSON…")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let draft = form.values()
                values = SettingsForm(hostAlias: draft.hostAlias, remoteDir: draft.remoteDir,
                                      remoteHome: draft.remoteHome,
                                      pollIntervalSeconds: Int(draft.pollIntervalText) ?? values.pollIntervalSeconds)
                do {
                    saveSettings(try validatedSettingsForm(hostAlias: draft.hostAlias, remoteDir: draft.remoteDir,
                                                           remoteHome: draft.remoteHome,
                                                           pollIntervalText: draft.pollIntervalText))
                    return
                } catch {
                    showAlert(title: "Check your settings", message: error.localizedDescription, style: .warning)
                    continue
                }
            }
            if response == .alertThirdButtonReturn { invoke("config") }
            return
        }
    }

    private func saveSettings(_ settings: SettingsForm) {
        guard !controlPath.isEmpty, !settingsInFlight else { return }
        beginSettingsOperation("Saving settings…")
        let arguments = ["settings-save", "--host-alias", settings.hostAlias,
                         "--remote-dir", settings.remoteDir, "--remote-home", settings.remoteHome,
                         "--poll-interval-seconds", String(settings.pollIntervalSeconds)]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = runControl(controlPath: self.controlPath, arguments: arguments, timeout: settingsControlTimeout)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.settingsInFlight = false
                if result.timedOut || result.exitCode != 0 {
                    let detail = result.timedOut
                        ? "Saving local settings timed out. No changes were confirmed."
                        : redactForDisplay(result.stderr.isEmpty ? result.stdout : result.stderr, limit: 400)
                    self.showAlert(title: "Settings were not saved", message: detail.isEmpty ? "Please try again." : detail, style: .warning)
                } else {
                    let detail = redactForDisplay(result.stdout, limit: 260)
                    self.showAlert(title: "Settings saved", message: detail.isEmpty ? "Automatic uploads will use the new settings." : detail, style: .informational)
                }
                self.refreshStatus()
            }
        }
    }

    @objc private func openSettings() {
        guard !controlPath.isEmpty, !settingsInFlight, !doctorInFlight, !serviceActionInFlight else { return }
        beginSettingsOperation("Loading settings…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = runControl(controlPath: self.controlPath, arguments: ["settings-read"], timeout: settingsControlTimeout)
            let settings: SettingsForm?
            if !result.timedOut, result.exitCode == 0, let data = result.stdout.data(using: .utf8) {
                settings = try? JSONDecoder().decode(SettingsForm.self, from: data)
            } else {
                settings = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.settingsInFlight = false
                if let settings {
                    self.presentSettings(settings)
                } else {
                    self.showSettingsReadFailure(result)
                }
                self.refreshStatus()
            }
        }
    }

    @objc private func openTmuxSetup() {
        guard !tmuxSetupInFlight else { return }
        guard FileManager.default.isExecutableFile(atPath: tmuxHelperPath) else {
            showAlert(title: "Tmux setup is unavailable", message: "The cpcv remote tmux helper is missing. Reinstall or update this cpcv checkout.", style: .warning)
            return
        }
        presentTmuxSetup(draft: TmuxBindingDraft(mode: .crossPlatform, customKey: "v"), status: nil)
    }

    private func presentTmuxSetup(draft: TmuxBindingDraft, status: String?) {
        guard !tmuxSetupInFlight else { return }
        let form = TmuxSetupFormView(draft: draft, status: status)
        let alert = NSAlert()
        alert.messageText = "cpcv tmux path insertion"
        alert.informativeText = "Check the remote setup first, then explicitly install and apply your selected binding."
        alert.alertStyle = .informational
        alert.accessoryView = form
        alert.addButton(withTitle: "Check Remote Setup")
        alert.addButton(withTitle: "Install / Apply")
        alert.addButton(withTitle: "Close")
        let response = alert.runModal()
        let nextDraft = form.draft()
        if response == .alertFirstButtonReturn {
            beginTmuxSetup(action: "status", draft: nextDraft)
        } else if response == .alertSecondButtonReturn {
            beginTmuxSetup(action: "apply", draft: nextDraft)
        }
    }

    private func beginTmuxSetup(action: String, draft: TmuxBindingDraft) {
        let binding: TmuxBinding
        do {
            binding = try validatedTmuxBinding(draft)
        } catch {
            showAlert(title: "Check the tmux binding", message: error.localizedDescription, style: .warning)
            presentTmuxSetup(draft: draft, status: nil)
            return
        }
        guard !controlPath.isEmpty, FileManager.default.isExecutableFile(atPath: tmuxHelperPath) else {
            showAlert(title: "Tmux setup is unavailable", message: "The local cpcv control or remote tmux helper is unavailable.", style: .warning)
            return
        }

        tmuxSetupInFlight = true
        tmuxSetupMenuItem.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let settingsResult = runControl(controlPath: self.controlPath, arguments: ["settings-read"], timeout: settingsControlTimeout)
            let settings: SettingsForm?
            if !settingsResult.timedOut, settingsResult.exitCode == 0, let data = settingsResult.stdout.data(using: .utf8) {
                settings = try? JSONDecoder().decode(SettingsForm.self, from: data)
            } else {
                settings = nil
            }
            guard let settings else {
                let detail = settingsResult.timedOut
                    ? "Reading the local SSH settings timed out."
                    : redactForDisplay(settingsResult.stderr.isEmpty ? settingsResult.stdout : settingsResult.stderr, limit: 400)
                DispatchQueue.main.async { [weak self] in
                    self?.finishTmuxSetupFailure(draft: draft, title: "Unable to read remote settings",
                                                 message: detail.isEmpty ? "The remote tmux setup needs valid local SSH settings." : detail)
                }
                return
            }

            var arguments = ["--host", settings.hostAlias, "--remote-dir", settings.remoteDir,
                             "--paste-table", binding.table, "--paste-key", binding.key,
                             "--action", action, "--format", "json"]
            if let secondaryTable = binding.secondaryTable, let secondaryKey = binding.secondaryKey {
                arguments.append(contentsOf: ["--paste-secondary-table", secondaryTable,
                                               "--paste-secondary-key", secondaryKey])
            }
            if action == "apply" { arguments.append("--reload-default-server") }
            let result = runControl(controlPath: self.tmuxHelperPath, arguments: arguments, timeout: tmuxSetupControlTimeout)
            let setup: TmuxRemoteSetupResult?
            if let data = result.stdout.data(using: .utf8) {
                setup = try? JSONDecoder().decode(TmuxRemoteSetupResult.self, from: data)
            } else {
                setup = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let setup, setup.action == action else {
                    let detail = result.timedOut
                        ? "The remote tmux operation timed out. No successful result was confirmed."
                        : redactForDisplay(result.stderr.isEmpty ? result.stdout : result.stderr, limit: 500)
                    self.finishTmuxSetupFailure(draft: draft, title: "Remote tmux setup failed",
                                                message: detail.isEmpty ? "No valid setup result was returned." : detail)
                    return
                }
                self.tmuxSetupInFlight = false
                self.tmuxSetupMenuItem.isEnabled = FileManager.default.isExecutableFile(atPath: self.tmuxHelperPath)
                self.presentTmuxSetup(draft: draft, status: tmuxSetupMessage(setup))
            }
        }
    }

    private func finishTmuxSetupFailure(draft: TmuxBindingDraft, title: String, message: String) {
        tmuxSetupInFlight = false
        tmuxSetupMenuItem.isEnabled = FileManager.default.isExecutableFile(atPath: tmuxHelperPath)
        showAlert(title: title, message: message, style: .warning)
        presentTmuxSetup(draft: draft, status: nil)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func showFatalConfiguration(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "cpcv tray could not start"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
