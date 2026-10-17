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
        case terminalTabs([URL])
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
    static func terminalScript(bundleID: String, directories: [URL], newWindow: Bool, appURL:URL? = nil) throws -> String {
        guard terminalIDs.contains(bundleID), !directories.isEmpty else { throw FileToolsError.invalid("终端应用或工作目录无效。") }
        // Terminal's public scripting interface creates a window with an untargeted
        // `do script`, but exposes no new-tab command. Sending a global Cmd-T and
        // then targeting the selected tab can write into a user's existing session.
        // Refuse that disposition before activating an app or generating commands.
        guard bundleID != "com.apple.Terminal" || newWindow else {
            throw FileToolsError.invalid("Terminal 新标签页尚无法安全核验，未发送任何命令。请在文件设置中开启“Terminal 使用新窗口”，或使用支持明确创建标签页的 iTerm。")
        }
        // The chosen bundle's path is also the AppleEvent target. LaunchServices
        // resolution by bundle ID alone can pick a different installed copy.
        let target=appURL.map{appleLiteral($0.path)} ?? "id \"\(bundleID)\""
        var lines = ["tell application \(target)", "activate"]
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
        if bundleID == "com.apple.Terminal", disposition == .reuseWindow { return .terminalTabs(try workingDirectories(files)) }
        if terminalIDs.contains(bundleID) { return .automation(try terminalScript(bundleID: bundleID, directories: workingDirectories(files), newWindow: disposition == .newWindow,appURL:appURL)) }
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
        case .terminalTabs(let directories):
            try TerminalFolderService.start(directories:directories,appURL:appURL,completion:completion)
        case .workspace(let urls):
            let configuration=NSWorkspace.OpenConfiguration()
            configuration.allowsRunningApplicationSubstitution=false
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration:configuration) { _, error in completion(error) }
        case .automation(let source):
            var failure: NSDictionary?
            guard let script = NSAppleScript(source: source) else { throw FileToolsError.invalid("无法构建终端自动化请求。") }
            script.executeAndReturnError(&failure)
            if let failure { throw FileToolsError.invalid(L10n.format("终端自动化失败；请检查自动化权限（%@）。",String(describing:failure[NSAppleScript.errorNumber] ?? L10n.text("未知")))) }
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

/// The system's documented folder service creates the session itself. No command
/// is ever typed or sent to an existing tab; only window IDs and TTYs are read.
@MainActor enum TerminalFolderService {
    struct Window: Equatable { var id:Int; var ttys:Set<String> }
    struct Snapshot: Equatable { var frontID:Int; var windows:[Window] }
    static var running = false
    static let serviceName = "New Terminal Tab at Folder"
    static func newTTY(before:Snapshot,after:Snapshot) throws -> String? {
        let oldIDs=before.windows.map(\.id), newIDs=after.windows.map(\.id)
        guard !oldIDs.isEmpty, Set(oldIDs).count == oldIDs.count, Set(newIDs).count == newIDs.count,
              oldIDs.allSatisfy({$0>0}), newIDs.allSatisfy({$0>0}),
              Set(oldIDs) == Set(newIDs), before.frontID == after.frontID,
              oldIDs.contains(before.frontID) else { throw FileToolsError.invalid("Terminal 原窗口身份已变化，停止标签页操作。") }
        var added:Set<String>=[]
        for old in before.windows {
            guard let current=after.windows.first(where:{$0.id == old.id}), !old.ttys.isEmpty,
                  old.ttys.allSatisfy({$0.hasPrefix("/dev/")}), old.ttys.isSubset(of:current.ttys) else { throw FileToolsError.invalid("Terminal 原标签页身份已变化，停止操作。") }
            let difference=current.ttys.subtracting(old.ttys)
            guard difference.isEmpty || old.id == before.frontID else { throw FileToolsError.invalid("Terminal 其他窗口出现新标签页，无法证明本次结果。") }
            added.formUnion(difference)
        }
        let allOld=before.windows.flatMap{$0.ttys}, allNew=after.windows.flatMap{$0.ttys}
        guard Set(allOld).count == allOld.count, Set(allNew).count == allNew.count,
              added.count <= 1, added.allSatisfy({$0.hasPrefix("/dev/")}), allNew.count == allOld.count+added.count else { throw FileToolsError.invalid("Terminal 新标签页不唯一，无法证明本次结果。") }
        return added.first
    }
    static func readSnapshot() throws -> Snapshot {
        let source="""
        tell application id "com.apple.Terminal"
            if (count of windows) is 0 then error "Terminal has no window" number -1728
            set capturedFront to id of front window
            set capturedWindows to {}
            repeat with w in windows
                set end of capturedWindows to {id of w, tty of every tab of w}
            end repeat
            return {capturedFront, capturedWindows}
        end tell
        """
        var failure:NSDictionary?
        guard let script=NSAppleScript(source:source) else { throw FileToolsError.invalid("无法建立 Terminal 身份核验请求。") }
        let result=script.executeAndReturnError(&failure)
        guard failure == nil, let front=result.atIndex(1), let rows=result.atIndex(2), rows.numberOfItems>0 else { throw FileToolsError.invalid("请先打开一个 Terminal 窗口并允许自动化，或选择新窗口方式；未向任何标签页发送命令。") }
        var windows:[Window]=[]
        for index in 1...rows.numberOfItems {
            guard let row=rows.atIndex(index), let id=row.atIndex(1), let values=row.atIndex(2), values.numberOfItems>0 else { throw FileToolsError.invalid("Terminal 标签页身份不可读取。") }
            var ttys:Set<String>=[]
            for position in 1...values.numberOfItems {
                guard let tty=values.atIndex(position)?.stringValue, tty.hasPrefix("/dev/"), ttys.insert(tty).inserted else { throw FileToolsError.invalid("Terminal 标签页标识无效。") }
            }
            windows.append(.init(id:Int(id.int32Value),ttys:ttys))
        }
        return .init(frontID:Int(front.int32Value),windows:windows)
    }
    static func start(directories:[URL],appURL:URL,completion:@escaping(Error?)->Void) throws {
        guard !running else { throw FileToolsError.invalid("请等待当前 Terminal 标签页请求完成。") }
        guard let bundle=Bundle(url:appURL), bundle.bundleIdentifier == "com.apple.Terminal",
              let services=bundle.object(forInfoDictionaryKey:"NSServices") as? [[String:Any]],
              services.contains(where:{ ($0["NSMenuItem"] as? [String:String])?["default"] == serviceName && $0["NSMessage"] as? String == "newTerminalAtFolder" && $0["NSUserData"] as? String == "New Tab" }) else { throw FileToolsError.invalid("当前 Terminal 未声明公开的新标签页目录服务。") }
        running=true
        Task { @MainActor in
            defer { running=false }
            do {
                for directory in directories {
                    try Task.checkCancellation()
                    let applications=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.Terminal")
                    guard applications.count == 1, let app=applications.first,
                          app.bundleURL?.standardizedFileURL == appURL.standardizedFileURL,
                          let identity=WindowProcessIdentity.capture(pid:app.processIdentifier,launchDate:app.launchDate) else { throw FileToolsError.invalid("请先打开 Terminal 窗口，或选择安全的新窗口方式。") }
                    let before=try readSnapshot()
                    _ = try newTTY(before:before,after:before)
                    let board=NSPasteboard.withUniqueName()
                    defer { board.releaseGlobally() }
                    // Use a dedicated request board; never read or replace the
                    // general clipboard. Paths are data for Apple's own service.
                    guard board.writeObjects([directory as NSURL]), board.setString(directory.path,forType:.string) else { throw FileToolsError.invalid("无法准备 Terminal 文件夹服务参数。") }
                    guard WindowProcessIdentity.matches(captured:identity,currentPID:app.processIdentifier,currentLaunchDate:app.launchDate), !app.isTerminated else { throw FileToolsError.invalid("Terminal 进程身份已变化。") }
                    try Task.checkCancellation()
                    guard NSPerformService(serviceName,board) else { throw FileToolsError.invalid("系统 Terminal 新标签页服务不可用；未改用旧标签页或新窗口。") }
                    var proven=false
                    for _ in 0..<30 {
                        try Task.checkCancellation()
                        guard WindowProcessIdentity.matches(captured:identity,currentPID:app.processIdentifier,currentLaunchDate:app.launchDate), !app.isTerminated else { throw FileToolsError.invalid("Terminal 进程身份已变化，结果未核验。") }
                        if try newTTY(before:before,after:readSnapshot()) != nil { proven=true;break }
                        try await Task.sleep(nanoseconds:100_000_000)
                    }
                    guard proven else { throw FileToolsError.invalid("系统服务已发送，但未核验到同窗口内唯一新标签页；请检查 Terminal，未重复发送请求。") }
                }
                completion(nil)
            } catch { completion(error) }
        }
    }
}
