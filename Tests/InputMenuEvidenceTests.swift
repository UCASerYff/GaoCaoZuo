import Foundation

/// Synthetic menu trees only. No AX reads, process launches, menu clicks, or GUI.
func runInputMenuEvidenceTests() throws {
    var checks = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw InputMenuEvidenceError.invalid("菜单证据测试失败：" + label) }; checks += 1
    }
    func reject(_ body: () throws -> Void, _ label: String) throws {
        do { try body() } catch { checks += 1; return }
        throw InputMenuEvidenceError.invalid("菜单证据测试未拒绝：" + label)
    }
    struct Node {
        var title: String
        var role: String
        var enabled = true
        var press = false
        var shortcut = InputMenuShortcutEvidence(character: nil, modifiers: nil, virtualKey: nil)
        var children: [Int] = []
    }
    let shortcut = InputMenuShortcutEvidence(character: "n", modifiers: 1, virtualKey: 45)
    let application = InputMenuApplicationEvidence(bundleID: "test.synthetic.Menu", bundlePath: "/Applications/SyntheticMenu.app", version: "1.00", build: "1")
    var evidence = InputMenuEvidence(application: application,
        components: [.init(title: "File", role: "AXMenuBarItem"), .init(title: "New", role: "AXMenuItem")], shortcut: shortcut)
    var nodes = [Node(title: "", role: "AXMenuBar", children: [1]), Node(title: "File", role: "AXMenuBarItem", children: [2]),
                 Node(title: "New", role: "AXMenuItem", press: true, shortcut: shortcut)]
    func resolve() throws -> Int {
        try InputMenuEvidenceResolver.resolve(evidence: evidence, root: 0, children: { nodes[$0].children },
            title: { nodes[$0].title }, role: { nodes[$0].role }, enabled: { nodes[$0].enabled },
            canPress: { nodes[$0].press }, shortcut: { nodes[$0].shortcut })
    }
    try expect(try resolve() == 2, "确切路径角色快捷键匹配")
    let encoded = try JSONEncoder().encode(evidence)
    try expect(try JSONDecoder().decode(InputMenuEvidence.self, from: encoded) == evidence, "菜单证据持久往返")
    nodes[1].enabled = false; try reject({ _ = try resolve() }, "禁用上级菜单"); nodes[1].enabled = true
    nodes[2].enabled = false; try reject({ _ = try resolve() }, "禁用最终菜单"); nodes[2].enabled = true
    nodes[2].role = "AXButton"; try reject({ _ = try resolve() }, "标题相同但角色变化"); nodes[2].role = "AXMenuItem"
    nodes[2].shortcut.modifiers = 0; try reject({ _ = try resolve() }, "快捷键修饰变化"); nodes[2].shortcut = shortcut
    nodes[2].shortcut.character = "x"; try reject({ _ = try resolve() }, "快捷键字符变化"); nodes[2].shortcut = shortcut
    nodes[2].shortcut.virtualKey = 7; try reject({ _ = try resolve() }, "真实虚拟键变化"); nodes[2].shortcut = shortcut
    nodes[2].press = false; try reject({ _ = try resolve() }, "无公开点按动作"); nodes[2].press = true
    nodes.append(Node(title: "New", role: "AXMenuItem", press: true, shortcut: shortcut)); nodes[1].children = [2,3]
    try reject({ _ = try resolve() }, "同级重名不能靠索引或快捷键猜测"); nodes[1].children = [2]
    nodes[2].title = "New Document"; try reject({ _ = try resolve() }, "应用语言或菜单标题变化"); nodes[2].title = "New"
    nodes[1].children = Array(repeating: 2, count: 513); try reject({ _ = try resolve() }, "单层过量菜单"); nodes[1].children = [2]
    evidence.schemaVersion = 2
    try reject({ _ = try JSONDecoder().decode(InputMenuEvidence.self, from: JSONEncoder().encode(evidence)) }, "未来证据版本不默默重写")
    evidence.schemaVersion = 1
    try reject({ try evidence.validate(path: ["File", "Other"], bundleID: application.bundleID) }, "配置路径与证据脱离")
    try reject({ try evidence.validate(path: evidence.path, bundleID: "test.another.App") }, "配置应用与证据脱离")
    evidence.components[1].title = ""
    try reject({ try evidence.validate(path: evidence.path, bundleID: application.bundleID) }, "空标题不能当正常路径")
    evidence.components[1].title = "New"; evidence.shortcut.modifiers = 16
    try reject({ try evidence.validate(path: evidence.path, bundleID: application.bundleID) }, "未知AX修饰位不猜测")
    evidence.shortcut = shortcut; evidence.application.bundlePath = "relative/SyntheticMenu.app"
    try reject({ try evidence.validate(path: evidence.path, bundleID: application.bundleID) }, "安装身份路径无效")
    print("菜单证据、角色与快捷键重新解析纯逻辑回归通过：\(checks)项；未访问AX或GUI。")
}
