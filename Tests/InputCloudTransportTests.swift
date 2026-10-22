import Foundation
import Darwin

private final class CloudHeldPresenter:NSObject,NSFilePresenter,@unchecked Sendable {
    let presentedItemURL:URL?
    let presentedItemOperationQueue=OperationQueue()
    private let lock=NSLock()
    private var count=0
    var relinquishes:Int {lock.lock();defer{lock.unlock()};return count}
    init(_ url:URL) {presentedItemURL=url;presentedItemOperationQueue.maxConcurrentOperationCount=1}
    func relinquishPresentedItem(toReader reader:@escaping @Sendable ((@Sendable ()->Void)?)->Void) {
        lock.lock();count += 1;lock.unlock()
        DispatchQueue.global().asyncAfter(deadline:.now()+1){reader(nil)}
    }
}

/// Uses only a freshly created, unpredictable child of the explicit cloud root.
/// Synthetic inputs and private local state never reference the user's settings.
@MainActor func runInputCloudTransportTests(cloudParent:URL) async throws {
    let fm=FileManager.default
    let cloud=cloudParent.appendingPathComponent("GaoCaoZuo-Transport-Test-"+UUID().uuidString+".noindex",isDirectory:true)
    let local=fm.temporaryDirectory.appendingPathComponent("GaoCaoZuo-Cloud-State-"+UUID().uuidString+".noindex",isDirectory:true)
    var active:InputCloudSync?
    var checks=0
    func check(_ condition:Bool,_ message:String)throws {checks += 1;if !condition {throw DataFailure.message(message)}}
    func rejects(_ body:()throws->Void)throws {checks += 1;do {try body()}catch{return};throw DataFailure.message("Cloud transport accepted "+String(checks))}
    func wait(_ description:String,seconds:Double=12,_ condition:()->Bool) async throws {
        let end=Date().addingTimeInterval(seconds)
        while !condition(),Date()<end {try await Task.sleep(nanoseconds:100_000_000)}
        try check(condition(),description+"; "+(active?.status ?? ""))
    }
    func disabled(_ value:InputEnhancementConfiguration)->InputEnhancementConfiguration {var value=value;value.iCloudSyncEnabled=false;return value}
    defer {
        if let active {active.configure(disabled(InputEnhancementConfiguration()))}
        try? fm.removeItem(at:cloud)
        try? fm.removeItem(at:local)
    }
    guard try cloudParent.resourceValues(forKeys:[.isUbiquitousItemKey]).isUbiquitousItem==true else {throw DataFailure.message("Live cloud test unavailable: selected CloudDocs root is not ubiquitous; no user configuration read or uploaded.")}
    try fm.createDirectory(at:cloud,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    try fm.createDirectory(at:local,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    var configuration=InputEnhancementConfiguration(),rule=EnhancedInputRule(),script=EnhancedInputRule()
    rule.name="Public synthetic cloud base";script.name="Public synthetic inert script";script.effect.kind = .appleScript;script.effect.script="return \"public synthetic value\""
    configuration.rules=[rule,script];configuration.iCloudSyncEnabled=true;configuration.iCloudSyncFolder=cloud.path
    let transport=try InputCloudTransport(configuration:configuration,cancellation:InputCloudCancellation())
    let other=try InputCloudTransport(configuration:configuration,cancellation:InputCloudCancellation())
    let initial=InputCloudRevision(deviceID:UUID(),parents:[],configuration:configuration.cloudPayload)
    let rootID=try transport.publish(initial,cancellation:InputCloudCancellation())
    try check(try other.read(cancellation:InputCloudCancellation())[rootID]==initial,"Second real cloud transport did not read published synthetic revision")
    try check(try other.publish(initial,cancellation:InputCloudCancellation())==rootID,"Immutable publication was not idempotent")
    var privateRevision=initial;privateRevision.configuration.iCloudSyncFolder="/public/forbidden-local-access"
    try rejects{_ = try transport.publish(privateRevision,cancellation:InputCloudCancellation())}
    var missingParent=initial;missingParent.parents=[String(repeating:"a",count:64)]
    try rejects{_ = try transport.publish(missingParent,cancellation:InputCloudCancellation())}
    let data=LocalData(directory:local)
    try data.save(InputCloudSync.State(folder:transport.namespace,appliedHeads:[rootID],base:configuration.cloudPayload),name:"state.json")
    var remote=configuration.cloudPayload;remote.rules[0].name="Public remote automatic update"
    let remoteRevision=InputCloudRevision(deviceID:UUID(),parents:[rootID],configuration:remote)
    let remoteID=try other.publish(remoteRevision,cancellation:InputCloudCancellation())
    var applied:InputEnhancementConfiguration?
    active=InputCloudSync(directory:local)
    active!.apply={value in applied=value}
    active!.configure(configuration)
    try await wait("Automatic controller did not apply a real coordinated cloud revision"){applied?.rules[0].name==remote.rules[0].name}
    configuration=applied!
    active!.configure(disabled(configuration));active=nil
    // Two authors now independently change the same base while A is stopped.
    var offlineA=configuration;offlineA.rules[0].name="Public offline A"
    var offlineB=configuration.cloudPayload;offlineB.rules[0].name="Public offline B"
    let branchB=InputCloudRevision(deviceID:UUID(),parents:[remoteID],configuration:offlineB)
    let branchBID=try other.publish(branchB,cancellation:InputCloudCancellation())
    applied=nil;active=InputCloudSync(directory:local);active!.apply={value in applied=value};active!.configure(offlineA)
    try await wait("Restarted automatic controller did not preserve offline conflict"){active?.conflicts.isEmpty==false}
    try check(applied==nil,"Offline conflict was silently applied before choice")
    active!.resolve(.local)
    try await wait("Explicit local resolution did not finish"){active?.conflicts.isEmpty==true && active?.status.contains("iCloud")==true && (active?.status.contains("上传")==true)}
    let resolved=try other.read(cancellation:InputCloudCancellation()),heads=try InputCloudMerge.heads(resolved)
    try check(heads.count==1 && resolved[heads[0]]?.configuration.rules[0].name=="Public offline A","Actual cloud merge selected a folded remote value")
    try check(resolved[branchBID]==branchB && resolved[rootID]==initial,"Actual cloud merge removed historical branches")
    configuration=applied ?? offlineA
    active!.configure(disabled(configuration));active=nil
    // Same script text, remotely enabled after the local device disabled it.
    var reenabled=configuration.cloudPayload;reenabled.rules[1].enabled=true
    _ = try other.publish(InputCloudRevision(deviceID:UUID(),parents:heads,configuration:reenabled),cancellation:InputCloudCancellation())
    applied=nil;active=InputCloudSync(directory:local);active!.apply={value in applied=value};active!.configure(configuration)
    try await wait("Restart did not receive remote reactivation"){applied?.rules[1].enabled==true}
    try check(applied!.cloudPendingScriptRules.contains(script.id),"Same-text remote script reactivation bypassed local consent")
    try check(applied!.cloudPayload.cloudPendingScriptRules.isEmpty && applied!.iCloudSyncFolder==cloud.path,"Local consent or authorization was copied into remote payload")
    active!.configure(disabled(applied!));active=nil
    let finalMap=try other.read(cancellation:InputCloudCancellation()),finalHeads=try InputCloudMerge.heads(finalMap)
    let uploadEnd=Date().addingTimeInterval(20)
    var uploaded=false
    while !uploaded,Date()<uploadEnd {
        uploaded=try other.uploaded(finalHeads,cancellation:InputCloudCancellation())
        if !uploaded {try await Task.sleep(nanoseconds:500_000_000)}
    }
    print("Live ubiquitous synthetic revisions uploaded=\(uploaded); a second Mac/network-offline transport was not exercised.")
    // Exact immutable file presented by our own presenter; no user presenter is touched.
    let held=CloudHeldPresenter(transport.root.appendingPathComponent(rootID+".json"))
    NSFileCoordinator.addFilePresenter(held)
    defer {NSFileCoordinator.removeFilePresenter(held)}
    let token=InputCloudCancellation()
    let read=Task.detached {try transport.read(cancellation:token)}
    let coordinationEnd=Date().addingTimeInterval(2)
    while held.relinquishes==0,Date()<coordinationEnd {try await Task.sleep(nanoseconds:20_000_000)}
    token.cancel()
    var rejected=false
    do {_ = try await read.value}catch {rejected=true}
    try check(rejected,"Cancelled coordinated read applied data")
    NSFileCoordinator.removeFilePresenter(held)
    try check(held.relinquishes>0,"Cancellation case never entered actual NSFileCoordinator presenter handoff")
    let cancelled=InputCloudCancellation();cancelled.cancel()
    try rejects{_ = try transport.publish(initial,cancellation:cancelled)}
    let invalidName=String(repeating:"b",count:64)+".json",invalid=transport.root.appendingPathComponent(invalidName)
    try Data("public malformed revision".utf8).write(to:invalid,options:.withoutOverwriting)
    try rejects{_ = try transport.read(cancellation:InputCloudCancellation())};try fm.removeItem(at:invalid)
    let target=local.appendingPathComponent("public-canary.txt");try Data("public canary".utf8).write(to:target)
    try fm.createSymbolicLink(at:invalid,withDestinationURL:target)
    try rejects{_ = try transport.read(cancellation:InputCloudCancellation())};try fm.removeItem(at:invalid)
    let moved=cloudParent.appendingPathComponent(cloud.lastPathComponent+"-displaced",isDirectory:true)
    try fm.moveItem(at:cloud,to:moved)
    defer {if fm.fileExists(atPath:moved.path) {try? fm.removeItem(at:cloud);try? fm.moveItem(at:moved,to:cloud)}}
    try fm.createDirectory(at:cloud,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    try rejects{_ = try transport.read(cancellation:InputCloudCancellation())}
    try rejects{_ = try transport.publish(initial,cancellation:InputCloudCancellation())}
    try fm.removeItem(at:cloud);try fm.moveItem(at:moved,to:cloud)
    try transport.ensureCurrent()
    try fm.removeItem(at:cloud);try fm.removeItem(at:local)
    try check(!fm.fileExists(atPath:cloud.path) && !fm.fileExists(atPath:local.path),"Synthetic cloud/local test directories were not removed")
    print("Live iCloud transport/controller targeted checks passed (\(checks)); real ubiquitous folder, automatic scheduling, restart/offline branches, local consent, cancellation, malformed/link/replaced directory. uploaded=\(uploaded); cleanup=verified")
}

@MainActor func runInputCloudLocalConsentTests()throws {
    var base=InputEnhancementConfiguration(),rule=EnhancedInputRule(),profile=HIDDeviceProfile(),button=HIDButtonMapping()
    base.enabled=true;rule.enabled=true;rule.effect.kind = .appleScript;rule.effect.script="return \"synthetic\"";base.rules=[rule]
    profile.deviceID="public-synthetic-hid";profile.enabled=true;button.enabled=true;button.effect=rule.effect;profile.buttons=[button];base.hidProfiles=[profile]
    var checks=0
    func check(_ condition:Bool,_ message:String)throws {checks += 1;if !condition{throw DataFailure.message(message)}}
    var incoming=base;incoming.rules[0].name="Only descriptive rename";incoming.hidProfiles[0].name="Rename"
    var safe=InputCloudLocalReview.review(incoming,against:base)
    try check(safe.cloudPendingScriptRules.isEmpty && safe.cloudPendingHIDMappings.isEmpty && safe.cloudPendingHIDProfiles.isEmpty,"Descriptive rename unnecessarily changed consent")
    var disabled=base;disabled.rules[0].enabled=false;disabled.hidProfiles[0].enabled=false
    safe=InputCloudLocalReview.review(base,against:disabled)
    try check(safe.cloudPendingScriptRules==[rule.id] && safe.cloudPendingHIDMappings==[button.id] && safe.cloudPendingHIDProfiles==[profile.id],"Remote reactivation bypassed local consent")
    incoming=base;incoming.rules[0].keyCode=32;incoming.hidProfiles[0].buttons[0].appBundleID="com.public.synthetic";incoming.hidProfiles[0].trackingSpeed=2
    safe=InputCloudLocalReview.review(incoming,against:base)
    try check(safe.cloudPendingScriptRules==[rule.id] && safe.cloudPendingHIDMappings==[button.id] && safe.cloudPendingHIDProfiles==[profile.id],"Remote trigger/scope/tracking change bypassed local consent")
    disabled=base;disabled.enabled=false;safe=InputCloudLocalReview.review(base,against:disabled)
    try check(safe.cloudPendingScriptRules.contains(rule.id) && safe.cloudPendingHIDMappings.contains(button.id) && safe.cloudPendingHIDProfiles.contains(profile.id),"Global remote reenable activated local input")
    safe=InputCloudLocalReview.review(base,against:safe)
    try check(safe.cloudPendingScriptRules==[rule.id] && safe.cloudPayload.cloudPendingScriptRules.isEmpty && safe.cloudPayload.cloudPendingHIDProfiles.isEmpty,"Local consent pause was cleared or uploaded on subsequent poll")
    safe=InputCloudLocalReview.review(InputEnhancementConfiguration(),against:safe)
    try check(safe.cloudPendingScriptRules.isEmpty && safe.cloudPendingHIDMappings.isEmpty && safe.cloudPendingHIDProfiles.isEmpty,"Deleted IDs left stale consent pause")
    let old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(base)) as! [String:Any]
    var legacy=old;legacy.removeValue(forKey:"cloudPendingHIDProfiles")
    let decoded=try JSONDecoder().decode(InputEnhancementConfiguration.self,from:JSONSerialization.data(withJSONObject:legacy))
    try check(decoded.cloudPendingHIDProfiles.isEmpty,"Legacy local configuration failed additive migration")
    var provenance=base
    let origin=InputRuleMigrationOrigin(sourceDigest:String(repeating:"c",count:64),rowID:UUID(),sourceEnabled:true,disposition:.exact,requirements:[],reason:"public synthetic provenance")
    provenance.rules[0].migrationOrigin=origin
    let portable=provenance.cloudPayload
    try EnhancedInputValidation.validate(portable)
    try check(portable.rules[0].migrationOrigin==nil && portable.migrationSources.isEmpty,"Private migration archive references made portable rules invalid")
    var renamed=portable;renamed.rules[0].name="Public remote descriptive name"
    safe=InputCloudLocalReview.review(renamed,against:provenance)
    try check(safe.rules[0].migrationOrigin==origin && safe.cloudPendingScriptRules.isEmpty,"Unchanged portable execution discarded local provenance or consent")
    renamed.rules[0].keyCode=33;safe=InputCloudLocalReview.review(renamed,against:provenance)
    try check(safe.rules[0].migrationOrigin==nil && safe.cloudPendingScriptRules==[rule.id],"Changed portable rule retained invalid exact-import execution proof")
    print("Cloud local consent targeted checks passed (\(checks)); no scripts, HID events, global settings or user configuration executed.")
}
