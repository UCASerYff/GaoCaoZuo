import Foundation
import CryptoKit
import Darwin

/// A distinct trusted broker target, with the existing main app's permission
/// model. Untrusted archive bytes are parsed only in restricted child processes.
/// This private boundary probe accepts only the known public 275-byte fixture.
private final class BrokerSession:NSObject,GaoQuickLookSandboxProbeProtocol {
    let callerPID:pid_t,expectedClient:URL
    init(callerPID:pid_t,expectedClient:URL) {self.callerPID=callerPID;self.expectedClient=expectedClient}
    func inspect(_ bookmark:Data,clientBundle:Data,reply:@escaping(Data)->Void) {
        var result:[String:Any]=["servicePID":getpid(),"parentPID":getppid(),"callerPID":callerPID,"serviceBundle":Bundle.main.bundleURL.path]
        do {
            guard bookmark.count<=64*1024,clientBundle.count<=64*1024 else {throw CocoaError(.fileReadTooLarge)}
            var stale=false
            let client=try URL(resolvingBookmarkData:clientBundle,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale)
            defer {client.stopAccessingSecurityScopedResource()}
            guard !stale,client.standardizedFileURL==expectedClient.standardizedFileURL else {throw CocoaError(.fileReadNoPermission)}
            try GaoQuickLookProbeIdentity.verifyPeer(pid:callerPID,bundle:client)
            result["peerVerified"]=true
            let url=try URL(resolvingBookmarkData:bookmark,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale)
            defer {url.stopAccessingSecurityScopedResource()}
            guard !stale,url.lastPathComponent=="public-encrypted.zip" else {throw CocoaError(.fileReadNoPermission)}
            let before=try QuickLookArchiveIdentity(url:url)
            let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
            guard fd>=0 else {throw CocoaError(.fileReadNoPermission)}
            defer {close(fd)}
            var s=stat();guard fstat(fd,&s)==0,s.st_dev==before.device,s.st_ino==before.inode,s.st_size==275 else {throw CocoaError(.fileReadCorruptFile)}
            var bytes=[UInt8](repeating:0,count:276)
            let count=Darwin.read(fd,&bytes,bytes.count)
            guard count==275,try QuickLookArchiveIdentity(url:url)==before else {throw CocoaError(.fileReadCorruptFile)}
            let digest=SHA256.hash(data:Data(bytes.prefix(count))).map{String(format:"%02x",$0)}.joined()
            guard digest=="9fde429d8f319ea61de29a30d3a051e7bf8eb6bde66bd4f90e9d44fc15b6cb85" else {throw CocoaError(.fileReadCorruptFile)}
            result["readSHA256"]=digest
            let fm=FileManager.default,job=fm.temporaryDirectory.appendingPathComponent("GaoBrokerPublic-"+UUID().uuidString,isDirectory:true)
            try fm.createDirectory(at:job,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:job)}
            let scratch=job.appendingPathComponent("scratch",isDirectory:true),outside=job.appendingPathComponent("outside-public.txt")
            try fm.createDirectory(at:scratch,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try Data("Public canary outside the decoder read grant".utf8).write(to:outside)
            guard let engine=Bundle.main.url(forAuxiliaryExecutable:"7zz"),let boundary=Bundle.main.url(forAuxiliaryExecutable:"IOBoundaryProbe") else {throw CocoaError(.fileNoSuchFile)}
            func canonical(_ url:URL)throws->String {
                guard !url.path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),let value=realpath(url.path,nil) else {throw CocoaError(.fileReadInvalidFileName)}
                defer {free(value)};return String(cString:value)
            }
            func quote(_ value:String)throws->String {let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes];return String(data:try encoder.encode(value),encoding:.utf8)!}
            let tools=try canonical(engine.deletingLastPathComponent()),input=try canonical(url),work=try canonical(scratch)
            // macOS libignition opens / as its openat root during dyld bootstrap.
            // This literal directory grant does not grant any child's file data.
            let readProfile="(version 1)(allow default)(deny network*)(deny file-write*)(deny file-read-data)(allow file-read-data (literal \"/\") (subpath \"/System\") (subpath \"/usr/lib\") (subpath \"/usr/share\") (literal \"/dev/null\") (literal \"/dev/random\") (literal \"/dev/urandom\") (subpath "+(try quote(tools))+") (subpath "+(try quote(work))+") (literal "+(try quote(input))+"))"
            func run(_ executable:URL,_ arguments:[String],profile:String)throws->(pid:pid_t,exit:Int32,data:Data) {
                let task=Process(),output=Pipe()
                task.executableURL=URL(fileURLWithPath:"/usr/bin/sandbox-exec");task.arguments=["-p",profile,executable.path]+arguments
                task.standardInput=FileHandle.nullDevice;task.standardOutput=output;task.standardError=output
                try task.run();try? output.fileHandleForWriting.close()
                let deadline=ProcessInfo.processInfo.systemUptime+8
                while task.isRunning,ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.02)}
                if task.isRunning {task.terminate()}
                let grace=ProcessInfo.processInfo.systemUptime+2
                while task.isRunning,ProcessInfo.processInfo.systemUptime<grace {Thread.sleep(forTimeInterval:0.02)}
                if task.isRunning {_ = kill(task.processIdentifier,SIGKILL)}
                task.waitUntilExit()
                let data=output.fileHandleForReading.readDataToEndOfFile()
                guard data.count<=8192 else {throw CocoaError(.fileReadTooLarge)}
                return (task.processIdentifier,task.terminationStatus,data)
            }
            let listing=try run(engine,["l","-slt","-bsp0","--",url.path],profile:readProfile)
            result["decoderPID"]=listing.pid;result["decoderExit"]=listing.exit
            if listing.exit != 0 {result["decoderDiagnostic"]=String(data:listing.data.prefix(2000),encoding:.utf8) ?? ""}
            result["publicMemberListed"]=String(data:listing.data,encoding:.utf8)?.contains("public-original.txt") == true
            let readBoundary=try run(boundary,[url.path,outside.path,scratch.appendingPathComponent("read-only-must-not-create").path],profile:readProfile)
            let writeProfile=readProfile+"(allow file-write* (subpath "+(try quote(work))+"))"
            let writeBoundary=try run(boundary,[url.path,outside.path,scratch.appendingPathComponent("limited-writer-public").path],profile:writeProfile)
            result["readOnlyBoundaryPID"]=readBoundary.pid;result["readOnlyBoundaryExit"]=readBoundary.exit
            result["limitedWriterBoundaryPID"]=writeBoundary.pid;result["limitedWriterBoundaryExit"]=writeBoundary.exit
            let readResult=try JSONSerialization.jsonObject(with:readBoundary.data) as? [String:Int] ?? [:]
            let writeResult=try JSONSerialization.jsonObject(with:writeBoundary.data) as? [String:Int] ?? [:]
            result["readOnlyBoundary"]=readResult;result["limitedWriterBoundary"]=writeResult
            func denied(_ code:Int?)->Bool {code==Int(EPERM) || code==Int(EACCES)}
            let passed=listing.exit==0 && result["publicMemberListed"] as? Bool==true && readBoundary.exit==0 && writeBoundary.exit==0 && readResult["selectedRead"]==0 && denied(readResult["outsideRead"]) && denied(readResult["originalWrite"]) && denied(readResult["scratchCreate"]) && writeResult["selectedRead"]==0 && denied(writeResult["outsideRead"]) && denied(writeResult["originalWrite"]) && writeResult["scratchCreate"]==0
            guard try QuickLookArchiveIdentity(url:url)==before else {throw CocoaError(.fileReadCorruptFile)}
            guard lseek(fd,0,SEEK_SET)==0,Darwin.read(fd,&bytes,bytes.count)==275,
                  SHA256.hash(data:Data(bytes.prefix(275))).map({String(format:"%02x",$0)}).joined()==digest else {throw CocoaError(.fileReadCorruptFile)}
            result["originalUnchanged"]=true;result["status"]=passed ? "boundary-passed":"boundary-failed"
        }catch {result["status"]="failed";result["error"]=String(describing:error as NSError)}
        reply((try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys)) ?? Data())
    }
}
private final class BrokerDelegate:NSObject,NSXPCListenerDelegate {
    let expectedClient:URL,requirement:String
    init(expectedClient:URL,requirement:String) {self.expectedClient=expectedClient;self.requirement=requirement}
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
        guard connection.effectiveUserIdentifier==getuid() else {return false}
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface=NSXPCInterface(with:GaoQuickLookSandboxProbeProtocol.self)
        connection.exportedObject=BrokerSession(callerPID:connection.processIdentifier,expectedClient:expectedClient)
        connection.resume();return true
    }
}
@main enum BrokerProbeMain {
    static func main() {
        let client=Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        do {
            let delegate=BrokerDelegate(expectedClient:client,requirement:try GaoQuickLookProbeIdentity.requirement(for:client))
            let listener=NSXPCListener.service();listener.delegate=delegate
            withExtendedLifetime(delegate){listener.resume()}
        }catch {exit(1)}
    }
}
