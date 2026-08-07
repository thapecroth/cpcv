// imgpaste native macOS client.
//
// This source is compiled locally by macos/install-macos.sh.  It intentionally
// uses AppKit and the system OpenSSH client only: no screenshot application,
// cloud service, shell interpolation of configuration, or third-party package
// is required.

import AppKit
import CryptoKit
import Darwin
import Foundation

private let imgPasteVersion = "0.2.0"
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

enum ImgPasteError: LocalizedError {
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
        .appendingPathComponent("Library/Application Support/imgpaste", isDirectory: true).path
}

private func configPath() -> String {
    if let override = ProcessInfo.processInfo.environment["IMGPASTE_CONFIG"], !override.isEmpty {
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
        throw ImgPasteError.configuration("\(name) is outside its supported range")
    }
    return resolved
}

private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

private func normalizedDataRoot(_ value: String?) throws -> String {
    let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultDataRoot()
    guard !raw.isEmpty, !raw.contains("\0") else {
        throw ImgPasteError.configuration("DataRoot must be a non-empty local path")
    }
    let expanded = (raw as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else {
        throw ImgPasteError.configuration("DataRoot must be an absolute macOS path")
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

private func loadConfig() throws -> Config {
    let path = configPath()
    let url = URL(fileURLWithPath: path)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber,
          size.intValue >= 0, size.intValue <= maxStatusBytes else {
        throw ImgPasteError.configuration("configuration-too-large")
    }
    let data: Data
    do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) }
    catch { throw ImgPasteError.configuration("configuration-unavailable") }
    guard data.count <= maxStatusBytes else { throw ImgPasteError.configuration("configuration-too-large") }

    let raw: RawConfig
    do { raw = try JSONDecoder().decode(RawConfig.self, from: data) }
    catch { throw ImgPasteError.configuration("configuration-invalid") }

    let host = raw.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard matches(host, "^[A-Za-z0-9][A-Za-z0-9._@:-]*$") else {
        throw ImgPasteError.configuration("host-alias-invalid")
    }
    let remoteDir = (raw.remoteDir ?? "clipboard-images").trimmingCharacters(in: .whitespacesAndNewlines)
    guard matches(remoteDir, "^[A-Za-z0-9][A-Za-z0-9._/-]*$"), !remoteDir.hasPrefix("/"),
          !matches(remoteDir, "(^|/)\\.\\.(/|$)") else {
        throw ImgPasteError.configuration("remote-dir-invalid")
    }
    let remoteHome = (raw.remoteHome ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard remoteHome.isEmpty || (matches(remoteHome, "^/[A-Za-z0-9._/-]*$") && !matches(remoteHome, "(^|/)\\.\\.(/|$)")) else {
        throw ImgPasteError.configuration("remote-home-invalid")
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
        throw ImgPasteError.configuration("watchdog-stale-too-small")
    }
    guard maxImage <= maxCache else { throw ImgPasteError.configuration("max-image-exceeds-cache") }

    return Config(
        hostAlias: host, remoteDir: remoteDir, remoteHome: remoteHome,
        dataRoot: try normalizedDataRoot(raw.dataRoot), commandTimeoutSeconds: commandTimeout,
        maxCommandOutputBytes: maxOutput, pollIntervalSeconds: poll,
        watchdogCheckSeconds: watchdogCheck, watchdogStaleSeconds: watchdogStale,
        maxLogBytes: maxLog, maxCacheFiles: maxFiles, maxCacheBytes: maxCache,
        maxImageBytes: maxImage
    )
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
        throw ImgPasteError.io("state-write-failed")
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

private func writeStatus(_ config: Config, mode: String, state: String, error: String? = nil, activeChildPgid: Int? = nil, success: Bool = false) {
    let prior = decodeStatus(config.statusFile)
    let remote = readRemotePath(config)
    let status = Status(
        version: imgPasteVersion, mode: mode, pid: Int(getpid()), updatedAt: ISO8601DateFormatter().string(from: Date()),
        state: state, lastSuccessAt: success ? ISO8601DateFormatter().string(from: Date()) : prior?.lastSuccessAt,
        lastError: error.map { redact($0, limit: 256) }, activeChildPgid: activeChildPgid,
        capabilities: ["status", "start", "stop", "restart", "logs", "upload", "config"],
        latestPath: remote, lastRemotePath: remote, logFile: config.logFile
    )
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writePrivateData(encoder.encode(status), path: config.statusFile)
    } catch { }
}

private func statusForUnavailableConfig() -> Status {
    Status(version: imgPasteVersion, mode: "guardian", pid: Int(getpid()), updatedAt: ISO8601DateFormatter().string(from: Date()),
           state: "configuration-invalid", lastSuccessAt: nil, lastError: "configuration-invalid", activeChildPgid: nil,
           capabilities: ["status", "config"], latestPath: nil, lastRemotePath: nil, logFile: nil)
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

private func uploadClipboard(_ config: Config, force: Bool, copyPath: Bool) -> UploadResult {
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
        if copyPath { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        return .unchanged(path)
    }
    do { try ensurePrivateDirectory(config.cacheDirectory) }
    catch { return .failed("cache-unavailable") }
    let local = URL(fileURLWithPath: config.cacheDirectory).appendingPathComponent("clip-\(hash).png").path
    do { try writePrivateData(bytes, path: local) }
    catch { return .failed("cache-write-failed") }
    pruneCache(config, keeping: local)

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
    if copyPath { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
    return .uploaded(path)
}

private func sleepSeconds(_ seconds: Int) { Thread.sleep(forTimeInterval: TimeInterval(seconds)) }

private func runWatcher() -> Never {
    let config: Config
    do { config = try loadConfig() }
    catch { exit(64) }
    guard let watcherLock = FileLock(config.watcherLockFile) else { exit(0) }
    _ = watcherLock
    installTerminationHandlers()
    log(config, "watcher started")
    var failures = 0
    while terminationRequested == 0 {
        writeStatus(config, mode: "watch", state: "checking")
        let result = uploadClipboard(config, force: false, copyPath: true)
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
        sleepSeconds(delay)
    }
    exit(0)
}

private func healthyWatcherStatus(_ status: Status?, pid: pid_t, staleSeconds: Int) -> Bool {
    guard let status, status.mode == "watch", status.pid == Int(pid),
          let timestamp = ISO8601DateFormatter().date(from: status.updatedAt),
          Date().timeIntervalSince(timestamp) >= -5,
          Date().timeIntervalSince(timestamp) <= TimeInterval(staleSeconds) else { return false }
    return ["checking", "healthy", "backoff"].contains(status.state)
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
            sleepSeconds(config.watchdogCheckSeconds)
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

private func printStatus() {
    let status: Status
    if let config = try? loadConfig(), let saved = decodeStatus(config.statusFile) {
        status = saved
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
    let result = uploadClipboard(config, force: true, copyPath: true)
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
    print("PASS: macOS config validation, redaction, timeout bound, output bound, and child cleanup path")
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
case "self-test": exit(runSelfTest())
case "validate-config": exit(validateConfiguration())
default:
    fputs("Usage: imgpaste-macos [guardian|watch|status|logs|upload|self-test|validate-config]\n", stderr)
    exit(64)
}
