import SwiftUI

extension MCPRegistry {
    /// Tools of the attachment's server that the task may call. Needs a live connection to expand "all".
    func tools(for attachment: ToolAttachment) -> [MCPTool] {
        tools(for: attachment.serverID).filter { attachment.includes($0.name) }
    }

    /// Full `server__tool` names the task may call: explicit selections, plus live tool lists for
    /// servers attached with all tools.
    func callableToolNames(for task: AgentTask) -> [String] {
        task.toolAttachments.flatMap { attachment -> [String] in
            guard let server = server(id: attachment.serverID) else { return [] }
            let names = attachment.toolNames ?? tools(for: attachment.serverID).map(\.name)
            return names.map { "\(server.slug)__\($0)" }
        }
    }

    /// Slugs of servers attached with every tool, so references highlight even before the server connects.
    func highlightPrefixes(for task: AgentTask) -> [String] {
        task.toolAttachments.filter(\.includesAllTools).compactMap { server(id: $0.serverID)?.slug }
    }

    func highlightNames(for task: AgentTask) -> Set<String> {
        Set(callableToolNames(for: task).map { $0.lowercased() })
    }
}

extension AgentTask {
    /// Prompt text with callable `server__tool` references drawn in the accent colour.
    func highlighted(_ text: String, registry: MCPRegistry) -> AttributedString {
        var result = AttributedString(text)
        let prefixes = Set(registry.highlightPrefixes(for: self).map { $0.lowercased() })
        let names = registry.highlightNames(for: self)
        for match in text.matches(of: Self.toolReferencePattern) {
            let full = String(match.0).lowercased()
            let prefix = String(match.1).lowercased()
            guard prefixes.contains(prefix) || names.contains(full) else { continue }
            guard let range = Range(match.range, in: result) else { continue }
            result[range].foregroundColor = .accentColor
            result[range].font = .system(.callout, design: .monospaced).weight(.semibold)
        }
        let keys = variableKeys
        for match in text.matches(of: Self.variablePattern) where keys.contains(String(match.1)) {
            guard let range = Range(match.range, in: result) else { continue }
            result[range].foregroundColor = .purple
            result[range].font = .system(.callout, design: .monospaced).weight(.semibold)
        }
        return result
    }
}
