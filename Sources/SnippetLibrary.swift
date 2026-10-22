import AppKit
import Foundation
import Carbon

// MARK: - Snippet Data Structures

public enum SnippetFormat: String, Codable, CaseIterable {
    case plain = "plain"
    case richText = "richText"
    case markdown = "markdown"
    case image = "image"
    case fileReference = "fileReference"

    public var title: String {
        switch self {
        case .plain: return L10n.text("纯文本")
        case .richText: return L10n.text("富文本 (RTF)")
        case .markdown: return L10n.text("Markdown")
        case .image: return L10n.text("图片附件")
        case .fileReference: return L10n.text("文件附件")
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
        case .pasteAndEnter: return L10n.text("粘贴并确认后发送回车 (Enter)")
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
    public var attachments: [SnippetAttachment]?
    public var rtfAttachment: SnippetAttachment?
    public var fileReferences: [SnippetFileReference]?

    public init(id: UUID = UUID(), groupID: UUID? = nil, name: String, text: String,
                format: SnippetFormat = .plain, richTextRTF: String? = nil,
                attachmentPaths: [String]? = nil, shortcut: String? = nil,
                executionMode: SnippetExecutionMode = .copyOnly, order: Int = 0,
                tags: [String] = [], attachments: [SnippetAttachment]? = nil,
                rtfAttachment: SnippetAttachment? = nil, fileReferences: [SnippetFileReference]? = nil) {
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
        self.attachments = attachments
        self.rtfAttachment = rtfAttachment
        self.fileReferences = fileReferences
    }

    /// Resolves variable placeholders like {date}, {time}, {clipboard}, {uuid}
    public func resolvedText() -> String {
        resolvedText(now: Date(), clipboardText: text.contains("{clipboard}") && !IsSecureEventInputEnabled()
                     ? NSPasteboard.general.string(forType: .string) : nil, uuid: UUID())
    }

    public func resolvedText(now: Date, clipboardText: String?, uuid: UUID) -> String {
        var content = text
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

        content = content.replacingOccurrences(of: "{uuid}", with: uuid.uuidString)

        if content.contains("{clipboard}") {
            let clip = clipboardText ?? ""
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
    @Published public private(set) var entries: [AdvancedSnippet] = []
    @Published public private(set) var failure: String?
    @Published var mergeCopyRecovery:ClipboardExplicitCopy.Recovery?
    private var library: SnippetLibraryStore?
    private var generation: UInt64 = 0
    private var persistenceBlocked = false
    public static let maximumItems = 50

    public init() {}

    public func configurePersistence(dataDirectory: URL) throws {
        if let library, library.directory.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dataDirectory.standardizedFileURL { return }
        let loaded = SnippetLibraryStore(dataDirectory: dataDirectory.appendingPathComponent("PasteStack", isDirectory: true))
        guard loaded.healthy, loaded.snippets.count <= Self.maximumItems else {
            persistenceBlocked = true
            failure = loaded.failure ?? "粘贴堆栈超过 50 项安全上限，原资料已保留。"
            throw DataFailure.message(failure!)
        }
        // Reconfiguration must never silently discard an unsaved in-memory stack.
        guard entries.isEmpty || library?.directory == loaded.directory else { throw DataFailure.message("堆栈已有未保存项目，未切换资料目录。") }
        let nextGeneration = max(generation, loaded.revision)
        guard nextGeneration < UInt64.max else { throw DataFailure.message("堆栈世代已达上限，原资料已保留。") }
        library = loaded; entries = loaded.snippets; generation = nextGeneration + 1; persistenceBlocked = false; publish()
    }

    public func pushContent(text: String?, rtf: Data? = nil, png: Data? = nil, fileReferences paths: [String] = []) throws {
        guard let library else { throw DataFailure.message("粘贴堆栈资料目录尚未连接。") }
        guard text?.isEmpty == false || rtf != nil || png != nil || !paths.isEmpty else { throw DataFailure.message("没有可加入堆栈的内容。") }
        let rtfAttachment = try rtf.map { try library.importAttachment(data: $0, originalName: "内容.rtf", type: "public.rtf") }
        let image = try png.map { try library.importAttachment(data: $0, originalName: "图片.png", type: "public.png") }
        let references = try paths.map { try SnippetFileReference.capture(path: $0) }
        let format: SnippetFormat = rtf != nil ? .richText : png != nil ? .image : !paths.isEmpty ? .fileReference : .plain
        let title = text.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? (png != nil ? "图片" : paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "富文本")
        try pushSnippet(AdvancedSnippet(name: title, text: text ?? "", format: format, attachments: image.map { [$0] }, rtfAttachment: rtfAttachment, fileReferences: references))
    }

    public func pushSnippet(_ snippet: AdvancedSnippet) throws {
        guard entries.count < Self.maximumItems, snippet.text.utf8.count <= 1_048_576 else { throw DataFailure.message("粘贴堆栈已满或文本超过预算。") }
        var entry = snippet; entry.id = UUID(); entry.groupID = nil; entry.shortcut = nil; entry.executionMode = .pasteOnly; entry.order = entries.count
        try persist(entries + [entry])
    }

    public func pushSnippet(_ snippet: AdvancedSnippet, from source: SnippetLibraryStore) throws {
        guard let library else { throw DataFailure.message("粘贴堆栈资料目录尚未连接。") }
        var copied = snippet
        copied.attachments = try snippet.attachments?.map { attachment in
            try library.importAttachment(data: source.verifiedAttachment(attachment), originalName: attachment.originalName, type: attachment.type)
        }
        copied.rtfAttachment = try snippet.rtfAttachment.map { attachment in
            try library.importAttachment(data: source.verifiedAttachment(attachment), originalName: attachment.originalName, type: attachment.type)
        }
        try pushSnippet(copied)
    }

    public func peek() -> PasteStackTicket? {
        entries.first.map { PasteStackTicket(id: $0.id, generation: generation, snippet: $0) }
    }

    public func pasteboardItems(for ticket: PasteStackTicket) throws -> [NSPasteboardItem] {
        try validate(ticket)
        if let library { return try library.pasteboardItems(for: ticket.snippet) }
        guard ticket.snippet.format == .plain, ticket.snippet.attachments?.isEmpty != false,
              ticket.snippet.fileReferences?.isEmpty != false else { throw DataFailure.message("富内容堆栈尚未连接持久化资料。") }
        let item = NSPasteboardItem(); item.setString(ticket.snippet.text, forType: .string); return [item]
    }

    public func validateTicket(_ ticket: PasteStackTicket) throws { try validate(ticket) }

    /// Call only after the user confirms insertion for the validated target.
    public func commit(_ ticket: PasteStackTicket) throws {
        try validate(ticket); try persist(Array(entries.dropFirst()))
    }

    public func clearDurably() throws { try persist([]) }

    public func push(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try pushSnippet(.init(name: String(text.prefix(60)), text: text)) } catch { failure = error.localizedDescription }
    }

    public func popAndPaste() -> String? {
        guard let ticket = peek() else { return nil }
        do {
            let prepared = try pasteboardItems(for: ticket)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects(prepared) else { throw DataFailure.message("堆栈复制失败，项目已保留。") }
            try commit(ticket); return ticket.snippet.text
        } catch { failure = error.localizedDescription; return nil }
    }

    public func mergedText(separator:String = "\n") throws -> String {
        guard !persistenceBlocked,!entries.isEmpty else {throw DataFailure.message(failure ?? "粘贴堆栈为空。")}
        try library?.validateCurrentRevision()
        guard entries.allSatisfy({
            ($0.format == .plain || $0.format == .markdown) && $0.richTextRTF == nil && $0.rtfAttachment == nil &&
            $0.attachments?.isEmpty != false && $0.fileReferences?.isEmpty != false && $0.attachmentPaths?.isEmpty != false
        }) else {throw DataFailure.message("富内容请逐项粘贴，未静默丢弃附件合并。")}
        let size=entries.reduce(0) {$0+$1.text.utf8.count}
        guard separator.utf8.count <= 4096,size+separator.utf8.count*(entries.count-1) <= 2_000_000 else {throw DataFailure.message("合并文字超过2MB，堆栈已保留。")}
        return entries.map(\.text).joined(separator:separator)
    }
    public func mergeAll(separator: String = "\n") -> String {
        do {
            guard mergeCopyRecovery==nil else {throw DataFailure.message("请先处理复制前剪贴板的恢复选择。")}
            guard !IsSecureEventInputEnabled() else {throw DataFailure.message("安全输入期间不读取剪贴板。")}
            let board=NSPasteboard.general,count=NSPasteboard.general.changeCount
            let prepared=try preparedMerge(separator:separator)
            try ClipboardExplicitCopy.publish(prepared,to:board,expectedCount:count,shouldProceed:{!IsSecureEventInputEnabled()})
            return prepared.string(forType:.string) ?? ""
        } catch {
            if let value=error as? ClipboardExplicitCopy.Failure {mergeCopyRecovery=value.recovery}
            failure=error.localizedDescription;return ""
        }
    }

    /// Build every representation before touching the system clipboard. A failed
    /// attachment/read/serialization leaves both the queue and clipboard intact.
    public func preparedMerge(separator:String = "\n") throws -> NSPasteboardItem {
        guard !persistenceBlocked,!entries.isEmpty,let library else {throw DataFailure.message(failure ?? "粘贴堆栈为空。")}
        try library.validateCurrentRevision()
        let result=try PasteStackRichMerge.prepare(entries,library:library,separator:separator)
        try library.validateCurrentRevision()
        return result
    }

    public func clear() {
        do { try clearDurably() } catch { failure = error.localizedDescription }
    }

    private func validate(_ ticket: PasteStackTicket) throws {
        guard !persistenceBlocked, generation == ticket.generation, entries.first?.id == ticket.id, entries.first == ticket.snippet else {
            throw DataFailure.message("堆栈在粘贴期间已变化，未移除任何项目。")
        }
        try library?.validateCurrentRevision()
    }
    private func persist(_ values: [AdvancedSnippet]) throws {
        guard !persistenceBlocked else { throw DataFailure.message(failure ?? "堆栈资料无法使用，未写入。") }
        guard generation < UInt64.max else { throw DataFailure.message("堆栈世代已达上限。") }
        var ordered = values
        for index in ordered.indices { ordered[index].order = index }
        if let library { try library.replaceAllSnippets(ordered) }
        entries = ordered; generation += 1; publish()
    }
    private func publish() { items = entries.map(\.text); failure = nil }
}

public struct PasteStackTicket {
    public let id: UUID
    public let generation: UInt64
    public let snippet: AdvancedSnippet
}

// MARK: - SnippetCSVCodec (RFC 4180 text-table transfer; XLSX is separate)

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
        let groupMap = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
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
        if ["=", "+", "-", "@", "'"].contains(first) || first.isWhitespace {
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

        let rows = try parseCSV(csvContent)
        guard rows.count > 1 else {
            throw DataFailure.message("CSV 文件为空或未包含有效数据行。")
        }
        guard rows.count <= maxImportRows + 1 else {
            throw DataFailure.message(L10n.format("CSV 记录超过 %@ 行安全限制。", String(describing: (maxImportRows))))
        }

        guard rows[0] == ["名称", "快捷码", "分组", "执行方式", "内容"] || rows[0] == ["name", "shortcut", "group", "mode", "text"] else {
            throw DataFailure.message("CSV 表头必须为：名称、快捷码、分组、执行方式、内容。")
        }
        var resultSnippets = existingSnippets
        var resultGroups = existingGroups
        var groupNameToID: [String: UUID] = Dictionary(existingGroups.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

        // Skip header
        for (offset, fields) in rows.dropFirst().enumerated() {
            if fields.allSatisfy({ $0.isEmpty }) { continue }
            guard fields.count == 5 else { throw DataFailure.message(L10n.format("CSV 第 %@ 条记录的列数不正确，未导入。", String(describing: (offset + 2)))) }

            let name = cleanImportField(fields[0])
            let shortcut = cleanImportField(fields[1])
            let groupName = cleanImportField(fields[2])
            let modeRaw = cleanImportField(fields[3])
            let text = cleanImportField(fields[4])

            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.isEmpty else {
                throw DataFailure.message(L10n.format("CSV 第 %@ 条记录缺少名称或内容，未导入。", String(describing: (offset + 2))))
            }

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

            guard let mode = SnippetExecutionMode(rawValue: modeRaw) else {
                throw DataFailure.message("CSV 包含未知执行方式，未导入。")
            }
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
                    var replacement = newSnippet
                    replacement.id = resultSnippets[existingIndex].id
                    resultSnippets[existingIndex] = replacement
                case .keepBoth:
                    var uniqueSnippet = newSnippet
                    var count = 1
                    repeat {
                        uniqueSnippet.name = count == 1 ? L10n.format("%@ (副本)", String(describing: (name))) : L10n.format("%@ (副本 %@)", String(describing: (name)), String(describing: (count)))
                        count += 1
                    } while resultSnippets.contains(where: { $0.name == uniqueSnippet.name })
                    if resultSnippets.contains(where: { $0.shortcut?.lowercased() == uniqueSnippet.shortcut?.lowercased() && $0.shortcut != nil }) {
                        uniqueSnippet.shortcut = nil
                    }
                    resultSnippets.append(uniqueSnippet)
                }
            } else {
                var addition = newSnippet
                if let shortcut = addition.shortcut, resultSnippets.contains(where: { $0.shortcut?.lowercased() == shortcut.lowercased() }) {
                    addition.shortcut = nil
                }
                resultSnippets.append(addition)
            }
        }

        return (resultSnippets, resultGroups)
    }

    private static func cleanImportField(_ field: String) -> String {
        var clean = field
        // If prepended with ' to neutralize formula injection, strip it safely
        if clean.hasPrefix("'") && clean.count > 1 {
            let rest = String(clean.dropFirst())
            if sanitizeForCSV(rest) == clean {
                clean = String(clean.dropFirst())
            }
        }
        return clean
    }

    public static func parseCSV(_ content: String) throws -> [[String]] {
        enum State { case start, unquoted, quoted, closed }
        var state = State.start, rows: [[String]] = [], fields: [String] = [], current = ""
        let characters = Array(content.hasPrefix("\u{feff}") ? String(content.dropFirst()) : content)
        var index = 0
        func endField() { fields.append(current); current = ""; state = .start }
        func endRecord() throws {
            endField(); rows.append(fields); fields = []
            guard rows.count <= maxImportRows + 1 else { throw DataFailure.message("CSV 记录超过安全限制。") }
        }
        while index < characters.count {
            let char = characters[index]
            if state == .quoted {
                if char == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { current.append("\""); index += 1 }
                    else { state = .closed }
                } else { current.append(char) }
            } else if char == "," { endField() }
            else if char == "\n" || char == "\r" || char == "\r\n" {
                try endRecord()
                if char == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else if char == "\"", state == .start { state = .quoted }
            else {
                guard state != .closed, char != "\"" else { throw DataFailure.message("CSV 引号格式不正确，未导入。") }
                current.append(char); state = .unquoted
            }
            index += 1
        }
        guard state != .quoted else { throw DataFailure.message("CSV 引号未闭合，未导入。") }
        if !fields.isEmpty || !current.isEmpty || state != .start { try endRecord() }
        return rows
    }
}
