import Foundation

enum ArchiveCompressionLevel: Int, Codable, CaseIterable, Identifiable {
    case store = 0, fast = 1, standard = 5, maximum = 9
    var id: Int { rawValue }
    var title: String { switch self { case .store:return "秒速打包（不压缩）";case .fast:return "快速";case .standard:return "标准";case .maximum:return "极限" } }
}
struct ArchiveCreationOptions: Codable, Equatable {
    var level: ArchiveCompressionLevel = .standard
    var threads: Int = 0
    var encryptFileNames = true
    var ignoredPatterns: [String] = []
    var appendDate = false
    var separateItems = false
    var trashOriginals = false
    var revealResults = false
    func validate() throws {
        guard (0...256).contains(threads), ignoredPatterns.count <= 200,
              ignoredPatterns.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\n") && !$0.contains("\0") }) else {
            throw ArchiveError.invalid("线程数应为自动或1–256；忽略规则不得包含换行或空字符。")
        }
        guard !trashOriginals || ignoredPatterns.isEmpty else { throw ArchiveError.invalid("当前包含忽略文件规则，为避免丢失未归档内容，请保留原件后自行核验。") }
    }
    func excludes(_ path: String) -> Bool {
        ignoredPatterns.contains { pattern in
            let expression = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            let subject = pattern.contains("/") ? path : URL(fileURLWithPath: path).lastPathComponent
            return subject.range(of: expression, options: .regularExpression) != nil
        }
    }
}
struct ArchiveExtractionOptions: Codable, Equatable {
    var recursiveContainers = true
    var allowSafeLinks = true
    var maximumExpandedGiB = 20
    var maximumEntries = 100_000
    var maximumMinutes = 60
    var filenameEncoding = "auto"
    var trashOriginals = false
    var revealResults = false
    var maximumBytes: UInt64 { UInt64(maximumExpandedGiB) * 1_024 * 1_024 * 1_024 }
    static var strict: Self { var value=Self();value.allowSafeLinks=false;return value }
    static let encodings = ["auto", "UTF-8", "GB18030", "CP932", "CP437", "CP850", "CP1252"]
    func validate() throws {
        guard (1...16_384).contains(maximumExpandedGiB), (1...5_000_000).contains(maximumEntries),
              (1...1_440).contains(maximumMinutes), Self.encodings.contains(filenameEncoding) else {
            throw ArchiveError.invalid("解压预算或文件名编码无效。")
        }
    }
}
enum ArchiveOpenBehavior: String, Codable, CaseIterable, Identifiable {
    case preview, extract, panel
    var id: String { rawValue }
    var title: String { switch self { case .preview:return "预览压缩包";case .extract:return "直接解压";case .panel:return "选择操作" } }
}
struct ArchiveEnhancementPreferences: Codable {
    var schema = 1
    var creation = ArchiveCreationOptions()
    var extraction = ArchiveExtractionOptions()
    var openBehavior: ArchiveOpenBehavior = .preview
    var saveCompressionPasswords = false
    var saveExtractionPasswords = false
    var tryPasswordBook = true
}
struct ArchiveTreeNode: Identifiable {
    let path: String
    let isDirectory: Bool
    var size: UInt64
    var children: [ArchiveTreeNode]?
    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    static func build(_ entries: [ArchiveEntry]) -> [ArchiveTreeNode] {
        var folders = Set<String>()
        for entry in entries {
            var components = entry.path.split(separator: "/").map(String.init)
            if entry.isDirectory { folders.insert(entry.path) }
            while components.count > 1 { components.removeLast();folders.insert(components.joined(separator: "/")) }
        }
        var all = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, ArchiveTreeNode(path:$0.path,isDirectory:$0.isDirectory,size:$0.size,children:$0.isDirectory ? [] : nil)) })
        for folder in folders where all[folder] == nil {all[folder] = .init(path:folder,isDirectory:true,size:0,children:[])}
        var result: [ArchiveTreeNode] = []
        for path in all.keys.sorted(by: { $0.split(separator:"/").count > $1.split(separator:"/").count }) {
            guard let node=all[path] else {continue}
            let parent=path.split(separator:"/").dropLast().joined(separator:"/")
            if parent.isEmpty {result.append(node)} else {all[parent]?.children?.append(node);all[parent]?.size += node.size}
        }
        func sorted(_ nodes:[ArchiveTreeNode])->[ArchiveTreeNode] {nodes.map {var n=$0;if let c=n.children {n.children=sorted(c)};return n}.sorted{if $0.isDirectory != $1.isDirectory{return $0.isDirectory};return $0.name.localizedStandardCompare($1.name) == .orderedAscending}}
        return sorted(result)
    }
}
