import AppKit
import Foundation

// MARK: - Snippet Data Structures

public enum SnippetFormat: String, Codable, CaseIterable {
    case plain = "plain"
    case richText = "richText"
    case markdown = "markdown"

    public var title: String {
        switch self {
        case .plain: return L10n.text("纯文本")
        case .richText: return L10n.text("富文本 (RTF)")
        case .markdown: return L10n.text("Markdown")
        }
    }
}

public enum SnippetExecutionMode: String, Codable, CaseIterable {
    case copyOnly = "copyOnly"
    case pasteOnly = "pasteOnly"
    case pasteAndEnter = "pasteAndEnter"

    public var title: String {
        switch self {
        case .copyOnly: return L10n.text("仅复制到剪贴板")
        case .pasteOnly: return L10n.text("自动粘贴到当前窗口")
        case .pasteAndEnter: return L10n.text("粘贴后发送回车 (Enter)")
        }
    }
}

public struct SnippetGroup: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var order: Int

    public init(id: UUID = UUID(), name: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.order = order
    }
}

public struct AdvancedSnippet: Identifiable, Codable, Equatable {
    public var id: UUID
    public var groupID: UUID?
    public var name: String
    public var text: String
    public var format: SnippetFormat
    public var richTextRTF: String?
    public var attachmentPaths: [String]?
    public var shortcut: String?
    public var executionMode: SnippetExecutionMode
    public var order: Int
    public var tags: [String]

    public init(id: UUID = UUID(), groupID: UUID? = nil, name: String, text: String,
                format: SnippetFormat = .plain, richTextRTF: String? = nil,
                attachmentPaths: [String]? = nil, shortcut: String? = nil,
                executionMode: SnippetExecutionMode = .copyOnly, order: Int = 0,
                tags: [String] = []) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.text = text
        self.format = format
        self.richTextRTF = richTextRTF
        self.attachmentPaths = attachmentPaths
        self.shortcut = shortcut
        self.executionMode = executionMode
        self.order = order
        self.tags = tags
    }

    /// Resolves variable placeholders like {date}, {time}, {clipboard}, {uuid}
    public func resolvedText() -> String {
        var content = text
        let now = Date()
        let dateFormatter = DateFormatter()

        dateFormatter.dateFormat = "yyyy-MM-dd"
        content = content.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: now))

        dateFormatter.dateFormat = "HH:mm:ss"
        content = content.replacingOccurrences(of: "{time}", with: dateFormatter.string(from: now))

        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        content = content.replacingOccurrences(of: "{datetime}", with: dateFormatter.string(from: now))

        dateFormatter.dateFormat = "yyyy"
        content = content.replacingOccurrences(of: "{year}", with: dateFormatter.string(from: now))

        dateFormatter.dateFormat = "MM"
        content = content.replacingOccurrences(of: "{month}", with: dateFormatter.string(from: now))

        dateFormatter.dateFormat = "dd"
        content = content.replacingOccurrences(of: "{day}", with: dateFormatter.string(from: now))

        content = content.replacingOccurrences(of: "{uuid}", with: UUID().uuidString)

        if content.contains("{clipboard}") {
            let clip = NSPasteboard.general.string(forType: .string) ?? ""
            content = content.replacingOccurrences(of: "{clipboard}", with: clip)
        }

        return content
    }
}

// MARK: - PasteStack (iCopy 多项堆栈按顺序粘贴或合并)

@MainActor
public final class PasteStack: ObservableObject {
    public static let shared = PasteStack()

    @Published public private(set) var items: [String] = []

    public init() {}

    public func push(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(trimmed)
    }

    public func popAndPaste() -> String? {
        guard !items.isEmpty else { return nil }
        let next = items.removeFirst()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(next, forType: .string)
        return next
    }

    public func mergeAll(separator: String = "\n") -> String {
        let merged = items.joined(separator: separator)
        if !merged.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(merged, forType: .string)
        }
        return merged
    }

    public func clear() {
        items.removeAll()
    }
}

// MARK: - SnippetCSVCodec (Safe CSV / Excel tabular batch transfer)

public enum SnippetConflictPolicy {
    case skip
    case overwrite
    case keepBoth
}

public enum SnippetCSVCodec {
    public static let maxImportRows = 5000
    public static let maxFileBytes = 10 * 1024 * 1024

    /// Exports snippets to RFC 4180 CSV with CSV Formula Injection defenses.
    public static func exportCSV(snippets: [AdvancedSnippet], groups: [SnippetGroup]) -> String {
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        var rows: [String] = []
        rows.append("名称,快捷码,分组,执行方式,内容")

        for s in snippets {
            let groupName = s.groupID.flatMap { groupMap[$0] } ?? ""
            let row = [
                sanitizeForCSV(s.name),
                sanitizeForCSV(s.shortcut ?? ""),
                sanitizeForCSV(groupName),
                sanitizeForCSV(s.executionMode.rawValue),
                sanitizeForCSV(s.text)
            ]
            rows.append(row.map { escapeCSVField($0) }.joined(separator: ","))
        }

        return rows.joined(separator: "\r\n")
    }

    /// Neutralizes CSV/Formula Injection by prepending ' if text starts with formula triggers (=, +, -, @, tab, cr).
    public static func sanitizeForCSV(_ text: String) -> String {
        guard let first = text.first else { return text }
        if ["=", "+", "-", "@", "\t", "\r"].contains(first) {
            return "'" + text
        }
        return text
    }

    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    /// Imports snippets from CSV text with formula neutralization and bounds check.
    public static func importCSV(
        _ csvContent: String,
        existingSnippets: [AdvancedSnippet],
        existingGroups: [SnippetGroup],
        policy: SnippetConflictPolicy
    ) throws -> (snippets: [AdvancedSnippet], groups: [SnippetGroup]) {
        guard csvContent.utf8.count <= maxFileBytes else {
            throw DataFailure.message("文件超过 10 MB 导入上限。")
        }

        let lines = csvContent.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else {
            throw DataFailure.message("CSV 文件为空或未包含有效数据行。")
        }
        guard lines.count <= maxImportRows + 1 else {
            throw DataFailure.message("CSV 记录超过 \(maxImportRows) 行安全限制。")
        }

        var resultSnippets = existingSnippets
        var resultGroups = existingGroups
        var groupNameToID: [String: UUID] = Dictionary(uniqueKeysWithValues: existingGroups.map { ($0.name, $0.id) })

        // Skip header
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 5 else { continue }

            let name = cleanImportField(fields[0])
            let shortcut = cleanImportField(fields[1])
            let groupName = cleanImportField(fields[2])
            let modeRaw = cleanImportField(fields[3])
            let text = cleanImportField(fields[4])

            guard !name.isEmpty, !text.isEmpty else { continue }

            var groupID: UUID? = nil
            if !groupName.isEmpty {
                if let existingID = groupNameToID[groupName] {
                    groupID = existingID
                } else {
                    let newGroup = SnippetGroup(name: groupName, order: resultGroups.count)
                    resultGroups.append(newGroup)
                    groupNameToID[groupName] = newGroup.id
                    groupID = newGroup.id
                }
            }

            let mode = SnippetExecutionMode(rawValue: modeRaw) ?? .copyOnly
            let newSnippet = AdvancedSnippet(
                groupID: groupID,
                name: name,
                text: text,
                format: .plain,
                shortcut: shortcut.isEmpty ? nil : shortcut,
                executionMode: mode,
                order: resultSnippets.count
            )

            if let existingIndex = resultSnippets.firstIndex(where: { $0.name == name }) {
                switch policy {
                case .skip:
                    continue
                case .overwrite:
                    resultSnippets[existingIndex] = newSnippet
                case .keepBoth:
                    var uniqueSnippet = newSnippet
                    uniqueSnippet.name = "\(name) (副本)"
                    resultSnippets.append(uniqueSnippet)
                }
            } else {
                resultSnippets.append(newSnippet)
            }
        }

        return (resultSnippets, resultGroups)
    }

    private static func cleanImportField(_ field: String) -> String {
        var clean = field.trimmingCharacters(in: .whitespaces)
        // If prepended with ' to neutralize formula injection, strip it safely
        if clean.hasPrefix("'") && clean.count > 1 {
            let next = clean[clean.index(after: clean.startIndex)]
            if ["=", "+", "-", "@", "\t", "\r"].contains(next) {
                clean = String(clean.dropFirst())
            }
        }
        return clean
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = line.makeIterator()

        while let char = iterator.next() {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == "," && !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }
}
