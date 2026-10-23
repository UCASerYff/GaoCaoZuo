import AppKit
import IOKit.hid
import Combine
import Darwin

struct HIDButtonMapping:Codable,Equatable,Identifiable {
    var id=UUID();var name="设备按钮";var enabled=false;var usage=1
    var whenReleased=false;var appBundleID="";var excludedApps:[String]=[];var effect=InputEffect()
}
struct HIDDeviceProfile:Codable,Equatable,Identifiable {
    var id=UUID();var name="设备配置";var deviceID="";var enabled=false
    var buttons:[HIDButtonMapping]=[]
    var trackingSpeed:Double=1;var trackingAcceleration:Double=0
    // Applied only through a uniquely bound IOHID service with readable real
    // originals, durable backup, exact numeric readback, and owned-value restore.
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
    var interfacePath:String = ""
    var bindingScope:String = "当前接口连接；断接或系统重启后须重新绑定"
    var eventServiceRegistryIDs:[UInt64]=[]
    var isTrackpad:Bool {usagePairs.contains("13:5")}
}
struct HIDButtonObservation {let deviceID:String;let usage:Int;let pressed:Bool;var generation:Int = 0}

/// Value-only lifecycle gate for passive service discovery. A topology change
/// invalidates an entire pending batch, including disconnect/reconnect ABA.
struct HIDEventServiceRefreshState {
    struct Interface:Equatable,Sendable {let deviceID:String;let registryID:UInt64;let path:String}
    struct Batch:Sendable {let session:UUID;let topology:UInt64;let token:UUID;let interfaces:[Interface]}
    private var session:UUID?
    private var topology:UInt64=0
    private var pending:UUID?
    private var cursor=0
    mutating func start() {session=UUID();topology=0;pending=nil;cursor=0}
    mutating func stop() {session=nil;pending=nil;cursor=0}
    mutating func connectionsChanged() {topology &+= 1;cursor=0}
    mutating func begin(devices:[HIDDeviceDescriptor])->Batch? {
        guard let session,pending==nil else{return nil}
        let current=devices.filter{$0.registryID != 0 && !$0.interfacePath.isEmpty && HIDConnectionIdentity.isConnectionScoped($0.id)}
            .sorted{($0.registryID,$0.id)<($1.registryID,$1.id)}
        guard !current.isEmpty else{return nil}
        let count=min(8,current.count),start=cursor % current.count
        let interfaces=(0..<count).map {offset -> Interface in
            let device=current[(start+offset) % current.count]
            return Interface(deviceID:device.id,registryID:device.registryID,path:device.interfacePath)
        }
        cursor=(start+count) % current.count
        let token=UUID();pending=token
        return Batch(session:session,topology:topology,token:token,interfaces:interfaces)
    }
    mutating func complete(_ batch:Batch,serviceIDs:[[UInt64]?],devices:inout [HIDDeviceDescriptor],identifiers:[UInt64:String])->Bool {
        guard session==batch.session,pending==batch.token else{return false}
        pending=nil
        guard topology==batch.topology,serviceIDs.count==batch.interfaces.count else{return false}
        var changed=false
        for (interface,found) in zip(batch.interfaces,serviceIDs) {
            guard let found,identifiers[interface.registryID]==interface.deviceID,
                  let index=devices.firstIndex(where:{$0.id==interface.deviceID && $0.registryID==interface.registryID && $0.interfacePath==interface.path}) else{continue}
            let ids=Set(found.filter{$0 != 0}).sorted()
            if devices[index].eventServiceRegistryIDs != ids {devices[index].eventServiceRegistryIDs=ids;changed=true}
        }
        return changed
    }
}

@MainActor final class HIDInputDevices:ObservableObject {
    @Published private(set) var devices:[HIDDeviceDescriptor]=[]
    @Published private(set) var status="尚未监听设备"
    @Published private(set) var lastButton:String=""
    var onButton:((HIDButtonObservation)->Void)?
    var onDevicesChanged:(()->Void)?
    private var manager:IOHIDManager?
    private var identifiers:[UInt64:String]=[:]
    private var pressed:Set<String>=[]
    private var serviceRefresh=HIDEventServiceRefreshState()
    private var serviceRefreshTimer:Timer?
    private let serviceRefreshQueue=DispatchQueue(label:"com.gaoseries.GaoCaoZuo.hid-service-refresh",qos:.utility)
    static let verifiedBootSession:String? = {
        var size=0
        guard sysctlbyname("kern.bootsessionuuid",nil,&size,nil,0)==0,size>1,size<1024 else {return nil}
        var bytes=[CChar](repeating:0,count:size)
        guard sysctlbyname("kern.bootsessionuuid",&bytes,&size,nil,0)==0 else{return nil}
        return String(cString:bytes)
    }()
    private static let bootSession=verifiedBootSession ?? UUID().uuidString
    func isCurrent(_ observation:HIDButtonObservation)->Bool {
        observation.generation==connectionGeneration && devices.contains{$0.id==observation.deviceID}
    }
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
        serviceRefresh.start()
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
            startServiceRefresh()
            return
        }
        let result=IOHIDManagerOpen(manager,IOOptionBits(kIOHIDOptionsTypeNone))
        guard result==kIOReturnSuccess else{status=L10n.format("无法打开鼠标HID输入（系统错误%@）；请检查输入监控权限。", String(describing: (result)));stop(keepStatus:true);return}
        if let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {for device in devices {add(device)}}
        status="HID监听已开启；只记录鼠标按钮，保留系统原输入。"
        startServiceRefresh()
    }
    func stop(keepStatus:Bool=false) {
        serviceRefreshTimer?.invalidate();serviceRefreshTimer=nil;serviceRefresh.stop()
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager,nil,nil)
            IOHIDManagerRegisterDeviceMatchingCallback(manager,nil,nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager,nil,nil)
            IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager,IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager=nil;identifiers.removeAll();pressed.removeAll();devices=[];connectionGeneration += 1
        onDevicesChanged?()
        if !keepStatus {status="设备监听已停止"}
    }
    private func startServiceRefresh() {
        let timer=Timer(timeInterval:3,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {self?.refreshEventServices()}
        }
        serviceRefreshTimer=timer;RunLoop.main.add(timer,forMode:.common)
        refreshEventServices()
    }
    private func refreshEventServices() {
        guard manager != nil,let batch=serviceRefresh.begin(devices:devices) else{return}
        serviceRefreshQueue.async { [weak self] in
            // Each query owns/releases its IOKit references on this queue. No
            // CGEvent, IOHIDDevice or service client crosses actor boundaries.
            let results=batch.interfaces.map {interface -> [UInt64]? in
                guard Self.interfaceIsCurrent(interface) else{return nil}
                let ids=HIDEventOwnership.relatedEventServiceIDs(deviceRegistryID:interface.registryID)
                return Self.interfaceIsCurrent(interface) ? ids:nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.manager != nil else{return}
                var updated=self.devices
                guard self.serviceRefresh.complete(batch,serviceIDs:results,devices:&updated,identifiers:self.identifiers) else{return}
                // Service changes are not new physical connections: preserve
                // button generations/pressed state, and notify only on change.
                self.devices=updated;self.onDevicesChanged?()
            }
        }
    }
    private nonisolated static func interfaceIsCurrent(_ interface:HIDEventServiceRefreshState.Interface)->Bool {
        let entry=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(interface.registryID))
        guard entry != 0 else{return false};defer{IOObjectRelease(entry)}
        var path=[CChar](repeating:0,count:4096)
        return IORegistryEntryGetPath(entry,kIOServicePlane,&path)==kIOReturnSuccess && String(cString:path)==interface.path
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
        let elements=IOHIDDeviceCopyMatchingElements(device,nil,0) as? [IOHIDElement] ?? []
        let usages=Set(elements.filter{IOHIDElementGetUsagePage($0)==9}.map{Int(IOHIDElementGetUsage($0))}.filter{(1...32).contains($0)}).sorted()
        let transport=IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String ?? "未知"
        let pairs=IOHIDDeviceGetProperty(device,kIOHIDDeviceUsagePairsKey as CFString) as? [[String:Any]] ?? []
        let usagePairs=Set(pairs.compactMap {pair -> String? in
            guard let page=pair[kIOHIDDeviceUsagePageKey] as? NSNumber,let usage=pair[kIOHIDDeviceUsageKey] as? NSNumber else{return nil}
            return "\(page.intValue):\(usage.intValue)"
        }).sorted()
        var path=[CChar](repeating:0,count:4096)
        let pathResult=IORegistryEntryGetPath(IOHIDDeviceGetService(device),kIOServicePlane,&path)
        let interfacePath=pathResult==kIOReturnSuccess ? String(cString:path):""
        let id=HIDConnectionIdentity.identifier(bootSession:Self.bootSession,registryID:registry,vendor:vendor,
            product:product,location:location,transport:transport,usagePairs:usagePairs,interfacePath:interfacePath)
        identifiers[registry]=id
        if !devices.contains(where:{$0.id==id}) {devices.append(.init(id:id,name:name,vendor:vendor,product:product,location:location,buttonUsages:usages,
            transport:transport,isBuiltIn:number(kIOHIDBuiltInKey) != 0,registryID:registry,usagePairs:usagePairs,
            hasWheelElement:elements.contains{IOHIDElementGetUsagePage($0)==1 && IOHIDElementGetUsage($0)==0x38},
            hasPressureElement:elements.contains{IOHIDElementGetUsagePage($0)==13 && IOHIDElementGetUsage($0)==0x30},interfacePath:interfacePath,
            eventServiceRegistryIDs:HIDEventOwnership.relatedEventServiceIDs(deviceRegistryID:registry)))
            serviceRefresh.connectionsChanged()
            connectionGeneration += 1;onDevicesChanged?()}
    }
    private func remove(_ device:IOHIDDevice) {
        guard let registry=registryID(device),let id=identifiers.removeValue(forKey:registry) else{return}
        serviceRefresh.connectionsChanged()
        devices.removeAll{$0.id==id};connectionGeneration += 1;pressed=pressed.filter{!$0.hasPrefix(id+"|")}
        onDevicesChanged?()
    }
    private func receive(_ value:IOHIDValue) {
        let element=IOHIDValueGetElement(value)
        let device=IOHIDElementGetDevice(element)
        guard IOHIDElementGetUsagePage(element)==9,let registry=registryID(device),let id=identifiers[registry] else{return}
        let usage=Int(IOHIDElementGetUsage(element));guard (1...32).contains(usage) else{return}
        let down=IOHIDValueGetIntegerValue(value) != 0,key=id+"|\(usage)"
        if down {guard pressed.insert(key).inserted else{return}} else {guard pressed.remove(key) != nil else{return}}
        lastButton="\(id) · Usage \(usage) · "+(down ? "按下":"松开")
        onButton?(.init(deviceID:id,usage:usage,pressed:down,generation:connectionGeneration))
    }
    isolated deinit {
        serviceRefreshTimer?.invalidate()
        if let manager {IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue);IOHIDManagerClose(manager,IOOptionBits(kIOHIDOptionsTypeNone))}
    }
}
