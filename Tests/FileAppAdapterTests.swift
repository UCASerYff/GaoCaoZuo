import Foundation
import AppKit
import Darwin

@MainActor func runFileAppAdapterTests() throws {
    let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent("GaoAdapter-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false);defer{try? fm.removeItem(at:root)}
    var checks=0
    func expect(_ value:@autoclosure () throws -> Bool,_ description:String) throws {checks += 1;guard try value() else{throw DataFailure.message(description)}}
    func rejects(_ description:String,_ body:() throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw DataFailure.message(description)
    }
    let directory=root.appendingPathComponent("中文 空格 '单双\"引号 `$() ; & #")
    try fm.createDirectory(at:directory,withIntermediateDirectories:false)
    let requestBoard=NSPasteboard.withUniqueName()
    defer {requestBoard.releaseGlobally()}
    try TerminalFolderService.prepareDirectoryPasteboard(directory,board:requestBoard)
    try expect(requestBoard.pasteboardItems?.count == 1,"Terminal service has exactly one directory request item")
    try expect(requestBoard.string(forType:.fileURL).flatMap{URL(string:$0)}?.standardizedFileURL.path == directory.standardizedFileURL.path,"Terminal file service preserves the Unicode and punctuation directory as a standard file URL")
    try expect(requestBoard.string(forType:.init("public.plain-text")) == directory.path && requestBoard.string(forType:.string) == directory.path,"Terminal text representations preserve the literal directory without shell interpretation")
    let file=directory.appendingPathComponent("-文件 ' \" ; $.txt");try Data("only test".utf8).write(to:file)
    let other=directory.appendingPathComponent("第二文件.txt");try Data("second".utf8).write(to:other)
    let dirs=try FileAppAdapter.workingDirectories([file,other,directory])
    try expect(dirs.map(\.path) == [directory.path],"terminal converts files to parent directories and deduplicates sessions")
    // Execute ONLY our constant cd/pwd check. Injection-looking path text stays one literal.
    let task=Process(), pipe=Pipe();task.executableURL=URL(fileURLWithPath:"/bin/zsh")
    task.arguments=["-f","-c","cd -- "+FileAppAdapter.shellLiteral(directory.path)+" && /bin/pwd -P"]
    task.standardOutput=pipe;task.standardError=FileHandle.nullDevice;try task.run()
    let actual=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
    try expect(task.terminationStatus == 0 && String(data:actual,encoding:.utf8)?.trimmingCharacters(in:.newlines) == (try FileTools.canonicalURL(directory)).path,"terminal quote roundtrip handles Unicode, spaces, quotes, command substitution and punctuation")
    let terminal=try FileAppAdapter.terminalScript(bundleID:"com.apple.Terminal",directories:dirs,newWindow:true)
    let iterm=try FileAppAdapter.terminalScript(bundleID:"com.googlecode.iterm2",directories:dirs,newWindow:false)
    try expect(terminal.contains("do script ") && !terminal.contains("System Events") && !terminal.contains("selected tab") && !terminal.contains("front window"),"Terminal new window never targets a user's existing session or sends global keystrokes")
    try rejects("Terminal tab request must fail closed before generating automation") {
        _ = try FileAppAdapter.terminalScript(bundleID:"com.apple.Terminal",directories:dirs,newWindow:false)
    }
    guard case .terminalTabs(let serviceDirectories)=try FileAppAdapter.plan(bundleID:"com.apple.Terminal",appURL:root,files:[directory],disposition:.reuseWindow) else {throw DataFailure.message("Terminal tab must use the public folder service, never silently substitute a new window")}
    try expect(serviceDirectories == [directory],"Terminal tab paths are data for the system folder service")
    guard case .automation(let newWindowScript)=try FileAppAdapter.plan(bundleID:"com.apple.Terminal",appURL:root,files:[directory],disposition:.newWindow) else {throw DataFailure.message("Terminal new-window plan missing")}
    try expect(newWindowScript == (try FileAppAdapter.terminalScript(bundleID:"com.apple.Terminal",directories:dirs,newWindow:true,appURL:root)),"explicit Terminal new-window disposition pins the selected app path")
    try expect(newWindowScript.hasPrefix("tell application "+FileAppAdapter.appleLiteral(root.path)),"Terminal AppleEvents target the selected installed copy, not an arbitrary same-bundle-ID app")
    try expect(iterm.contains("create tab with default profile command") && !iterm.contains("write text"),"iTerm tabs use documented new-session override")
    // Validate generated focus text only; this fixture is never opened and no
    // AppleScript is compiled or sent to a real Terminal process.
    let terminalApp=directory.appendingPathComponent("终端 ' \" \\ $().app")
    try fm.createDirectory(at:terminalApp.appendingPathComponent("Contents"),withIntermediateDirectories:true)
    try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"com.apple.Terminal"],format:.xml,options:0).write(to:terminalApp.appendingPathComponent("Contents/Info.plist"))
    let focus=try TerminalFolderService.terminalFocusScript(appURL:terminalApp,windowID:72164)
    try expect(focus.hasPrefix("tell application "+FileAppAdapter.appleLiteral(terminalApp.path)+"\n") && focus.contains("终端 ' \\\" \\\\ $().app"),"Terminal focus targets the exact selected app path with Unicode, quotes and backslashes escaped")
    try expect(focus.contains("every window whose id is 72164") && focus.contains("(count of candidates) is not 1"),"Terminal focus requires one exact positive captured window ID")
    try expect(focus.contains("visible of targetWindow") && focus.contains("miniaturized of targetWindow") && focus.contains("activate\n") && focus.contains("set frontmost of targetWindow to true"),"Terminal focus checks captured-window visibility before activating that window")
    try expect(!["do script","write text","keystroke","System Events","create tab","create window","close window"].contains(where:{focus.contains($0)}),"Terminal focus cannot create sessions, send shell input or control unrelated apps")
    for invalidID in [0,-1] {
        try rejects("Terminal focus rejects nonpositive window identity") {_ = try TerminalFolderService.terminalFocusScript(appURL:terminalApp,windowID:invalidID)}
    }
    try rejects("Terminal focus rejects non-file application URLs") {_ = try TerminalFolderService.terminalFocusScript(appURL:URL(string:"https://example.com/Terminal.app")!,windowID:72164)}
    try rejects("Terminal focus rejects a missing Terminal bundle identity") {_ = try TerminalFolderService.terminalFocusScript(appURL:root,windowID:72164)}
    let app=root.appendingPathComponent("Adapter.app"),mac=app.appendingPathComponent("Contents/MacOS"),resources=app.appendingPathComponent("Contents/Resources/app/out")
    try fm.createDirectory(at:mac,withIntermediateDirectories:true);try fm.createDirectory(at:resources,withIntermediateDirectories:true)
    let executable=mac.appendingPathComponent("Editor");try Data("test executable is never run".utf8).write(to:executable);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
    try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"com.microsoft.VSCode","CFBundleExecutable":"Editor"],format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
    try rejects("Terminal focus rejects a different app's bundle identity") {_ = try TerminalFolderService.terminalFocusScript(appURL:app,windowID:72164)}
    try Data("test CLI is never run".utf8).write(to:resources.appendingPathComponent("cli.js"))
    for id in ["com.microsoft.VSCode","com.todesktop.230313mzl4w4u92"] {
        guard case .command(let exe,let args,let env)=try FileAppAdapter.plan(bundleID:id,appURL:app,files:[file,other,directory],disposition:.newWindow) else {throw DataFailure.message("missing editor adapter")}
        try expect((try FileTools.canonicalURL(exe)).path == (try FileTools.canonicalURL(executable)).path && args == [resources.appendingPathComponent("cli.js").path,"--new-window","--",file.path,other.path,directory.path] && env["ELECTRON_RUN_AS_NODE"] == "1","Code/Cursor uses argument array, preserves file/folder order and explicit new-window semantics")
    }
    let subl=app.appendingPathComponent("Contents/SharedSupport/bin/subl");try fm.createDirectory(at:subl.deletingLastPathComponent(),withIntermediateDirectories:true);try Data().write(to:subl);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:subl.path)
    guard case .command(_,let args,_)=try FileAppAdapter.plan(bundleID:"com.sublimetext.4",appURL:app,files:[file,directory]) else {throw DataFailure.message("missing Sublime adapter")}
    try expect(args == ["--add","--",file.path,directory.path],"Sublime file/folder arguments cannot become options")
    let before=TerminalFolderService.Snapshot(frontID:10,windows:[.init(id:10,ttys:["/dev/ttys001"]),.init(id:20,ttys:["/dev/ttys002"])])
    try expect(try TerminalFolderService.newTTY(before:before,after:before) == nil,"unchanged TTY identities cannot masquerade as a created tab")
    let after=TerminalFolderService.Snapshot(frontID:10,windows:[.init(id:20,ttys:["/dev/ttys002"]),.init(id:10,ttys:["/dev/ttys001","/dev/ttys003"])])
    try expect(try TerminalFolderService.newTTY(before:before,after:after) == "/dev/ttys003","only one new TTY in the captured window proves the new tab")
    try rejects("old tab disappearance must stop verification") {_ = try TerminalFolderService.newTTY(before:before,after:.init(frontID:10,windows:[.init(id:10,ttys:["/dev/ttys003"]),.init(id:20,ttys:["/dev/ttys002"])]))}
    try rejects("two concurrent new tabs cannot prove service result") {_ = try TerminalFolderService.newTTY(before:before,after:.init(frontID:10,windows:[.init(id:10,ttys:["/dev/ttys001","/dev/ttys003","/dev/ttys004"]),.init(id:20,ttys:["/dev/ttys002"])]))}
    try rejects("new tab in another window cannot prove service result") {_ = try TerminalFolderService.newTTY(before:before,after:.init(frontID:10,windows:[.init(id:10,ttys:["/dev/ttys001"]),.init(id:20,ttys:["/dev/ttys002","/dev/ttys003"])]))}
    try rejects("new window is not silently accepted for tab request") {_ = try TerminalFolderService.newTTY(before:before,after:.init(frontID:30,windows:after.windows+[.init(id:30,ttys:["/dev/ttys004"])]))}
    try rejects("new front window must stop verification") {_ = try TerminalFolderService.newTTY(before:before,after:.init(frontID:20,windows:after.windows))}
    print("PASS: \(checks) file app adapter tests; simulated bundles are never launched, iTerm/Sublime real UI unverified")
}
