import Foundation
import Security

@objc(GaoQuickLookArchiveBrokerProtocol)
protocol GaoQuickLookArchiveBrokerProtocol {
    func execute(_ payload:Data,reply:@escaping(Data)->Void)
    func cancel(_ requestID:String,reply:@escaping()->Void)
}
struct QuickLookArchiveBrokerEnvelope:Codable {
    var request:QuickLookArchiveEditRequest
    var archiveBookmark:Data
    var directoryBookmark:Data?
    var addingBookmarks:[Data]
}
enum QuickLookArchiveBrokerIdentity {
    static let serviceName="com.gaoseries.GaoCaoZuo.QuickLook.ArchiveBroker"
    static func requirement(for bundle:URL)throws->String {
        var code:SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL,[],&code)==errSecSuccess,let code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),nil)==errSecSuccess else {throw CocoaError(.fileReadNoPermission)}
        var info:CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              let hash=(info as? [String:Any])?[kSecCodeInfoUnique as String] as? Data,!hash.isEmpty else {throw CocoaError(.fileReadNoPermission)}
        return "cdhash H\""+hash.map{String(format:"%02x",$0)}.joined()+"\""
    }
    static func verify(pid:pid_t,requirement:String)throws {
        var pin:SecRequirement?,guest:SecCode?
        guard SecRequirementCreateWithString(requirement as CFString,[],&pin)==errSecSuccess,let pin,
              SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&guest)==errSecSuccess,let guest,
              SecCodeCheckValidity(guest,[],pin)==errSecSuccess else {throw CocoaError(.fileReadNoPermission)}
    }
}
