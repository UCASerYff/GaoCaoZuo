import Foundation
import Darwin

@main enum QuickLookArchiveEditMain {
    @MainActor static func main() async {
        let input=FileHandle.standardInput
        var bytes=Data(),requestID=UUID()
        var activeService:ArchiveService?
        do {
            while let part=try input.read(upToCount:65536),!part.isEmpty {
                guard part.count<=512_000-bytes.count else {throw ArchiveError.invalid("压缩编辑请求超过预算。")}
                bytes.append(part)
            }
            let request=try JSONDecoder().decode(QuickLookArchiveEditRequest.self,from:bytes)
            requestID=request.requestID;bytes.resetBytes(in:0..<bytes.count);bytes.removeAll()
            guard let tool=Bundle.main.resourceURL?.appendingPathComponent("Tools/7zz") else {throw ArchiveError.invalid("扩展压缩引擎不完整，请重新安装完整发行包。")}
            let service=ArchiveService(engineURL:tool)
            activeService=service
            signal(SIGTERM,SIG_IGN)
            let signalSource=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
            signalSource.setEventHandler {Task{@MainActor in service.cancel()}};signalSource.resume()
            defer {signalSource.cancel()}
            let backup=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GaoCaoZuoQuickLook/ArchiveBackups",isDirectory:true)
            var response=try await QuickLookArchiveEditBackend.perform(request,service:service,backupDirectory:backup)
            response.helperPID=getpid();response.helperParentPID=getppid()
            let output=try JSONEncoder().encode(response)
            guard output.count<=8*1_024*1_024 else {throw ArchiveError.invalid("压缩目录响应超过预算。")}
            try FileHandle.standardOutput.write(contentsOf:output)
        }catch {
            let response=QuickLookArchiveEditResponse(requestID:requestID,status:error is CancellationError ? "cancelled":"failed",backup:activeService?.lastEditBackup,message:error.localizedDescription,helperPID:getpid(),helperParentPID:getppid())
            if let output=try? JSONEncoder().encode(response) {try? FileHandle.standardOutput.write(contentsOf:output)}
            exit(1)
        }
    }
}
