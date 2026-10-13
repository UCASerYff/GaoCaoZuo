import Foundation

/// An observed IOHID interface, not a claim that its hardware workflows were tested.
struct InputDeviceIdentity: Codable, Identifiable, Equatable {
    var id: String
    /// A zero VID/PID/location is the IOHID fallback for a property the interface did not provide.
    var vendorID: Int
    var productID: Int
    var locationID: Int
    var productName: String
    var transport: String
    var isBuiltIn: Bool
    var isMouse: Bool
    var isTrackpad: Bool
    var authorized: Bool
    var registryID: UInt64
    var usagePairs: [String]
    var verifiedModel: String? = nil
}
struct InputDeviceCapabilities: Codable, Equatable {
    var buttonCount: Int
    var supportsPressure: Bool
    var supportsTipTap: Bool
    var supportsContinuousScroll: Bool
    var supportsDiscreteScroll: Bool
    var supportsPerDeviceSpeedHardwareApplied: Bool
    var notes: String
}
enum InputDeviceMatrix {
    struct Entry: Identifiable, Equatable {
        var id: String { identity.id }
        let identity: InputDeviceIdentity
        let capabilities: InputDeviceCapabilities
        let verifiedOnCurrentMachine: Bool
        let verificationState: String
    }
    /// Never synthesizes absent mice/trackpads, and never promotes enumeration to a test result.
    static func currentMatrix(devices: [HIDDeviceDescriptor], monitoringAuthorized: Bool) -> [Entry] {
        devices.sorted { $0.id < $1.id }.map { device in
            let identity = InputDeviceIdentity(id: device.id, vendorID: device.vendor,
                productID: device.product, locationID: device.location, productName: device.name,
                transport: device.transport, isBuiltIn: device.isBuiltIn,
                isMouse: device.usagePairs.contains("1:2"), isTrackpad: device.isTrackpad,
                authorized: monitoringAuthorized, registryID: device.registryID, usagePairs: device.usagePairs)
            let capabilities = InputDeviceCapabilities(buttonCount: device.buttonUsages.count,
                supportsPressure: device.hasPressureElement, supportsTipTap: false,
                supportsContinuousScroll: false, supportsDiscreteScroll: device.hasWheelElement,
                supportsPerDeviceSpeedHardwareApplied: false,
                notes: "按钮/滚轮/压力仅表示HID描述符有相应元素，不证明实际投递；未公开元素也不证明硬件不具备。授权为CG事件监听预检，HID按钮还须实测。连续滚动无法从CGEvent绑定此设备；TipTap为默认关闭的实验私有触控算法；逐设备速度未应用。")
            return Entry(identity: identity, capabilities: capabilities, verifiedOnCurrentMachine: false,
                         verificationState: monitoringAuthorized ? "已识别；硬件动作未验收" : "已识别；输入监听未获授权")
        }
    }
}
