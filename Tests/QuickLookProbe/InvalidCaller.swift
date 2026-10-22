import Foundation
import Security

/// A different executable deliberately bearing the same identifier. Only a
/// pinned code hash, rather than an identifier check, should authenticate it.
@main enum InvalidProbeCaller {
    static func main() {
        let expected=Bundle.main.bundleURL
        let service=expected.appendingPathComponent("Contents/XPCServices/BrokerProbe.xpc")
        var record:[String:Any]=["clientBundle":expected.path,"clientPID":ProcessInfo.processInfo.processIdentifier]
        do {
            do {try GaoQuickLookProbeIdentity.verifyPeer(pid:ProcessInfo.processInfo.processIdentifier,bundle:expected);record["differentCodeRejectedByRequirement"]=false}
            catch {record["differentCodeRejectedByRequirement"]=true}
            let connection=NSXPCConnection(serviceName:"com.gaoseries.GaoCaoZuo.QuickLookHelperProbe.BrokerProbe")
            connection.setCodeSigningRequirement(try GaoQuickLookProbeIdentity.requirement(for:service))
            connection.remoteObjectInterface=NSXPCInterface(with:GaoQuickLookSandboxProbeProtocol.self)
            let signal=DispatchSemaphore(value:0),lock=NSLock()
            var error:NSError?,receivedReply=false
            connection.resume()
            let remote=connection.remoteObjectProxyWithErrorHandler{value in lock.lock();error=value as NSError;lock.unlock();signal.signal()} as? GaoQuickLookSandboxProbeProtocol
            remote?.inspect(Data(),clientBundle:Data()){_ in lock.lock();receivedReply=true;lock.unlock();signal.signal()}
            let waited=signal.wait(timeout:.now()+10)
            connection.invalidate()
            lock.lock();let failure=error,reply=receivedReply;lock.unlock()
            record["timedOut"]=waited != .success;record["receivedBusinessReply"]=reply
            record["transportErrorDomain"]=failure?.domain ?? "";record["transportErrorCode"]=failure?.code ?? 0
            record["transportError"]=failure?.localizedDescription ?? ""
            // Lookup failure is not an authentication proof. The real broker
            // launch/requirement rejection must be confirmed in system logs.
            record["systemRejectionEvidenceStillRequired"]=true
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]))
            exit(reply || waited != .success ? 1:0)
        }catch {
            record["failure"]=String(describing:error as NSError)
            if let data=try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]) {FileHandle.standardOutput.write(data)}
            exit(1)
        }
    }
}
