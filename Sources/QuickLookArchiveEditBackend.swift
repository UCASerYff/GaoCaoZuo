import Foundation

@MainActor enum QuickLookArchiveEditBackend {
    static func validateOriginal(_ request:QuickLookArchiveEditRequest)throws {
        guard request.schema==1,request.archive.isFileURL,["zip","7z"].contains(request.archive.pathExtension.lowercased()),
              request.sha256.count==64,request.sha256.allSatisfy(\.isHexDigit),request.adding.count<=64,request.removing.count<=10_000,
              try QuickLookArchiveIdentity(url:request.archive)==request.identity,
              try FileTools.sha256(request.archive)==request.sha256,
              try QuickLookArchiveIdentity(url:request.archive)==request.identity else {throw ArchiveError.invalid(L10n.text("压缩包在编辑期间发生变化，未保存到原包。"))}
    }
    static func perform(_ request:QuickLookArchiveEditRequest,service:ArchiveService,backupDirectory:URL,checkCancellation:@escaping ()throws->Void={}) async throws -> QuickLookArchiveEditResponse {
        guard let scope=service.executionScope else {throw ArchiveError.invalid(L10n.text("压缩编辑组件缺少受保护工作区，未启动引擎。"))}
        try checkCancellation();try validateOriginal(request)
        let root=scope.workspaceURL,staged=root.appendingPathComponent("source."+request.archive.pathExtension.lowercased())
        try await ArchiveFileIO.perform {try ArchiveOriginalCommit.copyRegular(request.archive,to:staged,expected:request.identity,sha256:request.sha256)}
        var extraction=ArchiveExtractionOptions.strict;extraction.maximumExpandedGiB=1;extraction.maximumEntries=10_000;extraction.maximumMinutes=1
        let entries=try await service.list(archive:staged,password:request.password,options:extraction)
        guard !entries.isEmpty,entries.count<=10_000,
              entries.allSatisfy({$0.size<=128*1_024*1_024 && $0.symbolicLink==nil && $0.hardLink==nil}),
              entries.reduce(UInt64(0),{$0+min($1.size,512*1_024*1_024+1)})<=512*1_024*1_024 else {throw ArchiveError.invalid(L10n.text("预览编辑超过保护预算，或包含不支持的链接；原压缩包保留。"))}
        try validateManifest(entries)
        try checkCancellation();try validateOriginal(request)
        if request.kind == .inspect {
            return QuickLookArchiveEditResponse(requestID:request.requestID,status:"completed",members:members(entries),resultSHA256:request.sha256)
        }
        guard !request.adding.isEmpty || !request.removing.isEmpty || request.removeHidden else {throw ArchiveError.invalid(L10n.text("请先选择增删或隐藏项目清理计划。"))}
        let encrypted=entries.contains(where:\.isEncrypted)
        if encrypted,request.password?.isEmpty != false {throw ArchiveError.invalid(L10n.text("请输入当前压缩包密码；不会把加密原包改存为明文。"))}
        let additions=root.appendingPathComponent("additions",isDirectory:true)
        try FileManager.default.createDirectory(at:additions,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var added:[URL]=[],names=Set<String>(),total:Int64=0
        for source in request.adding {
            try checkCancellation()
            let value=try QuickLookArchiveIdentity(url:source);total += value.bytes
            guard total<=256*1_024*1_024,names.insert(source.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()).inserted else {throw ArchiveError.invalid(L10n.text("新增文件重名或超过预览编辑预算，原包保留。"))}
            let target=additions.appendingPathComponent(source.lastPathComponent)
            try await ArchiveFileIO.perform {try ArchiveOriginalCommit.copyRegular(source,to:target,expected:value)};added.append(target)
        }
        let result=root.appendingPathComponent("result."+request.archive.pathExtension.lowercased())
        _=try await service.edit(archive:staged,password:encrypted ? request.password:nil,adding:added,removing:request.removing,removeHidden:request.removeHidden,saveTo:result,backupDirectory:root.appendingPathComponent("unused-backup"),options:.init(),extraction:extraction,preserveEncryption:encrypted)
        let verified=try await service.list(archive:result,password:encrypted ? request.password:nil,options:extraction)
        guard !verified.isEmpty,verified.count<=10_000,verified.allSatisfy({$0.size<=128*1_024*1_024 && $0.symbolicLink==nil && $0.hardLink==nil}),verified.reduce(UInt64(0),{$0+min($1.size,512*1_024*1_024+1)})<=512*1_024*1_024 else {throw ArchiveError.invalid(L10n.text("预览编辑超过保护预算，或包含不支持的链接；原压缩包保留。"))}
        try validateManifest(verified)
        guard !encrypted || verified.filter({!$0.isDirectory}).allSatisfy(\.isEncrypted) else {throw ArchiveError.invalid(L10n.text("编辑结果未保留加密；原压缩包未修改。"))}
        try checkCancellation();try validateOriginal(request)
        let committed=try await ArchiveFileIO.perform {
            try ArchiveOriginalCommit.commit(original:request.archive,expected:request.identity,sha256:request.sha256,candidate:result,backupDirectory:backupDirectory,requestID:request.requestID,checkCancellation:checkCancellation)
        }
        return QuickLookArchiveEditResponse(requestID:request.requestID,status:"completed",members:members(verified),resultSHA256:committed.sha256,backup:committed.backup)
    }
    private static func members(_ entries:[ArchiveEntry])->[QuickLookArchiveMember] {entries.map{.init(path:$0.path,size:$0.size,directory:$0.isDirectory,encrypted:$0.isEncrypted,permissions:$0.permissions)}}
    private static func validateManifest(_ entries:[ArchiveEntry])throws {
        var bytes=0,prefixBytes=0,prefixes=Set<String>()
        for entry in entries {
            try ArchiveService.validateArchivePath(entry.path);bytes += entry.path.utf8.count
            var prefix=""
            for part in entry.path.split(separator:"/") {
                prefix=prefix.isEmpty ? String(part):prefix+"/"+part
                let key=prefix.precomposedStringWithCanonicalMapping.lowercased()
                if prefixes.insert(key).inserted {prefixBytes += key.utf8.count}
            }
            guard bytes<=4*1_024*1_024,prefixBytes<=4*1_024*1_024,prefixes.count<=4000 else {throw ArchiveError.invalid(L10n.text("预览编辑超过保护预算，或包含不支持的链接；原压缩包保留。"))}
        }
    }
}
