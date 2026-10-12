import AppKit
import SwiftUI

@MainActor struct HIDDeviceConfigurationView:View {
    @Binding var profiles:[HIDDeviceProfile]
    let actions:[InputActionChoice]
    @StateObject private var monitor=HIDInputDevices()
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(monitor.status).font(.caption)
            HStack {Button("开始识别和按钮录制"){monitor.start()};Button("停止录制"){monitor.stop()}}
            if !monitor.lastButton.isEmpty {Text(monitor.lastButton).font(.caption.monospaced()).textSelection(.enabled)}
            ForEach(monitor.devices) {device in
                HStack {VStack(alignment:.leading){Text(device.name);Text("\(device.id) · 按钮Usage："+device.buttonUsages.map(String.init).joined(separator:",")).font(.caption.monospaced())};Spacer();Button("添加此设备配置"){var profile=HIDDeviceProfile();profile.name=device.name;profile.deviceID=device.id;profiles.append(profile)}}
            }
            Text("录制读取公开HID鼠标按钮报告，不读取键盘文字；原始按钮保持不变。设备未连接、按钮报告未提供或权限被拒绝时，规则不会回退至其他鼠标。无位置ID的设备断接后须重新绑定。").font(.caption).foregroundStyle(.secondary)
            ForEach($profiles) { $profile in
                DisclosureGroup {
                    TextField("配置名称",text:$profile.name)
                    Text(profile.deviceID).font(.caption.monospaced())
                    if !monitor.devices.contains(where:{$0.id==profile.deviceID}) {Text("录制列表未发现此设备；实际监听时仍按完整设备ID匹配。").font(.caption).foregroundStyle(.secondary)}
                    ForEach($profile.buttons) { $button in
                        VStack(alignment:.leading) {
                            Toggle(button.name,isOn:$button.enabled)
                            HStack {TextField("按钮名称",text:$button.name);Stepper("Usage：\(button.usage)",value:$button.usage,in:1...32)}
                            Toggle("松开时触发",isOn:$button.whenReleased)
                            TextField("限定应用Bundle ID",text:$button.appBundleID)
                            TextField("排除应用Bundle ID（逗号分隔）",text:Binding(get:{button.excludedApps.joined(separator:",")},set:{button.excludedApps=$0.split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)}}))
                            Picker("动作",selection:$button.effect.actionID){ForEach(actions){Text($0.title).tag($0.id)}}
                            Button("删除按钮映射",role:.destructive){profile.buttons.removeAll{$0.id==button.id}}
                        }
                    }
                    Button("添加录制按钮映射"){profile.buttons.append(HIDButtonMapping())}
                    Toggle("保留逐设备跟踪调校意向",isOn:$profile.requestsTrackingAdjustment)
                    if profile.requestsTrackingAdjustment {
                        LabeledContent("请求速度（暂未应用）"){Slider(value:$profile.trackingSpeed,in:0.1...8);Text(profile.trackingSpeed,format:.number.precision(.fractionLength(2)))}
                        LabeledContent("请求加速度（暂未应用）"){Slider(value:$profile.trackingAcceleration,in:0...3);Text(profile.trackingAcceleration,format:.number.precision(.fractionLength(2)))}
                        Text("当前公开用户态接口未提供可靠的逐设备跟踪控制，以上值仅保留在配置中，不会修改系统全局鼠标设置。需要此功能时仍需原驱动或原应用。").font(.caption).foregroundStyle(.orange)
                    }
                    Button("删除设备配置",role:.destructive){profiles.removeAll{$0.id==profile.id}}
                } label:{Toggle(profile.name,isOn:$profile.enabled)}
            }
        }.onDisappear {monitor.stop()}
    }
}
