import SwiftUI

/// Renders Markdown as native views: headings, paragraphs, bullet and numbered lists (nested), fenced
/// code, block quotes, tables and rules. Inline bold, italic, code, strikethrough and links come from
/// Foundation's parser. Plain text with no Markdown renders exactly as before, so it is safe as the default.
struct MarkdownView: View {
    let text: String

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownBlock.parse(text))
            .textSelection(.enabled)
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    @Environment(\.textScale) private var textScale

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .textStyle(level == 1 ? .title2 : level == 2 ? .title3 : .body, weight: .semibold)
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            Text(inline(text))
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)

        case .code(_, let code):
            Text(verbatim: code)
                .textStyle(.callout, design: .monospaced)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 8))

        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                MarkdownBlocksView(blocks: blocks)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Divider()

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(start + index)." : "•")
                            .textStyle(.body)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(inline(item.text))
                                .textStyle(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            if !item.children.isEmpty {
                                MarkdownBlocksView(blocks: item.children)
                            }
                        }
                    }
                }
            }

        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).textStyle(.body, weight: .semibold)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell)).textStyle(.body)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Inline Markdown (bold, italic, code, links) with code spans in a monospaced font on a light background.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let codeRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { return nil }
            return run.range
        }
        for range in codeRanges {
            attributed[range].font = .scaled(.callout, design: .monospaced, scale: textScale)
            attributed[range].backgroundColor = Color.secondary.opacity(0.15)
        }
        return attributed
    }
}

// MARK: - Block parser

enum MarkdownBlock {
    struct ListItem {
        var text: String
        var children: [MarkdownBlock]
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [ListItem])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case rule
    case table(header: [String], rows: [[String]])

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
        return parse(lines[...])
    }

    private struct ListMarker {
        let indent: Int
        let ordered: Bool
        let number: Int
        /// Column where the item's text starts; deeper-indented lines belong to the item.
        let contentOffset: Int
        let text: String
    }

    private static let headingPattern = #/^(#{1,6})\s+(.*?)\s*#*\s*$/#
    private static let rulePattern = #/^([-*_])( *\1){2,}$/#
    private static let listPattern = #/^( *)([-*+]|\d{1,9}[.)])( +)(.*)$/#
    private static let tableSeparatorPattern = #/^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$/#

    private static func listMarker(_ line: String) -> ListMarker? {
        guard let match = line.wholeMatch(of: listPattern) else { return nil }
        let indent = match.1.count
        let marker = String(match.2)
        let ordered = marker.first!.isNumber
        let number = ordered ? Int(marker.dropLast()) ?? 1 : 1
        return ListMarker(indent: indent, ordered: ordered, number: number, contentOffset: indent + marker.count + match.3.count, text: String(match.4))
    }

    /// Lines that begin a new block and so end a paragraph or list item, even without a blank line.
    private static func startsBlock(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix(">")
            || trimmed.wholeMatch(of: headingPattern) != nil || trimmed.wholeMatch(of: rulePattern) != nil
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|"), cells.count > 0 { cells.removeLast() }
        return cells
    }

    private static func parse(_ lines: ArraySlice<String>) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = lines.startIndex

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }

            // Fenced code (an unterminated fence runs to the end, which matters while streaming).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                if i < lines.endIndex { i += 1 }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            if let match = trimmed.wholeMatch(of: headingPattern) {
                flush()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
                i += 1
                continue
            }

            if trimmed.wholeMatch(of: rulePattern) != nil {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.endIndex {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var content = t.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    inner.append(String(content))
                    i += 1
                }
                blocks.append(.quote(parse(inner[...])))
                continue
            }

            if trimmed.contains("|"), i + 1 < lines.endIndex,
               lines[i + 1].trimmingCharacters(in: .whitespaces).wholeMatch(of: tableSeparatorPattern) != nil {
                flush()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.endIndex {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    var cells = tableCells(t)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let first = listMarker(line) {
                flush()
                var items: [ListItem] = []
                let base = first.indent
                while i < lines.endIndex, let marker = listMarker(lines[i]), marker.indent == base, marker.ordered == first.ordered {
                    var text = marker.text
                    var sub: [String] = []
                    i += 1
                    while i < lines.endIndex {
                        let l = lines[i]
                        let t = l.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty {
                            // Keep going only if the item continues after the blank line.
                            var j = i + 1
                            while j < lines.endIndex, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                            if j < lines.endIndex, indentation(lines[j]) >= marker.contentOffset {
                                sub.append("")
                                i += 1
                                continue
                            }
                            break
                        }
                        let indent = indentation(l)
                        if indent >= marker.contentOffset {
                            let dedented = String(l.dropFirst(marker.contentOffset))
                            if sub.isEmpty, listMarker(dedented) == nil, !startsBlock(t) {
                                text += "\n" + t  // wrapped continuation of the item's own text
                            } else {
                                sub.append(dedented)
                            }
                            i += 1
                            continue
                        }
                        if indent > base, listMarker(l) != nil {
                            sub.append(String(l.dropFirst(indent)))
                            i += 1
                            continue
                        }
                        if listMarker(l) != nil || !sub.isEmpty || startsBlock(t) { break }
                        // Lazy continuation of the item's own text.
                        text += "\n" + t
                        i += 1
                    }
                    items.append(ListItem(text: text, children: sub.isEmpty ? [] : parse(sub[...])))
                    // A blank line between items keeps the same list going.
                    var j = i
                    while j < lines.endIndex, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.endIndex, let next = listMarker(lines[j]), next.indent == base, next.ordered == first.ordered {
                        i = j
                    }
                }
                blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }
}
