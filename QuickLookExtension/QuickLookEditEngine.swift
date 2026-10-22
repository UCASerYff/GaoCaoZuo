import Foundation
import Darwin

enum QuickLookEditEngine {
    struct HelperFailure:LocalizedError {
        let response:QuickLookArchiveEditResponse
        var errorDescription:String? {(response.message ?? L10n.text("压缩编辑失败，原包安全备份保留。"))+(response.backup.map{"\n"+L10n.text("安全备份：")+$0.path} ?? "")}
    }
    private final class ReplyBox:@unchecked Sendable {
        let lock=NSLock();var result:Result<Data,Error>?
        func finish(_ value:Result<Data,Error>){lock.lock();defer{lock.unlock()};if result==nil{result=value}}
        func take()->Result<Data,Error>?{lock.lock();defer{lock.unlock()};return result}
    }
    static func request(kind:QuickLookArchiveEditRequest.Kind,url:URL,password:String?,adding:[URL]=[],removing:[String]=[],removeHidden:Bool=false,cancellation:NativeArchive.Cancellation)throws->QuickLookArchiveEditRequest {
        let identity=try QuickLookArchiveIdentity(url:url),digest=try NativeArchive.originalDigest(url,cancellation:cancellation)
        guard try QuickLookArchiveIdentity(url:url)==identity else {throw NativeArchive.Failure(message:L10n.text("压缩包在读取期间发生变化，请重新打开。"))}
        return .init(kind:kind,archive:url,identity:identity,sha256:digest,password:password,adding:adding,removing:removing,removeHidden:removeHidden)
    }
    static func run(_ request:QuickLookArchiveEditRequest,directory:URL?=nil,cancellation:NativeArchive.Cancellation)throws->QuickLookArchiveEditResponse {
        let bundle=Bundle(for:NativeArchiveBrowserController.self)
        let service=bundle.bundleURL.appendingPathComponent("Contents/XPCServices/ArchiveBroker.xpc",isDirectory:true)
        let envelope=QuickLookArchiveBrokerEnvelope(request:request,archiveBookmark:try request.archive.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil),directoryBookmark:try directory?.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil),addingBookmarks:try request.adding.map{try $0.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)})
        let data=try JSONEncoder().encode(envelope)
        guard data.count<=1_024*1_024 else {throw NativeArchive.Failure(message:L10n.text("压缩编辑请求超过预算。"))}
        let connection=NSXPCConnection(serviceName:QuickLookArchiveBrokerIdentity.serviceName),box=ReplyBox()
        connection.setCodeSigningRequirement(try QuickLookArchiveBrokerIdentity.requirement(for:service))
        connection.remoteObjectInterface=NSXPCInterface(with:GaoQuickLookArchiveBrokerProtocol.self)
        connection.invalidationHandler={box.finish(.failure(NativeArchive.Failure(message:L10n.text("压缩编辑连接已中断；请重新打开预览核对保存状态，安全备份保留。"))))}
        connection.resume();defer{connection.invalidate()}
        guard let remote=connection.remoteObjectProxyWithErrorHandler({box.finish(.failure($0))}) as? GaoQuickLookArchiveBrokerProtocol else {throw CocoaError(.featureUnsupported)}
        remote.execute(data){box.finish(.success($0))}
        var stopError:Error?,stopTime:Double?
        while box.take()==nil {
            do{try cancellation.check()}catch{
                if stopTime==nil {stopError=error;stopTime=ProcessInfo.processInfo.systemUptime;remote.cancel(request.requestID.uuidString){}}
            }
            if let stopTime,ProcessInfo.processInfo.systemUptime-stopTime>5 {throw stopError!}
            Thread.sleep(forTimeInterval:0.02)
        }
        let bytes=try box.take()!.get()
        guard bytes.count<=8*1_024*1_024 else {throw NativeArchive.Failure(message:L10n.text("压缩目录响应超过预算。"))}
        let response=try JSONDecoder().decode(QuickLookArchiveEditResponse.self,from:bytes)
        guard response.schema==1,response.requestID==request.requestID,response.helperPID==connection.processIdentifier else {throw NativeArchive.Failure(message:L10n.text("压缩编辑响应不属于当前请求。"))}
        guard response.status=="completed" else {throw HelperFailure(response:response)}
        return response
    }
}
