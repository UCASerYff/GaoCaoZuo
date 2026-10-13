import Foundation
import CryptoKit
import CoreFoundation

enum InputMigrationDisposition:String,Codable,Equatable {
    case exact,requiresReview,unavailable,preservedUserChange
}
struct InputRuleMigrationOrigin:Codable,Equatable {
    var sourceDigest:String
    var rowID:UUID
    var sourceEnabled:Bool?
    var disposition:InputMigrationDisposition
    var requirements:[String]
    var reason:String
    var verifiedRequirements:[String] = []
}
struct InputMigrationRow:Codable,Equatable,Identifiable {
    var id:UUID
    var module:String
    var groupIndex:Int
    var rowIndex:Int
    var sourceEnabled:Bool?
    var disposition:InputMigrationDisposition
    var requirements:[String]
    var reason:String
    var mappedRuleID:UUID?
    var unknownKeys:[String]
}
/// Only the explicitly selected operational preference keys are included. Account,
/// licence, analytics and OS-global preferences stay in the separate safety backup.
struct InputMigrationSource:Codable,Equatable,Identifiable {
    var id:String {sha256}
    var schema=1
    var sha256:String
    var operationalPlist:Data
    var originalBytesPreserved:Bool
    var rows:[InputMigrationRow]
    var retainedKeys:[String]
    var omittedKeyCount:Int
    var note:String
    func verify()throws {
        guard schema==1,operationalPlist.count<=8*1024*1024,
              sha256==InputMigrationFingerprint.digest(operationalPlist),rows.count<=1000,
              Set(rows.map(\.id)).count==rows.count else {throw SystemControlError.message("输入迁移档案摘要、版本或条目无效。")}
        guard let dictionary=try PropertyListSerialization.propertyList(from:operationalPlist,format:nil) as? [String:Any],
              BABRuleImporter.operationalSnapshot(dictionary).count==dictionary.count else {throw SystemControlError.message("输入迁移档案包含非操作字段或无效格式。")}
    }
    func semanticDigest()throws->String {
        let dictionary=try PropertyListSerialization.propertyList(from:operationalPlist,format:nil)
        return InputMigrationFingerprint.digest(try InputMigrationFingerprint.canonical(dictionary))
    }
}
struct EnhancedRuleMergeResult {
    var configuration:InputEnhancementConfiguration
    var added:Int
    var upgraded:Int
    var preserved:Int
    var blocked:Int
    var note:String
}
enum InputMigrationFingerprint {
    static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func uuid(_ data:Data)->UUID {
        var b=Array(SHA256.hash(data:data).prefix(16));b[6]=(b[6]&0x0f)|0x50;b[8]=(b[8]&0x3f)|0x80
        return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    /// Typed canonical encoding preserves Data/Date/Bool versus numbers and sorts
    /// dictionary keys. No archived object is ever instantiated.
    static func canonical(_ value:Any)throws->Data {
        var out=Data();var entries=0
        func append(_ value:Any,_ depth:Int)throws {
            entries+=1;guard depth<=32,entries<=65536 else {throw SystemControlError.message("输入迁移结构超过读取预算。")}
            func blob(_ type:UInt8,_ data:Data) {out.append(type);var n=UInt64(data.count).bigEndian;withUnsafeBytes(of:&n){out.append(contentsOf:$0)};out.append(data)}
            if let d=value as? Data {blob(1,d)}
            else if let s=value as? String {blob(2,Data(s.utf8))}
            else if let d=value as? Date {var bits=d.timeIntervalSinceReferenceDate.bitPattern.bigEndian;blob(3,withUnsafeBytes(of:&bits){Data($0)})}
            else if let n=value as? NSNumber {
                if CFGetTypeID(n)==CFBooleanGetTypeID() {out.append(n.boolValue ? 4:5)}
                else {let type=String(cString:n.objCType);blob(6,Data((["f","d"].contains(type) ? "real":"integer").utf8));blob(7,Data(n.stringValue.utf8))}
            } else if let a=value as? [Any] {out.append(8);for v in a {try append(v,depth+1)};out.append(9)}
            else if let d=value as? [String:Any] {out.append(10);for k in d.keys.sorted(){try append(k,depth+1);try append(d[k]!,depth+1)};out.append(11)}
            else {throw SystemControlError.message("输入迁移包含不支持的属性列表类型。")}
            guard out.count<=16*1024*1024 else {throw SystemControlError.message("输入迁移结构超过读取预算。")}
        }
        try append(value,0);return out
    }
    static func legacyRule(_ rule:EnhancedInputRule,ignoringEnabled:Bool=false)throws->Data {
        var value=rule;value.id=UUID(uuidString:"00000000-0000-0000-0000-000000000000")!;value.migrationOrigin=nil
        if ignoringEnabled {value.enabled=false}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(value)
    }
}
