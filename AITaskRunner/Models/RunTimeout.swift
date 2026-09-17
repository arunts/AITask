import Foundation

/// How long a run may work before the app stops it. An app-wide default lives in Settings and each task
/// may override it; both are seconds, with 0 meaning no limit. A per-machine choice, never exported.
nonisolated enum RunTimeout {
    /// The value that means "no limit".
    static let unlimited = 0
    /// Picked when the user turns a limit on without choosing a length.
    static let suggestedSeconds = 30 * 60
    /// Minutes the steppers accept.
    static let minuteRange = 1...(24 * 60)

    /// The limit for one run of `task`, in seconds: its own setting when it has one, else the app's.
    /// Nil when unlimited, and always nil for an interactive task.
    static func effective(for task: AgentTask, appDefault: Int) -> Int? {
        guard task.canHaveTimeLimit else { return nil }
        let seconds = task.runTimeoutSeconds ?? appDefault
        return seconds > 0 ? seconds : nil
    }

    /// Whole minutes for a stepper, rounded up and kept inside `minuteRange`.
    static func minutes(from seconds: Int) -> Int {
        min(max((seconds + 59) / 60, minuteRange.lowerBound), minuteRange.upperBound)
    }

    /// Seconds for a typed-in minute count, kept inside `minuteRange`.
    static func seconds(fromMinutes minutes: Int) -> Int {
        min(max(minutes, minuteRange.lowerBound), minuteRange.upperBound) * 60
    }

    /// "30 minutes", "1 hour", "1 hour 30 minutes". Anything under a minute reads as one minute.
    static func label(seconds: Int) -> String {
        let totalMinutes = max(1, (seconds + 59) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        return parts.joined(separator: " ")
    }
}
