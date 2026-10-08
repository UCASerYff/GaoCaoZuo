import Foundation
import Darwin

private struct DataTestDocument: Codable {
    var schema = 1
    var value: String
}

@MainActor
func runDataTests() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("GaoOperation-DataTests-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    func check(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try condition() else { throw DataFailure.message("资料回归测试失败：\(description)") }
    }
    func rejects(_ description: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try check(rejected, description)
    }
    func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    let encoder = JSONEncoder()
    let first = DataTestDocument(value: "原资料")
    let replacement = DataTestDocument(value: "不应覆盖")
    let originalBytes = try encoder.encode(first)

    do {
        let directory = try makeDirectory("normal")
        let store = LocalData(directory: directory)
        let missing = try store.load("settings.json", as: DataTestDocument.self)
        try check(missing == nil, "真正缺失的文件可初始化")
        try store.save(first, name: "settings.json")
        try store.save(DataTestDocument(value: "更新"), name: "settings.json")
        let loaded = try LocalData(directory: directory).load("settings.json", as: DataTestDocument.self)
        try check(loaded?.value == "更新", "正常资料可以原子保存及再次加载")
    }
    do {
        let directory = try makeDirectory("corrupt")
        let url = directory.appendingPathComponent("settings.json")
        let damaged = Data([0xff, 0x7b, 0x01])
        try damaged.write(to: url)
        let store = LocalData(directory: directory)
        try rejects("损坏资料应报错") { _ = try store.load("settings.json", as: DataTestDocument.self) }
        try rejects("损坏资料锁住后续写入") { try store.save(first, name: "other.json") }
        try check(try Data(contentsOf: url) == damaged, "损坏原件保留")
        try check(!fm.fileExists(atPath: directory.appendingPathComponent("other.json").path), "锁写不创建其他文件")
    }
    do {
        let directory = try makeDirectory("new-schema")
        let url = directory.appendingPathComponent("settings.json")
        var tooNew = first; tooNew.schema = 2
        let bytes = try encoder.encode(tooNew); try bytes.write(to: url)
        let store = LocalData(directory: directory)
        try rejects("过新格式不可加载成旧模型") { _ = try store.load("settings.json", as: DataTestDocument.self) }
        try rejects("过新格式不可覆盖") { try store.save(replacement, name: "settings.json") }
        try check(try Data(contentsOf: url) == bytes, "过新资料原件保留")
    }
    do {
        let directory = try makeDirectory("external-change")
        let url = directory.appendingPathComponent("settings.json")
        try originalBytes.write(to: url)
        let store = LocalData(directory: directory)
        _ = try store.load("settings.json", as: DataTestDocument.self)
        let external = try encoder.encode(DataTestDocument(value: "外部修改"))
        try external.write(to: url, options: .atomic)
        try rejects("运行中外部修改拒绝覆盖") { try store.save(replacement, name: "settings.json") }
        try check(try Data(contentsOf: url) == external, "外部版本完整保留")
    }
    do {
        let directory = try makeDirectory("external-insert")
        let url = directory.appendingPathComponent("settings.json")
        let store = LocalData(directory: directory)
        _ = try store.load("settings.json", as: DataTestDocument.self)
        try originalBytes.write(to: url)
        try rejects("检查缺失后出现的新文件不可覆盖") { try store.save(replacement, name: "settings.json") }
        try check(try Data(contentsOf: url) == originalBytes, "外部新增资料保留")
    }
    do {
        let directory = try makeDirectory("external-delete")
        let url = directory.appendingPathComponent("settings.json")
        try originalBytes.write(to: url)
        let store = LocalData(directory: directory)
        _ = try store.load("settings.json", as: DataTestDocument.self)
        try fm.removeItem(at: url)
        try rejects("运行中删除资料不能作为首次使用重建") { try store.save(replacement, name: "settings.json") }
        try check(!fm.fileExists(atPath: url.path), "不重新创建已被外部删除的资料")
    }
    for dangling in [false, true] {
        let directory = try makeDirectory(dangling ? "dangling-link" : "file-link")
        let outside = root.appendingPathComponent(dangling ? "missing-target.json" : "outside.json")
        if !dangling { try originalBytes.write(to: outside) }
        let link = directory.appendingPathComponent("settings.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = LocalData(directory: directory)
        try rejects("符号链接（包括悬挂链接）不可当作普通/缺失资料") { _ = try store.load("settings.json", as: DataTestDocument.self) }
        try rejects("符号链接不可覆盖") { try store.save(first, name: "settings.json") }
        try check(try fm.destinationOfSymbolicLink(atPath: link.path) == outside.path, "原链接保留")
        if !dangling { try check(try Data(contentsOf: outside) == originalBytes, "外部链接目标不修改") }
        else { try check(!fm.fileExists(atPath: outside.path), "不创建悬挂链接目标") }
    }
    do {
        let directory = try makeDirectory("permissions")
        let url = directory.appendingPathComponent("settings.json")
        try originalBytes.write(to: url)
        let store = LocalData(directory: directory)
        guard chmod(url.path, 0) == 0 else { throw DataFailure.message("无法配置权限回归测试") }
        defer { _ = chmod(url.path, 0o600) }
        try rejects("无读取权限不可当作缺失") { _ = try store.load("settings.json", as: DataTestDocument.self) }
        try rejects("权限故障锁写") { try store.save(first, name: "other.json") }
    }
    do {
        let outside = try makeDirectory("outside-directory")
        let link = root.appendingPathComponent("linked-parent")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = LocalData(directory: link.appendingPathComponent("Data", isDirectory: true))
        try rejects("父目录链接不可跟随") { try store.save(first, name: "settings.json") }
        try check(!fm.fileExists(atPath: outside.appendingPathComponent("Data").path), "未在外部目录创建资料")
    }
    do {
        let parent = try makeDirectory("inaccessible-parent")
        let directory = parent.appendingPathComponent("Data", isDirectory: true)
        let store = LocalData(directory: directory)
        try store.save(first, name: "settings.json")
        guard chmod(parent.path, 0) == 0 else { throw DataFailure.message("无法配置父目录权限回归测试") }
        defer { _ = chmod(parent.path, 0o700) }
        try rejects("无法遍历父目录不可视为空数据") { _ = try store.load("settings.json", as: DataTestDocument.self) }
        try rejects("无法遍历父目录时停止所有写入") { try store.save(first, name: "other.json") }
    }
    do {
        let directory = try makeDirectory("replaced-parent")
        let store = LocalData(directory: directory)
        try store.save(first, name: "settings.json")
        let retained = root.appendingPathComponent("retained-parent", isDirectory: true)
        try fm.moveItem(at: directory, to: retained)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try rejects("父目录运行中替换锁写") { try store.save(replacement, name: "settings.json") }
        try check(!fm.fileExists(atPath: directory.appendingPathComponent("settings.json").path), "不向替换后的目录写入")
        let loaded = try LocalData(directory: retained).load("settings.json", as: DataTestDocument.self)
        try check(loaded?.value == first.value, "旧目录资料完整保留")
    }

    // These tests only instantiate the service and operate on saved records. No pasteboard API is called.
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l1kAAAAASUVORK5CYII=")!
    func fixture(_ name: String) throws -> (URL, URL, ClipboardItem, Data) {
        let directory = try makeDirectory(name)
        let clipboard = directory.appendingPathComponent("Clipboard", isDirectory: true)
        try fm.createDirectory(at: clipboard, withIntermediateDirectories: false)
        var item = ClipboardItem(kind: .image, title: "测试附件", sourceApp: "test.application")
        item.imageFile = item.id.uuidString + ".png"
        try png.write(to: clipboard.appendingPathComponent(item.imageFile!))
        let history = try encoder.encode(ClipboardDocument(items: [item]))
        try history.write(to: clipboard.appendingPathComponent("history.json"))
        return (directory, clipboard, item, history)
    }
    do {
        let (directory, clipboard, item, original) = try fixture("attachment-missing-at-load")
        try fm.removeItem(at: clipboard.appendingPathComponent(item.imageFile!))
        let service = ClipboardService(directory: directory, tracksApplications: false)
        service.clearUnpinned()
        try check(service.error != nil, "启动时缺失附件必须显示错误")
        try check(try Data(contentsOf: clipboard.appendingPathComponent("history.json")) == original, "缺失附件不覆盖历史为空")
    }
    do {
        let (directory, clipboard, item, original) = try fixture("attachment-missing-after-load")
        let service = ClipboardService(directory: directory, tracksApplications: false)
        try check(service.items.count == 1, "有效附件可以加载")
        try fm.removeItem(at: clipboard.appendingPathComponent(item.imageFile!))
        service.delete(item.id)
        service.clearUnpinned()
        try check(service.error != nil && service.items.count == 1, "删除不能绕过缺失附件保护，内存历史也保留")
        try check(try Data(contentsOf: clipboard.appendingPathComponent("history.json")) == original, "每次持久化核验旧附件")
    }
    do {
        let (directory, clipboard, item, original) = try fixture("attachment-link-after-load")
        let service = ClipboardService(directory: directory, tracksApplications: false)
        let outside = root.appendingPathComponent("private-attachment.bin")
        let external = Data("外部私有附件，不能读取或删除".utf8)
        try external.write(to: outside)
        let attachment = clipboard.appendingPathComponent(item.imageFile!)
        try fm.removeItem(at: attachment)
        try fm.createSymbolicLink(at: attachment, withDestinationURL: outside)
        service.pin(item.id)
        service.delete(item.id)
        try check(service.error != nil && service.items.first?.pinned == false, "附件替换成链接锁住整个剪贴板写入")
        try check(try Data(contentsOf: clipboard.appendingPathComponent("history.json")) == original, "符号链接故障保留历史")
        try check(try fm.destinationOfSymbolicLink(atPath: attachment.path) == outside.path, "异常链接也不自动清理")
        try check(try Data(contentsOf: outside) == external, "外部附件完整保留")
    }
    do {
        let (directory, clipboard, item, original) = try fixture("attachment-external-change")
        let service = ClipboardService(directory: directory, tracksApplications: false)
        let external = Data("外部替换内容".utf8)
        try external.write(to: clipboard.appendingPathComponent(item.imageFile!), options: .atomic)
        service.clearUnpinned()
        try check(service.error != nil && service.items.count == 1, "常规附件被外部修改同样停止写入")
        try check(try Data(contentsOf: clipboard.appendingPathComponent("history.json")) == original, "附件外部修改不丢历史")
    }
    do {
        let (directory, clipboard, item, _) = try fixture("invalid-attachment-name")
        var invalid = item; invalid.imageFile = "history.json"
        let original = try encoder.encode(ClipboardDocument(items: [invalid]))
        try original.write(to: clipboard.appendingPathComponent("history.json"))
        let service = ClipboardService(directory: directory, tracksApplications: false)
        service.clearUnpinned()
        try check(service.error != nil, "附件不能引用 history.json")
        try check(try Data(contentsOf: clipboard.appendingPathComponent("history.json")) == original, "不会把历史文件作为附件删除")
        try rejects("重复 ID 拒绝加载") {
            try ClipboardService.validateDocument(ClipboardDocument(items: [item, item]), directory: clipboard)
        }
        var mismatch = item; mismatch.imageFile = UUID().uuidString + ".png"
        try rejects("附件必须归属对应记录 ID") { try ClipboardService.validateDocument(ClipboardDocument(items: [mismatch]), directory: clipboard) }
    }
    do {
        let (directory, clipboard, item, _) = try fixture("valid-delete")
        let service = ClipboardService(directory: directory, tracksApplications: false)
        service.delete(item.id)
        try check(service.error == nil && service.items.isEmpty, "正常删除能提交历史")
        try check(!fm.fileExists(atPath: clipboard.appendingPathComponent(item.imageFile!).path), "只删除已验证的本记录附件")
        let document = try JSONDecoder().decode(ClipboardDocument.self, from: Data(contentsOf: clipboard.appendingPathComponent("history.json")))
        try check(document.items.isEmpty, "正常删除磁盘结果正确")
    }
    do {
        let (directory, clipboard, item, _) = try fixture("clipboard-history-external-change")
        let service = ClipboardService(directory: directory, tracksApplications: false)
        var externalItem = item; externalItem.title = "其他程序修改的历史"
        let external = try encoder.encode(ClipboardDocument(items: [externalItem]))
        let history = clipboard.appendingPathComponent("history.json")
        try external.write(to: history, options: .atomic)
        service.delete(item.id)
        try check(service.error != nil && service.items.count == 1, "历史被外部修改拒绝提交")
        try check(try Data(contentsOf: history) == external, "外部历史完整保留")
        try check(fm.fileExists(atPath: clipboard.appendingPathComponent(item.imageFile!).path), "历史提交失败不删除附件")
    }
    do {
        let settings = OperationSettings()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(settings)) as! [String: Any]
        object.removeValue(forKey: "inputExcludedApps")
        let migrated = try JSONDecoder().decode(OperationSettings.self, from: JSONSerialization.data(withJSONObject: object))
        try check(migrated.inputExcludedApps.isEmpty && migrated.favorites == settings.favorites, "旧配置只补输入排除列表，不重置其他资料")
    }
    print("PASS: 资料损坏/版本/权限/符号链接/外部变更保护、剪贴板附件保留与安全删除")
}
