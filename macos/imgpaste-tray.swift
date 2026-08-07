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
// A native upload has three independently hard-bounded SSH/SCP operations.
// Keep the tray's parent timeout above their maximum so the UI never aborts a
// healthy upload midway through its own reliable child-process cleanup.
private let uploadControlTimeout: TimeInterval = 1_805

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
    print("PASS: macOS tray redaction self-test")
    return 0
}

func isSafeRemotePath(_ value: String?) -> Bool {
    guard let value = value, value.count < 4096 else { return false }
    return value.range(of: "^(~|/)[A-Za-z0-9._/-]+$", options: .regularExpression) != nil
}

@main
final class ImgPasteTray: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controlPath = ""
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusMenuItem: NSMenuItem!
    private var uploadMenuItem: NSMenuItem!
    private var copyLatestMenuItem: NSMenuItem!
    private var startMenuItem: NSMenuItem!
    private var stopMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!
    private var openLogMenuItem: NSMenuItem!
    private var configurationMenuItem: NSMenuItem!
    private var timer: Timer?
    private var currentStatus: ImgPasteStatus?
    private var currentSummary = "Checking local service…"

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
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = statusImage(for: "unknown")
        statusItem.button?.toolTip = "imgpaste: checking local service"

        menu = NSMenu()
        menu.delegate = self
        statusMenuItem = NSMenuItem(title: "imgpaste: checking…", action: #selector(showStatus), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        uploadMenuItem = NSMenuItem(title: "Upload clipboard image now", action: #selector(uploadNow), keyEquivalent: "")
        uploadMenuItem.target = self
        menu.addItem(uploadMenuItem)
        copyLatestMenuItem = NSMenuItem(title: "Copy latest upload path", action: #selector(copyLatestPath), keyEquivalent: "")
        copyLatestMenuItem.target = self
        copyLatestMenuItem.isEnabled = false
        menu.addItem(copyLatestMenuItem)
        menu.addItem(.separator())

        startMenuItem = NSMenuItem(title: "Start service", action: #selector(startService), keyEquivalent: "")
        startMenuItem.target = self
        stopMenuItem = NSMenuItem(title: "Stop service", action: #selector(stopService), keyEquivalent: "")
        stopMenuItem.target = self
        restartMenuItem = NSMenuItem(title: "Restart service", action: #selector(restartService), keyEquivalent: "")
        restartMenuItem.target = self
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(restartMenuItem)
        menu.addItem(.separator())

        openLogMenuItem = NSMenuItem(title: "View recent log", action: #selector(viewLog), keyEquivalent: "")
        openLogMenuItem.target = self
        menu.addItem(openLogMenuItem)
        configurationMenuItem = NSMenuItem(title: "Open configuration", action: #selector(openConfiguration), keyEquivalent: "")
        configurationMenuItem.target = self
        configurationMenuItem.isEnabled = false
        menu.addItem(configurationMenuItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit imgpaste tray", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refreshStatus() }

    private func refreshStatus() {
        guard !controlPath.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = runControl(controlPath: self.controlPath, arguments: ["status"])
            let status: ImgPasteStatus?
            if !result.timedOut, result.exitCode == 0, let data = result.stdout.data(using: .utf8) {
                status = try? JSONDecoder().decode(ImgPasteStatus.self, from: data)
            } else {
                status = nil
            }
            DispatchQueue.main.async { [weak self] in self?.apply(status: status, result: result) }
        }
    }

    private func apply(status: ImgPasteStatus?, result: ControlResult) {
        currentStatus = status
        let state = status?.state?.lowercased() ?? "unknown"
        if let status = status {
            currentSummary = summary(for: status)
        } else if result.timedOut {
            currentSummary = "Status command timed out"
        } else {
            currentSummary = "Status unavailable: \(redactForDisplay(result.stderr.isEmpty ? result.stdout : result.stderr, limit: 160))"
        }
        statusMenuItem.title = "imgpaste: \(currentSummary)"
        statusItem.button?.image = statusImage(for: state)
        statusItem.button?.toolTip = "imgpaste: \(currentSummary)"

        let configured = !state.contains("config") && !state.contains("invalid")
        let running = state == "healthy" || state == "running" || state == "uploading" || state == "checking" || state == "backoff"
        uploadMenuItem.isEnabled = configured && supports("upload")
        startMenuItem.isEnabled = configured && supports("start") && !running
        stopMenuItem.isEnabled = supports("stop") && running
        restartMenuItem.isEnabled = configured && supports("restart")
        openLogMenuItem.isEnabled = supports("logs")
        configurationMenuItem.isEnabled = configured && supports("config")
        let latest = status?.latestPath ?? status?.lastRemotePath
        copyLatestMenuItem.isEnabled = isSafeRemotePath(latest)
    }

    private func summary(for status: ImgPasteStatus) -> String {
        let state = status.state?.replacingOccurrences(of: "_", with: " ") ?? "unknown"
        if let error = status.lastError, !error.isEmpty, status.state?.lowercased() != "healthy" {
            return "\(state): \(redactForDisplay(error, limit: 120))"
        }
        if let pid = status.pid { return "\(state) (PID \(pid))" }
        return state
    }

    private func supports(_ action: String) -> Bool {
        guard let status = currentStatus else { return false }
        // Older controllers predate capabilities but support the conservative
        // service/status set. New optional actions must opt in explicitly.
        if let capabilities = status.capabilities { return capabilities.contains(action) }
        return ["status", "start", "stop", "restart", "logs"].contains(action)
    }

    private func statusImage(for state: String) -> NSImage? {
        let symbol: String
        switch state {
        case "healthy", "running", "uploading", "checking": symbol = "checkmark.circle.fill"
        case "stopped": symbol = "stop.circle.fill"
        case "backoff", "error", "failed", "unhealthy", "configuration-invalid": symbol = "exclamationmark.triangle.fill"
        default: symbol = "questionmark.circle"
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: "imgpaste \(state)")?.withSymbolConfiguration(configuration)
    }

    private func invoke(_ action: String, successMessage: String, timeout: TimeInterval = controlTimeout) {
        guard !controlPath.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = runControl(controlPath: self.controlPath, arguments: [action], timeout: timeout)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !result.timedOut && result.exitCode == 0 {
                    self.showAlert(title: "imgpaste", message: successMessage)
                } else {
                    let detail = result.timedOut ? "The local control command timed out." : redactForDisplay(result.stderr.isEmpty ? result.stdout : result.stderr)
                    self.showAlert(title: "imgpaste action failed", message: detail)
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
        }
        showAlert(title: "imgpaste status", message: lines.joined(separator: "\n"))
    }

    @objc private func uploadNow() { invoke("upload", successMessage: "Clipboard upload completed.", timeout: uploadControlTimeout) }
    @objc private func startService() { invoke("start", successMessage: "The imgpaste service was started.") }
    @objc private func stopService() { invoke("stop", successMessage: "The imgpaste service was stopped.") }
    @objc private func restartService() { invoke("restart", successMessage: "The imgpaste service was restarted.") }

    @objc private func copyLatestPath() {
        let latest = currentStatus?.latestPath ?? currentStatus?.lastRemotePath
        guard let latest = latest, isSafeRemotePath(latest) else {
            showAlert(title: "imgpaste", message: "There is no valid uploaded path to copy yet.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latest, forType: .string)
        showAlert(title: "imgpaste", message: "Latest upload path copied to the clipboard.")
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
                self.showAlert(title: "imgpaste recent log", message: text.isEmpty ? "No local log entries are available." : text)
            }
        }
    }

    @objc private func openConfiguration() {
        guard !controlPath.isEmpty else { return }
        invoke("config", successMessage: "Opened the local imgpaste configuration.")
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

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
