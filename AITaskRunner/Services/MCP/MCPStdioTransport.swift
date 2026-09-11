import Foundation

/// Launches an MCP server as a child process and speaks newline-delimited JSON-RPC over its stdio.
/// The command runs through `zsh -l` so the user's PATH (Homebrew, nvm, uv…) is honoured.
nonisolated final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    private let config: MCPServerConfig
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var buffer = Data()
    private var stderrText = ""
    private var closed = false
    private var onMessage: (@Sendable (JSONValue) -> Void)?
    private var onClose: (@Sendable (String) -> Void)?

    init(config: MCPServerConfig) {
        self.config = config
    }

    func start(
        onMessage: @escaping @Sendable (JSONValue) -> Void,
        onClose: @escaping @Sendable (String) -> Void
    ) async throws {
        let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw MCPError.launchFailed("No command specified.") }

        lock.withLock {
            self.onMessage = onMessage
            self.onClose = onClose
        }

        let commandLine = ([(command as NSString).expandingTildeInPath] + config.parsedArguments)
            .map(Self.shellQuote)
            .joined(separator: " ")

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec " + commandLine]
        process.environment = Self.environment(extra: config.parsedEnvironment)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            let status: String
            if proc.terminationReason == .uncaughtSignal {
                status = "Process killed by signal \(proc.terminationStatus)."
            } else {
                status = "Process exited with status \(proc.terminationStatus)."
            }
            let tail = self.stderrTail
            self.finish(reason: tail.isEmpty ? status : "\(status)\n\(tail)")
        }

        do {
            try process.run()
        } catch {
            throw MCPError.launchFailed(error.localizedDescription)
        }
    }

    func send(_ message: JSONValue) async throws {
        guard process.isRunning else { throw MCPError.transportClosed(stderrTail.isEmpty ? "process is not running" : stderrTail) }
        var data = message.encoded()
        data.append(0x0A)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw MCPError.transportClosed(error.localizedDescription)
        }
    }

    func close() async {
        let alreadyClosed = lock.withLock { () -> Bool in
            defer { closed = true }
            return closed
        }
        guard !alreadyClosed else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let proc = process
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
    }

    /// Last lines the server wrote to stderr; useful when a launch fails.
    var stderrTail: String {
        lock.withLock {
            let lines = stderrText.split(whereSeparator: \.isNewline).suffix(8)
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Internals

    private func consume(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        guard !lines.isEmpty else { return }
        let handler = lock.withLock { onMessage }
        for line in lines {
            guard !line.isEmpty else { continue }
            if let json = try? JSONValue.parse(line) {
                handler?(json)
            } else {
                appendStderr(String(decoding: line, as: UTF8.self) + "\n")
            }
        }
    }

    private func appendStderr(_ text: String) {
        lock.withLock {
            stderrText.append(text)
            if stderrText.count > 16_000 {
                stderrText = String(stderrText.suffix(8_000))
            }
        }
    }

    private func finish(reason: String) {
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            let wasClosed = closed
            closed = true
            return wasClosed ? nil : onClose
        }
        handler?(reason)
    }

    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Process environment with common tool directories prepended to PATH.
    static func environment(extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.volta/bin",
        ]
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node"),
           let latest = versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first {
            candidates.append("\(home)/.nvm/versions/node/\(latest)/bin")
        }
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var path: [String] = []
        for directory in candidates.filter({ FileManager.default.fileExists(atPath: $0) }) + existing
        where seen.insert(directory).inserted {
            path.append(directory)
        }
        env["PATH"] = path.joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        return env
    }
}
