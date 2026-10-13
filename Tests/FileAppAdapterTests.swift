import Foundation
import AppKit
import Darwin

func runFileAppAdapterTests() throws {
    let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent("GaoAdapter-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false);defer{try? fm.removeItem(at:root)}
    var checks=0
    func expect(_ value:Bool,_ description:String) throws {checks += 1;guard value else{throw DataFailure.message(description)}}
    func rejects(_ description:String,_ body:() throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw DataFailure.message(description)
    }
    let directory=root.appendingPathComponent("中文 空格 '单双\"引号 `$() ; & #")
    try fm.createDirectory(at:directory,withIntermediateDirectories:false)
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
    try rejects("Terminal tab adapter cannot silently substitute a new window") {
        _ = try FileAppAdapter.plan(bundleID:"com.apple.Terminal",appURL:root,files:[directory],disposition:.reuseWindow)
    }
    guard case .automation(let newWindowScript)=try FileAppAdapter.plan(bundleID:"com.apple.Terminal",appURL:root,files:[directory],disposition:.newWindow) else {throw DataFailure.message("Terminal new-window plan missing")}
    try expect(newWindowScript == terminal,"explicit Terminal new-window disposition remains available")
    try expect(iterm.contains("create tab with default profile command") && !iterm.contains("write text"),"iTerm tabs use documented new-session override")
    let app=root.appendingPathComponent("Adapter.app"),mac=app.appendingPathComponent("Contents/MacOS"),resources=app.appendingPathComponent("Contents/Resources/app/out")
    try fm.createDirectory(at:mac,withIntermediateDirectories:true);try fm.createDirectory(at:resources,withIntermediateDirectories:true)
    let executable=mac.appendingPathComponent("Editor");try Data("test executable is never run".utf8).write(to:executable);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
    try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"com.microsoft.VSCode","CFBundleExecutable":"Editor"],format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
    try Data("test CLI is never run".utf8).write(to:resources.appendingPathComponent("cli.js"))
    for id in ["com.microsoft.VSCode","com.todesktop.230313mzl4w4u92"] {
        guard case .command(let exe,let args,let env)=try FileAppAdapter.plan(bundleID:id,appURL:app,files:[file,other,directory],disposition:.newWindow) else {throw DataFailure.message("missing editor adapter")}
        try expect((try FileTools.canonicalURL(exe)).path == (try FileTools.canonicalURL(executable)).path && args == [resources.appendingPathComponent("cli.js").path,"--new-window","--",file.path,other.path,directory.path] && env["ELECTRON_RUN_AS_NODE"] == "1","Code/Cursor uses argument array, preserves file/folder order and explicit new-window semantics")
    }
    let subl=app.appendingPathComponent("Contents/SharedSupport/bin/subl");try fm.createDirectory(at:subl.deletingLastPathComponent(),withIntermediateDirectories:true);try Data().write(to:subl);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:subl.path)
    guard case .command(_,let args,_)=try FileAppAdapter.plan(bundleID:"com.sublimetext.4",appURL:app,files:[file,directory]) else {throw DataFailure.message("missing Sublime adapter")}
    try expect(args == ["--add","--",file.path,directory.path],"Sublime file/folder arguments cannot become options")
    print("PASS: \(checks) file app adapter tests; simulated bundles are never launched, iTerm/Sublime real UI unverified")
}
