import Darwin
import Foundation

/// A bounded, local OOXML text-table codec. ZIP decoding uses macOS libarchive;
/// no Office app, formula engine, macro, network request or extraction path runs.
/// Rich bodies and attachments belong to the native, revisioned snippet library.
public enum SnippetXLSXCodec {
    public static let maximumBytes = 10 * 1_024 * 1_024
    private static let maximumExpandedBytes = 24 * 1_024 * 1_024
    private static let headers = ["名称", "快捷码", "分组", "执行方式", "内容"]

    public static func exportXLSX(snippets: [AdvancedSnippet], groups: [SnippetGroup]) throws -> Data {
        guard snippets.count <= SnippetCSVCodec.maxImportRows else { throw failure("短语数量超过 XLSX 安全上限。") }
        let groupMap = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var rows = [headers]
        rows += snippets.map { [$0.name, $0.shortcut ?? "", $0.groupID.flatMap { groupMap[$0] } ?? "", $0.executionMode.rawValue, $0.text] }
        var sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (index, row) in rows.enumerated() {
            sheet += "<row r=\"\(index + 1)\">"
            for (column, text) in row.enumerated() {
                // inlineStr is explicitly text, even for =,+,-,@. There are no f elements.
                sheet += "<c r=\"\(Character(UnicodeScalar(65 + column)!))\(index + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(try xml(text))</t></is></c>"
            }
            sheet += "</row>"
            guard sheet.utf8.count <= maximumExpandedBytes else { throw failure("XLSX 文本超过展开预算。") }
        }
        sheet += "</sheetData></worksheet>"
        let parts: [(String, String)] = [
            ("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>"),
            ("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
            ("xl/workbook.xml", "<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"短语\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", sheet)
        ]
        let zip = try storedZIP(parts.map { ($0.0, Data($0.1.utf8)) })
        guard zip.count <= maximumBytes else { throw failure("XLSX 文件超过 10 MB 上限。") }
        return zip
    }

    /// Imports one ordinary worksheet, including inline and shared strings.
    /// Sparse/out-of-order cells are handled by coordinates; formulas and active
    /// or external parts cause an explicit rejection rather than silent data loss.
    public static func importXLSX(_ data: Data) throws -> [[String]] {
        guard data.count <= maximumBytes else { throw failure("XLSX 文件超过 10 MB 上限。") }
        let files = try readZIP(data)
        guard let content = files["[Content_Types].xml"], let workbook = files["xl/workbook.xml"],
              let relationships = files["xl/_rels/workbook.xml.rels"] else { throw failure("文件不是可识别的 XLSX 工作簿。") }
        guard String(data: content, encoding: .utf8)?.contains("macroEnabled") != true else { throw failure("不导入含宏的工作簿。") }
        for (name, bytes) in files where name.hasSuffix(".rels") {
            let node = try XMLTree.parse(bytes)
            guard !node.descendants("Relationship").contains(where: { $0.attributes["TargetMode"]?.lowercased() == "external" }) else {
                throw failure("不导入含外部链接的工作簿。")
            }
        }
        let sheets = try XMLTree.parse(workbook).descendants("sheet")
        guard sheets.count == 1, let relationshipID = sheets[0].attributes["r:id"] else {
            throw failure("请选择仅包含一张短语数据表的 XLSX 工作簿。")
        }
        let matches = try XMLTree.parse(relationships).descendants("Relationship").filter { $0.attributes["Id"] == relationshipID }
        guard matches.count == 1, matches[0].attributes["Type"]?.hasSuffix("/worksheet") == true,
              let target = matches[0].attributes["Target"], !target.contains(":"), !target.contains("\\"),
              !target.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw failure("工作表关系不正确。") }
        let path = target.hasPrefix("/xl/") ? String(target.dropFirst()) : "xl/" + target
        guard path.hasPrefix("xl/worksheets/"), let worksheet = files[path] else { throw failure("工作表内容缺失。") }
        var shared: [String] = []
        if let bytes = files["xl/sharedStrings.xml"] {
            shared = try XMLTree.parse(bytes).descendants("si").map { try decodeOOXML($0.descendants("t").map(\.text).joined()) }
            guard shared.count <= 50_000 else { throw failure("共享字符串数量超过安全预算。") }
        }
        let tree = try XMLTree.parse(worksheet)
        guard tree.descendants("f").isEmpty else { throw failure("短语表包含公式，请转为文本后导入；不会执行公式。") }
        let sourceRows = tree.descendants("row")
        guard sourceRows.count <= SnippetCSVCodec.maxImportRows + 1 else { throw failure("XLSX 记录超过 5000 行安全上限。") }
        var result: [(Int, [String])] = [], seenRows = Set<Int>()
        for row in sourceRows {
            guard let rowIndex = Int(row.attributes["r"] ?? ""), rowIndex > 0, rowIndex <= 1_048_576, seenRows.insert(rowIndex).inserted else { throw failure("XLSX 行坐标重复或无效。") }
            var fields = [String](repeating: "", count: 5), seen = Set<Int>()
            for cell in row.children where cell.name == "c" {
                guard let coordinate = cell.attributes["r"], let (column, number) = coordinateParts(coordinate), number == rowIndex,
                      column < 5, seen.insert(column).inserted else { throw failure("XLSX 包含重复坐标或超出五列表头的数据。") }
                let type = cell.attributes["t"] ?? "n"
                let raw = cell.children.first(where: { $0.name == "v" })?.text ?? ""
                let value: String
                switch type {
                case "inlineStr": value = try decodeOOXML(cell.descendants("t").map(\.text).joined())
                case "s":
                    guard let index = Int(raw), shared.indices.contains(index) else { throw failure("XLSX 共享字符串索引无效。") }
                    value = shared[index]
                case "str", "n": value = try decodeOOXML(raw)
                default: throw failure("短语表包含非文本单元格，请先转换为文本。")
                }
                guard value.utf8.count <= 1_048_576 else { throw failure("XLSX 单元格超过安全预算。") }
                fields[column] = value
            }
            if fields.contains(where: { !$0.isEmpty }) { result.append((rowIndex, fields)) }
        }
        let rows = result.sorted { $0.0 < $1.0 }.map(\.1)
        guard let header = rows.first, header == headers || header == ["name", "shortcut", "group", "mode", "text"] else { throw failure("XLSX 表头必须为：名称、快捷码、分组、执行方式、内容。") }
        return rows
    }

    public static func csvTable(_ rows: [[String]]) -> String {
        rows.map { row in row.map { field in
            let value = SnippetCSVCodec.sanitizeForCSV(field)
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n")
    }

    private static func coordinateParts(_ text: String) -> (Int, Int)? {
        let letters = text.prefix(while: { $0.isASCII && $0 >= "A" && $0 <= "Z" })
        guard !letters.isEmpty, letters.count <= 3, let row = Int(text.dropFirst(letters.count)), row > 0 else { return nil }
        var column = 0
        for value in letters.utf8 { column = column * 26 + Int(value - 64) }
        return (column - 1, row)
    }

    private static func xml(_ input: String) throws -> String {
        guard input.unicodeScalars.allSatisfy({ $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF }) else { throw failure("文本包含 XML 无法保存的控制字符。") }
        let escaped = input.replacingOccurrences(of: "_x[0-9a-fA-F]{4}_", with: "_x005F_$0", options: .regularExpression)
            .replacingOccurrences(of: "_x005F__x", with: "_x005F_x")
        return escaped.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static func decodeOOXML(_ value: String) throws -> String {
        let expression = try NSRegularExpression(pattern: "_x([0-9a-fA-F]{4})_")
        let source = value as NSString
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: source.length))
        var utf16: [UInt16] = [], position = 0
        for match in matches {
            utf16 += Array(source.substring(with: NSRange(location: position, length: match.range.location - position)).utf16)
            utf16.append(UInt16(source.substring(with: match.range(at: 1)), radix: 16)!)
            position = match.range.location + match.range.length
        }
        utf16 += Array(source.substring(from: position).utf16)
        let result = String(decoding: utf16, as: UTF16.self)
        guard !result.contains("\0") else { throw failure("XLSX 文本包含空字符。") }
        return result
    }

    private static func failure(_ text: String) -> DataFailure { .message(text) }

    private static func readZIP(_ data: Data) throws -> [String: Data] {
        typealias Pointer = OpaquePointer
        typealias New = @convention(c) () -> Pointer?
        typealias Single = @convention(c) (Pointer?) -> Int32
        typealias Open = @convention(c) (Pointer?, UnsafeRawPointer?, Int) -> Int32
        typealias Next = @convention(c) (Pointer?, UnsafeMutablePointer<Pointer?>?) -> Int32
        typealias Name = @convention(c) (Pointer?) -> UnsafePointer<CChar>?
        typealias Size = @convention(c) (Pointer?) -> Int64
        typealias Mode = @convention(c) (Pointer?) -> UInt32
        typealias Read = @convention(c) (Pointer?, UnsafeMutableRawPointer?, Int) -> Int
        guard let image = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw failure("系统 ZIP 组件不可用。") }
        defer { dlclose(image) }
        func function<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(image, name) else { throw failure("系统 ZIP 组件不完整。") }; return unsafeBitCast(address, to: T.self)
        }
        let make = try function("archive_read_new", New.self), free = try function("archive_read_free", Single.self)
        let zip = try function("archive_read_support_format_zip", Single.self), filters = try function("archive_read_support_filter_none", Single.self)
        let openMemory = try function("archive_read_open_memory", Open.self), next = try function("archive_read_next_header", Next.self)
        let pathname = try function("archive_entry_pathname_utf8", Name.self), size = try function("archive_entry_size", Size.self)
        let filetype = try function("archive_entry_filetype", Mode.self), encrypted = try function("archive_entry_is_encrypted", Single.self)
        let symlink = try function("archive_entry_symlink", Name.self), hardlink = try function("archive_entry_hardlink", Name.self)
        let read = try function("archive_read_data", Read.self)
        guard let archive = make() else { throw failure("无法创建 ZIP 读取器。") }; defer { _ = free(archive) }
        guard zip(archive) == 0, filters(archive) == 0 else { throw failure("系统 ZIP 读取器初始化失败。") }
        return try data.withUnsafeBytes { bytes in
            guard openMemory(archive, bytes.baseAddress, bytes.count) == 0 else { throw failure("无法读取 XLSX ZIP 容器。") }
            var result: [String: Data] = [:], names = Set<String>(), total = 0, count = 0
            while true {
                var entry: Pointer?; let status = next(archive, &entry)
                if status == 1 { break }
                guard status == 0, let entry, let path = pathname(entry) else { throw failure("XLSX ZIP 容器损坏。") }
                count += 1
                let name = String(cString: path), parts = name.split(separator: "/", omittingEmptySubsequences: false)
                let lower = name.lowercased()
                guard count <= 128, name.utf8.count <= 1024, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                      !parts.contains(".."), !parts.contains("."), names.insert(lower).inserted,
                      symlink(entry) == nil, hardlink(entry) == nil, encrypted(entry) == 0 else { throw failure("XLSX 包含越界、链接、加密或重复成员。") }
                guard !lower.contains("vbaproject"), !lower.contains("externallinks/"), !lower.contains("activex/"), !lower.contains("embeddings/"), !lower.hasSuffix(".bin") else { throw failure("不导入含宏、嵌入对象或活动内容的工作簿。") }
                let type = filetype(entry)
                let declared = size(entry)
                if type == 0o040000 {
                    guard declared == 0 else { throw failure("XLSX 目录成员包含异常数据。") }; continue
                }
                guard type == 0o100000 || type == 0, declared >= 0, declared <= maximumExpandedBytes - total else { throw failure("XLSX 成员超过展开预算或类型不支持。") }
                var content = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(archive, &buffer, buffer.count)
                    guard n >= 0, n <= Int(declared) - content.count, n <= maximumExpandedBytes - total else { throw failure("XLSX 解码超过声明大小或损坏。") }
                    if n == 0 { break }; content.append(contentsOf: buffer.prefix(n)); total += n
                }
                guard content.count == declared else { throw failure("XLSX 成员数据不完整。") }
                result[name] = content
            }
            return result
        }
    }

    private static func storedZIP(_ parts: [(String, Data)]) throws -> Data {
        var output = Data(), central = Data()
        func number<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        for (path, data) in parts {
            let name = Data(path.utf8), offset = UInt32(output.count), crc = crc32(data)
            guard data.count <= maximumExpandedBytes else { throw failure("XLSX 文本超过预算。") }
            number(UInt32(0x04034b50), to: &output); number(UInt16(20), to: &output); number(UInt16(0x800), to: &output)
            for _ in 0..<3 { number(UInt16(0), to: &output) }; number(crc, to: &output)
            number(UInt32(data.count), to: &output); number(UInt32(data.count), to: &output); number(UInt16(name.count), to: &output); number(UInt16(0), to: &output)
            output.append(name); output.append(data)
            number(UInt32(0x02014b50), to: &central); number(UInt16(20), to: &central); number(UInt16(20), to: &central); number(UInt16(0x800), to: &central)
            for _ in 0..<3 { number(UInt16(0), to: &central) }; number(crc, to: &central)
            number(UInt32(data.count), to: &central); number(UInt32(data.count), to: &central); number(UInt16(name.count), to: &central)
            for _ in 0..<4 { number(UInt16(0), to: &central) }; number(UInt32(0), to: &central); number(offset, to: &central); central.append(name)
        }
        let offset = UInt32(output.count); output.append(central)
        number(UInt32(0x06054b50), to: &output); number(UInt16(0), to: &output); number(UInt16(0), to: &output)
        number(UInt16(parts.count), to: &output); number(UInt16(parts.count), to: &output); number(UInt32(central.count), to: &output); number(offset, to: &output); number(UInt16(0), to: &output)
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 } }
        return ~value
    }

    private final class XMLNode {
        let name: String; let attributes: [String: String]; var children: [XMLNode] = []; var text = ""
        init(_ name: String, _ attributes: [String: String]) { self.name = name.split(separator: ":").last.map(String.init) ?? name; self.attributes = attributes }
        func descendants(_ name: String) -> [XMLNode] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
    }
    private final class XMLTree: NSObject, XMLParserDelegate {
        let root = XMLNode("document", [:]); var stack: [XMLNode] = []; var count = 0; var issue: Error?
        static func parse(_ data: Data) throws -> XMLNode {
            guard let string = String(data: data, encoding: .utf8), !string.uppercased().contains("<!DOCTYPE"), !string.uppercased().contains("<!ENTITY") else { throw failure("工作簿 XML 含外部实体、DTD 或不支持的编码。") }
            let delegate = XMLTree(); delegate.stack = [delegate.root]
            let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse(), delegate.issue == nil else { throw delegate.issue ?? failure("工作簿 XML 损坏。") }
            return delegate.root
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            count += 1
            guard count <= 100_000, stack.count <= 32 else { issue = failure("工作簿 XML 复杂度超过预算。"); parser.abortParsing(); return }
            let child = XMLNode(elementName, attributeDict); stack.last?.children.append(child); stack.append(child)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if stack.count > 1 { stack.removeLast() } }
    }
}
