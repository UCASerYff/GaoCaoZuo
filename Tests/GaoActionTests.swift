import Foundation
import CryptoKit
import Darwin

@MainActor func runGaoActionTests() async throws {
    let fm=FileManager.default,clock=GaoActionV1.parseDate("2026-10-12T12:00:00Z")!
    let temp=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("GaoAction-Tests-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:temp,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:temp)}
    let nonce=Data(repeating:0,count:32).base64EncodedString(),hello=Data("hello\n".utf8)
    let hash="5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    var checks=0
    func assert(_ condition:Bool,_ message:String) throws {guard condition else {throw DataFailure.message("GaoAction: "+message)};checks += 1}
    func rejected(_ name:String,_ body:() throws -> Void) throws {
        do {try body()} catch {checks += 1;return};throw DataFailure.message("GaoAction 未拒绝："+name)
    }
    func id(_ number:Int)->String {String(format:"11111111-1111-4111-8111-%012d",number)}
    func request(_ n:Int,action:String="documents.newText")->GaoActionManifest {
        .init(kind:.request,requestID:id(n),sourceBundleID:GaoActionV1.ownBundleID,targetBundleID:GaoActionV1.owners[action] ?? "com.gaoseries.GaoYanJiu",action:action,createdAt:"2026-10-12T12:00:00Z",expiresAt:"2026-10-12T12:02:00Z",nonce:nonce,items:action=="documents.newText" ? [.init(id:"item-1",relativePath:"input.txt",uti:"public.plain-text",byteCount:6,sha256:hash)] : [],parameters:action=="documents.newText" ? ["suggestedTitle":.init("交接测试")] : [:])
    }
    func package(_ m:GaoActionManifest,content:Data?=nil,suffix:String="") throws -> URL {
        let url=temp.appendingPathComponent(m.requestID+suffix+".gaoaction",isDirectory:true)
        try fm.createDirectory(at:url.appendingPathComponent("payload"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if let content,let first=m.items.first {
            // Deliberately unsafe item paths are never written; only manifest validation sees them.
            if !first.relativePath.contains("..") {
                let file=url.appendingPathComponent("payload").appendingPathComponent(first.relativePath)
                try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try content.write(to:file);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            }
        }
        let manifest=url.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(m).write(to:manifest);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
        return url
    }
    func validate(_ m:GaoActionManifest) throws {try GaoActionV1.validateManifest(m,now:clock)}
    var known=Set<String>()
    try assert(GaoActionV1.calculateSHA256(data:hello)==hash,"canonical UTF-8 hello 摘要")
    // Fixed V1 fixtures, with targets assigned to the actual owner of each action.
    let first=request(1),firstURL=try package(first,content:hello)
    let loaded=try GaoActionV1.validatePackageDirectory(at:firstURL,now:clock,knownIDs:&known,expectedTarget:"com.gaoseries.GaoWenJian")
    try assert(loaded==first,"v1-documents-newText")
    let refDir=temp.appendingPathComponent("真实目录 中文 ' 空格",isDirectory:true)
    try fm.createDirectory(at:refDir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    var storage=request(2,action:"storage.inspect");storage.references=[try GaoActionV1.reference(for:refDir)];storage.parameters=["mode":.init("metadata")]
    let storageURL=try package(storage)
    let loadedStorage=try GaoActionV1.validatePackageDirectory(at:storageURL,now:clock,knownIDs:&known)
    try assert(loadedStorage.references[0].declaredIdentity?.inode==storage.references[0].declaredIdentity?.inode,"v1-storage-directory 实际身份")
    let ocr=GaoActionManifest(kind:.result,requestID:id(3),sourceBundleID:"com.gaoseries.GaoJieTu",targetBundleID:GaoActionV1.ownBundleID,action:"ocr.files",createdAt:first.createdAt,expiresAt:first.expiresAt,nonce:nonce,inReplyTo:id(3),status:.partial,provenance:["pagesProcessed":.init(2),"pagesSucceeded":.init(1),"sources":.init([["sourceItemID":"item-1","sourceSHA256":hash,"pages":[["page":1,"status":"completed"],["page":2,"status":"failed"]]]])])
    let ocrURL=try package(ocr)
    let loadedOCR=try GaoActionV1.validatePackageDirectory(at:ocrURL,now:clock,knownIDs:&known,expectedTarget:GaoActionV1.ownBundleID)
    try assert(loadedOCR.status == .partial && loadedOCR.inReplyTo==id(3),"v1-ocr-partial 保留逐页失败与关联")
    let duplicateURL=try package(request(4),content:hello)
    _ = try GaoActionV1.validatePackageDirectory(at:duplicateURL,now:clock,knownIDs:&known)
    try rejected("v1-duplicate-request") {_ = try GaoActionV1.validatePackageDirectory(at:duplicateURL,now:clock,knownIDs:&known)}
    var expired=request(5);expired.createdAt="2026-10-12T11:50:00Z";expired.expiresAt="2026-10-12T11:52:00Z"
    try rejected("v1-expired") {try validate(expired)}
    var traversal=request(6);traversal.items[0].relativePath="../outside.txt"
    try rejected("v1-path-traversal") {try validate(traversal)}
    var unknown=request(7);unknown.action="arbitrary.unauthorized.command"
    try rejected("v1-unknown-action") {try validate(unknown)}
    var version=request(8);version.schemaVersion=2
    try rejected("v2-unsupported") {try validate(version)}
    // Invalid inputs must not reserve IDs. Revalidation with corrected content succeeds.
    var unpoisoned=Set<String>()
    try rejected("验证失败不得消耗ID") {try GaoActionV1.validateManifest(expired,now:clock,knownIDs:&unpoisoned)}
    try assert(unpoisoned.isEmpty,"invalid input leaves dedupe unchanged")
    var bad=first;bad.targetBundleID=GaoActionV1.ownBundleID
    try rejected("动作归属错误") {try validate(bad)}
    try rejected("目标不匹配") {try GaoActionV1.validateManifest(first,now:clock,expectedTarget:GaoActionV1.ownBundleID)}
    bad=first;bad.createdAt="2026-10-12T12:03:00Z"
    try rejected("未来createdAt") {try validate(bad)}
    bad=first;bad.expiresAt="2026-10-12T12:02:01Z"
    try rejected("TTL超过120秒") {try validate(bad)}
    bad=first;bad.createdAt="2026-10-12T20:00:00+08:00"
    try rejected("非UTC日期") {try validate(bad)}
    bad=first;bad.nonce=Data(repeating:0,count:31).base64EncodedString()
    try rejected("短nonce") {try validate(bad)}
    bad=first;bad.parameters["shell"] = .init("touch /tmp/forbidden")
    try rejected("任意shell参数") {try validate(bad)}
    bad=first;bad.parameters["suggestedTitle"] = .init(String(repeating:"字",count:257))
    try rejected("过长标题") {try validate(bad)}
    bad=first;bad.items.append(bad.items[0])
    try rejected("重复项目与路径") {try validate(bad)}
    bad=first;bad.items[0].sha256="abcd"
    try rejected("错误SHA256长度") {try validate(bad)}
    for path in ["/absolute","a//b","a/./b","a/../b","a\\b","a/","\0"] {
        bad=first;bad.items[0].relativePath=path;try rejected("非法相对路径") {try validate(bad)}
    }
    var capture=request(20,action:"capture.region");capture.parameters=["delaySeconds":.init(true)]
    try rejected("布尔伪装延迟") {try validate(capture)}
    capture.parameters=["delaySeconds":.init(61)]
    try rejected("延迟超过上限") {try validate(capture)}
    var download=request(21,action:"downloads.prepare");download.parameters=["urls":.init(["file:///tmp/private"])]
    try rejected("下载file URL") {try validate(download)}
    download.parameters=["urls":.init(["https://example.org/file"]),"mediaType":.init("audio")];try validate(download);checks += 1
    var result=ocr;result.inReplyTo=nil;try rejected("结果缺关联") {try validate(result)}
    result=ocr;result.status=nil;try rejected("结果缺状态") {try validate(result)}
    result=ocr;result.status = .completed;result.provenance=["workflowState":.init("awaitingUser")]
    try rejected("打开复核UI不能完成") {try validate(result)}
    result=ocr;result.provenance=["script":.init("malicious")]
    try rejected("provenance含指令") {try validate(result)}
    // Reference identity checks are against the actual object, never declarations alone.
    var changed=storage.references[0];changed.declaredIdentity?.inode=0
    try rejected("reference inode改变") {_ = try GaoActionV1.verifyReference(changed)}
    changed=storage.references[0];changed.declaredIdentity=GaoActionIdentity()
    try rejected("reference身份全null需重选") {_ = try GaoActionV1.verifyReference(changed)}
    changed=storage.references[0];changed.fileURL="https://example.org/private"
    try rejected("reference远程URL") {try GaoActionV1.validateReferenceStructure(changed)}
    // Descriptor staging: source copies survive later mutation and contain no extra source objects.
    let staged=try GaoActionV1.stagePackage(at:firstURL,in:temp.appendingPathComponent("Receiver"),now:clock,expectedTarget:"com.gaoseries.GaoWenJian")
    try Data("different".utf8).write(to:firstURL.appendingPathComponent("payload/input.txt"))
    try assert(try Data(contentsOf:staged.files[0])==hello,"仅处理已验证接收副本")
    try GaoActionV1.verifyRetainedPackage(staged);checks += 1
    let modalStage=try GaoActionV1.stagePackage(at:try package(first,content:hello,suffix:"-modal"),in:temp.appendingPathComponent("ModalReceiver"),now:clock,expectedTarget:"com.gaoseries.GaoWenJian")
    try Data("changed during modal".utf8).write(to:modalStage.files[0])
    try rejected("用户确认期间附件变化") {try GaoActionV1.verifyRetainedPackage(modalStage)}
    let manifestModal=try GaoActionV1.stagePackage(at:try package(first,content:hello,suffix:"-manifest-modal"),in:temp.appendingPathComponent("ManifestModalReceiver"),now:clock,expectedTarget:"com.gaoseries.GaoWenJian")
    var modalManifest=first;modalManifest.parameters=["suggestedTitle":.init("changed")]
    try JSONEncoder().encode(modalManifest).write(to:manifestModal.directory.appendingPathComponent("manifest.json"))
    try rejected("用户确认期间manifest变化") {try GaoActionV1.verifyRetainedPackage(manifestModal)}
    var statFile=stat();_ = lstat(staged.files[0].path,&statFile)
    try assert(statFile.st_mode & 0o777==0o600 && statFile.st_nlink==1,"接收副本0600且独立inode")
    let symlinkURL=try package(first,content:hello,suffix:"-symlink")
    let symlinkFile=symlinkURL.appendingPathComponent("payload/input.txt")
    try fm.removeItem(at:symlinkFile);try fm.createSymbolicLink(at:symlinkFile,withDestinationURL:staged.files[0])
    var separate=Set<String>()
    try rejected("附件符号链接") {_ = try GaoActionV1.validatePackageDirectory(at:symlinkURL,now:clock,knownIDs:&separate)}
    let nestedURL=try package(first,content:hello,suffix:"-parent")
    try fm.removeItem(at:nestedURL.appendingPathComponent("payload"));try fm.createSymbolicLink(at:nestedURL.appendingPathComponent("payload"),withDestinationURL:staged.directory.appendingPathComponent("payload"))
    try rejected("payload父级符号链接") {_ = try GaoActionV1.validatePackageDirectory(at:nestedURL,now:clock,knownIDs:&separate)}
    let hardURL=try package(first,content:hello,suffix:"-hardlink")
    let hard=hardURL.appendingPathComponent("payload/input.txt")
    try fm.linkItem(at:hard,to:temp.appendingPathComponent("hard-copy"))
    try rejected("硬链接附件") {_ = try GaoActionV1.validatePackageDirectory(at:hardURL,now:clock,knownIDs:&separate)}
    let modeURL=try package(first,content:hello,suffix:"-mode")
    try fm.setAttributes([.posixPermissions:0o777],ofItemAtPath:modeURL.path)
    try rejected("可被其他用户写入的包") {_ = try GaoActionV1.validatePackageDirectory(at:modeURL,now:clock,knownIDs:&separate)}
    let hugeURL=try package(first,content:hello,suffix:"-huge")
    try Data(repeating:32,count:GaoActionV1.maximumManifestBytes+1).write(to:hugeURL.appendingPathComponent("manifest.json"))
    try rejected("有界manifest读取") {_ = try GaoActionV1.validatePackageDirectory(at:hugeURL,now:clock,knownIDs:&separate)}
    var incorrect=first;incorrect.items[0].sha256=String(repeating:"0",count:64)
    let incorrectURL=try package(incorrect,content:hello,suffix:"-hash")
    try rejected("摘要不一致") {_ = try GaoActionV1.stagePackage(at:incorrectURL,in:temp.appendingPathComponent("FailedReceiver"),now:clock,expectedTarget:"com.gaoseries.GaoWenJian")}
    try assert(try fm.contentsOfDirectory(atPath:temp.appendingPathComponent("FailedReceiver").path).isEmpty,"失败暂存回滚不留半包")
    let invalidText=Data([0xc0,0xaf]);var text=first;text.items[0].byteCount=2;text.items[0].sha256=GaoActionV1.calculateSHA256(data:invalidText)
    let invalidTextURL=try package(text,content:invalidText,suffix:"-utf8")
    try rejected("过长UTF8序列") {_ = try GaoActionV1.validatePackageDirectory(at:invalidTextURL,now:clock,knownIDs:&separate)}
    let source=temp.appendingPathComponent("copy-source.txt");try Data(repeating:65,count:131072).write(to:source)
    let sourceFD=try GaoActionFiles.openRegular(source,owned:false);defer{close(sourceFD)}
    var mutated=false
    try rejected("复制途中内容改变") {
        _ = try GaoActionFiles.copy(fd:sourceFD,to:nil,limit:131072) { _ in
            if !mutated {mutated=true;let writer=open(source.path,O_WRONLY);var byte:UInt8=66;_ = pwrite(writer,&byte,1,100000);close(writer)}
        }
    }
    // Package creation copies ordinary files, publishes manifest last and never replaces an existing ID.
    let original=temp.appendingPathComponent("原创 中文 ' 空格.txt");try hello.write(to:original)
    let generated=try GaoActionV1.createRequestPackage(in:temp.appendingPathComponent("Outgoing"),action:"documents.newText",targetBundleID:"com.gaoseries.GaoWenJian",inputFiles:[original],requestID:UUID(uuidString:id(30))!,now:clock,nonce:nonce)
    let generatedManifest=try GaoActionV1.validatePackageDirectory(at:generated,now:clock,knownIDs:&separate)
    try assert(generatedManifest.items.first?.sha256==hash && (try Data(contentsOf:original))==hello,"源文件保留且中文引号路径可复制")
    try rejected("相同ID不可覆盖") {_ = try GaoActionV1.createRequestPackage(in:temp.appendingPathComponent("Outgoing"),action:"documents.newText",targetBundleID:"com.gaoseries.GaoWenJian",inputFiles:[original],requestID:UUID(uuidString:id(30))!,now:clock,nonce:nonce)}
    // Persistent idempotence, correspondence and crash recovery across fresh journal instances.
    let journalDir=temp.appendingPathComponent("Journal"),j=try GaoActionJournal(directory:journalDir)
    var originalOCR=request(3,action:"ocr.files");originalOCR.items=[.init(id:"item-1",relativePath:"page.pdf",uti:"com.adobe.pdf",byteCount:6,sha256:hash)]
    try j.prepare(manifest:originalOCR,package:generated,digest:hash,now:clock);try j.transition(id(3),direction:"out",to:.dispatched,now:clock)
    let receivedOCR=try GaoActionV1.stagePackage(at:ocrURL,in:temp.appendingPathComponent("ResultReceiver"),now:clock)
    if case .new=try j.receive(receivedOCR,now:clock) {checks += 1}else{throw DataFailure.message("first result deduped")}
    let fresh=try GaoActionJournal(directory:journalDir)
    if case .duplicate(let record)=try fresh.receive(receivedOCR,now:clock) {try assert(record.state == .received,"重启重复结果显示原状态")}else{throw DataFailure.message("persistent duplicate lost")}
    try fresh.acceptResult(id(3),now:clock)
    try assert(try fresh.record(id(3),direction:"out")?.businessStatus == .partial,"partial不升级为completed")
    try rejected("已完成结果不重复接受") {try fresh.acceptResult(id(3),now:clock)}
    var conflict=receivedOCR.manifest;conflict.status = .completed
    let altered=GaoActionReceivedPackage(manifest:conflict,directory:receivedOCR.directory,files:[],manifestSHA256:String(repeating:"0",count:64))
    try rejected("同ID不同内容冲突") {_ = try fresh.receive(altered,now:clock)}
    var unmatched=ocr;unmatched.requestID=id(40);unmatched.inReplyTo=id(41)
    try rejected("无本地原请求的结果") {_ = try fresh.receive(.init(manifest:unmatched,directory:temp,files:[],manifestSHA256:hash),now:clock)}
    var crashRequest=originalOCR;crashRequest.requestID=id(45)
    try fresh.prepare(manifest:crashRequest,package:generated,digest:hash,now:clock);try fresh.transition(id(45),direction:"out",to:.dispatched,now:clock)
    var wrongHash=ocr;wrongHash.inReplyTo=id(45);wrongHash.requestID=id(42);wrongHash.provenance=["sources":.init([["sourceItemID":"item-1","sourceSHA256":String(repeating:"0",count:64)]])]
    try rejected("结果源摘要不匹配") {_ = try fresh.receive(.init(manifest:wrongHash,directory:temp,files:[],manifestSHA256:hash),now:clock)}
    var pending=ocr;pending.requestID=id(43);pending.inReplyTo=id(45);pending.status = .pending
    _ = try fresh.receive(.init(manifest:pending,directory:temp,files:[],manifestSHA256:hash),now:clock)
    try fresh.transition(id(43),direction:"in",to:.approved,now:clock);try fresh.transition(id(43),direction:"in",to:.executing,now:clock)
    let recovery=try GaoActionJournal(directory:journalDir)
    try assert(try recovery.recoverInterruptedRecords()==1,"崩溃执行记录转为待人工核对")
    try rejected("崩溃不自动重放") {try recovery.acceptResult(id(43),now:clock)}
    let corrupted=journalDir.appendingPathComponent("out-"+id(3).lowercased()+".json")
    try Data("corrupt".utf8).write(to:corrupted)
    try rejected("journal损坏不得当空数据") {_ = try recovery.record(id(3),direction:"out")}
    // Pending means an actual accepted task is still unfinished; a later unique result carries completion.
    var progressiveRequest=originalOCR;progressiveRequest.requestID=id(50)
    let progressive=try GaoActionJournal(directory:temp.appendingPathComponent("ProgressiveJournal"))
    try progressive.prepare(manifest:progressiveRequest,package:generated,digest:hash,now:clock)
    try progressive.transition(id(50),direction:"out",to:.dispatched,now:clock)
    var pendingResult=ocr;pendingResult.requestID=id(51);pendingResult.inReplyTo=id(50);pendingResult.status = .pending
    _ = try progressive.receive(.init(manifest:pendingResult,directory:temp,files:[],manifestSHA256:hash),now:clock)
    try progressive.acceptResult(id(51),now:clock)
    try assert(try progressive.record(id(50),direction:"out")?.businessStatus == .pending,"接受pending仍保持业务pending")
    var finalResult=ocr;finalResult.requestID=id(52);finalResult.inReplyTo=id(50)
    _ = try progressive.receive(.init(manifest:finalResult,directory:temp,files:[],manifestSHA256:hash),now:clock)
    try progressive.acceptResult(id(52),now:clock)
    try assert(try progressive.record(id(50),direction:"out")?.businessStatus == .partial,"后续实际结果正确关联原请求")
    try assert(try progressive.history().count==3,"重启可见任务历史包含原请求和两次结果")
    let manifestHard=try package(first,content:hello,suffix:"-manifest-hard")
    try fm.linkItem(at:manifestHard.appendingPathComponent("manifest.json"),to:temp.appendingPathComponent("manifest-hard-copy"))
    try rejected("硬链接manifest") {_ = try GaoActionV1.inspectManifest(at:manifestHard,now:clock)}
    let parentAlias=temp.appendingPathComponent("parent-alias")
    try fm.createSymbolicLink(at:parentAlias,withDestinationURL:temp)
    try rejected("包祖先符号链接") {_ = try GaoActionV1.inspectManifest(at:parentAlias.appendingPathComponent(ocrURL.lastPathComponent),now:clock)}
    let unknownFields=try package(first,content:hello,suffix:"-unknown-field")
    var fields=try JSONSerialization.jsonObject(with:Data(contentsOf:unknownFields.appendingPathComponent("manifest.json"))) as! [String:Any]
    fields["callbackURL"]="https://example.org"
    try JSONSerialization.data(withJSONObject:fields).write(to:unknownFields.appendingPathComponent("manifest.json"))
    try rejected("manifest未知字段") {_ = try GaoActionV1.inspectManifest(at:unknownFields,now:clock)}
    let exchange=temp.appendingPathComponent("Budget/Exchange")
    let budgetOut=exchange.appendingPathComponent("Outgoing/retained.gaoaction/payload")
    let budgetFD=try GaoActionFiles.privateDirectory(budgetOut);close(budgetFD)
    let retained=budgetOut.appendingPathComponent("keep.bin");try hello.write(to:retained);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:retained.path)
    try rejected("全体留存字节预算") {try GaoActionStorageBudget.check(exchange:exchange,additionalBytes:5,maximumBytes:10)}
    try rejected("包数预算") {try GaoActionStorageBudget.check(exchange:exchange,additionalBytes:0,maximumCount:1)}
    try assert(try Data(contentsOf:retained)==hello,"预算拒绝不会删除未完成副本")
    var captureResult=ocr;captureResult.action="capture.region";captureResult.status = .completed;captureResult.provenance=[:]
    try rejected("截图完成但无图像") {try validate(captureResult)}
    var downloadResult=ocr;downloadResult.action="downloads.prepare";downloadResult.sourceBundleID="com.gaoseries.GaoXiaZai";downloadResult.status = .completed;downloadResult.provenance=["workflowState":.init("accepted"),"taskIDs":.init(["task-1"])]
    try rejected("下载accepted不得当完成") {try validate(downloadResult)}
    downloadResult.status = .pending;try validate(downloadResult);checks += 1
    var pinResult=ocr;pinResult.action="images.pin";pinResult.status = .completed;pinResult.provenance=["workflowState":.init("opened")]
    try validate(pinResult);checks += 1
    pinResult.provenance=[:];try rejected("贴图完成需实际UI状态") {try validate(pinResult)}
    var translated=ocr;translated.action="text.translate";translated.status = .completed;translated.items=first.items;translated.provenance=["provider":.init("local"),"networkUsed":.init(false)]
    try validate(translated);checks += 1
    translated.provenance?.removeValue(forKey:"networkUsed");try rejected("翻译联网来源缺失") {try validate(translated)}
    // Real installed provider capability gating is read-only; synthetic app tests below never launch apps.
    let fake=temp.appendingPathComponent("Fake.app"),resources=fake.appendingPathComponent("Contents/Resources",isDirectory:true)
    try fm.createDirectory(at:resources,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let info:[String:Any]=["CFBundleIdentifier":"com.gaoseries.GaoJieTu","CFBundleShortVersionString":"1.00","CFBundlePackageType":"APPL"]
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:fake.appendingPathComponent("Contents/Info.plist"))
    try rejected("已安装但无能力表") {_ = try GaoActionProviderCapabilities.load(appURL:fake,bundleID:"com.gaoseries.GaoJieTu")}
    let caps:[String:Any]=["schemaVersion":1,"bundleID":"com.gaoseries.GaoJieTu","appVersion":"1.00","actions":[["action":"capture.region","parametersSchema":["type":"object","properties":["delaySeconds":["type":"number","minimum":0,"maximum":60]],"additionalProperties":false],"supportsItems":false,"supportsReferences":false]]]
    try JSONSerialization.data(withJSONObject:caps).write(to:resources.appendingPathComponent("GaoCapabilities.json"))
    let capability=try GaoActionProviderCapabilities.load(appURL:fake,bundleID:"com.gaoseries.GaoJieTu")
    try capability.require(action:"capture.region",parameters:["delaySeconds":5],items:false,references:false);checks += 1
    try rejected("未声明动作") {try capability.require(action:"capture.display",parameters:[:],items:false,references:false)}
    try rejected("未声明附件") {try capability.require(action:"capture.region",parameters:[:],items:true,references:false)}
    try rejected("未知能力参数") {try capability.require(action:"capture.region",parameters:["callbackURL":"https://example.org"],items:false,references:false)}
    let client=GaoActionClient(dataDirectory:temp.appendingPathComponent("Client"))
    do {_ = try await client.sendRequest(action:"capture.region",targetBundleID:"com.gaoseries.NonExistentProvider")} catch GaoActionError.providerNotReady {checks += 1}
    print("PASS: GaoAction V1 canonical fixtures + \(checks) meaningful schema/FD staging/reference/journal/capability assertions; no provider or GUI completion claimed")
}
