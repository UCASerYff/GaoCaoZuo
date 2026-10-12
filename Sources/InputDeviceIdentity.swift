import Foundation
import AppKit

public struct InputDeviceIdentity: Codable, Identifiable, Equatable {
    public var id: String
    public var vendorID: Int
    public var productID: Int
    public var locationID: Int
    public var productName: String
    public var transport: String
    public var isBuiltIn: Bool
    public var isMouse: Bool
    public var isTrackpad: Bool
    public var authorized: Bool
    public var verifiedModel: String?

    public init(
        id: String,
        vendorID: Int,
        productID: Int,
        locationID: Int,
        productName: String,
        transport: String = "USB",
        isBuiltIn: Bool = false,
        isMouse: Bool = true,
        isTrackpad: Bool = false,
        authorized: Bool = true,
        verifiedModel: String? = nil
    ) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.productName = productName
        self.transport = transport
        self.isBuiltIn = isBuiltIn
        self.isMouse = isMouse
        self.isTrackpad = isTrackpad
        self.authorized = authorized
        self.verifiedModel = verifiedModel
    }

    public static var builtInTrackpad: InputDeviceIdentity {
        InputDeviceIdentity(
            id: "built-in:apple-trackpad",
            vendorID: 0x05AC,
            productID: 0x0000,
            locationID: 0,
            productName: "内置力度触控板 (Built-in Force Touch Trackpad)",
            transport: "Built-in",
            isBuiltIn: true,
            isMouse: false,
            isTrackpad: true,
            authorized: true,
            verifiedModel: "Apple Silicon MacBook Built-in Trackpad"
        )
    }
}

public struct InputDeviceCapabilities: Codable, Equatable {
    public var buttonCount: Int
    public var supportsPressure: Bool
    public var supportsTipTap: Bool
    public var supportsContinuousScroll: Bool
    public var supportsDiscreteScroll: Bool
    public var supportsPerDeviceSpeedHardwareApplied: Bool
    public var notes: String

    public init(
        buttonCount: Int,
        supportsPressure: Bool,
        supportsTipTap: Bool,
        supportsContinuousScroll: Bool,
        supportsDiscreteScroll: Bool,
        supportsPerDeviceSpeedHardwareApplied: Bool,
        notes: String
    ) {
        self.buttonCount = buttonCount
        self.supportsPressure = supportsPressure
        self.supportsTipTap = supportsTipTap
        self.supportsContinuousScroll = supportsContinuousScroll
        self.supportsDiscreteScroll = supportsDiscreteScroll
        self.supportsPerDeviceSpeedHardwareApplied = supportsPerDeviceSpeedHardwareApplied
        self.notes = notes
    }

    public static var builtInTrackpadCapabilities: InputDeviceCapabilities {
        InputDeviceCapabilities(
            buttonCount: 1,
            supportsPressure: true,
            supportsTipTap: true,
            supportsContinuousScroll: true,
            supportsDiscreteScroll: false,
            supportsPerDeviceSpeedHardwareApplied: true,
            notes: "内置触控板支持系统标准平滑滚动与压力检测；原始触控 ABI 属实验私有接口，默认关闭。"
        )
    }

    public static var genericMouseCapabilities: InputDeviceCapabilities {
        InputDeviceCapabilities(
            buttonCount: 5,
            supportsPressure: false,
            supportsTipTap: false,
            supportsContinuousScroll: false,
            supportsDiscreteScroll: true,
            supportsPerDeviceSpeedHardwareApplied: false,
            notes: "公开 IOHIDManager 支持监听中键与附加侧键。macOS 公开用户态 API 不提供逐物理鼠标独立硬件跟踪速度调节，偏好意向仅供保存与迁移，诚实保留缺口。"
        )
    }
}

public enum InputDeviceMatrix {
    public struct Entry: Identifiable {
        public var id: String { identity.id }
        public let identity: InputDeviceIdentity
        public let capabilities: InputDeviceCapabilities
        public let verifiedOnCurrentMachine: Bool
        public let verificationState: String // "已验证" | "缺设备未验收" | "系统不支持"
    }

    public static func currentMatrix() -> [Entry] {
        [
            Entry(
                identity: .builtInTrackpad,
                capabilities: .builtInTrackpadCapabilities,
                verifiedOnCurrentMachine: true,
                verificationState: "已实测部分（内置触控板手势与压力；私有ABI默认关闭）"
            ),
            Entry(
                identity: InputDeviceIdentity(
                    id: "apple:magic-mouse",
                    vendorID: 0x004C,
                    productID: 0x0269,
                    locationID: 0,
                    productName: "Apple Magic Mouse (蓝牙触控鼠标)",
                    transport: "Bluetooth",
                    isBuiltIn: false,
                    isMouse: true,
                    isTrackpad: false,
                    authorized: true,
                    verifiedModel: "Magic Mouse 2"
                ),
                capabilities: InputDeviceCapabilities(
                    buttonCount: 2,
                    supportsPressure: false,
                    supportsTipTap: true,
                    supportsContinuousScroll: true,
                    supportsDiscreteScroll: false,
                    supportsPerDeviceSpeedHardwareApplied: false,
                    notes: "支持单/双指表面触控滑动监听；当前物理未连接。"
                ),
                verifiedOnCurrentMachine: false,
                verificationState: "缺设备未验收"
            ),
            Entry(
                identity: InputDeviceIdentity(
                    id: "hid:generic:mouse",
                    vendorID: 0,
                    productID: 0,
                    locationID: 0,
                    productName: "标准多按钮鼠标 (USB/蓝牙外接鼠标)",
                    transport: "USB/Bluetooth",
                    isBuiltIn: false,
                    isMouse: true,
                    isTrackpad: false,
                    authorized: true,
                    verifiedModel: nil
                ),
                capabilities: .genericMouseCapabilities,
                verifiedOnCurrentMachine: false,
                verificationState: "缺设备未验收"
            )
        ]
    }
}
