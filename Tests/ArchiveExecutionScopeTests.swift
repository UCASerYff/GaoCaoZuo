import Foundation
import Darwin

@MainActor func runArchiveExecutionScopeTests(engine:URL)async throws {
    let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("GaoArchiveScope-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:root)}
    let job=root.appendingPathComponent("job \" ) (allow file-write*) \\ public",isDirectory:true)
    try fm.createDirectory(at:job,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let source=root.appendingPathComponent("public [a] $ ; 中文.txt"),outside=root.appendingPathComponent("outside-public.txt")
    let payload=Data("Public scope payload; exact bytes, no personal data.\n".utf8)
    try payload.write(to:source);try Data("Public outside canary".utf8).write(to:outside)
    var checks=0
    func check(_ value:Bool,_ message:String)throws {checks += 1;guard value else {throw DataFailure.message(message)}}
    func rejects(_ body:()throws->Void)throws {checks += 1;do {try body()}catch{return};throw DataFailure.message("Unsafe scope accepted")}
    let scope=try ArchiveExecutionScope(workspace:job,runtime:engine.deletingLastPathComponent())
    let service=ArchiveService(engineURL:engine);service.executionScope=scope
    for format in [ArchiveFormat.zip,.sevenZip] {
        let password="GaoPublicScopeV114!",archive=job.appendingPathComponent("public."+format.rawValue)
        _ = try await service.create(items:[source],destination:archive,format:format,password:password,splitMB:nil,solid:false)
        let members=try await service.list(archive:archive,password:password)
        try check(members.contains{$0.path==source.lastPathComponent && $0.isEncrypted},"Scoped rebuild/list lost encryption or special filename")
        let output=job.appendingPathComponent(format.rawValue+"-decoded")
        _ = try await service.extract(archive:archive,to:output,password:password,selected:nil)
        try check(try Data(contentsOf:output.appendingPathComponent(source.lastPathComponent))==payload,"Scoped decode did not preserve exact bytes")
    }
    try check(scope.environment["HOME"]==scope.workspaceURL.path && scope.environment.keys.sorted()==["HOME","LANG","LC_ALL","PATH","TMPDIR"],"Decoder inherited unrelated parent environment")
    let cSource=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("QuickLookProbe/IOBoundaryProbe.c")
    let binary=job.appendingPathComponent("boundary")
    let compiler=Process();compiler.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun");compiler.arguments=["clang",cSource.path,"-o",binary.path]
    try compiler.run();compiler.waitUntilExit();try check(compiler.terminationStatus==0,"Cannot build public scope boundary fixture")
    let probeScope=try ArchiveExecutionScope(workspace:job,runtime:engine.deletingLastPathComponent(),readOnlyFiles:[source])
    try check(access(source.path,R_OK|W_OK)==0 && access(outside.path,R_OK)==0,"Canary baseline must permit normal user access")
    for writing in [false,true] {
        let task=Process(),pipe=Pipe()
        task.executableURL=URL(fileURLWithPath:"/usr/bin/sandbox-exec")
        task.arguments=["-p",try probeScope.profile(writing:writing),binary.path,source.path,outside.path,job.appendingPathComponent(writing ? "may-create":"must-not-create").path]
        task.environment=probeScope.environment;task.standardOutput=pipe
        try task.run();try? pipe.fileHandleForWriting.close();task.waitUntilExit()
        let values=try JSONSerialization.jsonObject(with:pipe.fileHandleForReading.readDataToEndOfFile()) as? [String:Int] ?? [:]
        try check(task.terminationStatus==0 && values["selectedRead"]==0 && values["outsideRead"]==Int(EPERM) && values["originalWrite"]==Int(EPERM) && values["scratchCreate"]==(writing ? 0:Int(EPERM)),"Narrow scope/injection-name read or write boundary failed")
    }
    let unsafe=root.appendingPathComponent("unsafe",isDirectory:true)
    try fm.createDirectory(at:unsafe,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])
    try rejects {_ = try ArchiveExecutionScope(workspace:unsafe,runtime:engine.deletingLastPathComponent())}
    let link=root.appendingPathComponent("link");try fm.createSymbolicLink(at:link,withDestinationURL:source)
    try rejects {_ = try ArchiveExecutionScope(workspace:job,runtime:engine.deletingLastPathComponent(),readOnlyFiles:[link])}
    try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:job.path)
    try rejects {_ = try scope.profile(writing:false)}
    try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:job.path)
    let held=root.appendingPathComponent("held",isDirectory:true);try fm.moveItem(at:job,to:held)
    try fm.createDirectory(at:job,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    try rejects {_ = try scope.profile(writing:true)}
    print("受控归档引擎专项通过（\(checks)）：真实加密ZIP/7Z创建/列目/解码、限定临时树写入、外部读取与原件写入拒绝、注入式目录名、安全环境、权限变化/目录替换/链接拒绝；仅公开合成文件。")
}
