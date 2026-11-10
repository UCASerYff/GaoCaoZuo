import AppKit
import AVFoundation
import Security

struct ScreenshotPermissionSnapshot:Codable {
    var schemaVersion=1
    var checkedAtUTC:String
    var bundleID:String
    var version:String
    var build:String
    var codeDirectoryHash:String?
    var sourceCommit:String?
    var screenCaptureGranted:Bool
    var microphone:String
    var scrollingAccessibilityGranted:Bool
    var capturePerformed=false
}

enum ScreenshotPermissionService {
    static var screenGranted:Bool{CGPreflightScreenCaptureAccess()}
    static var microphoneStatus:AVAuthorizationStatus{AVCaptureDevice.authorizationStatus(for:.audio)}
    static var scrollingGranted:Bool{AXIsProcessTrusted()}
    @MainActor static func requestScreen()->Bool{CGRequestScreenCaptureAccess()}
    static func requestMicrophone() async -> Bool{await AVCaptureDevice.requestAccess(for:.audio)}
    @MainActor static func requestScrolling()->Bool{AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)}
    static func snapshot()->ScreenshotPermissionSnapshot {
        var ownCode:SecCode?;var staticCode:SecStaticCode?;var information:CFDictionary?;var codeHash:String?
        if SecCodeCopySelf(SecCSFlags(),&ownCode)==errSecSuccess,let ownCode,
           SecCodeCopyStaticCode(ownCode,SecCSFlags(),&staticCode)==errSecSuccess,let staticCode,
           SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&information)==errSecSuccess,
           let dictionary=information as? [String:Any],let data=dictionary[kSecCodeInfoUnique as String] as? Data {
            codeHash=data.map{String(format:"%02x",$0)}.joined()
        }
        let mic:String
        switch microphoneStatus{case .authorized:mic="authorized";case .denied:mic="denied";case .restricted:mic="restricted";case .notDetermined:mic="notDetermined";@unknown default:mic="unknown"}
        var commit:String?
        if let url=Bundle.main.url(forResource:"BuildInfo",withExtension:"json"),let data=try? Data(contentsOf:url),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{commit=value["sourceCommit"] as? String}
        return ScreenshotPermissionSnapshot(checkedAtUTC:ISO8601DateFormatter().string(from:Date()),bundleID:Bundle.main.bundleIdentifier ?? "unknown",version:ScreenshotAppVersion.version,build:ScreenshotAppVersion.build,codeDirectoryHash:codeHash,sourceCommit:commit,screenCaptureGranted:screenGranted,microphone:mic,scrollingAccessibilityGranted:scrollingGranted)
    }
}
