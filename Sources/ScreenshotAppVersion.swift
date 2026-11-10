import Foundation

enum ScreenshotAppVersion {
    static var version:String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版" }
    static var build:String { Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "未打包" }
}
