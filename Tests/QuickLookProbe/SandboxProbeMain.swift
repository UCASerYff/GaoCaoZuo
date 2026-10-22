import Foundation
import CryptoKit
import Darwin
import Security

private final class ProbeSession:NSObject,GaoQuickLookSandboxProbeProtocol {
    let callerPID:pid_t
    let expectedClient:URL
    init(callerPID:pid_t,expectedClient:URL) {self.callerPID=callerPID;self.expectedClient=expectedClient}
    func inspect(_ bookmark:Data,clientBundle:Data,reply:@escaping(Data)->Void) {
        var result:[String:Any]=["servicePID":getpid(),"parentPID":getppid(),"callerPID":callerPID,"serviceBundle":Bundle.main.bundleURL.path]
        do {
            guard bookmark.count<=64*1024,clientBundle.count<=64*1024 else {throw CocoaError(.fileReadTooLarge)}
            var clientStale=false
            let client=try URL(resolvingBookmarkData:clientBundle,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&clientStale)
            defer {client.stopAccessingSecurityScopedResource()}
            guard !clientStale,client.standardizedFileURL==expectedClient.standardizedFileURL else {throw CocoaError(.fileReadNoPermission)}
            // The service initially has access only to its own .xpc bundle.
            // A read-only implicit bookmark exposes the containing extension's
            // signed code for an exact hash check, before using the data bookmark.
            try GaoQuickLookProbeIdentity.verifyPeer(pid:callerPID,bundle:client)
            result["peerVerified"]=true
            var stale=false
            let url=try URL(resolvingBookmarkData:bookmark,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale)
            defer {url.stopAccessingSecurityScopedResource()}
            var s=stat()
            guard !stale,url.isFileURL,lstat(url.path,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_nlink==1,s.st_size>=0,s.st_size<=128*1024*1024 else {throw CocoaError(.fileReadUnsupportedScheme)}
            let data=try Data(contentsOf:url,options:.mappedIfSafe)
            result["readBytes"]=data.count
            result["readSHA256"]=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            guard let tool=Bundle.main.url(forAuxiliaryExecutable:"7zz") else {throw CocoaError(.fileNoSuchFile)}
            let task=Process();task.executableURL=tool;task.arguments=["i"]
            task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice;task.standardInput=FileHandle.nullDevice
            try task.run()
            let deadline=ProcessInfo.processInfo.systemUptime+5
            while task.isRunning,ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.02)}
            if task.isRunning {task.terminate()}
            task.waitUntilExit()
            result["toolPID"]=task.processIdentifier;result["toolExit"]=task.terminationStatus
            result["status"]=task.terminationStatus==0 ? "completed":"tool-failed"
            let isolated=Process(),errors=Pipe()
            isolated.executableURL=URL(fileURLWithPath:"/usr/bin/sandbox-exec")
            isolated.arguments=["-p","(version 1)(allow default)(deny network*)(deny file-write*)",tool.path,"i"]
            isolated.standardOutput=FileHandle.nullDevice;isolated.standardInput=FileHandle.nullDevice;isolated.standardError=errors
            try isolated.run();try? errors.fileHandleForWriting.close()
            let isolationDeadline=ProcessInfo.processInfo.systemUptime+5
            while isolated.isRunning,ProcessInfo.processInfo.systemUptime<isolationDeadline {Thread.sleep(forTimeInterval:0.02)}
            if isolated.isRunning {isolated.terminate()}
            isolated.waitUntilExit()
            result["isolatedToolPID"]=isolated.processIdentifier;result["isolatedToolExit"]=isolated.terminationStatus
            result["isolatedToolDiagnostic"]=String(data:errors.fileHandleForReading.readDataToEndOfFile().prefix(8192),encoding:.utf8) ?? ""
        }catch {result["status"]="failed";result["error"]=String(describing:error as NSError)}
        reply((try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys)) ?? Data())
    }
}
private final class ProbeDelegate:NSObject,NSXPCListenerDelegate {
    let expectedClient:URL
    init(expectedClient:URL) {self.expectedClient=expectedClient}
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
        guard connection.effectiveUserIdentifier==getuid() else {return false}
        connection.setCodeSigningRequirement("identifier \""+GaoQuickLookProbeIdentity.clientIdentifier+"\"")
        connection.exportedInterface=NSXPCInterface(with:GaoQuickLookSandboxProbeProtocol.self)
        connection.exportedObject=ProbeSession(callerPID:connection.processIdentifier,expectedClient:expectedClient)
        connection.resume();return true
    }
}
@main enum SandboxProbeMain {
    static func main() {
        let extensionBundle=Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let delegate=ProbeDelegate(expectedClient:extensionBundle)
        let listener=NSXPCListener.service();listener.delegate=delegate
        withExtendedLifetime(delegate){listener.resume()}
    }
}
