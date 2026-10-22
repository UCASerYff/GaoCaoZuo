import AppKit
import IOKit
import IOKit.hidsystem
import Darwin

/// Uses the source attached to this event; never guesses from the last active
/// mouse, product name, vendor ID, or a different event's timestamp.
enum HIDEventOwnership {
    private typealias CopyEvent=@convention(c)(CGEvent)->Unmanaged<CFTypeRef>?
    private typealias Sender=@convention(c)(CFTypeRef)->UInt64
    private typealias EventType=@convention(c)(CFTypeRef)->UInt32
    private static let graphics=dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",RTLD_NOW|RTLD_LOCAL)
    private static let hid=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_LOCAL)
    private static let copyEvent:CopyEvent?=graphics.flatMap{dlsym($0,"CGEventCopyIOHIDEvent")}.map{unsafeBitCast($0,to:CopyEvent.self)}
    private static let sender:Sender?=hid.flatMap{dlsym($0,"IOHIDEventGetSenderID")}.map{unsafeBitCast($0,to:Sender.self)}
    private static let eventType:EventType?=hid.flatMap{dlsym($0,"IOHIDEventGetType")}.map{unsafeBitCast($0,to:EventType.self)}
    static var available:Bool {copyEvent != nil && sender != nil && eventType != nil}
    static func owner(of event:CGEvent,devices:[HIDDeviceDescriptor])->String? {
        guard event.type == .scrollWheel,let copyEvent,let sender,let eventType,
              let native=copyEvent(event)?.takeRetainedValue(),eventType(native)==6 else {return nil}
        return uniqueOwner(senderID:sender(native),devices:devices)
    }
    static func uniqueOwner(senderID:UInt64,devices:[HIDDeviceDescriptor])->String? {
        guard senderID != 0 else {return nil}
        let matches=devices.filter{$0.registryID != 0 && HIDConnectionIdentity.isConnectionScoped($0.id) && ($0.registryID==senderID || $0.eventServiceRegistryIDs.contains(senderID))}
        return matches.count==1 ? matches[0].id:nil
    }
    /// Discovery-time mapping accepts only the same IORegistry entry or a direct
    /// ancestor/descendant relation, never a shared USB port/common ancestor.
    static func relatedEventServiceIDs(deviceRegistryID:UInt64)->[UInt64] {
        guard deviceRegistryID != 0 else {return []}
        let client=IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services=IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.compactMap {service in
            guard IOHIDServiceClientConformsTo(service,1,2) != 0 || IOHIDServiceClientConformsTo(service,13,5) != 0,
                  let id=(IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value,id != 0,
                  id==deviceRegistryID || isAncestor(id,of:deviceRegistryID) || isAncestor(deviceRegistryID,of:id) else {return nil}
            return id
        }.sorted()
    }
    private static func isAncestor(_ ancestor:UInt64,of descendant:UInt64)->Bool {
        var entry=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(descendant))
        for _ in 0..<24 {
            guard entry != 0 else {return false}
            var id:UInt64=0
            if IORegistryEntryGetRegistryEntryID(entry,&id)==kIOReturnSuccess,id==ancestor {IOObjectRelease(entry);return true}
            var parent:io_registry_entry_t=0
            let result=IORegistryEntryGetParentEntry(entry,kIOServicePlane,&parent)
            IOObjectRelease(entry);entry=result==kIOReturnSuccess ? parent:0
        }
        if entry != 0 {IOObjectRelease(entry)}
        return false
    }
    static func profile(_ profiles:[ScrollDeviceProfile],owner:String?,precise:Bool,app:String,flags:UInt64)->ScrollDeviceProfile? {
        let active=profiles.filter(\.enabled)
        let physical=active.filter{!["allWheel","allPrecise"].contains($0.deviceID)}
        // A physical rule's bypass/exclusion never falls through to a global
        // rule; an unowned event stays unchanged when physical rules are active.
        if owner==nil,!physical.isEmpty {return nil}
        let selected=owner.flatMap{id in physical.first{$0.deviceID==id}} ?? active.first{$0.deviceID==(precise ? "allPrecise":"allWheel")}
        guard let selected,!selected.excludedApps.contains(app),selected.bypassModifiers==0 || flags&selected.bypassModifiers==0 else {return nil}
        return selected
    }
}
