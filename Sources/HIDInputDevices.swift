import AppKit
import IOKit.hid
import Combine

struct HIDButtonMapping:Codable,Equatable,Identifiable {
    var id=UUID();var name="设备按钮";var enabled=false;var usage=1
    var whenReleased=false;var appBundleID="";var excludedApps:[String]=[];var effect=InputEffect()
}
struct HIDDeviceProfile:Codable,Equatable,Identifiable {
    var id=UUID();var name="设备配置";var deviceID="";var enabled=false
    var buttons:[HIDButtonMapping]=[]
    var trackingSpeed:Double=1;var trackingAcceleration:Double=0
    // These requested values are retained for migration; no undocumented/global setting is written.
    // A per-device tracking backend is not available through the public user-space APIs used here.
    var requestsTrackingAdjustment=false
}
struct HIDDeviceDescriptor:Identifiable,Equatable {
    var id:String;var name:String;var vendor:Int;var product:Int;var location:Int
    var buttonUsages:[Int]
    var transport:String = "未知"
    var isBuiltIn=false
    var registryID:UInt64=0
    var usagePairs:[String]=[]
    var hasWheelElement=false
    var hasPressureElement=false
    var isTrackpad:Bool {usagePairs.contains("13:5") || name.localizedCaseInsensitiveContains("trackpad") || name.localizedCaseInsensitiveContains("touchpad")}
}
struct HIDButtonObservation {let deviceID:String;let usage:Int;let pressed:Bool}

@MainActor final class HIDInputDevices:ObservableObject {
    @Published private(set) var devices:[HIDDeviceDescriptor]=[]
    @Published private(set) var status="尚未监听设备"
    @Published private(set) var lastButton:String=""
    var onButton:((HIDButtonObservation)->Void)?
    private var manager:IOHIDManager?
    private var identifiers:[UInt64:String]=[:]
    private var pressed:Set<String>=[]
    @Published private(set) var connectionGeneration=0
    private static let attached:IOHIDDeviceCallback={ context,result,_,device in
        guard let context,result==kIOReturnSuccess else{return}
        let owner=Unmanaged<HIDInputDevices>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {owner.add(device)}
    }
    private static let removed:IOHIDDeviceCallback={ context,_,_,device in
        guard let context else{return};let owner=Unmanaged<HIDInputDevices>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {owner.remove(device)}
    }
    private static let value:IOHIDValueCallback={ context,result,_,value in
        guard let context,result==kIOReturnSuccess else{return};let owner=Unmanaged<HIDInputDevices>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {owner.receive(value)}
    }
    func start(recordButtons:Bool=true) {
        stop()
        let manager=IOHIDManagerCreate(kCFAllocatorDefault,IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager=manager
        // Match mice/pointers only. Do not observe keyboard character reports.
        IOHIDManagerSetDeviceMatchingMultiple(manager,Self.matching as CFArray)
        let context=Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager,Self.attached,context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager,Self.removed,context)
        if recordButtons {IOHIDManagerRegisterInputValueCallback(manager,Self.value,context)}
        IOHIDManagerSetInputValueMatching(manager,[kIOHIDElementUsagePageKey:9] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
        // Discovery does not open input queues or request/assume event authorization.
        if !recordButtons {
            if let found=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {for device in found {add(device)}}
            status="正在识别已连接HID接口；未录制按钮。"
            return
        }
        let result=IOHIDManagerOpen(manager,IOOptionBits(kIOHIDOptionsTypeNone))
        guard result==kIOReturnSuccess else{status="无法打开鼠标HID输入（系统错误\(result)）；请检查输入监控权限。";stop(keepStatus:true);return}
        if let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {for device in devices {add(device)}}
        status="HID监听已开启；只记录鼠标按钮，保留系统原输入。"
    }
    func stop(keepStatus:Bool=false) {
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager,nil,nil)
            IOHIDManagerRegisterDeviceMatchingCallback(manager,nil,nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager,nil,nil)
            IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager,IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager=nil;identifiers.removeAll();pressed.removeAll();devices=[]
        if !keepStatus {status="设备监听已停止"}
    }
    private static let matching:[[String:Int]] = [[kIOHIDDeviceUsagePageKey:1,kIOHIDDeviceUsageKey:2],[kIOHIDDeviceUsagePageKey:1,kIOHIDDeviceUsageKey:1],[kIOHIDDeviceUsagePageKey:13,kIOHIDDeviceUsageKey:5]]
    private func registryID(_ device:IOHIDDevice)->UInt64? {
        var id:UInt64=0;guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&id)==kIOReturnSuccess else{return nil};return id
    }
    private func add(_ device:IOHIDDevice) {
        guard let registry=registryID(device),identifiers[registry]==nil else{return}
        func number(_ key:String)->Int {(IOHIDDeviceGetProperty(device,key as CFString) as? NSNumber)?.intValue ?? 0}
        let vendor=number(kIOHIDVendorIDKey),product=number(kIOHIDProductIDKey),location=number(kIOHIDLocationIDKey)
        let name=IOHIDDeviceGetProperty(device,kIOHIDProductKey as CFString) as? String ?? "鼠标/指针设备"
        var id="hid:\(vendor):\(product):"+(location != 0 ? String(location):"session-\(registry)")
        if identifiers.values.contains(id) {id += ":session-\(registry)"}
        let elements=IOHIDDeviceCopyMatchingElements(device,nil,0) as? [IOHIDElement] ?? []
        let usages=Set(elements.filter{IOHIDElementGetUsagePage($0)==9}.map{Int(IOHIDElementGetUsage($0))}.filter{(1...32).contains($0)}).sorted()
        let transport=IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String ?? "未知"
        let pairs=IOHIDDeviceGetProperty(device,kIOHIDDeviceUsagePairsKey as CFString) as? [[String:Any]] ?? []
        let usagePairs=Set(pairs.compactMap {pair -> String? in
            guard let page=pair[kIOHIDDeviceUsagePageKey] as? NSNumber,let usage=pair[kIOHIDDeviceUsageKey] as? NSNumber else{return nil}
            return "\(page.intValue):\(usage.intValue)"
        }).sorted()
        identifiers[registry]=id
        if !devices.contains(where:{$0.id==id}) {devices.append(.init(id:id,name:name,vendor:vendor,product:product,location:location,buttonUsages:usages,
            transport:transport,isBuiltIn:number(kIOHIDBuiltInKey) != 0,registryID:registry,usagePairs:usagePairs,
            hasWheelElement:elements.contains{IOHIDElementGetUsagePage($0)==1 && IOHIDElementGetUsage($0)==0x38},
            hasPressureElement:elements.contains{IOHIDElementGetUsagePage($0)==13 && IOHIDElementGetUsage($0)==0x30}))
            connectionGeneration += 1}
    }
    private func remove(_ device:IOHIDDevice) {
        guard let registry=registryID(device),let id=identifiers.removeValue(forKey:registry) else{return}
        devices.removeAll{$0.id==id};connectionGeneration += 1;pressed=pressed.filter{!$0.hasPrefix(id+"|")}
    }
    private func receive(_ value:IOHIDValue) {
        let element=IOHIDValueGetElement(value)
        let device=IOHIDElementGetDevice(element)
        guard IOHIDElementGetUsagePage(element)==9,let registry=registryID(device),let id=identifiers[registry] else{return}
        let usage=Int(IOHIDElementGetUsage(element));guard (1...32).contains(usage) else{return}
        let down=IOHIDValueGetIntegerValue(value) != 0,key=id+"|\(usage)"
        if down {guard pressed.insert(key).inserted else{return}} else {guard pressed.remove(key) != nil else{return}}
        lastButton="\(id) · Usage \(usage) · "+(down ? "按下":"松开")
        onButton?(.init(deviceID:id,usage:usage,pressed:down))
    }
    isolated deinit {
        if let manager {IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue);IOHIDManagerClose(manager,IOOptionBits(kIOHIDOptionsTypeNone))}
    }
}
