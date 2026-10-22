import Foundation
import Security

@objc(GaoQuickLookSandboxProbeProtocol)
protocol GaoQuickLookSandboxProbeProtocol {
    func inspect(_ bookmark:Data,clientBundle:Data,reply:@escaping(Data)->Void)
}

enum GaoQuickLookProbeIdentity {
    static let serviceName="com.gaoseries.GaoCaoZuo.QuickLookHelperProbe.SandboxProbe"
    static let clientIdentifier="com.gaoseries.GaoCaoZuo.QuickLookHelperProbe"
    static func verifyPeer(pid:pid_t,bundle:URL)throws {
        let pinned=try requirement(for:bundle)
        var requirement:SecRequirement?,guest:SecCode?
        guard SecRequirementCreateWithString(pinned as CFString,[],&requirement)==errSecSuccess,let requirement,
              SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&guest)==errSecSuccess,let guest,
              SecCodeCheckValidity(guest,[],requirement)==errSecSuccess else {throw CocoaError(.fileReadNoPermission)}
    }
    static func requirement(for bundle:URL)throws->String {
        var code:SecStaticCode?
        let flags=SecCSFlags(rawValue:kSecCSStrictValidate)
        let created=SecStaticCodeCreateWithPath(bundle as CFURL,[],&code)
        guard created==errSecSuccess,let code else {throw NSError(domain:"GaoQuickLookProbeSignature.Create",code:Int(created),userInfo:[NSFilePathErrorKey:bundle.path])}
        let checked=SecStaticCodeCheckValidity(code,flags,nil)
        guard checked==errSecSuccess else {throw NSError(domain:"GaoQuickLookProbeSignature.Validate",code:Int(checked),userInfo:[NSFilePathErrorKey:bundle.path])}
        var info:CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              let hash=(info as? [String:Any])?[kSecCodeInfoUnique as String] as? Data,!hash.isEmpty else {throw CocoaError(.fileReadCorruptFile)}
        return "cdhash H\""+hash.map{String(format:"%02x",$0)}.joined()+"\""
    }
}
