import Foundation

struct InputMenuApplicationEvidence: Codable, Equatable {
    var bundleID: String
    var bundlePath: String
    var version: String?
    var build: String?
    func validate() throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 256, !bundleID.contains("\0"),
              bundlePath.hasPrefix("/"), bundlePath.utf8.count <= 4096, !bundlePath.contains("\0"),
              [version, build].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 && !$0.contains("\0") }) else {
            throw InputMenuEvidenceError.invalid("菜单应用身份无效，请重新选择。")
        }
    }
}

struct InputMenuShortcutEvidence: Codable, Equatable {
    var character: String?
    var modifiers: Int?
    var virtualKey: Int?
    func validate() throws {
        guard character.map({ !$0.contains("\0") && $0.utf8.count <= 128 }) ?? true,
              modifiers.map({ (0...15).contains($0) }) ?? true,
              virtualKey.map({ (0...Int(UInt16.max)).contains($0) }) ?? true else {
            throw InputMenuEvidenceError.invalid("菜单快捷键属性超出公开范围，请重新选择。")
        }
    }
}

struct InputMenuComponentEvidence: Codable, Equatable {
    var title: String
    var role: String
}

/// Private user settings only. Paths bind the rule to the selected local installation;
/// they are not bundled into program resources or public acceptance examples.
struct InputMenuEvidence: Codable, Equatable {
    var schemaVersion = 1
    var application: InputMenuApplicationEvidence
    var components: [InputMenuComponentEvidence]
    var shortcut: InputMenuShortcutEvidence
    init(application: InputMenuApplicationEvidence, components: [InputMenuComponentEvidence], shortcut: InputMenuShortcutEvidence) {
        self.application = application; self.components = components; self.shortcut = shortcut
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, application, components, shortcut }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        application = try c.decode(InputMenuApplicationEvidence.self, forKey: .application)
        components = try c.decode([InputMenuComponentEvidence].self, forKey: .components)
        shortcut = try c.decode(InputMenuShortcutEvidence.self, forKey: .shortcut)
        try validate(path: path, bundleID: application.bundleID)
    }
    var path: [String] { components.map(\.title) }
    func validate(path: [String], bundleID: String) throws {
        try application.validate(); try shortcut.validate()
        guard schemaVersion == 1, application.bundleID == bundleID, self.path == path,
              (2...10).contains(components.count), components.allSatisfy({
                  !$0.title.isEmpty && $0.title.utf8.count <= 1024 && !$0.title.contains("\0")
                    && !$0.role.isEmpty && $0.role.utf8.count <= 128 && !$0.role.contains("\0")
              }) else { throw InputMenuEvidenceError.invalid("菜单证据版本、路径或角色不匹配，原规则保留，请重新选择。") }
    }
}

enum InputMenuEvidenceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum InputMenuEvidenceResolver {
    static func resolve<Node>(evidence: InputMenuEvidence, root: Node,
                              children: (Node) throws -> [Node], title: (Node) -> String,
                              role: (Node) -> String, enabled: (Node) -> Bool,
                              canPress: (Node) -> Bool, shortcut: (Node) -> InputMenuShortcutEvidence) throws -> Node {
        try evidence.validate(path: evidence.path, bundleID: evidence.application.bundleID)
        var current = root
        for component in evidence.components {
            let siblings = try children(current)
            guard siblings.count <= 512 else { throw InputMenuEvidenceError.invalid("菜单项目超过安全读取预算。") }
            let matches = siblings.filter { title($0) == component.title }
            guard matches.count == 1 else {
                throw InputMenuEvidenceError.invalid(matches.isEmpty ? "菜单已变化或未公开，请重新选择。" : "同级菜单存在重名，未执行以免点错。")
            }
            current = matches[0]
            guard role(current) == component.role, enabled(current) else {
                throw InputMenuEvidenceError.invalid("菜单角色或可用状态已变化，未执行。")
            }
        }
        guard canPress(current), shortcut(current) == evidence.shortcut else {
            throw InputMenuEvidenceError.invalid("菜单动作或快捷键线索已变化，请重新选择。")
        }
        return current
    }
}
