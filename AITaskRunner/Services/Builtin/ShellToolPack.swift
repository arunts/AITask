import Foundation

/// Runs shell commands in the user's login shell. Approval is handled by the caller (ToolBox).
nonisolated enum ShellToolPack {
    static let definitions: [BuiltinTool] = [
        BuiltinTool(
            name: "run",
            description: "Run a shell command in the user's login shell (zsh) and return its stdout, stderr and exit code. The user is asked to approve each command before it runs.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The command line to execute, exactly as it would be typed in Terminal."],
                    "working_directory": ["type": "string", "description": "Directory to run in. Defaults to the working directory set in Settings › Tools."],
                    "timeout_seconds": ["type": "integer", "description": "Kill the command after this many seconds. Default from Settings (60)."],
                ],
                "required": ["command"],
            ]
        ),
    ]

    private static let outputLimit = 30_000

    struct Outcome {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var timedOut: Bool
        var seconds: Double
    }

    @concurrent
    static func call(_ tool: String, arguments: JSONValue, settings: BuiltinToolSettings) async -> MCPToolResult {
        guard tool == "run" else { return MCPToolResult(text: "Unknown Shell tool “\(tool)”.", isError: true) }
        guard let command = arguments["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return MCPToolResult(text: "Missing required argument “command”.", isError: true)
        }
        let requestedDirectory = arguments["working_directory"]?.string?.trimmingCharacters(in: .whitespaces)
        let directory: String
        if let requestedDirectory, !requestedDirectory.isEmpty {
            directory = (requestedDirectory as NSString).expandingTildeInPath
        } else {
            directory = settings.resolvedWorkingDirectory
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return MCPToolResult(text: "Working directory does not exist: \(directory)", isError: true)
        }
        let timeout = min(max(arguments["timeout_seconds"]?.int ?? settings.shellTimeoutSeconds, 1), 600)

        let outcome = await run(command: command, directory: directory, timeout: timeout)

        var text = "$ \(command)\n(cwd: \(directory))\n"
        if outcome.timedOut {
            text += "TIMED OUT after \(timeout) s; the process was killed.\n"
        } else {
            text += "exit code: \(outcome.exitCode) · \(String(format: "%.2f", outcome.seconds)) s\n"
        }
        text += "--- stdout ---\n" + (outcome.stdout.isEmpty ? "(none)" : outcome.stdout)
        if !outcome.stderr.isEmpty {
            text += "\n--- stderr ---\n" + outcome.stderr
        }
        return MCPToolResult(text: text, isError: outcome.timedOut || outcome.exitCode != 0)
    }

    private static func run(command: String, directory: String, timeout: Int) async -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.environment = MCPStdioTransport.environment(extra: [:])
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.append(data, stderr: false) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.append(data, stderr: true) }
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try process.run()
        } catch {
            return Outcome(stdout: "", stderr: "Could not start /bin/zsh: \(error.localizedDescription)", exitCode: -1, timedOut: false, seconds: 0)
        }

        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, process.isRunning else { return }
            collector.markTimedOut()
            process.terminate()
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        await Task.detached { process.waitUntilExit() }.value
        watchdog.cancel()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? stdoutPipe.fileHandleForReading.readToEnd() { collector.append(rest, stderr: false) }
        if let rest = try? stderrPipe.fileHandleForReading.readToEnd() { collector.append(rest, stderr: true) }

        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let (stdout, stderr, timedOut) = collector.snapshot()
        return Outcome(
            stdout: clip(stdout),
            stderr: clip(stderr),
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            seconds: seconds
        )
    }

    private static func clip(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard text.count > outputLimit else { return text }
        return String(text.prefix(outputLimit)) + "\n… [output truncated; \(text.count - outputLimit) more characters]"
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var timedOut = false

        func append(_ data: Data, stderr isStderr: Bool) {
            lock.withLock {
                if isStderr { stderr.append(data) } else { stdout.append(data) }
            }
        }

        func markTimedOut() {
            lock.withLock { timedOut = true }
        }

        func snapshot() -> (Data, Data, Bool) {
            lock.withLock { (stdout, stderr, timedOut) }
        }
    }
}
