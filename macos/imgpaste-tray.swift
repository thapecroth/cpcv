// Native macOS menu-bar companion for imgpaste.
//
// It is intentionally separate from the uploader.  The only integration
// boundary is imgpaste-macos-ctl.sh, which returns bounded JSON for `status`
// and performs named local actions.  No status value is ever passed to a
// shell: Process receives a fixed executable and an argument array.

import AppKit
import Darwin
import Foundation

private let maximumControlOutput = 65_536
private let controlTimeout: TimeInterval = 8
private let doctorControlTimeout: TimeInterval = 3_300
private let settingsControlTimeout: TimeInterval = 20

struct ImgPasteStatus: Decodable {
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
                            doctorTitle: needsAttention ? "Repair imgpaste…" : "Check & Repair…",
                            needsAttention: needsAttention)
}

private func refreshInterval(state: String?, actionInFlight: Bool) -> TimeInterval {
    actionInFlight || state?.lowercased() == "uploading" ? 1 : 4
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
    guard ready.title == "Ready · Uploaded 2m ago", ready.pauseTitle == "Pause Automatic Uploads", !ready.needsAttention,
          stopped.title == "Paused", stopped.pauseTitle == "Resume Automatic Uploads",
          broken.title == "Needs attention · SSH server is unreachable", broken.doctorTitle == "Repair imgpaste…",
          invalid.pauseTitle == nil, invalid.needsAttention,
          refreshInterval(state: "healthy", actionInFlight: false) == 4,
          refreshInterval(state: "uploading", actionInFlight: false) == 1 else {
        fputs("tray self-test menu presentation failed\n", stderr)
        return 1
    }
    guard let settings = try? validatedSettingsForm(hostAlias: "me@work-server", remoteDir: "images/clipboard",
                                                     remoteHome: "/srv/imgpaste", pollIntervalText: "5"),
          settings.hostAlias == "me@work-server", settings.remoteDir == "images/clipboard",
          settings.remoteHome == "/srv/imgpaste", settings.pollIntervalSeconds == 5,
          (try? validatedSettingsForm(hostAlias: "host;unsafe", remoteDir: "images", remoteHome: "", pollIntervalText: "2")) == nil,
          (try? validatedSettingsForm(hostAlias: "host", remoteDir: "../images", remoteHome: "", pollIntervalText: "2")) == nil,
          (try? validatedSettingsForm(hostAlias: "host", remoteDir: "images", remoteHome: "/tmp/../unsafe", pollIntervalText: "2")) == nil,
          (try? validatedSettingsForm(hostAlias: "host", remoteDir: "images", remoteHome: "", pollIntervalText: "61")) == nil else {
        fputs("tray self-test settings validation failed\n", stderr)
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

@main
final class ImgPasteTray: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controlPath = ""
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusMenuItem: NSMenuItem!
    private var copyLatestMenuItem: NSMenuItem!
    private var pauseMenuItem: NSMenuItem!
    private var doctorMenuItem: NSMenuItem!
    private var settingsMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!
    private var openLogMenuItem: NSMenuItem!
    private var statusDetailsMenuItem: NSMenuItem!
    private var timer: Timer?
    private var currentStatus: ImgPasteStatus?
    private var currentSummary = "Checking…"
    private var statusRefreshInFlight = false
    private var doctorInFlight = false
    private var serviceActionInFlight = false
    private var settingsInFlight = false
    private var activityIndicator: NSProgressIndicator?

    static func main() {
        if CommandLine.arguments.dropFirst().first == "self-test" {
            exit(runTraySelfTest())
        }
        let app = NSApplication.shared
        let delegate = ImgPasteTray()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        guard let rootIndex = arguments.firstIndex(of: "--root"), rootIndex + 1 < arguments.count else {
            showFatalConfiguration("The launcher did not provide the imgpaste checkout path.")
            return
        }
        let root = arguments[rootIndex + 1]
        controlPath = URL(fileURLWithPath: root).appendingPathComponent("macos/imgpaste-macos-ctl.sh").path
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
        statusItem.button?.toolTip = "imgpaste: checking local service"
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
            let status: ImgPasteStatus?
            if !result.timedOut, result.exitCode == 0, let data = result.stdout.data(using: .utf8) {
                status = try? JSONDecoder().decode(ImgPasteStatus.self, from: data)
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

    private func apply(status: ImgPasteStatus?, result: ControlResult) {
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
                                            doctorTitle: "Repair imgpaste…", needsAttention: true)
        } else {
            presentation = TrayPresentation(title: "Needs attention · Status unavailable",
                                            iconState: "needs-attention", pauseTitle: nil,
                                            doctorTitle: "Repair imgpaste…", needsAttention: true)
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
        return NSImage(systemSymbolName: statusSymbol(for: state), accessibilityDescription: "imgpaste \(state)")?.withSymbolConfiguration(configuration)
    }

    private func updateIndicator(state: String, summary: String) {
        statusMenuItem.title = summary
        statusMenuItem.image = statusImage(for: state)
        statusItem.button?.toolTip = "imgpaste: \(summary)"
        statusItem.button?.setAccessibilityLabel("imgpaste: \(summary)")
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
                    self.showAlert(title: "imgpaste action failed", message: detail, style: .warning)
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
        case "remote-directory": return "Remote folder"
        case "codex-bridge": return "Codex image paste"
        default: return "imgpaste"
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
        case "healthy": title = "imgpaste is ready"; style = .informational
        case "repaired": title = "imgpaste repaired"; style = .informational
        default: title = "imgpaste needs attention"; style = .warning
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
                    self.showAlert(title: "imgpaste repair failed", message: detail.isEmpty ? "No diagnostic report was returned." : detail, style: .warning)
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
        showAlert(title: "imgpaste status", message: lines.joined(separator: "\n"), style: .informational)
    }

    @objc private func toggleAutomaticUploads() {
        let stopped = currentStatus?.state?.lowercased() == "stopped"
        invoke(stopped ? "start" : "stop", busySummary: stopped ? "Resuming automatic uploads…" : "Pausing automatic uploads…")
    }

    @objc private func restartService() { invoke("restart", busySummary: "Restarting uploader…") }

    @objc private func copyLatestPath() {
        let latest = currentStatus?.latestPath ?? currentStatus?.lastRemotePath
        guard let latest = latest, isSafeRemotePath(latest) else {
            showAlert(title: "imgpaste", message: "There is no valid uploaded path to copy yet.", style: .warning)
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
                let text = redactForDisplay(result.stdout.isEmpty ? result.stderr : result.stdout, limit: 3_500)
                self.showAlert(title: "imgpaste recent activity", message: text.isEmpty ? "No local log entries are available." : text, style: .informational)
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
            alert.messageText = "imgpaste Settings"
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

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func showFatalConfiguration(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "imgpaste tray could not start"
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
