import AppKit
import SwiftUI

@MainActor struct HIDDeviceConfigurationView:View {
    @Binding var profiles:[HIDDeviceProfile]
    let actions:[InputActionChoice]
    @StateObject private var monitor=HIDInputDevices()
    @State private var trackingInspector=HIDTrackingServiceBackend()
    @State private var trackingReadiness:[String:String]=[:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            recordingControls
            deviceList
            Text("录制读取公开HID鼠标按钮报告，不读取键盘文字；原始按钮保持不变。设备未连接、按钮报告未提供或权限被拒绝时，规则不会回退至其他鼠标。配置仅绑定当前系统启动中的该条实际接口；断接、接口更换或系统重启后须重新绑定。不会按 VID/PID 或复用端口接管。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($profiles) { (profile: Binding<HIDDeviceProfile>) in
                profileEditor(profile)
            }
        }
        .onAppear { monitor.start(recordButtons: false) }
        .onDisappear { monitor.stop() }
        .onReceive(monitor.$devices) { devices in refreshTrackingReadiness(devices) }
    }

    @ViewBuilder private var recordingControls: some View {
        Text(L10n.text(monitor.status)).font(.caption)
        HStack {
            Button("刷新设备识别") { monitor.start(recordButtons: false) }
            Button("开始按钮录制") { monitor.start() }
            Button("停止录制") { monitor.stop() }
        }
        if !monitor.lastButton.isEmpty {
            Text(monitor.lastButton).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    @ViewBuilder private var deviceList: some View {
        let matrix = InputDeviceMatrix.currentMatrix(devices: monitor.devices, monitoringAuthorized: CGPreflightListenEventAccess())
        ForEach(matrix) { entry in
            evidenceRow(entry)
        }
        if monitor.devices.isEmpty {
            Text("尚未识别到接口；不会假定内置触控板或外置鼠标已连接。刷新识别不代表硬件动作验收。").font(.caption)
        }
        ForEach(monitor.devices) { device in
            deviceRow(device)
        }
    }

    private func evidenceRow(_ entry: InputDeviceMatrix.Entry) -> some View {
        let identity = entry.identity
        let vendor = identity.vendorID == 0 ? L10n.text("未提供") : String(identity.vendorID)
        let product = identity.productID == 0 ? L10n.text("未提供") : String(identity.productID)
        let location = L10n.format(" / 位置 %@ · ", String(identity.locationID))
        let placement = L10n.text(identity.isBuiltIn ? "内置" : "外置/未知")
        let hardware = "VID \(vendor) / PID \(product)\(location)\(identity.transport) · \(placement)"
        let interface = L10n.format("接口 %@ · Usage ", String(identity.registryID))
        let usages = identity.usagePairs.joined(separator: ", ")
        return VStack(alignment: .leading) {
            Text(identity.productName + " · " + L10n.text(entry.verificationState))
            Text(hardware).font(.caption)
            Text(interface + usages).font(.caption.monospaced())
            Text(L10n.text(entry.capabilities.notes)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func deviceRow(_ device: HIDDeviceDescriptor) -> some View {
        if !device.interfacePath.isEmpty {
            Text(L10n.text("接口路径：") + device.interfacePath).font(.caption.monospaced()).textSelection(.enabled)
        }
        Text(L10n.text(device.bindingScope)).font(.caption).foregroundStyle(.secondary)
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                let usages = device.buttonUsages.map { String($0) }.joined(separator: ",")
                Text(L10n.format("%@ · 按钮Usage：", device.id) + usages).font(.caption.monospaced())
            }
            Spacer()
            Button("添加此设备配置") {
                var profile = HIDDeviceProfile()
                profile.name = device.name
                profile.deviceID = device.id
                profiles.append(profile)
            }
        }
    }

    private func profileEditor(_ profile: Binding<HIDDeviceProfile>) -> some View {
        let id = profile.wrappedValue.id
        return DisclosureGroup {
            connectionControls(profile)
            ForEach(profile.buttons) { (button: Binding<HIDButtonMapping>) in
                let buttonID = button.wrappedValue.id
                buttonEditor(button) {
                    profile.wrappedValue.buttons.removeAll { $0.id == buttonID }
                }
            }
            Button("添加录制按钮映射") {
                profile.wrappedValue.buttons.append(HIDButtonMapping())
            }
            trackingControls(profile)
            Button("删除设备配置", role: .destructive) {
                profiles.removeAll { $0.id == id }
            }
        } label: {
            Toggle(profile.wrappedValue.name, isOn: profile.enabled)
        }
    }

    @ViewBuilder private func connectionControls(_ profile: Binding<HIDDeviceProfile>) -> some View {
        let deviceID = profile.wrappedValue.deviceID
        TextField("配置名称", text: profile.name)
        Text(deviceID).font(.caption.monospaced())
        if !HIDConnectionIdentity.isConnectionScoped(deviceID) {
            Text("旧设备标识缺少接口连接身份，已保留但不执行；请从已识别设备重新添加配置。")
                .font(.caption).foregroundStyle(.orange)
        }
        Menu("重新绑定此配置到已识别接口") {
            ForEach(monitor.devices) { device in
                Button(device.name + " · " + String(device.registryID)) {
                    profile.wrappedValue.deviceID = device.id
                    profile.wrappedValue.enabled = false
                }
            }
        }.disabled(monitor.devices.isEmpty)
        if !monitor.devices.contains(where: { $0.id == deviceID }) {
            Text("录制列表未发现此设备；实际监听时仍按完整设备ID匹配。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func buttonEditor(_ button: Binding<HIDButtonMapping>, remove: @escaping () -> Void) -> some View {
        let excludedApps = Binding<String>(
            get: { button.wrappedValue.excludedApps.joined(separator: ",") },
            set: { text in
                button.wrappedValue.excludedApps = text.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
        )
        return VStack(alignment: .leading) {
            Toggle(button.wrappedValue.name, isOn: button.enabled)
            HStack {
                TextField("按钮名称", text: button.name)
                Stepper("Usage：\(button.wrappedValue.usage)", value: button.usage, in: 1...32)
            }
            Toggle("松开时触发", isOn: button.whenReleased)
            TextField("限定应用Bundle ID", text: button.appBundleID)
            TextField("排除应用Bundle ID（逗号分隔）", text: excludedApps)
            Picker("动作", selection: button.effect.actionID) {
                ForEach(actions) { action in
                    Text(L10n.text(action.title)).tag(action.id)
                }
            }
            Button("删除按钮映射", role: .destructive, action: remove)
        }
    }

    @ViewBuilder private func trackingControls(_ profile: Binding<HIDDeviceProfile>) -> some View {
        Toggle("逐设备跟踪调校", isOn: profile.requestsTrackingAdjustment)
        if profile.wrappedValue.requestsTrackingAdjustment {
            trackingSlider("相对原值速度", value: profile.trackingSpeed, range: 0.1...8)
            trackingSlider("加速度", value: profile.trackingAcceleration, range: 0...3)
            Text(L10n.text(trackingReadiness[profile.wrappedValue.deviceID] ?? "调校设备未连接或需要重新绑定；未修改其他设备。"))
                .font(.caption).foregroundStyle(.secondary)
            Text("保存并启用配置后，先备份真实原值，再向唯一设备服务写入并读回；停用或退出时恢复。设备不提供原值或读回失败时拒绝调校，系统或其他应用更改的值不会被强行覆盖。这里的设备检查只读，不代表硬件调校已经验收。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func trackingSlider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
        }
    }

    private func refreshTrackingReadiness(_ devices: [HIDDeviceDescriptor]) {
        trackingInspector.refresh(devices)
        trackingReadiness = Dictionary(uniqueKeysWithValues: devices.map { device in
            (device.id, trackingInspector.refusal[device.id] ?? "已唯一识别设备服务并读到原值；应用后的实际读回状态见高级输入状态。")
        })
    }
}
