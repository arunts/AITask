import SwiftUI

/// Paste-a-JSON-block importer for MCP servers.
struct MCPImportSheet: View {
    let onImport: ([MCPServerConfig]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var parsed: Result<[MCPServerConfig], any Error> = .success([])

    private static let example = """
    {
      "mcpServers": {
        "filesystem": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        },
        "remote": {
          "url": "http://localhost:3000/mcp",
          "headers": { "Authorization": "Bearer …" }
        }
      }
    }
    """

    private var servers: [MCPServerConfig] { (try? parsed.get()) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import MCP Servers")
                    .textStyle(.title2, weight: .semibold)
                Text("Paste the JSON block from a server's README, or the mcpServers section of a Claude Desktop, Cursor or VS Code config.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            HSplitView {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .textStyle(.body, design: .monospaced)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                    if text.isEmpty {
                        Text(Self.example)
                            .textStyle(.body, design: .monospaced)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minWidth: 340)
                preview
                    .frame(minWidth: 240, idealWidth: 280)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(servers.count == 1 ? "Import 1 Server" : "Import \(servers.count) Servers") {
                    onImport(servers)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(servers.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 440, idealHeight: 500)
        .onChange(of: text, initial: true) {
            parsed = Result { try MCPServerImport.parse(text) }
        }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detected")
                .textStyle(.headline)
            switch parsed {
            case .success(let servers) where !servers.isEmpty:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(servers) { server in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.summary)
                                        .textStyle(.callout, design: .monospaced)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                    if !server.environment.isEmpty {
                                        Text("env: \(server.parsedEnvironment.keys.sorted().joined(separator: ", "))")
                                            .textStyle(.subheadline)
                                            .foregroundStyle(.tertiary)
                                    }
                                    if !server.headers.isEmpty {
                                        Text("headers: \(server.parsedHeaders.keys.sorted().joined(separator: ", "))")
                                            .textStyle(.subheadline)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Label(server.name, systemImage: server.transport == .stdio ? "terminal" : "network")
                            }
                        }
                    }
                }
            case .success:
                Text("Servers found in the JSON are listed here.")
                    .foregroundStyle(.tertiary)
                Spacer()
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(16)
    }
}
