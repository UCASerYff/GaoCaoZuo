import Foundation
import IOKit
import IOKit.hidsystem
import Darwin

/// Fixed IOHID pointer service backend. This client is passive, has no input
/// callbacks/queues, and can write only the two validated per-service keys.
@MainActor final class HIDTrackingServiceBackend {
    private typealias CreateClient = @convention(c)(CFAllocator?, Int32, CFDictionary?) -> Unmanaged<CFTypeRef>?
    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL)
    private static let create: CreateClient? = library.flatMap{dlsym($0, "IOHIDEventSystemClientCreateWithType")}.map{unsafeBitCast($0, to: CreateClient.self)}
    private var client: IOHIDEventSystemClient?
    private var devices: [HIDDeviceDescriptor] = []
    private var services: [UInt64: IOHIDServiceClient] = [:]
    private(set) var bindings: [String: HIDTrackingBinding] = [:]
    private(set) var refusal: [String: String] = [:]

    struct ReadOnlyPreflightReport: Encodable {
        struct NumericProperty: Encodable {
            // Missing/invalid is explicit and never encoded as a zero default.
            let state: String
            let value: Int64?
            enum CodingKeys: String, CodingKey {case state,value}
            func encode(to encoder: Encoder) throws {
                var values=encoder.container(keyedBy:CodingKeys.self)
                try values.encode(state,forKey:.state)
                if let value {try values.encode(value,forKey:.value)} else {try values.encodeNil(forKey:.value)}
            }
        }
        struct Device: Encodable {
            let deviceID: String
            let deviceRegistryID: UInt64
            let types: [String]
            let builtIn: Bool
            let relatedServiceIDs: [UInt64]
            let uniquelyMappedServiceID: UInt64?
            let scopeVerifiedBeforeAndAfterRead: Bool
            let accelerationType: String?
            let resolution: NumericProperty
            let acceleration: NumericProperty
            let originalValuesAcceptedByBackend: Bool
            let refusal: String?
        }
        let schema = 1
        let kind = "read-only-hid-tracking-preflight"
        let parameterWritesPerformed = false
        let inputEventCallbacksRegistered = false
        let inputQueuesOpened = false
        let globalPreferencesReadOrWritten = false
        let hardwareAdjustmentVerified = false
        let bootSessionAvailable: Bool
        let passiveServiceClientAvailable: Bool
        let devices: [Device]
    }

    /// Safe to call before NSApplication initialization. This deliberately does
    /// not construct HIDTrackingTuning, open its journal, install an event tap,
    /// register input-value callbacks, or call the parameter write boundary.
    /// Output is restricted to connection IDs, pointer types and the same
    /// whitelisted raw numeric properties needed by the production backend.
    static func readOnlyPreflightReport() -> ReadOnlyPreflightReport {
        let discovery=HIDInputDevices()
        discovery.start(recordButtons:false)
        defer {discovery.stop()}
        let inspector=HIDTrackingServiceBackend()
        let devices=discovery.devices
        inspector.refresh(devices)
        let unavailable=ReadOnlyPreflightReport.NumericProperty(state:"unavailable-scope",value:nil)
        let rows=devices.sorted {($0.registryID,$0.id)<($1.registryID,$1.id)}.map {device -> ReadOnlyPreflightReport.Device in
            let related=inspector.services.keys.filter{device.registryID == $0 || device.eventServiceRegistryIDs.contains($0)}.sorted()
            let unique=related.count == 1 && HIDEventOwnership.uniqueOwner(senderID:related[0],devices:devices) == device.id
            let before=unique && inspector.currentInterface(device)
            var accelerationType:String?
            var resolution=unavailable,acceleration=unavailable
            if before,let serviceID=related.first,let service=inspector.services[serviceID] {
                @MainActor func numeric(_ property:CFTypeRef?) -> ReadOnlyPreflightReport.NumericProperty {
                    guard let property else {return .init(state:"absent",value:nil)}
                    guard let value=inspector.integer(property) else {return .init(state:"unsupported-numeric-encoding",value:nil)}
                    return .init(state:"numeric",value:value)
                }
                resolution=numeric(IOHIDServiceClientCopyProperty(service,HIDTrackingValues.resolutionKey as CFString))
                if let type=IOHIDServiceClientCopyProperty(service,"HIDPointerAccelerationType" as CFString) as? String,
                   HIDTrackingValues.accelerationKeys.contains(type) {
                    accelerationType=type
                    acceleration=numeric(IOHIDServiceClientCopyProperty(service,type as CFString))
                } else {acceleration = .init(state:"acceleration-type-unavailable-or-unsupported",value:nil)}
            }
            let after=before && inspector.currentInterface(device) && related.first.map{HIDEventOwnership.uniqueOwner(senderID:$0,devices:devices) == device.id} == true
            let finalValues=inspector.bindings[device.id].flatMap{try? inspector.read($0)}
            let accepted=after && finalValues != nil && finalValues?.accelerationKey == accelerationType &&
                finalValues?.resolution == resolution.value && finalValues?.acceleration == acceleration.value
            var types:[String]=[]
            if device.usagePairs.contains("1:1") {types.append("pointer")}
            if device.usagePairs.contains("1:2") {types.append("mouse")}
            if device.isTrackpad {types.append("trackpad")}
            return .init(deviceID:device.id,deviceRegistryID:device.registryID,types:types,builtIn:device.isBuiltIn,
                         relatedServiceIDs:related,uniquelyMappedServiceID:after ? related.first:nil,
                         scopeVerifiedBeforeAndAfterRead:after,accelerationType:accelerationType,
                         resolution:resolution,acceleration:acceleration,originalValuesAcceptedByBackend:accepted,
                         refusal:inspector.refusal[device.id] ?? (accepted ? nil:"read-only-snapshot-not-accepted"))
        }
        return ReadOnlyPreflightReport(bootSessionAvailable:HIDInputDevices.verifiedBootSession != nil,
                                      passiveServiceClientAvailable:inspector.client != nil,devices:rows)
    }

    func refresh(_ devices: [HIDDeviceDescriptor]) {
        self.devices = devices;bindings = [:];refusal = [:];services = [:]
        if client == nil, let create = Self.create,
           let value = create(kCFAllocatorDefault, 2, nil)?.takeRetainedValue(), CFGetTypeID(value) == IOHIDEventSystemClientGetTypeID() {
            client = (value as! IOHIDEventSystemClient)
        }
        guard let client else {
            for device in devices {refusal[device.id] = "当前系统没有可用的逐设备参数服务；未修改任何设置。"};return
        }
        let found = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        for service in found where IOHIDServiceClientConformsTo(service, 1, 2) != 0 || IOHIDServiceClientConformsTo(service, 13, 5) != 0 {
            guard let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value, id != 0 else {continue}
            services[id] = service
        }
        for device in devices {
            let candidates = services.keys.filter {id in
                (device.registryID == id || device.eventServiceRegistryIDs.contains(id)) &&
                    HIDEventOwnership.uniqueOwner(senderID: id, devices: devices) == device.id
            }
            guard HIDConnectionIdentity.isConnectionScoped(device.id), Set(devices.map(\.id)).count == devices.count,
                  candidates.count == 1, currentInterface(device) else {
                refusal[device.id] = "无法唯一确认该设备的当前参数服务；不会按型号、端口或其他设备代替。";continue
            }
            let binding = HIDTrackingBinding(deviceID: device.id, serviceID: candidates[0],bootSession:HIDInputDevices.verifiedBootSession)
            do {_ = try read(binding);bindings[device.id] = binding}
            catch {refusal[device.id] = error.localizedDescription}
        }
    }
    private func currentInterface(_ device: HIDDeviceDescriptor) -> Bool {
        guard device.registryID != 0, !device.interfacePath.isEmpty else {return false}
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(device.registryID))
        guard entry != 0 else {return false};defer {IOObjectRelease(entry)}
        var path = [CChar](repeating: 0, count: 4096)
        return IORegistryEntryGetPath(entry, kIOServicePlane, &path) == kIOReturnSuccess && String(cString: path) == device.interfacePath
    }
    private func service(_ binding: HIDTrackingBinding) throws -> IOHIDServiceClient {
        guard binding.bootSession == HIDInputDevices.verifiedBootSession,
              let device = devices.first(where:{$0.id == binding.deviceID}), currentInterface(device),
              HIDEventOwnership.uniqueOwner(senderID: binding.serviceID, devices: devices) == device.id,
              let service = services[binding.serviceID],
              (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value == binding.serviceID else {
            throw HIDTrackingFailure.message("原设备接口已断开或归属发生变化；恢复记录已保留，不会写入替代设备。")
        }
        return service
    }
    private func integer(_ value: CFTypeRef?) -> Int64? {
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber else {return nil}
        let floating = number.doubleValue
        guard floating.isFinite, floating.rounded() == floating, floating >= Double(Int32.min), floating <= Double(Int32.max) else {return nil}
        return number.int64Value
    }
    func read(_ binding: HIDTrackingBinding) throws -> HIDTrackingValues {
        let service = try service(binding)
        guard let key = IOHIDServiceClientCopyProperty(service, "HIDPointerAccelerationType" as CFString) as? String,
              HIDTrackingValues.accelerationKeys.contains(key),
              let resolution = integer(IOHIDServiceClientCopyProperty(service, HIDTrackingValues.resolutionKey as CFString)),
              let acceleration = integer(IOHIDServiceClientCopyProperty(service, key as CFString)) else {
            throw HIDTrackingFailure.message("该设备未提供可读的原始速度及加速度；已拒绝调校，未把缺失值当作零或默认值。")
        }
        if let support = IOHIDServiceClientCopyProperty(service, "HIDSupportsPointerAcceleration" as CFString) as? NSNumber, !support.boolValue {
            throw HIDTrackingFailure.message("该设备明确不支持指针加速度调校；未修改设备。")
        }
        let values = HIDTrackingValues(accelerationKey: key, resolution: resolution, acceleration: acceleration)
        guard values.valid else {throw HIDTrackingFailure.message("设备原始参数不是受支持的定点数值；未修改设备。")}
        return values
    }
    func write(_ binding: HIDTrackingBinding, key: String, value: Int64) throws -> Bool {
        let service = try service(binding)
        let current = try read(binding)
        guard current.keys.contains(key), value >= Int64(Int32.min), value <= Int64(Int32.max), key != HIDTrackingValues.resolutionKey || value > 0 else {
            throw HIDTrackingFailure.message("拒绝写入未经核验的设备参数。")
        }
        return IOHIDServiceClientSetProperty(service, key as CFString, NSNumber(value: value))
    }
    var backend: HIDTrackingBackend {HIDTrackingBackend(read:{[self] in try read($0)}, write:{[self] in try write($0, key: $1, value: $2)},currentBootSession:{HIDInputDevices.verifiedBootSession})}
    static var defaultDataDirectory: URL {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--data-dir"), args.count > index + 1, args[index + 1].hasPrefix("/") {return URL(fileURLWithPath: args[index + 1], isDirectory: true)}
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoCaoZuo", isDirectory: true)
    }
    static func journalURL(in directory: URL) -> URL {directory.appendingPathComponent("HIDTracking/parameter-ownership.json")}
    static func persistence(in directory: URL) -> HIDTrackingTuning.Persistence {
        let local = LocalData(directory: directory.appendingPathComponent("HIDTracking", isDirectory: true))
        return .init(load:{try local.load("parameter-ownership.json", as: HIDTrackingTuning.Document.self)},
                     save:{try local.save($0, name: "parameter-ownership.json")})
    }
}
