import AppKit
import ApplicationServices
import Carbon
import CoreWLAN

enum EnhancedSystemPreset:String,Codable,CaseIterable,Identifiable {
    case volumeUp,volumeDown,mute,playPause,nextTrack,previousTrack
    case brightnessUp,brightnessDown,keyboardBrightnessUp,keyboardBrightnessDown
    case missionControl,applicationWindows,showDesktop,spaceLeft,spaceRight,screenSaver
    case wifiOn,wifiOff,wifiToggle
    var id:String {rawValue}
    var title:String {switch self {
    case .wifiOn:return "开启 Wi-Fi";case .wifiOff:return "关闭 Wi-Fi";case .wifiToggle:return "切换 Wi-Fi"
    case .volumeUp:return "音量增加";case .volumeDown:return "音量减小";case .mute:return "静音切换"
    case .playPause:return "播放/暂停";case .nextTrack:return "下一曲";case .previousTrack:return "上一曲"
    case .brightnessUp:return "显示器亮度增加";case .brightnessDown:return "显示器亮度减小"
    case .keyboardBrightnessUp:return "键盘背光增加";case .keyboardBrightnessDown:return "键盘背光减小"
    case .missionControl:return "调度中心";case .applicationWindows:return "应用窗口总览";case .showDesktop:return "显示桌面"
    case .spaceLeft:return "左侧桌面空间";case .spaceRight:return "右侧桌面空间";case .screenSaver:return "启动屏幕保护程序"
    }}
    var mediaKey:Int? {switch self {
    case .volumeUp:return 0;case .volumeDown:return 1;case .brightnessUp:return 2;case .brightnessDown:return 3;case .mute:return 7
    case .playPause:return 16;case .nextTrack:return 17;case .previousTrack:return 18
    case .keyboardBrightnessUp:return 21;case .keyboardBrightnessDown:return 22
    default:return nil
    }}
    var symbolicHotKey:String? {switch self {
    case .missionControl:return "32";case .applicationWindows:return "33";case .showDesktop:return "36";case .spaceLeft:return "79";case .spaceRight:return "81";default:return nil
    }}
}
@MainActor enum EnhancedSystemControls {
    static func perform(_ preset:EnhancedSystemPreset)throws {
        if [.wifiOn,.wifiOff,.wifiToggle].contains(preset) {
            guard let interface=CWWiFiClient.shared().interface() else {throw SystemControlError.message("系统没有可用的 Wi-Fi 接口。") }
            let desired=preset == .wifiToggle ? !interface.powerOn():preset == .wifiOn
            do {try interface.setPower(desired)} catch {throw SystemControlError.message("系统未允许修改 Wi-Fi 电源状态："+error.localizedDescription)}
            guard interface.powerOn()==desired else {throw SystemControlError.message("系统未确认 Wi-Fi 电源状态已改变。")};return
        }
        if preset == .screenSaver {
            let url=URL(fileURLWithPath:"/System/Library/CoreServices/ScreenSaverEngine.app")
            guard FileManager.default.fileExists(atPath:url.path),NSWorkspace.shared.open(url) else {throw SystemControlError.message("系统未提供可启动的屏保引擎。")};return
        }
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled() else {throw SystemControlError.message("系统输入控制需要辅助功能权限，且不能在安全输入状态使用。")}
        if let code=preset.mediaKey {
            for down in [true,false] {
                guard let event=NSEvent.otherEvent(with:.systemDefined,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,subtype:8,data1:(code<<16)|(down ? 0xa00:0xb00),data2:-1)?.cgEvent else {throw SystemControlError.message("无法创建媒体控制事件。")}
                event.setIntegerValueField(.eventSourceUserData,value:EnhancedInputEngine.syntheticTag);event.post(tap:.cghidEventTap)
            }
            return
        }
        if let identifier=preset.symbolicHotKey {
            guard let hotkeys=CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,"com.apple.symbolichotkeys" as CFString) as? [String:Any],let row=hotkeys[identifier] as? [String:Any],let enabled=row["enabled"] as? Bool,enabled,let value=row["value"] as? [String:Any],let parameters=value["parameters"] as? [NSNumber],parameters.count>=3 else {throw SystemControlError.message("请先在系统设置 → 键盘 → 键盘快捷键中启用“\(preset.title)”。搞操作会使用你的实际系统绑定。")}
            let key=parameters[1].uint16Value,flags=parameters[2].uint64Value
            guard key<=127 else {throw SystemControlError.message("系统绑定不是可模拟的键盘快捷键。")}
            for down in [true,false] {
                guard let event=CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:down) else {throw SystemControlError.message("无法创建系统快捷键事件。")}
                event.flags=CGEventFlags(rawValue:flags);event.setIntegerValueField(.eventSourceUserData,value:EnhancedInputEngine.syntheticTag);event.post(tap:.cghidEventTap)
            }
            return
        }
        throw SystemControlError.message("不支持的系统动作。")
    }
}
