import AppKit
import Combine

private final class InputCloudPresenter:NSObject,NSFilePresenter {
    let presentedItemURL:URL?
    let presentedItemOperationQueue=OperationQueue()
    let changed:()->Void
    init(url:URL,changed:@escaping()->Void) {presentedItemURL=url;self.changed=changed;presentedItemOperationQueue.maxConcurrentOperationCount=1}
    func presentedItemDidChange() {changed()}
    func presentedSubitemDidAppear(at url:URL) {changed()}
    func presentedSubitemDidChange(at url:URL) {changed()}
    func presentedSubitem(at oldURL:URL,didMoveTo newURL:URL) {changed()}
    func presentedItemDidChangeUbiquityAttributes(_ attributes:Set<URLResourceKey>) {changed()}
}

@MainActor final class InputCloudSync:ObservableObject {
    struct State:Codable {
        var schema=1
        var deviceID=UUID()
        var folder=""
        var appliedHeads:[String]=[]
        var base:InputEnhancementConfiguration?
    }
    struct RemoteChoice:Identifiable {
        let id:String
        let configuration:InputEnhancementConfiguration
        var text:String {Self.render(configuration)}
        static func render(_ configuration:InputEnhancementConfiguration)->String {
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            return (try? encoder.encode(configuration.cloudPayload)).flatMap{String(data:$0,encoding:.utf8)} ?? ""
        }
    }
    enum Resolution {case local;case remote(String)}
    @Published private(set) var status="iCloud 自动同步未开启"
    @Published private(set) var conflicts:[String]=[]
    @Published private(set) var remoteChoices:[RemoteChoice]=[]
    @Published private(set) var localConflictText=""
    var apply:((InputEnhancementConfiguration)throws->Void)?
    private let data:LocalData
    private var state=State(),stateLoaded=false
    private var current=InputEnhancementConfiguration()
    private var transport:InputCloudTransport?
    private var presenter:InputCloudPresenter?
    private var timer:Timer?
    private var debounce:DispatchWorkItem?
    private var working=false,generation:UInt64=0
    private var cancellation:InputCloudCancellation?
    private var pendingConflictHeads:[String]=[]
    private var pendingConflictLocal:InputEnhancementConfiguration?
    init(directory:URL) {data=LocalData(directory:directory)}
    func configure(_ configuration:InputEnhancementConfiguration) {
        if configuration==current,working || transport != nil || !configuration.iCloudSyncEnabled {return}
        let accessChanged=current.iCloudSyncFolder != configuration.iCloudSyncFolder || current.iCloudSyncBookmark != configuration.iCloudSyncBookmark
        current=configuration;generation &+= 1;cancellation?.cancel()
        if accessChanged || !configuration.iCloudSyncEnabled {stopTransport()}
        guard configuration.iCloudSyncEnabled else {status="iCloud 自动同步未开启";return}
        if timer==nil {timer=Timer.scheduledTimer(withTimeInterval:5,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.schedule()}}}
        schedule()
    }
    private func stopTransport() {
        cancellation?.cancel();debounce?.cancel();debounce=nil;timer?.invalidate();timer=nil
        if let presenter {NSFileCoordinator.removeFilePresenter(presenter)}
        presenter=nil;transport=nil;conflicts=[];remoteChoices=[];pendingConflictHeads=[];pendingConflictLocal=nil;localConflictText=""
    }
    private func schedule() {
        guard current.iCloudSyncEnabled,!working else {return}
        debounce?.cancel()
        let job=DispatchWorkItem{[weak self] in Task{@MainActor in await self?.synchronize()}}
        debounce=job;DispatchQueue.main.asyncAfter(deadline:.now()+0.4,execute:job)
    }
    func resolve(_ choice:Resolution) {Task{@MainActor in await synchronize(resolution:choice)}}
    private func synchronize(resolution:Resolution?=nil) async {
        guard current.iCloudSyncEnabled,!working else {return}
        working=true
        let observedGeneration=generation,configuration=current,token=InputCloudCancellation()
        cancellation=token
        defer {working=false;if cancellation===token {cancellation=nil};if generation != observedGeneration {schedule()}}
        do {
            if !stateLoaded {state=try data.load("state.json",as:State.self) ?? State();guard state.schema==1 else {throw DataFailure.message("iCloud 本机同步状态来自新版本，未覆盖。")};stateLoaded=true}
            let transport:InputCloudTransport
            if let existing=self.transport {transport=existing}
            else {
                transport=try await Task.detached(priority:.utility){try InputCloudTransport(configuration:configuration,cancellation:token)}.value
                guard generation==observedGeneration else {return}
                self.transport=transport
                let observer=InputCloudPresenter(url:transport.root){[weak self] in DispatchQueue.main.async{self?.schedule()}}
                presenter=observer;NSFileCoordinator.addFilePresenter(observer)
            }
            if state.folder != transport.namespace {state=State(folder:transport.namespace)}
            let initialState=state
            let initial=try await Task.detached(priority:.utility){()throws->(revisions:[String:InputCloudRevision],published:String?) in
                var revisions=try transport.read(cancellation:token)
                _ = try InputCloudMerge.heads(revisions)
                guard initialState.appliedHeads.allSatisfy({revisions[$0] != nil}) else {throw DataFailure.message("iCloud 已应用版本尚未完整下载或被移除；停止发布，本机及现有远端版本保留。")}
                var published:String?
                if initialState.base != configuration.cloudPayload {
                    let revision=InputCloudRevision(deviceID:initialState.deviceID,parents:initialState.appliedHeads.sorted(),configuration:configuration.cloudPayload)
                    let id=try transport.publish(revision,cancellation:token);revisions[id]=revision;published=id
                }
                return (revisions,published)
            }.value
            guard generation==observedGeneration else {return}
            if let id=initial.published {state.appliedHeads=[id];state.base=configuration.cloudPayload;try data.save(state,name:"state.json")}
            let plan=try InputCloudMerge.plan(revisions:initial.revisions,local:configuration,appliedHeads:state.appliedHeads)
            guard !plan.heads.isEmpty else {return}
            var merged=plan.value
            if !plan.conflicts.isEmpty {
                conflicts=plan.conflicts
                guard let resolution,plan.heads==pendingConflictHeads,pendingConflictLocal==configuration.cloudPayload else {
                    pendingConflictHeads=plan.heads;pendingConflictLocal=configuration.cloudPayload;localConflictText=RemoteChoice.render(configuration)
                    remoteChoices=plan.heads.filter{initial.revisions[$0]!.configuration != configuration.cloudPayload}.map{RemoteChoice(id:$0,configuration:initial.revisions[$0]!.configuration)}
                    status=L10n.format("iCloud 有 %d 处离线修改冲突；本机内容及双方版本均保留。",conflicts.count);return
                }
                let choice:InputCloudMerge.Choice
                switch resolution {case .local:choice = .local;case .remote(let id):choice = .remote(id)}
                merged=try InputCloudMerge.resolvedValue(plan,choice:choice,local:configuration,revisions:initial.revisions)
            }
            let safe=InputCloudLocalReview.review(merged,against:configuration)
            try EnhancedInputValidation.validate(safe)
            if safe != configuration {
                guard let apply else {throw DataFailure.message("iCloud 合并尚未连接本机保存，未覆盖规则。")}
                try apply(safe);current=safe
            }
            let finalHeads=try await Task.detached(priority:.utility){()throws->[String] in
                if plan.heads.count>1 || resolution != nil {
                    let revision=try InputCloudRevision.merged(parents:plan.heads,configuration:safe.cloudPayload)
                    return [try transport.publish(revision,cancellation:token)]
                }
                return plan.heads
            }.value
            guard generation==observedGeneration else {return}
            state.appliedHeads=finalHeads;state.base=safe.cloudPayload;try data.save(state,name:"state.json")
            conflicts=[];remoteChoices=[];pendingConflictHeads=[];pendingConflictLocal=nil;localConflictText=""
            let uploaded=try await Task.detached(priority:.utility){try transport.uploaded(finalHeads,cancellation:token)}.value
            guard generation==observedGeneration else {return}
            status=uploaded ? "iCloud 自动同步已上传；正在监听远端修改":"iCloud 本机版本已保存，等待系统上传；离线修改不会覆盖远端分支"
        } catch {if generation==observedGeneration {status=error.localizedDescription}}
    }
}

/// Review is local consent, never a remotely supplied execution permission.
/// Keep legacy field names for existing documents; they now protect every
/// executable rule/mapping, including reactivation without a changed script.
enum InputCloudLocalReview {
    static func review(_ incoming:InputEnhancementConfiguration,against local:InputEnhancementConfiguration)->InputEnhancementConfiguration {
        var safe=incoming.retainingLocalCloudAccess(from:local)
        var rules=Set(local.cloudPendingScriptRules),buttons=Set(local.cloudPendingHIDMappings),profiles=Set(local.cloudPendingHIDProfiles)
        for rule in safe.rules {
            let previous=local.rules.first{$0.id==rule.id}
            var before=previous,after=rule
            before?.name="";before?.enabled=false;before?.migrationOrigin=nil;after.name="";after.enabled=false;after.migrationOrigin=nil
            if before != after || rule.enabled && (previous?.enabled != true || !local.enabled && safe.enabled) {rules.insert(rule.id)}
        }
        for profile in safe.hidProfiles {
            let previous=local.hidProfiles.first{$0.id==profile.id}
            let changedTracking=previous?.deviceID != profile.deviceID || previous?.requestsTrackingAdjustment != profile.requestsTrackingAdjustment || previous?.trackingSpeed != profile.trackingSpeed || previous?.trackingAcceleration != profile.trackingAcceleration
            let reactivated=profile.enabled && (previous?.enabled != true || !local.enabled && safe.enabled)
            if changedTracking || reactivated {profiles.insert(profile.id)}
            for mapping in profile.buttons {
                let original=previous?.buttons.first{$0.id==mapping.id}
                var before=original,after=mapping
                before?.name="";before?.enabled=false;after.name="";after.enabled=false
                if before != after || mapping.enabled && (original?.enabled != true || reactivated) {buttons.insert(mapping.id)}
            }
        }
        safe.cloudPendingScriptRules=rules.filter{id in safe.rules.contains{$0.id==id}}.sorted{$0.uuidString<$1.uuidString}
        safe.cloudPendingHIDMappings=buttons.filter{id in safe.hidProfiles.contains{$0.buttons.contains{$0.id==id}}}.sorted{$0.uuidString<$1.uuidString}
        safe.cloudPendingHIDProfiles=profiles.filter{id in safe.hidProfiles.contains{$0.id==id}}.sorted{$0.uuidString<$1.uuidString}
        return safe
    }
}
