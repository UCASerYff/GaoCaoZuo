import AppKit
import Foundation
import Darwin

/// Product adapters use documented automation/CLI surfaces. Paths are data,
/// never appended as unquoted shell syntax, and are never logged.
enum FileAppAdapter {
    enum Disposition { case reuseWindow, newWindow }
    enum Plan {
        case workspace([URL])
        case command(executable: URL, arguments: [String], environment: [String:String])
        case automation(String)
    }
    static let terminalIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
    static func shellLiteral(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func workingDirectories(_ files: [URL]) throws -> [URL] {
        var seen = Set<String>()
        return try files.compactMap { file in
            guard file.isFileURL, !file.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw FileToolsError.invalid("应用打开路径无效或包含控制字符。") }
            let checked = try EnhancedFileTools.checked(file)
            let directory = checked.st_mode & S_IFMT == S_IFDIR ? file : file.deletingLastPathComponent()
            return seen.insert(directory.path).inserted ? directory : nil
        }
    }
    static func terminalScript(bundleID: String, directories: [URL], newWindow: Bool) throws -> String {
        guard terminalIDs.contains(bundleID), !directories.isEmpty else { throw FileToolsError.invalid("终端应用或工作目录无效。") }
        // Terminal's public scripting interface creates a window with an untargeted
        // `do script`, but exposes no new-tab command. Sending a global Cmd-T and
        // then targeting the selected tab can write into a user's existing session.
        // Refuse that disposition before activating an app or generating commands.
        guard bundleID != "com.apple.Terminal" || newWindow else {
            throw FileToolsError.invalid("Terminal 新标签页尚无法安全核验，未发送任何命令。请在文件设置中开启“Terminal 使用新窗口”，或使用支持明确创建标签页的 iTerm。")
        }
        var lines = ["tell application id \"\(bundleID)\"", "activate"]
        for directory in directories {
            guard directory.isFileURL, !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw FileToolsError.invalid("终端目录包含控制字符，未执行。") }
            let command = "cd -- " + shellLiteral(directory.path)
            if bundleID == "com.googlecode.iterm2" {
                // iTerm's documented command override starts a NEW session; never type into a user's existing shell.
                let session = appleLiteral("/bin/zsh -f -c " + shellLiteral(command + " && exec /bin/zsh"))
                if newWindow { lines.append("create window with default profile command " + session) }
                else { lines += ["if (count of windows) is 0 then", "create window with default profile command " + session, "else", "tell current window to create tab with default profile command " + session, "end if"] }
            } else { lines.append("do script " + appleLiteral(command)) }
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }
    static func plan(bundleID: String, appURL: URL, files: [URL], disposition: Disposition = .reuseWindow) throws -> Plan {
        guard !files.isEmpty, files.count <= 1000 else { throw FileToolsError.invalid("请选择 1–1000 个文件或目录。") }
        for file in files { _ = try EnhancedFileTools.checked(file); guard file.isFileURL, !file.path.contains("\0") else { throw FileToolsError.invalid("打开路径无效。") } }
        if terminalIDs.contains(bundleID) { return .automation(try terminalScript(bundleID: bundleID, directories: workingDirectories(files), newWindow: disposition == .newWindow)) }
        let isCode = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"].contains(bundleID)
        if isCode {
            guard let executable = Bundle(url: appURL)?.executableURL else { throw FileToolsError.invalid("编辑器程序不完整。") }
            let cli = appURL.appendingPathComponent("Contents/Resources/app/out/cli.js")
            guard FileManager.default.fileExists(atPath: cli.path), FileManager.default.isExecutableFile(atPath: executable.path) else { throw FileToolsError.invalid("编辑器缺少官方命令行入口，未改用不确定的打开方式。") }
            let flag = disposition == .newWindow ? "--new-window" : "--reuse-window"
            return .command(executable: executable, arguments: [cli.path, flag, "--"] + files.map(\.path), environment: ["ELECTRON_RUN_AS_NODE":"1"])
        }
        if bundleID == "com.sublimetext.4" || bundleID == "com.sublimetext.3" {
            let cli = appURL.appendingPathComponent("Contents/SharedSupport/bin/subl")
            guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw FileToolsError.invalid("Sublime Text 缺少官方 subl 工具。") }
            return .command(executable: cli, arguments: [disposition == .newWindow ? "--new-window" : "--add", "--"] + files.map(\.path), environment: [:])
        }
        return .workspace(files)
    }
    @MainActor static func open(files: [URL], bundleID: String, appURL: URL, disposition: Disposition = .reuseWindow, completion: @escaping (Error?) -> Void) throws {
        guard Bundle(url: appURL)?.bundleIdentifier == bundleID else { throw FileToolsError.invalid("应用身份已变化，请重新选择应用。") }
        switch try plan(bundleID: bundleID, appURL: appURL, files: files, disposition: disposition) {
        case .workspace(let urls):
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in completion(error) }
        case .automation(let source):
            var failure: NSDictionary?
            guard let script = NSAppleScript(source: source) else { throw FileToolsError.invalid("无法构建终端自动化请求。") }
            script.executeAndReturnError(&failure)
            if let failure { throw FileToolsError.invalid("终端自动化失败；请检查自动化权限（\(failure[NSAppleScript.errorNumber] ?? "未知")）。") }
            completion(nil)
        case .command(let executable, let arguments, let environment):
            let task = Process(); task.executableURL = executable; task.arguments = arguments
            task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            task.terminationHandler = { task in completion(task.terminationStatus == 0 ? nil : FileToolsError.invalid("编辑器命令失败（\(task.terminationStatus)）。")) }
            try task.run()
        }
    }
}
