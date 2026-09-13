// cpcv native macOS client.
//
// This source is compiled locally by macos/install-macos.sh.  It intentionally
// uses AppKit and the system OpenSSH client only: no screenshot application,
// cloud service, shell interpolation of configuration, or third-party package
// is required.

import AppKit
import CryptoKit
import Darwin
import Foundation

private let cpcvVersion = "0.5.0"
private let maxStatusBytes = 65_536
private let sshOptions = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=8",
    "-o", "ConnectionAttempts=1",
    "-o", "ServerAliveInterval=3",
    "-o", "ServerAliveCountMax=2"
]

// The two long-running modes use this signal-safe flag so launchctl bootout
// stops the watcher child as well as the guardian job leader.
private var terminationRequested: Int32 = 0
private func requestTermination(_ signal: Int32) { terminationRequested = 1 }
private func installTerminationHandlers() {
    _ = signal(SIGTERM, requestTermination)
    _ = signal(SIGINT, requestTermination)
}

enum CpcvError: LocalizedError {
    case configuration(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .io(let message): return message
        }
    }
}

struct RawConfig: Decodable {
    let hostAlias: String
    let remoteDir: String?
    let remoteHome: String?
    let dataRoot: String?
    let commandTimeoutSeconds: Int?
    let maxCommandOutputBytes: Int?
    let pollIntervalSeconds: Int?
    let watchdogCheckSeconds: Int?
    let watchdogStaleSeconds: Int?
    let maxLogBytes: Int?
    let maxCacheFiles: Int?
    let maxCacheBytes: Int?
    let maxImageBytes: Int?
}

struct SettingsForm: Codable {
    let hostAlias: String
    let remoteDir: String
    let remoteHome: String
    let pollIntervalSeconds: Int
}

struct Config {
    let hostAlias: String
    let remoteDir: String
    let remoteHome: String
    let dataRoot: String
    let commandTimeoutSeconds: Int
    let maxCommandOutputBytes: Int
    let pollIntervalSeconds: Int
    let watchdogCheckSeconds: Int
    let watchdogStaleSeconds: Int
    let maxLogBytes: Int
    let maxCacheFiles: Int
    let maxCacheBytes: Int
    let maxImageBytes: Int

    var cacheDirectory: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("cache").path }
    var stateFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("last-hash.txt").path }
    var latestPathFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("last-remote-path.txt").path }
    var logFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("watch.log").path }
    var statusFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("status.json").path }
    var guardianLockFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("guardian.lock").path }
    var watcherLockFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("watcher.lock").path }
    var uploadLockFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("upload.lock").path }
    var doctorLockFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("doctor.lock").path }
    var doctorReportFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("doctor-report.json").path }
    var bridgeReceiptFile: String { URL(fileURLWithPath: dataRoot).appendingPathComponent("codex-x11-bridge.json").path }
}

struct Status: Codable {
    let version: String
    let mode: String
    let pid: Int
    let updatedAt: String
    let state: String
    let lastSuccessAt: String?
    let lastError: String?
    let activeChildPgid: Int?
    let capabilities: [String]
    let latestPath: String?
    let lastRemotePath: String?
    let logFile: String?
    let doctorOverall: String?
    let doctorSummary: String?
    let doctorUpdatedAt: String?
}

struct DoctorCheck: Codable {
    let id: String
    let status: String
    let message: String
}

struct DoctorReport: Codable {
    let version: String
    let overall: String
    let updatedAt: String
    let summary: String
    let checks: [DoctorCheck]
    let repairs: [String]
}

struct BridgeReceipt: Codable {
    let version: String
    let hostAlias: String
    let remoteDir: String
    let display: String
    let enableZsh: Bool
}

struct ProcessResult {
    let ok: Bool
    let timedOut: Bool
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let outputTruncated: Bool
    let processGroup: Int?
}

enum UploadResult {
    case uploaded(String)
    case unchanged(String)
    case noImage
    case superseded
    case busy
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var errorCode: String? {
        if case .failed(let value) = self { return value }
        return nil
    }
}

private func defaultDataRoot() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/cpcv", isDirectory: true).path
}

private func configPath() -> String {
    if let override = ProcessInfo.processInfo.environment["CPCV_CONFIG"], !override.isEmpty {
        // Keep the override literal and absolute. Expanding `~` here would
        // diverge from the installer/controller contract and turn a compact
        // environment value into an unexpected local path.
        guard override.hasPrefix("/"), !override.contains("\n"), !override.contains("\r"), !override.contains("\0") else { return "" }
        return URL(fileURLWithPath: override).standardizedFileURL.path
    }
    return URL(fileURLWithPath: defaultDataRoot()).appendingPathComponent("config.json").path
}

private func strictInteger(_ value: Int?, defaultValue: Int, name: String, minimum: Int, maximum: Int) throws -> Int {
    let resolved = value ?? defaultValue
    guard resolved >= minimum && resolved <= maximum else {
        throw CpcvError.configuration("\(name) is outside its supported range")
    }
    return resolved
}

private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

private func normalizedDataRoot(_ value: String?) throws -> String {
    let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultDataRoot()
    guard !raw.isEmpty, !raw.contains("\0") else {
        throw CpcvError.configuration("DataRoot must be a non-empty local path")
    }
    let expanded = (raw as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else {
        throw CpcvError.configuration("DataRoot must be an absolute macOS path")
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

private func configFromData(_ data: Data) throws -> Config {
    let raw: RawConfig
    do { raw = try JSONDecoder().decode(RawConfig.self, from: data) }
    catch { throw CpcvError.configuration("configuration-invalid") }

    let host = raw.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard matches(host, "^[A-Za-z0-9][A-Za-z0-9._@:-]*$") else {
        throw CpcvError.configuration("host-alias-invalid")
    }
    let remoteDir = (raw.remoteDir ?? "clipboard-images").trimmingCharacters(in: .whitespacesAndNewlines)
    guard matches(remoteDir, "^[A-Za-z0-9][A-Za-z0-9._/-]*$"), !remoteDir.hasPrefix("/"),
          !matches(remoteDir, "(^|/)\\.\\.(/|$)") else {
        throw CpcvError.configuration("remote-dir-invalid")
    }
    let remoteHome = (raw.remoteHome ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard remoteHome.isEmpty || (matches(remoteHome, "^/[A-Za-z0-9._/-]*$") && !matches(remoteHome, "(^|/)\\.\\.(/|$)")) else {
        throw CpcvError.configuration("remote-home-invalid")
    }

    let commandTimeout = try strictInteger(raw.commandTimeoutSeconds, defaultValue: 35, name: "CommandTimeoutSeconds", minimum: 1, maximum: 600)
    let maxOutput = try strictInteger(raw.maxCommandOutputBytes, defaultValue: 65_536, name: "MaxCommandOutputBytes", minimum: 1_024, maximum: 1_048_576)
    let poll = try strictInteger(raw.pollIntervalSeconds, defaultValue: 2, name: "PollIntervalSeconds", minimum: 1, maximum: 60)
    let watchdogCheck = try strictInteger(raw.watchdogCheckSeconds, defaultValue: 15, name: "WatchdogCheckSeconds", minimum: 1, maximum: 300)
    let watchdogStale = try strictInteger(raw.watchdogStaleSeconds, defaultValue: 120, name: "WatchdogStaleSeconds", minimum: 10, maximum: 3_600)
    let maxLog = try strictInteger(raw.maxLogBytes, defaultValue: 1_048_576, name: "MaxLogBytes", minimum: 65_536, maximum: 104_857_600)
    let maxFiles = try strictInteger(raw.maxCacheFiles, defaultValue: 200, name: "MaxCacheFiles", minimum: 0, maximum: 10_000)
    let maxCache = try strictInteger(raw.maxCacheBytes, defaultValue: 268_435_456, name: "MaxCacheBytes", minimum: 8_388_608, maximum: 1_073_741_824)
    let maxImage = try strictInteger(raw.maxImageBytes, defaultValue: 52_428_800, name: "MaxImageBytes", minimum: 1_048_576, maximum: 268_435_456)
    guard watchdogStale >= commandTimeout * 3 + watchdogCheck else {
        throw CpcvError.configuration("watchdog-stale-too-small")
    }
    guard maxImage <= maxCache else { throw CpcvError.configuration("max-image-exceeds-cache") }

    return Config(
        hostAlias: host, remoteDir: remoteDir, remoteHome: remoteHome,
        dataRoot: try normalizedDataRoot(raw.dataRoot), commandTimeoutSeconds: commandTimeout,
        maxCommandOutputBytes: maxOutput, pollIntervalSeconds: poll,
        watchdogCheckSeconds: watchdogCheck, watchdogStaleSeconds: watchdogStale,
        maxLogBytes: maxLog, maxCacheFiles: maxFiles, maxCacheBytes: maxCache,
        maxImageBytes: maxImage
    )
}

private func loadConfig() throws -> Config {
    let path = configPath()
    let url = URL(fileURLWithPath: path)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber,
          size.intValue >= 0, size.intValue <= maxStatusBytes else {
        throw CpcvError.configuration("configuration-too-large")
    }
    let data: Data
    do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) }
    catch { throw CpcvError.configuration("configuration-unavailable") }
    guard data.count <= maxStatusBytes else { throw CpcvError.configuration("configuration-too-large") }
    return try configFromData(data)
}

private func settingsConfigURL() throws -> URL {
    let path = configPath()
    guard !path.isEmpty else { throw CpcvError.configuration("configuration-unavailable") }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard isRegularNonSymlink(url.path) else {
        throw CpcvError.configuration("configuration-unavailable")
    }
    return url.resolvingSymlinksInPath().standardizedFileURL
}

private func settingsJSONObject() throws -> (URL, [String: Any]) {
    let url = try settingsConfigURL()
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber,
          size.intValue >= 0, size.intValue <= maxStatusBytes else {
        throw CpcvError.configuration("configuration-too-large")
    }
    let data: Data
    do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) }
    catch { throw CpcvError.configuration("configuration-unavailable") }
    guard data.count <= maxStatusBytes,
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        throw CpcvError.configuration("configuration-invalid")
    }
    return (url, dictionary)
}

private func settingsString(_ dictionary: [String: Any], key: String, fallback: String) -> String {
    guard let value = dictionary[key] as? String,
          value.utf8.count <= 4_096,
          !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else { return fallback }
    return value
}

private func settingsInteger(_ dictionary: [String: Any], key: String, fallback: Int) -> Int {
    guard let value = dictionary[key] as? NSNumber else { return fallback }
    let number = value.doubleValue
    guard number.isFinite, number.rounded(.towardZero) == number,
          number >= 1, number <= 60 else { return fallback }
    return Int(number)
}

private func settingsForm(from dictionary: [String: Any]) -> SettingsForm {
    SettingsForm(
        hostAlias: settingsString(dictionary, key: "hostAlias", fallback: ""),
        remoteDir: settingsString(dictionary, key: "remoteDir", fallback: "clipboard-images"),
        remoteHome: settingsString(dictionary, key: "remoteHome", fallback: ""),
        pollIntervalSeconds: settingsInteger(dictionary, key: "pollIntervalSeconds", fallback: 2)
    )
}

private func printSettingsForm(_ settings: SettingsForm) -> Int32 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(settings), let text = String(data: data, encoding: .utf8) else { return 1 }
    print(text)
    return 0
}

private func readSettings() -> Int32 {
    guard let (_, dictionary) = try? settingsJSONObject() else {
        fputs("Unable to read the local settings file. Open Advanced JSON to repair it.\n", stderr)
        return 64
    }
    return printSettingsForm(settingsForm(from: dictionary))
}

private func settingsArguments() -> SettingsForm? {
    let arguments = Array(CommandLine.arguments.dropFirst().dropFirst())
    guard arguments.count == 8,
          arguments[0] == "--host-alias", arguments[2] == "--remote-dir",
          arguments[4] == "--remote-home", arguments[6] == "--poll-interval-seconds",
          arguments[1].utf8.count <= 255, arguments[3].utf8.count <= 1_024,
          arguments[5].utf8.count <= 1_024,
          arguments[7].range(of: "^[0-9]{1,2}$", options: .regularExpression) != nil,
          let interval = Int(arguments[7]) else { return nil }
    return SettingsForm(hostAlias: arguments[1], remoteDir: arguments[3],
                        remoteHome: arguments[5], pollIntervalSeconds: interval)
}

private func writePrivateConfiguration(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path else {
        throw CpcvError.io("configuration-directory-unsafe")
    }
    let temporary = directory.appendingPathComponent(".cpcv-settings-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                         attributes: [.posixPermissions: 0o600]) else {
        throw CpcvError.io("configuration-write-failed")
    }
    _ = chmod(temporary.path, S_IRUSR | S_IWUSR)
    guard rename(temporary.path, url.path) == 0 else {
        throw CpcvError.io("configuration-write-failed")
    }
    _ = chmod(url.path, S_IRUSR | S_IWUSR)
}

private func saveSettings() -> Int32 {
    guard let update = settingsArguments() else {
        fputs("Settings contain an unsupported value.\n", stderr)
        return 64
    }
    do {
        let (url, current) = try settingsJSONObject()
        var candidate = current
        candidate["hostAlias"] = update.hostAlias
        candidate["remoteDir"] = update.remoteDir
        candidate["remoteHome"] = update.remoteHome
        candidate["pollIntervalSeconds"] = update.pollIntervalSeconds
        let data = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
        guard data.count <= maxStatusBytes else { throw CpcvError.configuration("configuration-too-large") }
        _ = try configFromData(data)
        try writePrivateConfiguration(data, to: url)
        return printSettingsForm(update)
    } catch {
        fputs("Settings were not saved. Check the values or use Advanced JSON for other invalid settings.\n", stderr)
        return 64
    }
}

private func ensurePrivateDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    _ = chmod(path, S_IRUSR | S_IWUSR | S_IXUSR)
}

private func writePrivateData(_ data: Data, path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try ensurePrivateDirectory(directory)
    let temporary = URL(fileURLWithPath: directory).appendingPathComponent(".\(UUID().uuidString).tmp").path
    defer { try? FileManager.default.removeItem(atPath: temporary) }
    try data.write(to: URL(fileURLWithPath: temporary), options: [])
    _ = chmod(temporary, S_IRUSR | S_IWUSR)
    guard rename(temporary, path) == 0 else {
        throw CpcvError.io("state-write-failed")
    }
    _ = chmod(path, S_IRUSR | S_IWUSR)
}

private func writePrivateText(_ value: String, path: String) throws {
    try writePrivateData(Data(value.utf8), path: path)
}

private func readBoundedText(_ path: String, limit: Int) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber, size.intValue <= limit,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func redact(_ value: String, limit: Int = 8_192) -> String {
    var safe = value.replacingOccurrences(of: "(?i)(https?://)[^/\\s:@]+:[^@\\s/]+@", with: "$1[REDACTED]@", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "(?i)https?://[^\\s?]+\\?[^\\s]+", with: "[redacted URL query]", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "(?im)^\\s*(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\\s*:\\s*.*$", with: "$1: [REDACTED]", options: .regularExpression)
    let keyValuePattern = #"(?i)(?<![A-Za-z0-9])([\"']?(?:access[\s_-]*token|id[\s_-]*token|refresh[\s_-]*token|token|client[\s_-]*secret|api[\s_-]*key|password|passwd|pwd|private[\s_-]*key|secret)\b[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}\]\r\n]+)"#
    safe = safe.replacingOccurrences(of: keyValuePattern, with: "$1[REDACTED]", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "(?i)\\bBearer\\s+[^\\s,;]+", with: "Bearer [REDACTED]", options: .regularExpression)
    safe = safe.replacingOccurrences(of: "[\\r\\n]+", with: " | ", options: .regularExpression)
    return safe.count > limit ? String(safe.prefix(limit)) + " [truncated]" : safe
}

private func rotateLog(_ config: Config) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: config.logFile),
          let size = attributes[.size] as? NSNumber, size.intValue >= config.maxLogBytes else { return }
    let manager = FileManager.default
    try? manager.removeItem(atPath: config.logFile + ".3")
    try? manager.moveItem(atPath: config.logFile + ".2", toPath: config.logFile + ".3")
    try? manager.moveItem(atPath: config.logFile + ".1", toPath: config.logFile + ".2")
    try? manager.moveItem(atPath: config.logFile, toPath: config.logFile + ".1")
}

private func log(_ config: Config, _ message: String) {
    do {
        try ensurePrivateDirectory(config.dataRoot)
        rotateLog(config)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(redact(message, limit: config.maxCommandOutputBytes))\n"
        if !FileManager.default.fileExists(atPath: config.logFile) { FileManager.default.createFile(atPath: config.logFile, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: config.logFile))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        _ = chmod(config.logFile, S_IRUSR | S_IWUSR)
    } catch { }
}

private func decodeStatus(_ path: String) -> Status? {
    guard let text = readBoundedText(path, limit: maxStatusBytes), let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
}

private func decodeDoctorReport(_ path: String) -> DoctorReport? {
    guard let text = readBoundedText(path, limit: maxStatusBytes), let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(DoctorReport.self, from: data)
}

private func decodeBridgeReceipt(_ path: String) -> BridgeReceipt? {
    guard let text = readBoundedText(path, limit: 4_096), let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(BridgeReceipt.self, from: data)
}

private func doctorFields(_ config: Config) -> (String?, String?, String?) {
    guard let report = decodeDoctorReport(config.doctorReportFile) else { return (nil, nil, nil) }
    return (report.overall, report.summary, report.updatedAt)
}

private func writeStatus(_ config: Config, mode: String, state: String, error: String? = nil, activeChildPgid: Int? = nil, success: Bool = false) {
    let prior = decodeStatus(config.statusFile)
    let remote = readRemotePath(config)
    let doctor = doctorFields(config)
    let status = Status(
        version: cpcvVersion, mode: mode, pid: Int(getpid()), updatedAt: ISO8601DateFormatter().string(from: Date()),
        state: state, lastSuccessAt: success ? ISO8601DateFormatter().string(from: Date()) : prior?.lastSuccessAt,
        lastError: error.map { redact($0, limit: 256) }, activeChildPgid: activeChildPgid,
        capabilities: ["status", "start", "stop", "restart", "logs", "upload", "config", "settings-read", "settings-save", "doctor"],
        latestPath: remote, lastRemotePath: remote, logFile: config.logFile,
        doctorOverall: doctor.0, doctorSummary: doctor.1, doctorUpdatedAt: doctor.2
    )
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writePrivateData(encoder.encode(status), path: config.statusFile)
    } catch { }
}

private func statusForUnavailableConfig() -> Status {
    let reportPath = URL(fileURLWithPath: defaultDataRoot()).appendingPathComponent("doctor-report.json").path
    let report = decodeDoctorReport(reportPath)
    return Status(version: cpcvVersion, mode: "guardian", pid: Int(getpid()), updatedAt: ISO8601DateFormatter().string(from: Date()),
           state: "configuration-invalid", lastSuccessAt: nil, lastError: "configuration-invalid", activeChildPgid: nil,
           capabilities: ["status", "config", "settings-read", "settings-save", "doctor"], latestPath: nil, lastRemotePath: nil, logFile: nil,
           doctorOverall: report?.overall, doctorSummary: report?.summary, doctorUpdatedAt: report?.updatedAt)
}

private final class BoundedCollector {
    private let limit: Int
    private let lock = NSLock()
    private var value = Data()
    private var wasTruncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - value.count
        if remaining > 0 { value.append(data.prefix(remaining)) }
        if data.count > remaining { wasTruncated = true }
    }

    var text: String { lock.lock(); defer { lock.unlock() }; return String(data: value, encoding: .utf8) ?? "[non-UTF-8 output]" }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return wasTruncated }
}

private func descendants(of root: pid_t) -> [pid_t] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "pid=,ppid="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    let collector = BoundedCollector(limit: 1_048_576)
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { readers.leave() }
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { return }
            collector.append(data)
        }
    }
    let completion = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in completion.signal() }
    guard (try? task.run()) != nil else {
        pipe.fileHandleForWriting.closeFile()
        _ = readers.wait(timeout: .now() + .seconds(1))
        return []
    }
    if completion.wait(timeout: .now() + .seconds(2)) == .timedOut {
        task.terminate()
        if completion.wait(timeout: .now() + .seconds(1)) == .timedOut { _ = Darwin.kill(task.processIdentifier, SIGKILL) }
    }
    pipe.fileHandleForWriting.closeFile()
    _ = readers.wait(timeout: .now() + .seconds(1))
    let raw = collector.text
    var parents: [pid_t: [pid_t]] = [:]
    for line in raw.split(whereSeparator: { $0.isNewline }) {
        let values = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard values.count == 2, let child = Int32(String(values[0])), let parent = Int32(String(values[1])) else { continue }
        parents[parent, default: []].append(child)
    }
    var result: [pid_t] = []
    var pending = [root]
    while let current = pending.popLast() {
        for child in parents[current, default: []] where child != root && !result.contains(child) {
            result.append(child)
            pending.append(child)
        }
    }
    return result
}

private func killProcessTree(root: pid_t, processGroup: pid_t?) {
    // Snapshot descendants before killing the group. A child forked before the
    // parent-side setpgid call can retain the old group, so group signalling
    // alone is not sufficient for an SSH ProxyCommand timeout.
    let children = descendants(of: root)
    if let group = processGroup, group > 0, group == root {
        _ = Darwin.kill(-group, SIGTERM)
    }
    for pid in children.reversed() { _ = Darwin.kill(pid, SIGTERM) }
    _ = Darwin.kill(root, SIGTERM)
    usleep(150_000)
    if let group = processGroup, group > 0, group == root { _ = Darwin.kill(-group, SIGKILL) }
    for pid in children.reversed() { _ = Darwin.kill(pid, SIGKILL) }
    _ = Darwin.kill(root, SIGKILL)
}

private func privatePipe() -> (read: Int32, write: Int32)? {
    var fds: [Int32] = [0, 0]
    guard Darwin.pipe(&fds) == 0 else { return nil }
    for index in 0..<2 where fds[index] < 3 {
        let replacement = fcntl(fds[index], F_DUPFD_CLOEXEC, 3)
        guard replacement >= 0 else {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
            return nil
        }
        Darwin.close(fds[index])
        fds[index] = replacement
    }
    return (fds[0], fds[1])
}

private func setNonBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
}

// A nonblocking drainer means a malicious or misbehaving descendant cannot
// strand a FileHandle reader after the root SSH process has timed out. `stop`
// is observed within one polling interval, then the sole owner closes its FD.
private final class PipeDrainer {
    private let descriptor: Int32
    private let collector: BoundedCollector
    private let stateLock = NSLock()
    private var stopped = false

    init(descriptor: Int32, collector: BoundedCollector) {
        self.descriptor = descriptor
        self.collector = collector
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private func shouldStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    func run() {
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while !shouldStop() {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                collector.append(Data(buffer.prefix(Int(count))))
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(10_000)
                continue
            }
            return
        }
    }
}

private func decodedExitCode(_ status: Int32) -> Int32 {
    // waitpid without WUNTRACED returns terminal state here. Darwin's wait
    // status layout has the signal in the low seven bits and an ordinary exit
    // code in bits 8-15.
    if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
    return 128 + (status & 0x7f)
}

private func runProcess(executable: String, arguments: [String], timeoutSeconds: Int, outputLimit: Int) -> ProcessResult {
    guard let stdoutPipe = privatePipe() else {
        return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "process-pipe-failed", outputTruncated: false, processGroup: nil)
    }
    guard let stderrPipe = privatePipe() else {
        Darwin.close(stdoutPipe.read); Darwin.close(stdoutPipe.write)
        return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "process-pipe-failed", outputTruncated: false, processGroup: nil)
    }
    guard setNonBlocking(stdoutPipe.read), setNonBlocking(stderrPipe.read) else {
        Darwin.close(stdoutPipe.read); Darwin.close(stdoutPipe.write)
        Darwin.close(stderrPipe.read); Darwin.close(stderrPipe.write)
        return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "process-pipe-setup-failed", outputTruncated: false, processGroup: nil)
    }
    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        Darwin.close(stdoutPipe.read); Darwin.close(stdoutPipe.write)
        Darwin.close(stderrPipe.read); Darwin.close(stderrPipe.write)
        return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "process-spawn-init-failed", outputTruncated: false, processGroup: nil)
    }
    guard posix_spawnattr_init(&attributes) == 0 else {
        posix_spawn_file_actions_destroy(&actions)
        Darwin.close(stdoutPipe.read); Darwin.close(stdoutPipe.write)
        Darwin.close(stderrPipe.read); Darwin.close(stderrPipe.write)
        return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "process-spawn-init-failed", outputTruncated: false, processGroup: nil)
    }
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }

    let closeOnExec = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    let stdinAction = "/dev/null".withCString {
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0)
    }
    let actionResult = stdinAction == 0 &&
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, STDOUT_FILENO) == 0 &&
        posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, STDERR_FILENO) == 0 &&
        posix_spawn_file_actions_addclose(&actions, stdoutPipe.read) == 0 &&
        posix_spawn_file_actions_addclose(&actions, stderrPipe.read) == 0 &&
        posix_spawn_file_actions_addclose(&actions, stdoutPipe.write) == 0 &&
        posix_spawn_file_actions_addclose(&actions, stderrPipe.write) == 0 &&
        posix_spawnattr_setpgroup(&attributes, 0) == 0 &&
        posix_spawnattr_setflags(&attributes, closeOnExec) == 0
    guard actionResult else {
        Darwin.close(stdoutPipe.read); Darwin.close(stdoutPipe.write)
        Darwin.close(stderrPipe.read); Darwin.close(stderrPipe.write)
        return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "process-spawn-setup-failed", outputTruncated: false, processGroup: nil)
    }

    var argv: [UnsafeMutablePointer<CChar>?] = []
    for value in [executable] + arguments {
        let allocated = value.withCString { strdup($0) }
        guard let pointer = allocated else {
            for existing in argv { if let existing { free(existing) } }
            Darwin.close(stdoutPipe.read); Darwin.close(stdoutPipe.write)
            Darwin.close(stderrPipe.read); Darwin.close(stderrPipe.write)
            return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "process-argument-allocation-failed", outputTruncated: false, processGroup: nil)
        }
        argv.append(pointer)
    }
    argv.append(nil)
    defer { for pointer in argv { if let pointer { free(pointer) } } }

    var pid: pid_t = 0
    let spawnResult: Int32 = executable.withCString { program in
        argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, program, &actions, &attributes, $0.baseAddress, environ)
        }
    }
    Darwin.close(stdoutPipe.write)
    Darwin.close(stderrPipe.write)
    guard spawnResult == 0, pid > 0 else {
        Darwin.close(stdoutPipe.read); Darwin.close(stderrPipe.read)
        return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "process-start-failed", outputTruncated: false, processGroup: nil)
    }

    let stdout = BoundedCollector(limit: outputLimit)
    let stderr = BoundedCollector(limit: outputLimit)
    let stdoutDrainer = PipeDrainer(descriptor: stdoutPipe.read, collector: stdout)
    let stderrDrainer = PipeDrainer(descriptor: stderrPipe.read, collector: stderr)
    let readers = DispatchGroup()
    func drain(_ drainer: PipeDrainer) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readers.leave() }
            drainer.run()
        }
    }
    drain(stdoutDrainer)
    drain(stderrDrainer)

    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    var status: Int32 = 0
    var didTimeout = false
    var waitFailed = false
    var reaped = false
    while !reaped {
        let observed = waitpid(pid, &status, WNOHANG)
        if observed == pid { reaped = true; break }
        if observed == -1 && errno != EINTR { waitFailed = true; break }
        if terminationRequested != 0 || Date() >= deadline { didTimeout = true; break }
        usleep(100_000)
    }
    if didTimeout || waitFailed {
        // POSIX_SPAWN_SETPGROUP with pgroup 0 created this group before exec.
        // The descendant snapshot remains a defensive cleanup for a hostile
        // child that explicitly creates a new session or process group.
        killProcessTree(root: pid, processGroup: pid)
        let reapDeadline = Date().addingTimeInterval(2)
        while !reaped && Date() < reapDeadline {
            let observed = waitpid(pid, &status, WNOHANG)
            if observed == pid { reaped = true; break }
            if observed == -1 && errno != EINTR { break }
            usleep(50_000)
        }
    }
    if readers.wait(timeout: .now() + .seconds(2)) == .timedOut {
        stdoutDrainer.stop()
        stderrDrainer.stop()
        _ = readers.wait(timeout: .now() + .seconds(1))
    }
    let exitCode = reaped && !didTimeout && !waitFailed ? decodedExitCode(status) : nil
    let combinedTruncated = stdout.truncated || stderr.truncated
    let errorOutput = waitFailed ? "process-wait-failed \(stderr.text)" : stderr.text
    return ProcessResult(ok: !didTimeout && !waitFailed && exitCode == 0, timedOut: didTimeout,
                         exitCode: exitCode, stdout: stdout.text, stderr: errorOutput,
                         outputTruncated: combinedTruncated, processGroup: Int(pid))
}

private final class FileLock {
    private let descriptor: Int32

    init?(_ path: String) {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard (try? ensurePrivateDirectory(directory)) != nil else { return nil }
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        _ = chmod(path, S_IRUSR | S_IWUSR)
        descriptor = fd
    }

    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func clipboardPNG() -> Data? {
    let pasteboard = NSPasteboard.general
    if let png = pasteboard.data(forType: .png) { return png }
    guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff) else { return nil }
    return representation.representation(using: .png, properties: [:])
}

private func currentClipboardHash() -> String? {
    guard let data = clipboardPNG(), !data.isEmpty else { return nil }
    return sha256(data)
}

private func isSafeRemotePath(_ value: String?) -> Bool {
    guard let value, value.count < 4_096 else { return false }
    return matches(value, "^(~|/)[A-Za-z0-9._/-]+$")
}

private func remotePath(config: Config, leaf: String) -> String {
    let relative = "\(config.remoteDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(leaf)"
    let home = config.remoteHome.hasSuffix("/") ? String(config.remoteHome.dropLast()) : config.remoteHome
    return home.isEmpty ? "~/\(relative)" : "\(home)/\(relative)"
}

private func readRemotePath(_ config: Config) -> String? {
    guard let path = readBoundedText(config.latestPathFile, limit: 4_096)?.trimmingCharacters(in: .whitespacesAndNewlines),
          isSafeRemotePath(path) else { return nil }
    return path
}

private func pruneCache(_ config: Config, keeping: String? = nil) {
    let manager = FileManager.default
    guard let files = try? manager.contentsOfDirectory(at: URL(fileURLWithPath: config.cacheDirectory), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return }
    let candidates = files.filter { matches($0.lastPathComponent, "^clip-[0-9a-f]{64}\\.png$") }.sorted {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return a > b
    }
    let protected = keeping.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    var retainedCount = 0
    var retainedBytes: Int64 = 0
    for file in candidates {
        let path = file.standardizedFileURL.path
        let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let keep = path == protected
        let exceedsCount = !keep && config.maxCacheFiles > 0 && retainedCount >= config.maxCacheFiles
        let exceedsBytes = !keep && retainedBytes + bytes > Int64(config.maxCacheBytes)
        if exceedsCount || exceedsBytes {
            try? manager.removeItem(at: file)
        } else {
            retainedCount += 1
            retainedBytes += bytes
        }
    }
}

private func processFailure(_ result: ProcessResult, prefix: String) -> UploadResult {
    if result.timedOut { return .failed("\(prefix)-timeout") }
    return .failed("\(prefix)-failed")
}

private func uploadClipboard(_ config: Config, force: Bool, onUploading: (() -> Void)? = nil) -> UploadResult {
    guard let lock = FileLock(config.uploadLockFile) else { return .busy }
    _ = lock
    guard let bytes = clipboardPNG(), !bytes.isEmpty else { return .noImage }
    guard bytes.count <= config.maxImageBytes else {
        log(config, "upload rejected: image-too-large")
        return .failed("image-too-large")
    }
    let hash = sha256(bytes)
    let lastHash = readBoundedText(config.stateFile, limit: 128)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let latestLocal = URL(fileURLWithPath: config.cacheDirectory).appendingPathComponent("latest.png").path
    if !force, lastHash == hash, FileManager.default.fileExists(atPath: latestLocal) {
        let path = readRemotePath(config) ?? remotePath(config: config, leaf: "latest.png")
        return .unchanged(path)
    }
    do { try ensurePrivateDirectory(config.cacheDirectory) }
    catch { return .failed("cache-unavailable") }
    let local = URL(fileURLWithPath: config.cacheDirectory).appendingPathComponent("clip-\(hash).png").path
    do { try writePrivateData(bytes, path: local) }
    catch { return .failed("cache-write-failed") }
    pruneCache(config, keeping: local)
    onUploading?()

    let mkdirCommand = "mkdir -p \"$HOME/\(config.remoteDir)\""
    let mkdir = runProcess(executable: "/usr/bin/ssh", arguments: sshOptions + [config.hostAlias, mkdirCommand], timeoutSeconds: config.commandTimeoutSeconds, outputLimit: config.maxCommandOutputBytes)
    guard mkdir.ok else { log(config, "mkdir failed: \(redact(mkdir.stderr + mkdir.stdout))"); pruneCache(config, keeping: local); return processFailure(mkdir, prefix: "ssh-mkdir") }

    let copy = runProcess(executable: "/usr/bin/scp", arguments: sshOptions + [local, "\(config.hostAlias):\(config.remoteDir)/\(URL(fileURLWithPath: local).lastPathComponent)"], timeoutSeconds: config.commandTimeoutSeconds, outputLimit: config.maxCommandOutputBytes)
    guard copy.ok else { log(config, "scp failed: \(redact(copy.stderr + copy.stdout))"); pruneCache(config, keeping: local); return processFailure(copy, prefix: "scp") }
    guard currentClipboardHash() == hash else { log(config, "upload superseded before latest update"); pruneCache(config, keeping: local); return .superseded }

    let base = URL(fileURLWithPath: local).lastPathComponent
    // `set -e` is intentional: a failed link update must fail the whole SSH
    // operation instead of letting the fallback printf advance local state.
    let latestCommand = "set -e; ln -sfn \(base) \"$HOME/\(config.remoteDir)/latest.png\"; readlink -f \"$HOME/\(config.remoteDir)/\(base)\" 2>/dev/null || printf '%s\\n' \"$HOME/\(config.remoteDir)/\(base)\""
    let latest = runProcess(executable: "/usr/bin/ssh", arguments: sshOptions + [config.hostAlias, latestCommand], timeoutSeconds: config.commandTimeoutSeconds, outputLimit: config.maxCommandOutputBytes)
    guard latest.ok else { log(config, "latest update failed: \(redact(latest.stderr + latest.stdout))"); pruneCache(config, keeping: local); return processFailure(latest, prefix: "ssh-latest") }
    let returned = latest.stdout.split(whereSeparator: { $0.isNewline }).last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = isSafeRemotePath(returned) ? returned! : remotePath(config: config, leaf: base)
    guard currentClipboardHash() == hash else { log(config, "upload superseded during latest update"); pruneCache(config, keeping: local); return .superseded }
    do {
        try FileManager.default.copyItem(atPath: local, toPath: latestLocal)
    } catch {
        try? FileManager.default.removeItem(atPath: latestLocal)
        do { try FileManager.default.copyItem(atPath: local, toPath: latestLocal) }
        catch { return .failed("latest-local-write-failed") }
    }
    do {
        try writePrivateText(hash, path: config.stateFile)
        try writePrivateText(path, path: config.latestPathFile)
    } catch { return .failed("state-write-failed") }
    pruneCache(config, keeping: local)
    log(config, "uploaded \(base) (\(bytes.count) bytes)")
    return .uploaded(path)
}

@discardableResult
private func sleepSeconds(_ seconds: Int, shouldContinue: @escaping () -> Bool = { terminationRequested == 0 }) -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline {
        guard shouldContinue() else { return false }
        Thread.sleep(forTimeInterval: max(0.01, min(0.25, deadline.timeIntervalSinceNow)))
    }
    return shouldContinue()
}

private func runWatcher() -> Never {
    let config: Config
    do { config = try loadConfig() }
    catch { exit(64) }
    guard let watcherLock = FileLock(config.watcherLockFile) else { exit(0) }
    _ = watcherLock
    installTerminationHandlers()
    let guardianPID = getppid()
    log(config, "watcher started")
    var failures = 0
    while terminationRequested == 0 && getppid() == guardianPID {
        writeStatus(config, mode: "watch", state: "checking")
        let result = uploadClipboard(config, force: false) {
            writeStatus(config, mode: "watch", state: "uploading")
        }
        switch result {
        case .uploaded:
            failures = 0
            writeStatus(config, mode: "watch", state: "healthy", success: true)
        case .unchanged, .noImage, .superseded, .busy:
            failures = 0
            writeStatus(config, mode: "watch", state: "healthy")
        case .failed(let code):
            failures += 1
            writeStatus(config, mode: "watch", state: "backoff", error: code)
            log(config, "upload failure \(code), attempt \(failures)")
        }
        let multiplier = min(failures, 5)
        let delay = min(60, config.pollIntervalSeconds * Int(pow(2.0, Double(multiplier))))
        guard sleepSeconds(delay, shouldContinue: { terminationRequested == 0 && getppid() == guardianPID }) else { break }
    }
    exit(0)
}

private func healthyWatcherStatus(_ status: Status?, pid: pid_t, staleSeconds: Int) -> Bool {
    guard let status, status.mode == "watch", status.pid == Int(pid),
          let timestamp = ISO8601DateFormatter().date(from: status.updatedAt),
          Date().timeIntervalSince(timestamp) >= -5,
          Date().timeIntervalSince(timestamp) <= TimeInterval(staleSeconds) else { return false }
    return ["checking", "uploading", "healthy", "backoff"].contains(status.state)
}

private func startWatcher() -> Process? {
    let executable = CommandLine.arguments[0]
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = ["watch"]
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        _ = setpgid(task.processIdentifier, task.processIdentifier)
        return task
    } catch { return nil }
}

private func runGuardian() -> Never {
    var worker: Process?
    var workerStarted = Date.distantPast
    installTerminationHandlers()
    while terminationRequested == 0 {
        guard let config = try? loadConfig() else {
            let root = defaultDataRoot()
            try? ensurePrivateDirectory(root)
            let fallback = Config(hostAlias: "", remoteDir: "clipboard-images", remoteHome: "", dataRoot: root,
                                  commandTimeoutSeconds: 35, maxCommandOutputBytes: 65_536, pollIntervalSeconds: 2,
                                  watchdogCheckSeconds: 15, watchdogStaleSeconds: 120, maxLogBytes: 1_048_576,
                                  maxCacheFiles: 200, maxCacheBytes: 268_435_456, maxImageBytes: 52_428_800)
            writeStatus(fallback, mode: "guardian", state: "configuration-invalid", error: "configuration-invalid")
            sleepSeconds(60)
            continue
        }
        guard let guardianLock = FileLock(config.guardianLockFile) else { exit(0) }
        _ = guardianLock
        log(config, "guardian started")
        while terminationRequested == 0 {
            if worker == nil || worker?.isRunning == false {
                worker = startWatcher()
                workerStarted = Date()
                if worker == nil { writeStatus(config, mode: "guardian", state: "error", error: "watcher-start-failed") }
                else { log(config, "guardian started watcher") }
            }
            if let active = worker, active.isRunning,
               Date().timeIntervalSince(workerStarted) > max(5, Double(config.watchdogCheckSeconds) * 2),
               !healthyWatcherStatus(decodeStatus(config.statusFile), pid: active.processIdentifier, staleSeconds: config.watchdogStaleSeconds) {
                let group = getpgid(active.processIdentifier) == active.processIdentifier ? active.processIdentifier : nil
                killProcessTree(root: active.processIdentifier, processGroup: group)
                log(config, "guardian restarted watcher after invalid or stale heartbeat")
                worker = nil
            }
            guard sleepSeconds(config.watchdogCheckSeconds) else { break }
            // Reload after each interval so a fixed configuration becomes live
            // without a manual restart. The next outer iteration retains the
            // per-user guardian lock while changing no remote state.
            if (try? loadConfig()) == nil {
                if let active = worker {
                    let group = getpgid(active.processIdentifier) == active.processIdentifier ? active.processIdentifier : nil
                    killProcessTree(root: active.processIdentifier, processGroup: group)
                }
                worker = nil
                break
            }
        }
        if terminationRequested != 0, let active = worker {
            let group = getpgid(active.processIdentifier) == active.processIdentifier ? active.processIdentifier : nil
            killProcessTree(root: active.processIdentifier, processGroup: group)
        }
    }
    exit(0)
}

private func isRegularNonSymlink(_ path: String) -> Bool {
    var information = stat()
    guard lstat(path, &information) == 0 else { return false }
    return (information.st_mode & S_IFMT) == S_IFREG
}

private func projectRoot() -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent().path
}

private func encodeDoctorReport(_ report: DoctorReport) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try? encoder.encode(report)
}

private func publishDoctorReport(_ report: DoctorReport, path: String?, persist: Bool = true) {
    guard let data = encodeDoctorReport(report) else { return }
    if persist, let path { try? writePrivateData(data, path: path) }
    if let text = String(data: data, encoding: .utf8) { print(text) }
}

private func finalDoctorReport(checks: [DoctorCheck], repairs: [String]) -> DoctorReport {
    let failed = checks.first { $0.status == "failed" }
    let overall: String
    let summary: String
    if let failed {
        overall = "needs-attention"
        summary = failed.message
    } else if repairs.isEmpty {
        overall = "healthy"
        summary = "All systems are operational."
    } else {
        overall = "repaired"
        summary = repairs.count == 1 ? "Repaired 1 issue; all checks now pass." : "Repaired \(repairs.count) issues; all checks now pass."
    }
    return DoctorReport(version: "1", overall: overall,
                        updatedAt: ISO8601DateFormatter().string(from: Date()),
                        summary: summary, checks: checks, repairs: repairs)
}

private func clockSynchronizationCheck(remoteEpoch: TimeInterval, startedAt: Date, finishedAt: Date) -> DoctorCheck {
    let duration = max(0, finishedAt.timeIntervalSince(startedAt))
    let midpoint = (startedAt.timeIntervalSince1970 + finishedAt.timeIntervalSince1970) / 2
    let estimatedDrift = max(0, abs(remoteEpoch - midpoint) - duration / 2 - 1)
    let seconds = Int(estimatedDrift.rounded())
    if estimatedDrift <= 5 {
        return DoctorCheck(id: "clock-sync", status: "pass", message: "Host and SSH target clocks are within \(seconds) seconds.")
    }
    return DoctorCheck(id: "clock-sync", status: "failed", message: "Host and SSH target clocks differ by about \(seconds) seconds. Enable automatic time synchronization on the target.")
}

private func checkClockSynchronization(_ config: Config, checks: inout [DoctorCheck]) {
    let startedAt = Date()
    let result = runProcess(executable: "/usr/bin/ssh", arguments: sshOptions + [config.hostAlias, "LC_ALL=C date +%s"],
                            timeoutSeconds: config.commandTimeoutSeconds, outputLimit: 256)
    let finishedAt = Date()
    let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.ok, value.range(of: "^[0-9]{9,12}$", options: .regularExpression) != nil,
          let remoteEpoch = TimeInterval(value) else {
        checks.append(DoctorCheck(id: "clock-sync", status: "skipped", message: "Clock synchronization could not be verified."))
        return
    }
    checks.append(clockSynchronizationCheck(remoteEpoch: remoteEpoch, startedAt: startedAt, finishedAt: finishedAt))
}

private func localWatcherHealthy(_ config: Config, notBefore: Date? = nil) -> Bool {
    guard let status = decodeStatus(config.statusFile),
          let pid = pid_t(exactly: status.pid),
          processIsAlive(pid),
          healthyWatcherStatus(status, pid: pid, staleSeconds: config.watchdogStaleSeconds),
          let updated = ISO8601DateFormatter().date(from: status.updatedAt) else { return false }
    return notBefore.map { updated >= $0.addingTimeInterval(-1) } ?? true
}

private func processIsAlive(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

private func waitForLocalWatcher(_ config: Config, notBefore: Date) -> Bool {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if localWatcherHealthy(config, notBefore: notBefore) { return true }
        if terminationRequested != 0 { return false }
        usleep(250_000)
    }
    return localWatcherHealthy(config, notBefore: notBefore)
}

private func repairLocalService(_ config: Config, checks: inout [DoctorCheck], repairs: inout [String]) {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let plist = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/io.cpcv.guardian.plist").path
    let marker = "Managed by cpcv install-macos.sh"
    let domainLabel = "gui/\(getuid())/io.cpcv.guardian"
    let installer = URL(fileURLWithPath: projectRoot()).appendingPathComponent("macos/install-macos.sh").path

    if FileManager.default.fileExists(atPath: plist) {
        guard isRegularNonSymlink(plist), readBoundedText(plist, limit: maxStatusBytes)?.contains(marker) == true else {
            checks.append(DoctorCheck(id: "local-service", status: "failed", message: "The local service has an ownership conflict."))
            return
        }
    } else {
        guard isRegularNonSymlink(installer) else {
            checks.append(DoctorCheck(id: "local-service", status: "failed", message: "The local service installer is unavailable."))
            return
        }
        let result = runProcess(executable: "/bin/bash", arguments: [installer, "--config", configPath()],
                                timeoutSeconds: 180, outputLimit: config.maxCommandOutputBytes)
        guard result.ok, isRegularNonSymlink(plist), readBoundedText(plist, limit: maxStatusBytes)?.contains(marker) == true else {
            checks.append(DoctorCheck(id: "local-service", status: "failed", message: "The local service could not be reinstalled."))
            return
        }
        repairs.append("local-service-installed")
    }

    let loaded = runProcess(executable: "/bin/launchctl", arguments: ["print", domainLabel],
                            timeoutSeconds: 5, outputLimit: 4_096).ok
    if loaded, localWatcherHealthy(config) {
        checks.append(DoctorCheck(id: "local-service", status: "pass", message: "Automatic uploads are running."))
        return
    }

    let repairStarted = Date()
    let action: ProcessResult
    if loaded {
        action = runProcess(executable: "/bin/launchctl", arguments: ["kickstart", "-k", domainLabel],
                            timeoutSeconds: 10, outputLimit: 4_096)
    } else {
        let domain = "gui/\(getuid())"
        let bootstrap = runProcess(executable: "/bin/launchctl", arguments: ["bootstrap", domain, plist],
                                   timeoutSeconds: 10, outputLimit: 4_096)
        action = bootstrap.ok
            ? runProcess(executable: "/bin/launchctl", arguments: ["kickstart", "-k", domainLabel],
                         timeoutSeconds: 10, outputLimit: 4_096)
            : bootstrap
    }
    guard action.ok, waitForLocalWatcher(config, notBefore: repairStarted) else {
        checks.append(DoctorCheck(id: "local-service", status: "failed", message: "Automatic uploads could not be started."))
        return
    }
    repairs.append(loaded ? "local-service-restarted" : "local-service-started")
    checks.append(DoctorCheck(id: "local-service", status: "repaired", message: "Automatic uploads were restored."))
}

private func remoteBridgeDetectionCommand(remoteDir: String) -> String {
    """
    set -eu
    a="$HOME/.config/systemd/user/io.cpcv.codex-x11.service"
    b="$HOME/.config/systemd/user/io.cpcv.codex-x11-bridge.service"
    if [ ! -e "$a" ] && [ ! -e "$b" ]; then printf 'absent'; exit 0; fi
    if [ ! -f "$a" ] || [ -L "$a" ] || [ ! -f "$b" ] || [ -L "$b" ]; then printf 'conflict'; exit 20; fi
    marker='# Managed by cpcv install-codex-x11-bridge.sh'
    grep -Fqx "$marker" "$a" && grep -Fqx "$marker" "$b" || { printf 'conflict'; exit 21; }
    c="$HOME/.config/cpcv/codex-x11.conf"
    [ -f "$c" ] && [ ! -L "$c" ] || { printf 'partial'; exit 22; }
    for key in display image_dir authority; do
      count=$(grep -c "^$key=" "$c" || true)
      [ "$count" = 1 ] || { printf 'partial'; exit 23; }
    done
    display=$(sed -n 's/^display=//p' "$c")
    image_dir=$(sed -n 's/^image_dir=//p' "$c")
    authority=$(sed -n 's/^authority=//p' "$c")
    printf '%s' "$display" | grep -Eq '^:[0-9]+$' || { printf 'partial'; exit 23; }
    match=0
    [ "$image_dir" = "$HOME/\(remoteDir)" ] && match=1
    case "$authority" in "$HOME/"*) ;; *) printf 'partial'; exit 24 ;; esac
    [ -f "$authority" ] && [ ! -L "$authority" ] || { printf 'partial'; exit 24; }
    z=0
    grep -Fqx '# >>> cpcv Codex X11 >>>' "$HOME/.zshrc" 2>/dev/null && z=1
    printf 'managed|%s|%s|%s' "$display" "$z" "$match"
    """
}

private func remoteBridgeVerifyCommand(remoteDir: String) -> String {
    """
    set -eu
    systemctl --user is-active --quiet io.cpcv.codex-x11.service
    systemctl --user is-active --quiet io.cpcv.codex-x11-bridge.service
    test -x "$HOME/.local/lib/cpcv/cpcv-codex-x11-test"
    if [ ! -e "$HOME/\(remoteDir)/latest.png" ]; then printf 'pending'; exit 0; fi
    "$HOME/.local/lib/cpcv/cpcv-codex-x11-test" >/dev/null
    printf 'ready'
    """
}

private func deployRemoteBridge(_ config: Config, receipt: BridgeReceipt) -> ProcessResult {
    let deploy = URL(fileURLWithPath: projectRoot()).appendingPathComponent("macos/deploy-remote-codex-x11-bridge.sh").path
    guard isRegularNonSymlink(deploy) else {
        return ProcessResult(ok: false, timedOut: false, exitCode: nil, stdout: "", stderr: "deployment-script-unavailable", outputTruncated: false, processGroup: nil)
    }
    var arguments = [deploy, "--host", config.hostAlias, "--remote-dir", receipt.remoteDir, "--display", receipt.display,
                     "--receipt", config.bridgeReceiptFile]
    if !receipt.enableZsh { arguments.append("--no-zsh-env") }
    let timeout = min(600, max(90, config.commandTimeoutSeconds * 6))
    return runProcess(executable: "/bin/bash", arguments: arguments, timeoutSeconds: timeout,
                      outputLimit: config.maxCommandOutputBytes)
}

private func writeBridgeReceipt(_ receipt: BridgeReceipt, config: Config) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(receipt) else { return }
    try? writePrivateData(data, path: config.bridgeReceiptFile)
}

private func checkRemoteBridge(_ config: Config, remoteDir: String,
                               checks: inout [DoctorCheck], repairs: inout [String]) {
    let detection = runProcess(executable: "/usr/bin/ssh",
                               arguments: sshOptions + [config.hostAlias, remoteBridgeDetectionCommand(remoteDir: remoteDir)],
                               timeoutSeconds: config.commandTimeoutSeconds,
                               outputLimit: config.maxCommandOutputBytes)
    let token = detection.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    var receipt: BridgeReceipt?
    var matchesCurrentDirectory = false

    if detection.ok, token == "absent" {
        if isRegularNonSymlink(config.bridgeReceiptFile) { try? FileManager.default.removeItem(atPath: config.bridgeReceiptFile) }
        checks.append(DoctorCheck(id: "codex-bridge", status: "skipped", message: "Direct Codex image paste is not configured on this server."))
        return
    } else if detection.ok, token.hasPrefix("managed|") {
        let fields = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, matches(fields[1], "^:[0-9]+$"), ["0", "1"].contains(fields[2]), ["0", "1"].contains(fields[3]) else {
            checks.append(DoctorCheck(id: "codex-bridge", status: "failed", message: "The Codex image bridge configuration is invalid."))
            return
        }
        receipt = BridgeReceipt(version: "1", hostAlias: config.hostAlias, remoteDir: remoteDir,
                                display: fields[1], enableZsh: fields[2] == "1")
        matchesCurrentDirectory = fields[3] == "1"
    } else {
        let message = token == "conflict" ? "The Codex image bridge has an ownership conflict." : "The Codex image bridge is incomplete."
        checks.append(DoctorCheck(id: "codex-bridge", status: "failed", message: message))
        return
    }

    guard let receipt else { return }
    let verify = { () -> String? in
        let result = runProcess(executable: "/usr/bin/ssh",
                                arguments: sshOptions + [config.hostAlias, remoteBridgeVerifyCommand(remoteDir: remoteDir)],
                                timeoutSeconds: config.commandTimeoutSeconds,
                                outputLimit: config.maxCommandOutputBytes)
        let status = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && ["ready", "pending"].contains(status) ? status : nil
    }
    if matchesCurrentDirectory, let status = verify() {
        writeBridgeReceipt(receipt, config: config)
        let message = status == "ready"
            ? "Direct Codex image paste is ready."
            : "Direct Codex image paste is configured and waiting for the first upload."
        checks.append(DoctorCheck(id: "codex-bridge", status: "pass", message: message))
        return
    }

    let deployment = deployRemoteBridge(config, receipt: receipt)
    guard deployment.ok, let status = verify() else {
        let message = deployment.timedOut
            ? "The Codex image bridge repair timed out."
            : "The Codex image bridge could not be repaired. Check the remote package and service requirements."
        checks.append(DoctorCheck(id: "codex-bridge", status: "failed", message: message))
        return
    }
    writeBridgeReceipt(receipt, config: config)
    repairs.append("codex-bridge-repaired")
    let message = status == "ready"
        ? "Direct Codex image paste was repaired."
        : "Direct Codex image paste was repaired and is waiting for the first upload."
    checks.append(DoctorCheck(id: "codex-bridge", status: "repaired", message: message))
}

private func runDoctor() -> Int32 {
    installTerminationHandlers()
    let config: Config
    do {
        config = try loadConfig()
    } catch {
        let report = finalDoctorReport(
            checks: [DoctorCheck(id: "configuration", status: "failed", message: "Settings are invalid and need attention.")],
            repairs: [])
        let path = URL(fileURLWithPath: defaultDataRoot()).appendingPathComponent("doctor-report.json").path
        publishDoctorReport(report, path: path)
        return 1
    }
    guard let doctorLock = FileLock(config.doctorLockFile) else {
        let report = finalDoctorReport(
            checks: [DoctorCheck(id: "doctor", status: "failed", message: "Another repair check is already running.")],
            repairs: [])
        publishDoctorReport(report, path: nil, persist: false)
        return 75
    }
    _ = doctorLock

    var checks = [DoctorCheck(id: "configuration", status: "pass", message: "Settings are valid.")]
    var repairs: [String] = []
    repairLocalService(config, checks: &checks, repairs: &repairs)

    let ssh = runProcess(executable: "/usr/bin/ssh", arguments: sshOptions + [config.hostAlias, "true"],
                         timeoutSeconds: config.commandTimeoutSeconds, outputLimit: config.maxCommandOutputBytes)
    if !ssh.ok {
        let message = ssh.timedOut ? "The SSH server did not respond in time." : "The SSH server is unreachable or authentication failed."
        checks.append(DoctorCheck(id: "ssh", status: "failed", message: message))
        checks.append(DoctorCheck(id: "clock-sync", status: "skipped", message: "Clock synchronization could not be checked because SSH is unavailable."))
        checks.append(DoctorCheck(id: "remote-directory", status: "skipped", message: "The upload directory could not be checked."))
        checks.append(DoctorCheck(id: "codex-bridge", status: "skipped", message: "The Codex image bridge could not be checked."))
    } else {
        checks.append(DoctorCheck(id: "ssh", status: "pass", message: "The SSH server is reachable."))
        checkClockSynchronization(config, checks: &checks)
        let remoteDir = config.remoteDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let directoryCommand = """
        set -eu
        d="$HOME/\(remoteDir)"
        if [ -d "$d" ]; then state=present; else mkdir -p "$d"; state=created; fi
        probe="$d/.cpcv-doctor-$$"
        trap 'rm -f "$probe"' EXIT HUP INT TERM
        : > "$probe"
        printf '%s' "$state"
        """
        let directory = runProcess(executable: "/usr/bin/ssh",
                                   arguments: sshOptions + [config.hostAlias, directoryCommand],
                                   timeoutSeconds: config.commandTimeoutSeconds,
                                   outputLimit: config.maxCommandOutputBytes)
        if directory.ok {
            let created = directory.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "created"
            if created { repairs.append("remote-directory-created") }
            checks.append(DoctorCheck(id: "remote-directory", status: created ? "repaired" : "pass",
                                      message: created ? "The remote upload directory was created." : "The remote upload directory is writable."))
            checkRemoteBridge(config, remoteDir: remoteDir, checks: &checks, repairs: &repairs)
        } else {
            checks.append(DoctorCheck(id: "remote-directory", status: "failed", message: "The remote upload directory is not writable."))
            checks.append(DoctorCheck(id: "codex-bridge", status: "skipped", message: "The Codex image bridge was not changed."))
        }
    }

    let report = finalDoctorReport(checks: checks, repairs: repairs)
    publishDoctorReport(report, path: config.doctorReportFile)
    log(config, "doctor \(report.overall): \(report.summary)")
    return report.overall == "needs-attention" ? 1 : 0
}

private func printStatus() {
    let status: Status
    if let config = try? loadConfig(), let saved = decodeStatus(config.statusFile) {
        let doctor = doctorFields(config)
        status = Status(version: saved.version, mode: saved.mode, pid: saved.pid, updatedAt: saved.updatedAt,
                        state: saved.state, lastSuccessAt: saved.lastSuccessAt, lastError: saved.lastError,
                        activeChildPgid: saved.activeChildPgid,
                        capabilities: ["status", "start", "stop", "restart", "logs", "upload", "config", "settings-read", "settings-save", "doctor"],
                        latestPath: saved.latestPath, lastRemotePath: saved.lastRemotePath, logFile: saved.logFile,
                        doctorOverall: doctor.0, doctorSummary: doctor.1, doctorUpdatedAt: doctor.2)
    } else {
        status = statusForUnavailableConfig()
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(status), let text = String(data: data, encoding: .utf8) { print(text) }
}

private func printLogs() -> Int32 {
    guard let config = try? loadConfig(), let text = readBoundedText(config.logFile, limit: maxStatusBytes) else { return 0 }
    let lines = text.split(whereSeparator: { $0.isNewline }).suffix(100).map { redact(String($0), limit: 1_024) }
    print(lines.joined(separator: "\n"))
    return 0
}

private func uploadNow() -> Int32 {
    guard let config = try? loadConfig() else { return 64 }
    installTerminationHandlers()
    // Do not overwrite the watcher's heartbeat/status record. The guardian
    // authenticates that record against its child PID, so a concurrent tray
    // action must remain an independent, lock-serialized operation.
    let result = uploadClipboard(config, force: true)
    switch result {
    case .uploaded, .unchanged:
        return 0
    case .noImage:
        log(config, "one-shot upload failed: no-image")
        return 1
    case .superseded:
        log(config, "one-shot upload superseded by newer clipboard data")
        return 1
    case .busy:
        return 75
    case .failed(let code):
        log(config, "one-shot upload failed: \(code)")
        return 1
    }
}

private func runSelfTest() -> Int32 {
    let credentialFixture = """
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
    let redactedFixture = redact(credentialFixture)
    let retainedSecret = ["authorization-secret", "proxy-secret", "header-key-secret", "cookie-secret", "plain-password", "underscored-password", "oauth-client-secret", "api-key-secret", "private-key-secret", "loose-bearer-token", "basic-url-password", "url-query-secret"].contains { redactedFixture.contains($0) }
    guard !matches("host;rm", "^[A-Za-z0-9][A-Za-z0-9._@:-]*$"),
          !matches("../../bad", "^[A-Za-z0-9][A-Za-z0-9._/-]*$"),
          !retainedSecret else {
        fputs("self-test validation/redaction failed\n", stderr)
        return 1
    }
    // The command and arguments are fixed test data. It creates a child sleep
    // and exercises the timeout process-group/descendant cleanup code without
    // contacting a host or reading the clipboard.
    let started = Date()
    let result = runProcess(executable: "/bin/sh", arguments: ["-c", "sleep 5 & child=$!; echo $child; wait"], timeoutSeconds: 1, outputLimit: 1_024)
    let elapsed = Date().timeIntervalSince(started)
    guard result.timedOut, elapsed < 4 else { fputs("self-test timeout bound failed\n", stderr); return 1 }
    let childText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let childPid = Int32(childText) else { fputs("self-test child pid failed\n", stderr); return 1 }
    var childGone = false
    for _ in 0..<20 {
        if Darwin.kill(childPid, 0) != 0 && errno == ESRCH { childGone = true; break }
        usleep(100_000)
    }
    guard childGone else {
        fputs("self-test child cleanup failed\n", stderr)
        return 1
    }
    let noisy = runProcess(executable: "/bin/sh", arguments: ["-c", "i=0; while [ \"$i\" -lt 2048 ]; do printf x; i=$((i + 1)); done"], timeoutSeconds: 5, outputLimit: 128)
    guard noisy.ok, noisy.outputTruncated, noisy.stdout.lengthOfBytes(using: .utf8) <= 128 else {
        fputs("self-test output bound failed\n", stderr)
        return 1
    }
    let uploadingStatus = Status(version: cpcvVersion, mode: "watch", pid: 42,
                                 updatedAt: ISO8601DateFormatter().string(from: Date()), state: "uploading",
                                 lastSuccessAt: nil, lastError: nil, activeChildPgid: nil, capabilities: [],
                                 latestPath: nil, lastRemotePath: nil, logFile: nil,
                                 doctorOverall: nil, doctorSummary: nil, doctorUpdatedAt: nil)
    guard healthyWatcherStatus(uploadingStatus, pid: 42, staleSeconds: 10) else {
        fputs("self-test uploading status failed\n", stderr)
        return 1
    }
    let passCheck = DoctorCheck(id: "ssh", status: "pass", message: "ready")
    let repairedCheck = DoctorCheck(id: "local-service", status: "repaired", message: "restored")
    let failedCheck = DoctorCheck(id: "ssh", status: "failed", message: "unreachable")
    let clockStart = Date(timeIntervalSince1970: 10_000)
    let synchronizedClock = clockSynchronizationCheck(remoteEpoch: 10_000, startedAt: clockStart,
                                                      finishedAt: clockStart.addingTimeInterval(0.2))
    let skewedClock = clockSynchronizationCheck(remoteEpoch: 10_020, startedAt: clockStart,
                                                finishedAt: clockStart.addingTimeInterval(0.2))
    let bridgeDetection = remoteBridgeDetectionCommand(remoteDir: "clipboard-images")
    guard finalDoctorReport(checks: [passCheck], repairs: []).overall == "healthy",
          finalDoctorReport(checks: [passCheck, repairedCheck], repairs: ["local-service-started"]).overall == "repaired",
          finalDoctorReport(checks: [passCheck, failedCheck], repairs: []).overall == "needs-attention",
          finalDoctorReport(checks: [passCheck, failedCheck], repairs: []).summary == "unreachable",
          synchronizedClock.status == "pass", skewedClock.status == "failed",
          bridgeDetection.contains("case \"$authority\" in \"$HOME/\"*"),
          !bridgeDetection.contains("[ \"$authority\" = \"$HOME/\"* ]") else {
        fputs("self-test doctor report failed\n", stderr)
        return 1
    }
    print("PASS: macOS config validation, redaction, process bounds, and Doctor report self-test")
    return 0
}

private func validateConfiguration() -> Int32 {
    do {
        _ = try loadConfig()
        return 0
    } catch {
        return 64
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "guardian"
switch command {
case "guardian": runGuardian()
case "watch": runWatcher()
case "status": printStatus()
case "logs": exit(printLogs())
case "upload": exit(uploadNow())
case "doctor": exit(runDoctor())
case "settings-read": exit(readSettings())
case "settings-save": exit(saveSettings())
case "self-test": exit(runSelfTest())
case "validate-config": exit(validateConfiguration())
default:
    fputs("Usage: cpcv-macos [guardian|watch|status|logs|upload|doctor|settings-read|settings-save|self-test|validate-config]\n", stderr)
    exit(64)
}
