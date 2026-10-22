import Foundation
import CryptoKit

/// Append-only revisions prevent an offline writer from overwriting an unseen
/// remote edit. Timestamps are descriptive; ancestry determines ordering.
struct InputCloudRevision:Codable,Equatable {
    var schema=1
    var revisionID=UUID()
    var deviceID:UUID
    var parents:[String]
    var configuration:InputEnhancementConfiguration
    var encoded:Data {get throws {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(self)}}
    var digest:String {get throws {SHA256.hash(data:try encoded).map{String(format:"%02x",$0)}.joined()}}
    static func merged(parents:[String],configuration:InputEnhancementConfiguration)throws->Self {
        let zero=UUID(uuidString:"00000000-0000-0000-0000-000000000000")!
        var value=Self(revisionID:zero,deviceID:zero,parents:parents.sorted(),configuration:configuration.cloudPayload)
        let hash=try value.digest
        let bytes=Array(hash.prefix(32))
        let uuid=String(bytes[0..<8])+"-"+String(bytes[8..<12])+"-"+String(bytes[12..<16])+"-"+String(bytes[16..<20])+"-"+String(bytes[20..<32])
        value.revisionID=UUID(uuidString:uuid)!;return value
    }
}

extension InputEnhancementConfiguration {
    var cloudPayload:Self {
        var value=self
        value.syncFolder="";value.iCloudSyncEnabled=false;value.iCloudSyncFolder="";value.iCloudSyncBookmark=nil
        value.cloudPendingScriptRules=[];value.cloudPendingHIDMappings=[];value.cloudPendingHIDProfiles=[]
        // Import provenance and private experimental activation remain local.
        value.migrationSources=[];value.experimentalRawTouch=false
        for index in value.rules.indices {value.rules[index].migrationOrigin=nil}
        return value
    }
    func retainingLocalCloudAccess(from local:Self)->Self {
        var value=self
        value.syncFolder=local.syncFolder;value.iCloudSyncEnabled=local.iCloudSyncEnabled
        value.iCloudSyncFolder=local.iCloudSyncFolder;value.iCloudSyncBookmark=local.iCloudSyncBookmark
        value.migrationSources=local.migrationSources;value.experimentalRawTouch=local.experimentalRawTouch
        value.cloudPendingScriptRules=local.cloudPendingScriptRules;value.cloudPendingHIDMappings=local.cloudPendingHIDMappings
        value.cloudPendingHIDProfiles=local.cloudPendingHIDProfiles
        // A portable rule omits the private import archive. Keep the existing
        // local provenance when its execution semantics are unchanged.
        for index in value.rules.indices {
            guard let previous=local.rules.first(where:{$0.id==value.rules[index].id}),previous.migrationOrigin != nil else {continue}
            var before=previous,after=value.rules[index]
            before.name="";after.name="";before.enabled=false;after.enabled=false
            before.migrationOrigin=nil;after.migrationOrigin=nil
            if before==after {value.rules[index].migrationOrigin=previous.migrationOrigin}
        }
        return value
    }
}

enum InputCloudMerge {
    enum Choice {case local,remote(String)}
    enum GraphFailure:Error {case ambiguousBase}
    struct Result {var value:InputEnhancementConfiguration;var conflicts:[String]}
    struct Plan {var heads:[String];var value:InputEnhancementConfiguration;var conflicts:[String]}
    static func resolvedValue(_ plan:Plan,choice:Choice,local:InputEnhancementConfiguration,revisions:[String:InputCloudRevision])throws->InputEnhancementConfiguration {
        let selected:InputEnhancementConfiguration
        switch choice {
        case .local:selected=local
        case .remote(let id):
            guard plan.heads.contains(id),let revision=revisions[id] else {throw DataFailure.message("iCloud 冲突版本已变化，请重新复核后选择。")}
            selected=revision.configuration
        }
        return applyingConflictValues(plan.conflicts,from:selected,to:plan.value)
    }
    /// The same decision path is used by the live controller and restart tests.
    static func plan(revisions:[String:InputCloudRevision],local:InputEnhancementConfiguration,appliedHeads:[String]) throws -> Plan {
        let frontier=try heads(revisions)
        let base:InputEnhancementConfiguration
        do {base=try commonBase(heads:Array(Set(frontier+appliedHeads)).sorted(),revisions:revisions)}
        catch GraphFailure.ambiguousBase {return Plan(heads:frontier,value:local.cloudPayload,conflicts:["configuration"])}
        var value=local.cloudPayload,conflicts:Set<String>=[]
        for id in frontier {
            let result=try merge(base:base,local:value,remote:revisions[id]!.configuration)
            value=result.value;conflicts.formUnion(result.conflicts)
        }
        return Plan(heads:frontier,value:value,conflicts:conflicts.sorted())
    }
    static func applyingConflictValues(_ paths:[String],from chosen:InputEnhancementConfiguration,to candidate:InputEnhancementConfiguration)->InputEnhancementConfiguration {
        var value=candidate
        if paths.contains("configuration") {return chosen.cloudPayload}
        func replace<T:Identifiable>(_ id:UUID,_ source:[T],_ target:inout [T]) where T.ID==UUID {
            let originalIndex=target.firstIndex{$0.id==id};target.removeAll{$0.id==id}
            guard let sourceIndex=source.firstIndex(where:{$0.id==id}) else {return}
            let position:Int
            if let originalIndex {position=min(originalIndex,target.count)}
            else if let next=source.dropFirst(sourceIndex+1).first(where:{item in target.contains{$0.id==item.id}}),let nextIndex=target.firstIndex(where:{$0.id==next.id}) {position=nextIndex}
            else if let previous=source.prefix(sourceIndex).reversed().first(where:{item in target.contains{$0.id==item.id}}),let previousIndex=target.firstIndex(where:{$0.id==previous.id}) {position=previousIndex+1}
            else {position=target.count}
            target.insert(source[sourceIndex],at:position)
        }
        for path in paths {
            if path=="enabled" {value.enabled=chosen.enabled;continue}
            let parts=path.split(separator:"/");guard parts.count==2,let id=UUID(uuidString:String(parts[1])) else {continue}
            switch parts[0] {
            case "rules":replace(id,chosen.rules,&value.rules)
            case "scrollProfiles":replace(id,chosen.scrollProfiles,&value.scrollProfiles)
            case "hidProfiles":replace(id,chosen.hidProfiles,&value.hidProfiles)
            case "scriptLibrary":replace(id,chosen.scriptLibrary,&value.scriptLibrary)
            default:break
            }
        }
        // Item choices settle membership first. An explicit order choice then
        // restores the selected side's relative order without losing new items.
        func reorder<T:Identifiable>(_ target:inout[T],preferred:[T]) where T.ID==UUID {
            let byID=Dictionary(uniqueKeysWithValues:target.map{($0.id,$0)})
            let selected=preferred.map(\.id).filter{byID[$0] != nil},seen=Set(preferred.map(\.id))
            target=(selected+target.map(\.id).filter{!seen.contains($0)}).compactMap{byID[$0]}
        }
        for path in paths {
            switch path {
            case "rules/@order":reorder(&value.rules,preferred:chosen.rules)
            case "scrollProfiles/@order":reorder(&value.scrollProfiles,preferred:chosen.scrollProfiles)
            case "hidProfiles/@order":reorder(&value.hidProfiles,preferred:chosen.hidProfiles)
            case "scriptLibrary/@order":reorder(&value.scriptLibrary,preferred:chosen.scriptLibrary)
            default:break
            }
        }
        return value
    }
    static func merge(base:InputEnhancementConfiguration,local:InputEnhancementConfiguration,remote:InputEnhancementConfiguration) throws -> Result {
        func unique<T:Identifiable>(_ values:[T]) throws {
            guard Set(values.map(\.id)).count==values.count else {throw DataFailure.message("iCloud 同步记录有重复 ID，未覆盖本机内容。")}
        }
        for value in [base,local,remote] {
            try unique(value.rules);try unique(value.scrollProfiles);try unique(value.hidProfiles);try unique(value.scriptLibrary)
            try EnhancedInputValidation.validate(value)
        }
        var result=local.cloudPayload,conflicts:[String]=[]
        func scalar<T:Equatable>(_ key:String,_ base:T,_ local:T,_ remote:T)->T {
            if local==remote || remote==base {return local}
            if local==base {return remote}
            conflicts.append(key);return local
        }
        func collection<T:Equatable & Identifiable>(_ key:String,_ base:[T],_ local:[T],_ remote:[T])->[T] where T.ID==UUID {
            let b=Dictionary(uniqueKeysWithValues:base.map{($0.id,$0)})
            let l=Dictionary(uniqueKeysWithValues:local.map{($0.id,$0)})
            let r=Dictionary(uniqueKeysWithValues:remote.map{($0.id,$0)})
            let union=local.map(\.id)+remote.map(\.id).filter{l[$0]==nil}+base.map(\.id).filter{l[$0]==nil && r[$0]==nil}
            var seen:Set<UUID>=[]
            let items=union.filter{seen.insert($0).inserted}.compactMap {id in scalar(key+"/"+id.uuidString,b[id],l[id],r[id])}
            let order=mergeOrder(base:base.map(\.id),local:local.map(\.id),remote:remote.map(\.id),retained:Set(items.map(\.id)))
            if order.conflicted {conflicts.append(key+"/@order")}
            let byID=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0)})
            return order.ids.compactMap{byID[$0]}
        }
        result.enabled=scalar("enabled",base.enabled,local.enabled,remote.enabled)
        result.rules=collection("rules",base.rules,local.rules,remote.rules)
        result.scrollProfiles=collection("scrollProfiles",base.scrollProfiles,local.scrollProfiles,remote.scrollProfiles)
        result.hidProfiles=collection("hidProfiles",base.hidProfiles,local.hidProfiles,remote.hidProfiles)
        result.scriptLibrary=collection("scriptLibrary",base.scriptLibrary,local.scriptLibrary,remote.scriptLibrary)
        return Result(value:result,conflicts:conflicts.sorted())
    }
    private static func mergeOrder(base:[UUID],local:[UUID],remote:[UUID],retained:Set<UUID>)->(ids:[UUID],conflicted:Bool) {
        let common=Set(base).intersection(local).intersection(remote).intersection(retained)
        let baseline=base.filter{common.contains($0)},left=local.filter{common.contains($0)},right=remote.filter{common.contains($0)}
        let leftChanged=left != baseline,rightChanged=right != baseline
        func fallback()->[UUID] {var seen:Set<UUID>=[];return (local+remote+base).filter{retained.contains($0) && seen.insert($0).inserted}}
        if leftChanged && rightChanged && left != right {return (fallback(),true)}
        var following:[UUID:Set<UUID>]=[:],incoming=Dictionary(uniqueKeysWithValues:retained.map{($0,0)})
        func add(_ values:[UUID],ignoreUnchangedBase:Bool) {
            let values=values.filter{retained.contains($0)}
            for (before,after) in zip(values,values.dropFirst()) {
                if ignoreUnchangedBase && common.contains(before) && common.contains(after) {continue}
                if following[before,default:[]].insert(after).inserted {incoming[after,default:0] += 1}
            }
        }
        add(local,ignoreUnchangedBase:rightChanged && !leftChanged)
        add(remote,ignoreUnchangedBase:leftChanged && !rightChanged)
        var ready=incoming.keys.filter{incoming[$0]==0}.sorted{$0.uuidString<$1.uuidString},ordered:[UUID]=[]
        while !ready.isEmpty {
            let id=ready.removeFirst();ordered.append(id)
            for next in following[id] ?? [] {incoming[next]! -= 1;if incoming[next]==0 {ready.append(next)}}
            ready.sort{$0.uuidString<$1.uuidString}
        }
        return ordered.count==retained.count ? (ordered,false):(fallback(),true)
    }
    static func heads(_ revisions:[String:InputCloudRevision]) throws -> [String] {
        let parentSet=Set(revisions.values.flatMap(\.parents))
        guard parentSet.isSubset(of:Set(revisions.keys)) else {throw DataFailure.message("iCloud 同步版本尚未下载完整；保留本机内容，稍后自动重试。")}
        var visited:Set<String>=[],visiting:Set<String>=[]
        func visit(_ id:String) throws {
            if visited.contains(id) {return}
            guard visiting.count<512,visiting.insert(id).inserted else {throw DataFailure.message("iCloud 同步版本链无效，原版本已保留。")}
            for parent in revisions[id]!.parents {try visit(parent)}
            visiting.remove(id);visited.insert(id)
        }
        for id in revisions.keys {try visit(id)}
        let result=revisions.keys.filter{!parentSet.contains($0)}.sorted()
        guard revisions.isEmpty || !result.isEmpty else {throw DataFailure.message("iCloud 同步版本链无效，原版本已保留。")}
        return result
    }
    static func commonBase(heads:[String],revisions:[String:InputCloudRevision]) throws -> InputEnhancementConfiguration {
        guard !heads.isEmpty else {return InputEnhancementConfiguration()}
        var depthCache:[String:Int]=[:]
        func depth(_ id:String,_ visiting:Set<String>) throws -> Int {
            if let cached=depthCache[id] {return cached}
            guard let revision=revisions[id],!visiting.contains(id),visiting.count<=512 else {throw DataFailure.message("iCloud 同步版本链无效，原版本已保留。")}
            var path=visiting;path.insert(id)
            let value=try revision.parents.map{try depth($0,path)}.max().map{$0+1} ?? 0
            depthCache[id]=value;return value
        }
        func ancestors(_ start:String) throws -> Set<String> {
            var found:Set<String>=[],pending=[start]
            while let id=pending.popLast() {
                guard let revision=revisions[id] else {throw DataFailure.message("iCloud 同步版本尚未下载完整；保留本机内容，稍后自动重试。")}
                if found.insert(id).inserted {pending += revision.parents}
                guard found.count<=4096 else {throw DataFailure.message("iCloud 同步版本超过保护预算；历史版本已保留。")}
            }
            return found
        }
        var common=try ancestors(heads[0])
        for head in heads.dropFirst() {common.formIntersection(try ancestors(head))}
        guard !common.isEmpty else {return InputEnhancementConfiguration()}
        let ranked=try common.map{($0,try depth($0,[]))}.sorted{$0.1>$1.1}
        guard let best=ranked.first else {return InputEnhancementConfiguration()}
        let peers=ranked.filter{$0.1==best.1}.map{revisions[$0.0]!.configuration}
        if peers.count>1,!peers.allSatisfy({$0==peers[0]}) {throw GraphFailure.ambiguousBase}
        return revisions[best.0]!.configuration
    }
}
