import AppKit
import Darwin

struct RawTouchContact:Equatable {let id:Int;let point:CGPoint}
struct RawTouchFrame {let deviceID:String;let timestamp:Double;let contacts:[RawTouchContact]}
struct TouchSequence {
    let pid:pid_t;let start:Double
    var hadClick=false
    var seedContacts:[RawTouchContact]
    var current:[RawTouchContact]
    var lastIncrease:Double
    var maxFingers:Int
    var initial:[RawTouchContact]
    var latest:[RawTouchContact]
    var path:[CGPoint]
    init(pid:pid_t,start:Double,contacts:[RawTouchContact]) {
        self.pid=pid;self.start=start;maxFingers=contacts.count;initial=contacts;latest=contacts;seedContacts=contacts;current=contacts;lastIncrease=start;path=[Self.center(contacts)]
    }
    static func center(_ contacts:[RawTouchContact])->CGPoint {
        guard !contacts.isEmpty else{return .zero}
        return CGPoint(x:contacts.map{$0.point.x}.reduce(0,+)/Double(contacts.count),y:contacts.map{$0.point.y}.reduce(0,+)/Double(contacts.count))
    }
    mutating func update(_ contacts:[RawTouchContact],timestamp:Double?=nil) {
        current=contacts
        if contacts.count>maxFingers {maxFingers=contacts.count;initial=contacts;lastIncrease=timestamp ?? start;path=[Self.center(contacts)]}
        if contacts.count==maxFingers {latest=contacts;if path.count<2048 {path.append(Self.center(contacts))}}
    }
    func isTipTap(remaining:[RawTouchContact],ended:Double)->Bool {
        guard maxFingers>seedContacts.count,!seedContacts.isEmpty,remaining.count==seedContacts.count,ended-lastIncrease>=0,ended-lastIncrease<0.35 else{return false}
        return seedContacts.allSatisfy { seed in remaining.contains { end in end.id==seed.id && hypot(seed.point.x-end.point.x,seed.point.y-end.point.y)<0.035 }} && initial.filter {p in !seedContacts.contains(where:{$0.id==p.id})}.allSatisfy {start in latest.contains {end in start.id==end.id && hypot(start.point.x-end.point.x,start.point.y-end.point.y)<0.045}}
    }
    var hasBottomAnchor:Bool {initial.contains { $0.point.y<0.18 } && latest.contains {end in initial.contains {start in start.id==end.id && start.point.y<0.18 && hypot(start.point.x-end.point.x,start.point.y-end.point.y)<0.04}}}
    var displacement:CGPoint {let a=Self.center(initial),b=Self.center(latest);return CGPoint(x:b.x-a.x,y:b.y-a.y)}
    var travel:Double {Double(DrawingRecognition.length(path))}
    var spreadChange:Double {
        func spread(_ c:[RawTouchContact])->Double {let center=Self.center(c);return c.map{hypot($0.point.x-center.x,$0.point.y-center.y)}.reduce(0,+)/Double(max(1,c.count))}
        return spread(latest)-spread(initial)
    }
    var rotation:Double {
        guard initial.count>=2,let first=latest.first(where:{$0.id==initial[0].id}),let second=latest.first(where:{$0.id==initial[1].id}) else{return 0}
        let a=atan2(initial[1].point.y-initial[0].point.y,initial[1].point.x-initial[0].point.x)
        let b=atan2(second.point.y-first.point.y,second.point.x-first.point.x)
        return atan2(sin(b-a),cos(b-a))
    }
    func matches(region:String)->Bool {
        let p=Self.center(initial)
        switch region {case "left":return p.x<0.18;case "right":return p.x>0.82;case "bottom":return p.y<0.18;case "top":return p.y>0.82;case "topLeft":return p.x<0.18 && p.y>0.82;case "topRight":return p.x>0.82 && p.y>0.82;case "bottomLeft":return p.x<0.18 && p.y<0.18;case "bottomRight":return p.x>0.82 && p.y<0.18;default:return true}
    }
}

/// This optional adapter uses an undocumented Apple ABI. It is deliberately off by default.
/// No third-party implementation is embedded. Field offsets are checked against captured values;
/// the z/quality fields are NOT called pressure and are never used as pressure triggers.
/// Symbol/OS/data checks reduce failures but cannot guarantee a private ABI will never change.
private final class RawTouchRelay:@unchecked Sendable {
    static let shared=RawTouchRelay()
    let lock=NSLock()
    var handler:((RawTouchFrame)->Void)?
    var error:((String)->Void)?
    var devices:[UInt:String]=[:]
    var generation=0
    var lastDelivery:[UInt:Double]=[:]
    func accept(device:UnsafeMutableRawPointer?,raw:UnsafeRawPointer?,count:Int32,time:Double) {
        guard let device,count>=0,count<=16,time.isFinite else{return}
        let key=UInt(bitPattern:device)
        lock.lock();let id=devices[key];let token=generation;let last=lastDelivery[key] ?? 0
        guard let id,handler != nil else{lock.unlock();return}
        if count>0,time-last<1/120 {lock.unlock();return};lastDelivery[key]=time;lock.unlock()
        var contacts:[RawTouchContact]=[];var invalid=false
        if count>0 {
            guard let raw else{return}
            for i in 0..<Int(count) {
                let p=raw.advanced(by:i*96)
                let state=p.loadUnaligned(fromByteOffset:20,as:Int32.self)
                let index=p.loadUnaligned(fromByteOffset:16,as:Int32.self)
                let x=p.loadUnaligned(fromByteOffset:32,as:Float.self),y=p.loadUnaligned(fromByteOffset:36,as:Float.self)
                guard (0...7).contains(state),x.isFinite,y.isFinite,(-0.1...1.1).contains(x),(-0.1...1.1).contains(y),index>=0,index<65536 else{invalid=true;break}
                if state==3 || state==4 {contacts.append(RawTouchContact(id:Int(index),point:CGPoint(x:Double(x),y:Double(y))))}
            }
        }
        let capturedContacts=contacts,wasInvalid=invalid
        DispatchQueue.main.async { [weak self] in
            guard let self else{return};self.lock.lock();let active=token==self.generation;let callback=self.handler;let report=self.error;self.lock.unlock()
            guard active else{return}
            if wasInvalid {report?("多点设备数据与已知接口格式不符，实验触控已停止。")}
            else {callback?(RawTouchFrame(deviceID:id,timestamp:time,contacts:capturedContacts))}
        }
    }
}
@MainActor final class RawTouchInput {
    private typealias ContactCallback = @convention(c)(UnsafeMutableRawPointer?,UnsafeRawPointer?,Int32,Double,Int32)->Void
    private typealias CreateList = @convention(c)()->Unmanaged<CFArray>?
    private typealias Register = @convention(c)(UnsafeMutableRawPointer?,ContactCallback)->Void
    private typealias Start = @convention(c)(UnsafeMutableRawPointer?,Int32)->Void
    private typealias Stop = @convention(c)(UnsafeMutableRawPointer?)->Void
    private typealias Running = @convention(c)(UnsafeMutableRawPointer?)->Bool
    private typealias BuiltIn = @convention(c)(UnsafeMutableRawPointer?)->Bool
    private var library:UnsafeMutableRawPointer?
    private var list:CFArray?
    private var handles:[UnsafeMutableRawPointer]=[]
    private var unregister:Register?
    private var stopDevice:Stop?
    private var generation=0
    private(set) var isRunning=false
    private(set) var status="原始多点触控未启用（实验功能，未公开接口）"
    private(set) var deviceNames:[String]=[]
    private(set) var observedFrames=0
    private static let callback:ContactCallback={device,raw,count,time,_ in RawTouchRelay.shared.accept(device:device,raw:raw,count:count,time:time)}
    func start(handler:@escaping(RawTouchFrame)->Void) {
        stop()
        let version=ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard (14...27).contains(version) else{status="此 macOS 版本的私有触控接口尚未核验，实验触控未启动。";return}
        guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else{status="原始触控需要输入监控权限。";return}
        let path="/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib=library ?? dlopen(path,RTLD_NOW|RTLD_LOCAL) else{status="系统未提供 MultitouchSupport 接口。";return}
        library=lib
        guard let createSymbol=dlsym(lib,"MTDeviceCreateList"),let registerSymbol=dlsym(lib,"MTRegisterContactFrameCallback"),let unregisterSymbol=dlsym(lib,"MTUnregisterContactFrameCallback"),let startSymbol=dlsym(lib,"MTDeviceStart"),let stopSymbol=dlsym(lib,"MTDeviceStop"),let runningSymbol=dlsym(lib,"MTDeviceIsRunning") else{status="多点触控接口缺少必要符号，未启动。";return}
        let create=unsafeBitCast(createSymbol,to:CreateList.self),register=unsafeBitCast(registerSymbol,to:Register.self),start=unsafeBitCast(startSymbol,to:Start.self)
        unregister=unsafeBitCast(unregisterSymbol,to:Register.self);stopDevice=unsafeBitCast(stopSymbol,to:Stop.self)
        guard let devices=create()?.takeRetainedValue() else{status="没有可用的多点触控设备。";return}
        list=devices
        let builtIn=dlsym(lib,"MTDeviceIsBuiltIn").map{unsafeBitCast($0,to:BuiltIn.self)}
        let running=unsafeBitCast(runningSymbol,to:Running.self)
        let relay=RawTouchRelay.shared
        relay.lock.lock();relay.generation+=1;relay.handler={ [weak self] frame in self?.observedFrames += 1;handler(frame) };relay.error={ [weak self] message in self?.stop();self?.status=message };relay.devices.removeAll();relay.lock.unlock()
        for index in 0..<min(16,CFArrayGetCount(devices)) {
            guard let value=CFArrayGetValueAtIndex(devices,index) else{continue}
            let device=UnsafeMutableRawPointer(mutating:value)

            let isInternal=builtIn?(device) ?? false
            let id="session-\(index)"
            let key=(isInternal ? "trackpad:":"touch:")+id
            relay.lock.lock();relay.devices[UInt(bitPattern:device)]=key;relay.lock.unlock()
            register(device,Self.callback)
            start(device,0)
            if running(device) {handles.append(device);deviceNames.append((isInternal ? "内置触控板":"外置触控设备")+" · "+key)}
            else {unregister?(device,Self.callback);relay.lock.lock();relay.devices[UInt(bitPattern:device)]=nil;relay.lock.unlock()}
        }
        isRunning = !handles.isEmpty
        status=isRunning ? "实验触控已监听 \(handles.count) 个设备（macOS \(version)）；需实际手势验收，私有接口无兼容保证。压力值和系统手势独占不受支持。":"设备未接受触控监听；请检查输入监控权限和设备连接。"
        if !isRunning {stop()}
    }
    func stop() {
        let relay=RawTouchRelay.shared;relay.lock.lock();relay.generation+=1;relay.handler=nil;relay.error=nil;relay.devices.removeAll();relay.lastDelivery.removeAll();relay.lock.unlock()
        for device in handles {unregister?(device,Self.callback);stopDevice?(device)}
        handles.removeAll();list=nil;deviceNames=[];isRunning=false
        // Keep the library loaded: callbacks racing with stop must never jump into unmapped code.
    }
}
