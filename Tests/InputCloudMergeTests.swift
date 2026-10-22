import Foundation

@MainActor func runInputCloudMergeTests() throws {
    var checks=0
    func check(_ value:Bool,_ message:String) throws {checks += 1;guard value else {throw DataFailure.message(message)}}
    func rejects(_ body:() throws -> Void) throws {checks += 1;do {try body()}catch{return};throw DataFailure.message("Cloud invalid revision accepted")}
    var base=InputEnhancementConfiguration(),rule=EnhancedInputRule();rule.name="public base";rule.enabled=false;base.rules=[rule]
    var local=base,remote=base
    local.rules[0].name="local offline edit"
    var another=EnhancedInputRule();another.name="remote new rule";another.enabled=false;remote.rules.append(another)
    let merged=try InputCloudMerge.merge(base:base,local:local,remote:remote)
    try check(merged.conflicts.isEmpty && merged.value.rules.count==2 && merged.value.rules[0].name=="local offline edit","Nonoverlapping offline edits not merged")
    remote.rules[0].name="remote offline edit"
    let remoteConflict=remote
    let conflict=try InputCloudMerge.merge(base:base,local:local,remote:remote)
    try check(conflict.conflicts==["rules/"+rule.id.uuidString] && conflict.value.rules[0].name=="local offline edit" && conflict.value.rules.contains(another),"Conflict did not retain local choice and unrelated remote edit")
    local.rules=[]
    let deleted=try InputCloudMerge.merge(base:base,local:local,remote:remote)
    try check(!deleted.conflicts.isEmpty && !deleted.value.rules.contains(where:{$0.id==rule.id}),"Deletion versus modification conflict lost")
    remote=base
    let unopposedDelete=try InputCloudMerge.merge(base:base,local:local,remote:remote)
    try check(unopposedDelete.conflicts.isEmpty && unopposedDelete.value.rules.isEmpty,"Unopposed deletion resurrected")
    let deviceA=UUID(),deviceB=UUID(),root=InputCloudRevision(deviceID:deviceA,parents:[],configuration:base)
    let rootID=try root.digest
    let a=InputCloudRevision(deviceID:deviceA,parents:[rootID],configuration:merged.value),aID=try a.digest
    let b=InputCloudRevision(deviceID:deviceB,parents:[rootID],configuration:remote),bID=try b.digest
    let map=[rootID:root,aID:a,bID:b]
    try check(try InputCloudMerge.heads(map)==[aID,bID].sorted(),"Offline revision frontier incorrect")
    try check(try InputCloudMerge.commonBase(heads:[aID,bID],revisions:map)==base,"Common ancestor incorrect")
    let liveMap=[rootID:root,aID:a]
    try check(try InputCloudMerge.heads(liveMap)==[aID],"Real frontier must exclude the applied ancestor")
    let fastForward=try InputCloudMerge.plan(revisions:liveMap,local:base,appliedHeads:[rootID])
    try check(fastForward.value==merged.value && fastForward.conflicts.isEmpty,"Fast-forward update ignored")
    let beforeRestart=InputCloudSync.State(appliedHeads:[rootID],base:base)
    let restarted=try JSONDecoder().decode(InputCloudSync.State.self,from:JSONEncoder().encode(beforeRestart))
    let afterRestart=try InputCloudMerge.plan(revisions:liveMap,local:restarted.base!,appliedHeads:restarted.appliedHeads)
    try check(afterRestart.value==merged.value && afterRestart.conflicts.isEmpty,"Restart lost the applied ancestor and remote fast-forward")
    try rejects {_ = try InputCloudMerge.heads([aID:a])}
    var duplicate=base;duplicate.rules.append(rule)
    try rejects {_ = try InputCloudMerge.merge(base:base,local:duplicate,remote:remote)}
    var cycleA=root,cycleB=a;cycleA.parents=[aID];cycleB.parents=[rootID]
    try rejects {_ = try InputCloudMerge.heads([rootID:cycleA,aID:cycleB])}
    let chosen=InputCloudMerge.applyingConflictValues(conflict.conflicts,from:remoteConflict,to:conflict.value)
    try check(chosen.rules.first(where:{$0.id==rule.id})==remoteConflict.rules.first(where:{$0.id==rule.id}) && chosen.rules.contains(another),"Explicit remote conflict choice lost another edit")
    let mergeA=try InputCloudRevision.merged(parents:[aID,bID],configuration:merged.value)
    let mergeB=try InputCloudRevision.merged(parents:[bID,aID],configuration:merged.value)
    try check(try mergeA.digest==mergeB.digest,"Commuting identical merges created different heads")
    var privateAccess=base;privateAccess.iCloudSyncEnabled=true;privateAccess.iCloudSyncFolder="/private/local/only";privateAccess.iCloudSyncBookmark=Data([1,2]);privateAccess.syncFolder="/private/manual";privateAccess.experimentalRawTouch=true
    try check(privateAccess.cloudPayload.iCloudSyncFolder.isEmpty && privateAccess.cloudPayload.iCloudSyncBookmark==nil && !privateAccess.cloudPayload.experimentalRawTouch && privateAccess.cloudPayload.syncFolder.isEmpty,"Local authorization or experimental activation entered cloud payload")
    let decoded=try JSONDecoder().decode(InputCloudRevision.self,from:root.encoded)
    try check(try decoded.digest==rootID && decoded==root,"Revision digest/roundtrip mismatch")
    // The local device is still at A; two remote branches disagree. The live
    // controller must select actual A, not the first remote folded into plan.
    var branchB=base,branchC=base,addedB=EnhancedInputRule(),addedC=EnhancedInputRule()
    addedB.name="public independent B";addedC.name="public independent C"
    branchB.rules[0].name="public branch B";branchC.rules[0].name="public branch C"
    branchB.rules.append(addedB);branchC.rules.append(addedC)
    let rb=InputCloudRevision(deviceID:UUID(),parents:[rootID],configuration:branchB),rc=InputCloudRevision(deviceID:UUID(),parents:[rootID],configuration:branchC)
    let rbID=try rb.digest,rcID=try rc.digest,branches=[rootID:root,rbID:rb,rcID:rc]
    try check(try InputCloudMerge.heads(branches)==[rbID,rcID].sorted(),"Actual two-remote frontier incorrect")
    let divergent=try InputCloudMerge.plan(revisions:branches,local:base,appliedHeads:restarted.appliedHeads)
    try check(divergent.conflicts==["rules/"+rule.id.uuidString],"Two remote edits must conflict with unchanged local")
    for (choice,expected) in [(InputCloudMerge.Choice.local,base),(.remote(rbID),branchB),(.remote(rcID),branchC)] {
        let selected=try InputCloudMerge.resolvedValue(divergent,choice:choice,local:base,revisions:branches)
        try check(selected.rules.first{$0.id==rule.id}==expected.rules.first{$0.id==rule.id},"Actual local/B/C conflict choice applied a different value")
        try check(selected.rules.contains(addedB) && selected.rules.contains(addedC),"Conflict choice removed unrelated remote additions")
    }
    try rejects {_ = try InputCloudMerge.resolvedValue(divergent,choice:.remote(rootID),local:base,revisions:branches)}
    let ambiguous=InputCloudMerge.Plan(heads:[rbID,rcID],value:branchB,conflicts:["configuration"])
    try check(try InputCloudMerge.resolvedValue(ambiguous,choice:.local,local:base,revisions:branches)==base,"Whole-configuration local choice did not use local snapshot")

    var orderBase=base,second=EnhancedInputRule(),third=EnhancedInputRule()
    second.name="public second";third.name="public third";orderBase.rules += [second,third]
    orderBase.scrollProfiles=[ScrollDeviceProfile(),ScrollDeviceProfile()]
    var h1=HIDDeviceProfile(),h2=HIDDeviceProfile();h1.deviceID="public-1";h2.deviceID="public-2";orderBase.hidProfiles=[h1,h2]
    orderBase.scriptLibrary=[InputScript(),InputScript()]
    var orderRemote=orderBase;orderRemote.rules.swapAt(0,1);orderRemote.scrollProfiles.reverse();orderRemote.hidProfiles.reverse();orderRemote.scriptLibrary.reverse()
    let orderRoot=InputCloudRevision(deviceID:deviceA,parents:[],configuration:orderBase),orderRootID=try orderRoot.digest
    let reordered=InputCloudRevision(deviceID:deviceB,parents:[orderRootID],configuration:orderRemote),reorderedID=try reordered.digest
    let orderState=try JSONDecoder().decode(InputCloudSync.State.self,from:JSONEncoder().encode(InputCloudSync.State(appliedHeads:[orderRootID],base:orderBase)))
    let forwardedOrder=try InputCloudMerge.plan(revisions:[orderRootID:orderRoot,reorderedID:reordered],local:orderBase,appliedHeads:orderState.appliedHeads)
    try check(forwardedOrder.conflicts.isEmpty && forwardedOrder.value==orderRemote,"Remote-only rule/scroll/HID/script reordering was silently ignored")
    var orderB=orderRemote,orderC=orderBase,newB=EnhancedInputRule(),newC=EnhancedInputRule()
    orderC.rules.swapAt(1,2);newB.name="public ordered B addition";newC.name="public ordered C addition"
    orderB.rules[0].name="unrelated B content edit";orderC.rules[1].name="unrelated C content edit"
    orderB.rules.append(newB);orderC.rules.append(newC)
    // Other collection order changes occur only in B and remain unopposed.
    let ob=InputCloudRevision(deviceID:deviceA,parents:[orderRootID],configuration:orderB),oc=InputCloudRevision(deviceID:deviceB,parents:[orderRootID],configuration:orderC)
    let obID=try ob.digest,ocID=try oc.digest,orderBranches=[orderRootID:orderRoot,obID:ob,ocID:oc]
    let orderPlan=try InputCloudMerge.plan(revisions:orderBranches,local:orderBase,appliedHeads:orderState.appliedHeads)
    try check(orderPlan.conflicts==["rules/@order"],"Different concurrent orders were not an explicit order conflict")
    let oldIDs=Set(orderBase.rules.map(\.id))
    for (choice,expected) in [(InputCloudMerge.Choice.local,orderBase),(.remote(obID),orderB),(.remote(ocID),orderC)] {
        let selected=try InputCloudMerge.resolvedValue(orderPlan,choice:choice,local:orderBase,revisions:orderBranches)
        try check(selected.rules.filter{oldIDs.contains($0.id)}.map(\.id)==expected.rules.filter{oldIDs.contains($0.id)}.map(\.id),"Explicit local/B/C order choice ignored the chosen order")
        try check(selected.rules.contains(newB) && selected.rules.contains(newC),"Explicit order choice dropped an independent addition")
        try check(selected.rules.first{$0.id==second.id}?.name=="unrelated B content edit" && selected.rules.first{$0.id==third.id}?.name=="unrelated C content edit","Order choice reset unrelated item edits")
    }
    let appendedAB=try InputCloudMerge.merge(base:base,local:{var v=base;v.rules.append(addedB);return v}(),remote:{var v=base;v.rules.append(addedC);return v}())
    let appendedBA=try InputCloudMerge.merge(base:base,local:{var v=base;v.rules.append(addedC);return v}(),remote:{var v=base;v.rules.append(addedB);return v}())
    try check(appendedAB.conflicts.isEmpty && appendedAB.value==appendedBA.value,"Independent append order did not converge deterministically")
    var deleteBase=base,deleteLocal=base,modifyRemote=base
    deleteBase.rules.append(second);deleteLocal=deleteBase;modifyRemote=deleteBase
    deleteLocal.rules.removeFirst();modifyRemote.rules[0].name="restore original first position"
    let deleteConflict=try InputCloudMerge.merge(base:deleteBase,local:deleteLocal,remote:modifyRemote)
    let restoredPosition=InputCloudMerge.applyingConflictValues(deleteConflict.conflicts,from:modifyRemote,to:deleteConflict.value)
    try check(restoredPosition.rules.map(\.id)==deleteBase.rules.map(\.id) && restoredPosition.rules[0].name=="restore original first position","Choosing a deleted remote rule silently appended it and changed priority")
    print("Automatic cloud revision/merge targeted checks passed (\(checks)); offline branches, conflicts, deletion, ancestry, duplicates and private access. This unit test is not live iCloud transport proof.")
}
