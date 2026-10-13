import AppKit
import ApplicationServices
import Carbon
import Combine

struct InputActionChoice:Identifiable {let id:String;let title:String}

@MainActor struct InputPressureMonitorBackend {
    var addGlobal:(@escaping(NSEvent)->Void)->Any?
    var addLocal:(@escaping(NSEvent)->NSEvent?)->Any?
    var remove:(Any)->Void
    static var system:Self {
        Self(addGlobal:{NSEvent.addGlobalMonitorForEvents(matching:.pressure,handler:$0)},
             addLocal:{NSEvent.addLocalMonitorForEvents(matching:.pressure,handler:$0)},remove:{NSEvent.removeMonitor($0)})
    }
}

@MainActor final class EnhancedInputEngine {
    static let syntheticTag:Int64 = 0x47414F43414F
    var configuration = InputEnhancementConfiguration()
    var handler:((String)->Void)?
    var report:((String?)->Void)?
    var excludedApps:Set<String> = []
    private var keys:Set<UInt16> = []
    private var buttons:Set<Int> = []
    private var timers:[String:Timer] = [:]
    private var consumedKeys:Set<UInt16> = []
    private var consumedButtons:Set<Int> = []
    private var replacements:[UInt16:(InputEffect,pid_t)] = [:]
    private var drawing:(points:[CGPoint],rules:[EnhancedInputRule],pid:pid_t,flags:UInt64,button:Int)?
    private var corner:String?
    private var lastScrollFire:TimeInterval = 0
    private var deliveryState=InputRuleDeliveryState()
    private var smoothTimer:Timer?
    private var scrollRemaining = CGPoint.zero
    private var scrollTarget:pid_t?
    private var scrollDuration:Double = 0.16
    private var activeScript:Process?
    private var pressureMonitor:Any?
    private var localPressureMonitor:Any?
    private let pressureBackend:InputPressureMonitorBackend
    private var deviceMonitoringStarted=false
    private var pressureLatched=false
    private(set) var observedPressureEvents=0
    private let touch = RawTouchInput()
    private let hid = HIDInputDevices()
    private var touchDrag:(device:String,pid:pid_t,origin:CGPoint,pointer:CGPoint,ruleID:UUID)?
    private var lastTouchTap:(device:String,fingers:Int,time:Double)?
    private var touchSession:[String:TouchSequence] = [:]
    init(pressureBackend:InputPressureMonitorBackend?=nil) {self.pressureBackend=pressureBackend ?? .system}
    var needsActiveTap:Bool {
        configuration.enabled && (configuration.rules.contains { $0.enabled && ($0.consume || $0.trigger == .keyReplacement) } || configuration.scrollProfiles.contains(where: \.enabled))
    }
    var needsEvents:Bool {configuration.enabled && (configuration.rules.contains(where: \.enabled) || configuration.scrollProfiles.contains(where: \.enabled) || configuration.hidProfiles.contains(where: \.enabled))}
    var capabilityStatus:String {
        guard configuration.enabled else{return L10n.text("高级输入未启用")}
        var details=["高级输入已配置：\(configuration.rules.filter(\.enabled).count)条规则"]
        if configuration.hidProfiles.contains(where: \.enabled) {details.append(hid.status)}
        if configuration.experimentalRawTouch {details.append(touch.status+"；实际触点帧：\(touch.observedFrames)")}
        if configuration.rules.contains(where:{$0.enabled && $0.trigger == .pressure}) {details.append("压力监听：全局\(pressureMonitor == nil ? "未安装":"已安装")、局部\(localPressureMonitor == nil ? "未安装":"已安装")；实际压力事件：\(observedPressureEvents)；需要在目标应用中验收")}
        return details.joined(separator:"\n")
    }
    var touchDeviceNames:[String] {touch.deviceNames}

    func configure(_ configuration:InputEnhancementConfiguration,excludedApps:Set<String>,handler:@escaping(String)->Void,report reportCallback:@escaping(String?)->Void) {
        stop();self.configuration=configuration;self.excludedApps=excludedApps;self.handler=handler;self.report=reportCallback
        guard configuration.enabled else {return}
        do {try EnhancedInputValidation.validate(configuration)} catch {self.configuration.enabled=false;report?(error.localizedDescription);return}
        let conflicts=EnhancedInputValidation.conflictingIDs(configuration.rules)
        if !conflicts.isEmpty {self.configuration.rules.removeAll {conflicts.contains($0.id)};report?("高级输入存在相同触发冲突，相关规则已暂停。")}
        if configuration.scrollProfiles.contains(where:{$0.enabled && !["allWheel","allPrecise"].contains($0.deviceID)}) {report?("逐个物理鼠标滚轮规则尚不可用：公开 CGEvent 不提供可靠设备标识。该配置不会退化为修改所有鼠标。")}
    }
    func startMonitoring() {
        guard configuration.enabled else{return}
        if configuration.rules.contains(where:{$0.enabled && $0.trigger == .pressure}) {
            if pressureMonitor == nil {pressureMonitor=pressureBackend.addGlobal { [weak self] event in MainActor.assumeIsolated {self?.receivePressure(event)} }}
            if localPressureMonitor == nil {localPressureMonitor=pressureBackend.addLocal { [weak self] event in MainActor.assumeIsolated {self?.receivePressure(event)};return event }}
        }
        // The permission poll may call this repeatedly; device sessions must stay intact.
        guard !deviceMonitoringStarted else{return}
        deviceMonitoringStarted=true
        if configuration.enabled,configuration.hidProfiles.contains(where: \.enabled) {hid.onButton={ [weak self] observation in self?.receiveHIDButton(observation) };hid.start()}
        guard configuration.enabled,configuration.experimentalRawTouch,configuration.rules.contains(where:{$0.enabled && $0.trigger == .touch}) else {return}
        touch.start { [weak self] frame in self?.receiveTouch(frame) }
        if !touch.isRunning {report?(touch.status)}
    }
    func stop() {
        deviceMonitoringStarted=false
        finishTouchDrag();touch.stop();hid.stop();touchSession.removeAll()
        if let pressureMonitor {pressureBackend.remove(pressureMonitor)};pressureMonitor=nil
        if let localPressureMonitor {pressureBackend.remove(localPressureMonitor)};localPressureMonitor=nil;pressureLatched=false
        timers.values.forEach{$0.invalidate()};timers.removeAll();smoothTimer?.invalidate();smoothTimer=nil;scrollRemaining = .zero
        for (_,value) in replacements {try? sendKey(value.0,down:false,pid:value.1)}
        replacements.removeAll();keys.removeAll();buttons.removeAll();consumedKeys.removeAll();consumedButtons.removeAll();drawing=nil;corner=nil
        activeScript?.terminate();activeScript=nil;deliveryState=InputRuleDeliveryState()
    }
    private func matching(_ trigger:EnhancedInputTrigger,flags:UInt64,app:String)->[EnhancedInputRule] {
        configuration.rules.filter { $0.enabled && $0.trigger == trigger && $0.modifiers & EnhancedInputValidation.modifiers == flags & EnhancedInputValidation.modifiers && ($0.appBundleID.isEmpty || $0.appBundleID == app) && !$0.excludedApps.contains(app) }.sorted { !$0.appBundleID.isEmpty && $1.appBundleID.isEmpty }
    }
    private func buttonMatches(_ r:EnhancedInputRule,_ button:Int)->Bool {r.button == button && Set(r.heldButtons).isSubset(of:buttons)}
    private func scheduleHold(_ r:EnhancedInputRule,key:String,pid:pid_t) {
        timers[key]?.invalidate()
        guard let launch=NSRunningApplication(processIdentifier:pid)?.launchDate else{return}
        timers[key]=Timer.scheduledTimer(withTimeInterval:r.holdSeconds,repeats:false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else{return};self.timers[key]=nil
                let mask=r.keyCode==63 && r.trigger == .keyHold ? EnhancedInputValidation.modifiers & ~UInt64(NSEvent.ModifierFlags.function.rawValue):EnhancedInputValidation.modifiers
                guard self.allowed(pid:pid),NSRunningApplication(processIdentifier:pid)?.launchDate==launch,!IsSecureEventInputEnabled(),UInt64(NSEvent.modifierFlags.rawValue)&mask == r.modifiers&mask else{return}
                self.executeRule(r,pid:pid)
            }
        }
    }
    private func allowed(pid:pid_t)->Bool {
        configuration.enabled && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !excludedApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }
    /// Returns true only for an explicitly configured replacement or consume rule.
    func receive(type:CGEventType,event:CGEvent)->Bool {
        guard configuration.enabled,event.getIntegerValueField(.eventSourceUserData) != Self.syntheticTag else{return false}
        guard let front=NSWorkspace.shared.frontmostApplication else{return false}
        let pid=front.processIdentifier,app=front.bundleIdentifier ?? ""
        let code=UInt16(clamping:event.getIntegerValueField(.keyboardEventKeycode))
        // Release an already replaced key to its original recipient even after a focus/exclusion change.
        if type == .keyUp,let replacement=replacements.removeValue(forKey:code) {try? sendKey(replacement.0,down:false,pid:replacement.1);keys.remove(code);consumedKeys.remove(code);return true}
        if type == .keyUp,consumedKeys.contains(code),excludedApps.contains(app) {consumedKeys.remove(code);keys.remove(code);timers.removeValue(forKey:"k\(code)")?.invalidate();return true}
        if excludedApps.contains(app) {drawing=nil;timers.values.forEach{$0.invalidate()};timers.removeAll();return false}
        let flags=event.flags.rawValue & EnhancedInputValidation.modifiers
        let now=ProcessInfo.processInfo.systemUptime
        var consume=false
        switch type {
        case .keyDown:
            if IsSecureEventInputEnabled() {return false}
            let repeatKey=event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let replacement=replacements[code] {try? sendKey(replacement.0,down:true,pid:replacement.1);return true}
            if let r=matching(.keyReplacement,flags:flags,app:app).first(where:{$0.keyCode==code}) {
                guard AXIsProcessTrusted() else {report?("按键替换需要辅助功能权限。原始输入仍保留。");return false}
                do {try sendKey(r.effect,down:true,pid:pid);replacements[code]=(r.effect,pid);keys.insert(code);return true} catch {report?(error.localizedDescription);return false}
            }
            keys.insert(code)
            if repeatKey {
                if let rule=matching(.keyDown,flags:flags,app:app).first(where:{$0.keyCode==code && $0.allowKeyRepeat}) {executeLater(rule,pid:pid)}
                return consumedKeys.contains(code)
            }
            if let r=matching(.keyDown,flags:flags,app:app).first(where:{$0.keyCode==code}) {executeLater(r,pid:pid);consume=r.consume}
            if let r=matching(.keyHold,flags:flags,app:app).first(where:{$0.keyCode==code}) {scheduleHold(r,key:"k\(code)",pid:pid);consume = consume || r.consume}
            if let r=matching(.keyUp,flags:flags,app:app).first(where:{$0.keyCode==code}),r.consume {consume=true}
            if consume {consumedKeys.insert(code)}
        case .keyUp:
            keys.remove(code);timers.removeValue(forKey:"k\(code)")?.invalidate()
            consume=consumedKeys.remove(code) != nil
            if !IsSecureEventInputEnabled(),let r=matching(.keyUp,flags:flags,app:app).first(where:{$0.keyCode==code}) {executeLater(r,pid:pid);consume = consume || r.consume}
        case .flagsChanged:
            // Fn is a modifier in matching and also has key code 63 for explicit Fn down/up rules.
            let down=code==63 ? event.flags.contains(.maskSecondaryFn) : false
            if code==63 {
                let fnFlags=flags & ~UInt64(NSEvent.ModifierFlags.function.rawValue)
                if let r=matching(down ? .keyDown:.keyUp,flags:fnFlags,app:app).first(where:{$0.keyCode==63}) {executeLater(r,pid:pid);consume=r.consume}
                if down,let r=matching(.keyHold,flags:fnFlags,app:app).first(where:{$0.keyCode==63}) {scheduleHold(r,key:"fn",pid:pid)}
                if !down {timers.removeValue(forKey:"fn")?.invalidate()}
            }
            if drawing?.flags != flags {drawing=nil}
        case .leftMouseDown,.rightMouseDown,.otherMouseDown:
            let button=Int(event.getIntegerValueField(.mouseEventButtonNumber));buttons.insert(button)
            if let r=matching(.buttonDown,flags:flags,app:app).first(where:{buttonMatches($0,button)}) {executeLater(r,pid:pid);consume=r.consume}
            if let r=matching(.buttonHold,flags:flags,app:app).first(where:{buttonMatches($0,button)}) {scheduleHold(r,key:"b\(button)",pid:pid);consume = consume || r.consume}
            let drawRules=matching(.drawing,flags:flags,app:app).filter{buttonMatches($0,button)}
            if !drawRules.isEmpty {drawing=([event.location],drawRules,pid,flags,button);consume = consume || drawRules.contains(where: \.consume)}
            if matching(.buttonUp,flags:flags,app:app).contains(where:{buttonMatches($0,button) && $0.consume}) {consume=true}
            if consume {consumedButtons.insert(button)}
            if type == .leftMouseDown {receiveTouchClick(pid:pid,flags:flags,app:app)}
            if let r=matching(.screenEdge,flags:flags,app:app).first(where:{$0.direction=="click" && $0.button==button && Self.matchesEdge($0.corner,at:event.location,start:$0.edgeStart,end:$0.edgeEnd,width:$0.edgeWidth)}) {executeLater(r,pid:pid);consume = consume || r.consume}
        case .leftMouseUp,.rightMouseUp,.otherMouseUp:
            if type == .leftMouseUp {pressureLatched=false}
            let button=Int(event.getIntegerValueField(.mouseEventButtonNumber));timers.removeValue(forKey:"b\(button)")?.invalidate()
            if let r=matching(.buttonUp,flags:flags,app:app).first(where:{buttonMatches($0,button)}) {executeLater(r,pid:pid);consume=r.consume}
            if let d=drawing,d.button==button {
                defer {drawing=nil}
                if d.pid==pid,d.flags==flags {recognizeDrawing(d.points+[event.location],rules:d.rules,pid:pid)}
            }
            consume = consumedButtons.remove(button) != nil || consume;buttons.remove(button)
        case .leftMouseDragged,.rightMouseDragged,.otherMouseDragged:
            let button=Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if var d=drawing,d.button==button,d.pid==pid,d.flags==flags,d.points.count<2048 {
                if let last=d.points.last,hypot(event.location.x-last.x,event.location.y-last.y)>=2 {d.points.append(event.location);drawing=d}
            }
            consume=consumedButtons.contains(button)
        case .scrollWheel:
            let y=event.getDoubleValueField(.scrollWheelEventDeltaAxis1),x=event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            let direction=abs(y)>=abs(x) ? (y>=0 ? "up":"down"):(x>=0 ? "left":"right")
            if now-lastScrollFire>0.15,let r=matching(.screenEdge,flags:flags,app:app).first(where:{$0.direction=="scroll"+direction.prefix(1).uppercased()+direction.dropFirst() && Self.matchesEdge($0.corner,at:event.location,start:$0.edgeStart,end:$0.edgeEnd,width:$0.edgeWidth)}) {lastScrollFire=now;executeLater(r,pid:pid);consume=r.consume}
            if !consume,now-lastScrollFire>0.15,let r=matching(.scroll,flags:flags,app:app).first(where:{$0.direction==direction && Set($0.heldButtons).isSubset(of:buttons)}) {lastScrollFire=now;executeLater(r,pid:pid);consume=r.consume}
            if !consume {consume=transformScroll(event,pid:pid,app:app,flags:flags)}
        case .mouseMoved:
            updateHotCorner(point:event.location,pid:pid,flags:flags,app:app)
        default:break
        }
        return consume && AXIsProcessTrusted()
    }
    static func matchesEdge(_ name:String,at point:CGPoint,frames:[CGRect]?=nil,start:Double=0,end:Double=1,width:Double=8)->Bool {
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        let rectangles=frames ?? NSScreen.screens.map {WindowGeometry.accessibilityRect(fromAppKit:$0.frame,primaryTop:top)}
        return InputScreenEdgeGeometry.matches(name,point:point,frames:rectangles,start:start,end:end,width:width)
    }
    private func receivePressure(_ event:NSEvent) {
        observedPressureEvents += 1
        guard configuration.enabled,event.type == .pressure,let front=NSWorkspace.shared.frontmostApplication,!excludedApps.contains(front.bundleIdentifier ?? ""),!IsSecureEventInputEnabled() else{return}
        if event.stage==0 || event.pressure<0.05 {pressureLatched=false;return}
        guard !pressureLatched else{return}
        let rules=matching(.pressure,flags:UInt64(event.modifierFlags.rawValue),app:front.bundleIdentifier ?? "")
        guard let rule=rules.first(where:{event.stage >= $0.pressureStage && Double(event.pressure)>=$0.pressureThreshold}) else{return}
        pressureLatched=true;executeLater(rule,pid:front.processIdentifier)
    }
    private func recognizeDrawing(_ points:[CGPoint],rules:[EnhancedInputRule],pid:pid_t) {
        guard DrawingRecognition.length(points)>=40 else{return}
        let ranked=rules.map{($0,DrawingRecognition.distance(points,$0.drawing.map(\.point)))}.sorted{$0.1<$1.1}
        guard let best=ranked.first,best.1<best.0.recognitionThreshold else{return}
        // Ambiguous similar templates do not choose arbitrarily.
        if ranked.count>1,ranked[1].1-best.1<0.035 {report?("绘图与多个规则过于接近，未执行；请调整模板。");return}
        executeLater(best.0,pid:pid)
    }
    private func updateHotCorner(point:CGPoint,pid:pid_t,flags:UInt64,app:String) {
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        var found:String?
        for screen in NSScreen.screens {
            let f=WindowGeometry.accessibilityRect(fromAppKit:screen.frame,primaryTop:top)
            guard f.insetBy(dx:-1,dy:-1).contains(point) else{continue}
            if point.x<f.minX+8,point.y<f.minY+8 {found="topLeft"}
            if point.x>f.maxX-8,point.y<f.minY+8 {found="topRight"}
            if point.x<f.minX+8,point.y>f.maxY-8 {found="bottomLeft"}
            if point.x>f.maxX-8,point.y>f.maxY-8 {found="bottomRight"}
        }
        let identity=found.map{$0+"|\(flags)|\(pid)"}
        guard identity != corner else{return}
        timers.removeValue(forKey:"corner")?.invalidate();corner=identity
        if let found,let r=matching(.hotCorner,flags:flags,app:app).first(where:{$0.corner==found}) {scheduleHold(r,key:"corner",pid:pid)}
    }
    private func transformScroll(_ event:CGEvent,pid:pid_t,app:String,flags:UInt64)->Bool {
        guard AXIsProcessTrusted() else{return false}
        let precise=event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        guard let p=configuration.scrollProfiles.first(where:{$0.enabled && $0.deviceID == (precise ? "allPrecise":"allWheel") && !$0.excludedApps.contains(app) && ($0.bypassModifiers==0 || flags & $0.bypassModifiers == 0)}) else{return false}
        if p.smooth && !precise {
            let y=event.getDoubleValueField(.scrollWheelEventDeltaAxis1)*10,x=event.getDoubleValueField(.scrollWheelEventDeltaAxis2)*10
            if scrollTarget != pid {scrollRemaining = .zero};scrollTarget=pid;scrollDuration=p.smoothingDuration
            scrollRemaining.x += ScrollTransformation.delta(x,profile:p,horizontal:true)
            scrollRemaining.y += ScrollTransformation.delta(y,profile:p,horizontal:false)
            if smoothTimer==nil {
                smoothTimer=Timer.scheduledTimer(withTimeInterval:1/60,repeats:true) { [weak self] _ in MainActor.assumeIsolated{self?.smoothTick()} }
            }
            return true
        }
        for (field,horizontal) in [(CGEventField.scrollWheelEventDeltaAxis1,false),(.scrollWheelEventDeltaAxis2,true),(.scrollWheelEventFixedPtDeltaAxis1,false),(.scrollWheelEventFixedPtDeltaAxis2,true),(.scrollWheelEventPointDeltaAxis1,false),(.scrollWheelEventPointDeltaAxis2,true)] {
            event.setDoubleValueField(field,value:ScrollTransformation.delta(event.getDoubleValueField(field),profile:p,horizontal:horizontal))
        }
        return false
    }
    private func smoothTick() {
        guard let pid=scrollTarget,allowed(pid:pid),AXIsProcessTrusted() else {smoothTimer?.invalidate();smoothTimer=nil;scrollRemaining = .zero;return}
        let fraction=min(1,1/(60*max(0.04,scrollDuration)*0.3))
        let dx=abs(scrollRemaining.x)<1 ? scrollRemaining.x : scrollRemaining.x*fraction
        let dy=abs(scrollRemaining.y)<1 ? scrollRemaining.y : scrollRemaining.y*fraction
        let ix=Int32(dx.rounded()),iy=Int32(dy.rounded())
        scrollRemaining.x -= Double(ix);scrollRemaining.y -= Double(iy)
        if ix != 0 || iy != 0,let e=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:iy,wheel2:ix,wheel3:0) {e.setIntegerValueField(.eventSourceUserData,value:Self.syntheticTag);e.postToPid(pid)}
        if abs(scrollRemaining.x)<0.5,abs(scrollRemaining.y)<0.5 {smoothTimer?.invalidate();smoothTimer=nil;scrollRemaining = .zero}
    }
    private func executeRule(_ rule:EnhancedInputRule,pid:pid_t) {
        guard deliveryState.accept(id:rule.id,interval:rule.minimumIntervalSeconds,now:ProcessInfo.processInfo.systemUptime) else{return}
        execute(rule.effect,pid:pid)
    }
    private func executeLater(_ rule:EnhancedInputRule,pid:pid_t) {
        guard let launch=NSRunningApplication(processIdentifier:pid)?.launchDate else{return}
        DispatchQueue.main.async { [weak self] in
            guard let self,self.allowed(pid:pid),let app=NSRunningApplication(processIdentifier:pid),!app.isTerminated,
                  WindowProcessIdentity.matches(capturedPID:pid,capturedLaunchDate:launch,currentPID:app.processIdentifier,currentLaunchDate:app.launchDate) else{return}
            self.executeRule(rule,pid:pid)
        }
    }
    private func executeLater(_ effect:InputEffect,pid:pid_t) {
        guard let launch=NSRunningApplication(processIdentifier:pid)?.launchDate else{return}
        DispatchQueue.main.async { [weak self] in
            guard let self,self.allowed(pid:pid),let app=NSRunningApplication(processIdentifier:pid),!app.isTerminated,
                  WindowProcessIdentity.matches(capturedPID:pid,capturedLaunchDate:launch,currentPID:app.processIdentifier,currentLaunchDate:app.launchDate) else{return}
            self.execute(effect,pid:pid)
        }
    }
    private func execute(_ effect:InputEffect,pid:pid_t) {
        do {
            switch effect.kind {
            case .action:handler?(effect.actionID)
            case .shortcut:try sendKey(effect,down:true,pid:pid);try sendKey(effect,down:false,pid:pid)
            case .mouseClick:try sendMouseClick(effect.mouseButton,pid:pid)
            case .scroll:
                guard AXIsProcessTrusted(),let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:Int32(effect.scrollY),wheel2:Int32(effect.scrollX),wheel3:0) else {throw SystemControlError.message("模拟滚动需要辅助功能权限。")}
                event.setIntegerValueField(.eventSourceUserData,value:Self.syntheticTag);event.postToPid(pid)
            case .systemPreset:
                guard let preset=EnhancedSystemPreset(rawValue:effect.systemPreset) else {throw SystemControlError.message("未知系统动作。")};try EnhancedSystemControls.perform(preset)
            case .appleScript:try executeScript(effect.script)
            case .menuItem:try InputMenuAction.perform(path:effect.menuPath,bundleID:effect.menuBundleID,pid:pid)
            }
        } catch {report?(error.localizedDescription)}
    }
    private func sendMouseClick(_ button:Int,pid:pid_t)throws {
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled(),NSRunningApplication(processIdentifier:pid)?.isTerminated == false,let point=CGEvent(source:nil)?.location else {throw SystemControlError.message("模拟鼠标需要辅助功能权限和有效目标。")}
        let cgButton=CGMouseButton(rawValue:UInt32(button)) ?? .center
        let types:[CGEventType]=button==0 ? [.leftMouseDown,.leftMouseUp]:button==1 ? [.rightMouseDown,.rightMouseUp]:[.otherMouseDown,.otherMouseUp]
        for type in types {guard let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:cgButton) else {throw SystemControlError.message("不能生成鼠标事件。")};event.setIntegerValueField(.eventSourceUserData,value:Self.syntheticTag);event.postToPid(pid)}
    }
    private func sendKey(_ effect:InputEffect,down:Bool,pid:pid_t)throws {
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled() else{throw SystemControlError.message("模拟按键需要辅助功能权限，且不能在安全输入状态使用。")}
        guard NSRunningApplication(processIdentifier:pid)?.isTerminated == false,let event=CGEvent(keyboardEventSource:nil,virtualKey:effect.keyCode,keyDown:down) else{throw SystemControlError.message("无法发送按键，目标应用可能已退出。")}
        event.flags=CGEventFlags(rawValue:effect.modifiers & EnhancedInputValidation.modifiers)
        event.setIntegerValueField(.eventSourceUserData,value:Self.syntheticTag);event.postToPid(pid)
    }
    private func executeScript(_ script:String)throws {
        guard activeScript == nil else{throw SystemControlError.message("上一个输入脚本仍在执行，请等待或暂停输入以停止它。")}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");process.arguments=["-e",script]
        // No shell expansion, no command logging, bounded output. osascript triggers Automation only as needed.
        let pipe=Pipe();process.standardError=pipe;process.standardOutput=FileHandle.nullDevice
        let output=BoundedInputScriptOutput()
        pipe.fileHandleForReading.readabilityHandler={ handle in
            output.append(handle.availableData)
        }
        process.terminationHandler={ [weak self] p in
            pipe.fileHandleForReading.readabilityHandler=nil
            let message=output.message
            DispatchQueue.main.async {guard let self else{return};if self.activeScript===p {self.activeScript=nil};if p.terminationStatus != 0 {self.report?("脚本执行失败："+message.prefix(500))}}
        }
        try process.run();activeScript=process
        DispatchQueue.main.asyncAfter(deadline:.now()+15) { [weak self,weak process] in
            guard let process,process.isRunning else{return};process.terminate();self?.report?("脚本运行超过 15 秒，已发送停止请求。")
        }
    }
    private func receiveHIDButton(_ observation:HIDButtonObservation) {
        guard configuration.enabled,let front=NSWorkspace.shared.frontmostApplication,!excludedApps.contains(front.bundleIdentifier ?? ""),!IsSecureEventInputEnabled() else{return}
        let app=front.bundleIdentifier ?? ""
        let mappings=configuration.hidProfiles.filter{$0.enabled && $0.deviceID==observation.deviceID}.flatMap(\.buttons).filter{$0.enabled && $0.usage==observation.usage && $0.whenReleased != observation.pressed && ($0.appBundleID.isEmpty || $0.appBundleID==app) && !$0.excludedApps.contains(app)}.sorted{!$0.appBundleID.isEmpty && $1.appBundleID.isEmpty}
        if let first=mappings.first {executeLater(first.effect,pid:front.processIdentifier)}
    }
    private func receiveTouch(_ frame:RawTouchFrame) {
        guard configuration.enabled,let app=NSWorkspace.shared.frontmostApplication,!excludedApps.contains(app.bundleIdentifier ?? ""),!IsSecureEventInputEnabled() else{finishTouchDrag();touchSession.removeAll();return}
        let pid=app.processIdentifier
        if frame.contacts.isEmpty {
            if touchDrag?.device==frame.deviceID {finishTouchDrag()}
            guard let sequence=touchSession.removeValue(forKey:frame.deviceID),sequence.pid==pid else{return}
            evaluateTouch(sequence,device:frame.deviceID,app:app.bundleIdentifier ?? "",ended:frame.timestamp)
        } else {
            var sequence=touchSession[frame.deviceID] ?? TouchSequence(pid:pid,start:frame.timestamp,contacts:frame.contacts)
            guard sequence.pid==pid else{touchSession[frame.deviceID]=nil;return}
            if frame.contacts.count<sequence.current.count,sequence.isTipTap(remaining:frame.contacts,ended:frame.timestamp) {
                let flags=UInt64(NSEvent.modifierFlags.rawValue)&EnhancedInputValidation.modifiers
                if let rule=matching(.touch,flags:flags,app:app.bundleIdentifier ?? "").first(where:{$0.touchGesture=="tipTap" && $0.fingers==sequence.maxFingers && ($0.touchDevice=="any" || $0.touchDevice==frame.deviceID) && sequence.matches(region:$0.touchRegion)}) {executeLater(rule,pid:pid);sequence=TouchSequence(pid:pid,start:frame.timestamp,contacts:frame.contacts);sequence.hadClick=true}
            }
            sequence.update(frame.contacts,timestamp:frame.timestamp);touchSession[frame.deviceID]=sequence
            updateTouchDrag(frame,pid:pid,app:app.bundleIdentifier ?? "")
        }
    }
    private func updateTouchDrag(_ frame:RawTouchFrame,pid:pid_t,app:String) {
        let flags=UInt64(NSEvent.modifierFlags.rawValue)&EnhancedInputValidation.modifiers
        if let active=touchDrag {
            guard active.device==frame.deviceID else{return}
            guard active.pid==pid,let rule=configuration.rules.first(where:{$0.id==active.ruleID}),rule.enabled,rule.modifiers&EnhancedInputValidation.modifiers==flags,frame.contacts.count==rule.fingers else{finishTouchDrag();return}
            let point=TouchSequence.center(frame.contacts)
            let screen=NSScreen.screens.first?.frame ?? CGRect(x:0,y:0,width:1400,height:900)
            var destination=CGPoint(x:active.pointer.x+(point.x-active.origin.x)*screen.width,y:active.pointer.y-(point.y-active.origin.y)*screen.height)
            let top=NSScreen.screens.first?.frame.maxY ?? 0
            let screens=NSScreen.screens.map {WindowGeometry.accessibilityRect(fromAppKit:$0.frame,primaryTop:top)}
            if let index=WindowGeometry.screenIndex(for:CGRect(x:destination.x,y:destination.y,width:1,height:1),in:screens) {let f=screens[index];destination.x=min(f.maxX-1,max(f.minX,destination.x));destination.y=min(f.maxY-1,max(f.minY,destination.y))}
            do {try postMiddle(type:.otherMouseDragged,point:destination,pid:pid);CGWarpMouseCursorPosition(destination)} catch {finishTouchDrag();report?(error.localizedDescription)}
            return
        }
        guard AXIsProcessTrusted(),let pointer=CGEvent(source:nil)?.location,let sequence=touchSession[frame.deviceID],let rule=matching(.touch,flags:flags,app:app).first(where:{$0.touchGesture=="middleDrag" && $0.fingers==frame.contacts.count && ($0.touchDevice=="any" || $0.touchDevice==frame.deviceID) && sequence.matches(region:$0.touchRegion)}) else{return}
        do {try postMiddle(type:.otherMouseDown,point:pointer,pid:pid);touchDrag=(frame.deviceID,pid,TouchSequence.center(frame.contacts),pointer,rule.id);touchSession[frame.deviceID]?.hadClick=true} catch {report?(error.localizedDescription)}
    }
    private func finishTouchDrag() {
        guard let active=touchDrag else{return};touchDrag=nil
        if let event=CGEvent(mouseEventSource:nil,mouseType:.otherMouseUp,mouseCursorPosition:CGEvent(source:nil)?.location ?? active.pointer,mouseButton:.center) {event.setIntegerValueField(.eventSourceUserData,value:Self.syntheticTag);event.postToPid(active.pid)}
    }
    private func postMiddle(type:CGEventType,point:CGPoint,pid:pid_t)throws {
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled(),allowed(pid:pid),let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.center) else{throw SystemControlError.message("中键拖移的目标或辅助功能权限已失效。")}
        event.setIntegerValueField(.eventSourceUserData,value:Self.syntheticTag);event.postToPid(pid)
    }
    private func receiveTouchClick(pid:pid_t,flags:UInt64,app:String) {
        for (device,s) in touchSession where s.pid==pid {
            touchSession[device]?.hadClick=true
            if let r=matching(.touch,flags:flags,app:app).first(where:{$0.touchGesture=="click" && $0.fingers==s.maxFingers && ($0.touchDevice=="any" || $0.touchDevice==device) && s.matches(region:$0.touchRegion) && (!$0.thumbAtBottom || s.hasBottomAnchor)}) {executeLater(r,pid:pid)}
        }
    }
    private func evaluateTouch(_ s:TouchSequence,device:String,app:String,ended:Double) {
        let flags=UInt64(NSEvent.modifierFlags.rawValue)&EnhancedInputValidation.modifiers
        let candidates=matching(.touch,flags:flags,app:app).filter{$0.fingers==s.maxFingers && ($0.touchDevice=="any" || $0.touchDevice==device) && s.matches(region:$0.touchRegion) && (!$0.thumbAtBottom || s.hasBottomAnchor)}
        guard !candidates.isEmpty,ended-s.start<10 else{return}
        let displacement=s.displacement
        var matched:[EnhancedInputRule]=[]
        for r in candidates {
            switch r.touchGesture {
            case "tap":if !s.hadClick && ended-s.start<0.3 && s.travel<0.045 {matched.append(r)}
            case "doubleTap":if !s.hadClick,ended-s.start<0.3,s.travel<0.045,let last=lastTouchTap,last.device==device,last.fingers==s.maxFingers,ended-last.time<0.4 {matched.append(r)}
            case "swipe":if hypot(displacement.x,displacement.y)>0.13,InputRules.direction(from:.zero,to:CGPoint(x:displacement.x*1000,y:-displacement.y*1000),threshold:100)==r.direction {matched.append(r)}
            case "pinchIn":if s.spreadChange < -0.1 {matched.append(r)}
            case "pinchOut":if s.spreadChange > 0.1 {matched.append(r)}
            case "rotateLeft":if s.rotation > 0.35 {matched.append(r)}
            case "rotateRight":if s.rotation < -0.35 {matched.append(r)}
            case "drawing":if s.travel>0.15,DrawingRecognition.distance(s.path.map{CGPoint(x:$0.x*1000,y:-$0.y*1000)},r.drawing.map(\.point))<r.recognitionThreshold {matched.append(r)}
            default:break
            }
        }
        if ended-s.start<0.3,s.travel<0.045 {lastTouchTap=(device,s.maxFingers,ended)}
        if let double=matched.first(where:{$0.touchGesture=="doubleTap"}) {timers.removeValue(forKey:"tap-"+device)?.invalidate();executeLater(double,pid:s.pid);return}
        if let tap=matched.first(where:{$0.touchGesture=="tap"}),candidates.contains(where:{$0.touchGesture=="doubleTap"}) {
            timers["tap-"+device]?.invalidate();timers["tap-"+device]=Timer.scheduledTimer(withTimeInterval:0.4,repeats:false) { [weak self] _ in MainActor.assumeIsolated {guard let self,self.allowed(pid:s.pid) else{return};self.executeLater(tap,pid:s.pid);self.timers["tap-"+device]=nil} };return
        }
        // A scoped rule overrides an otherwise identical global rule. Different interpretations remain ambiguous.
        if let first=matched.first {if matched.dropFirst().contains(where:{$0.touchGesture != first.touchGesture}) {report?("触控动作匹配多个解释，未执行。")} else {executeLater(first,pid:s.pid)}}
    }
}

private final class BoundedInputScriptOutput:@unchecked Sendable {
    private let lock=NSLock();private var data=Data()
    func append(_ value:Data) {lock.lock();defer{lock.unlock()};if data.count<4096 {data.append(value.prefix(4096-data.count))}}
    var message:String {lock.lock();defer{lock.unlock()};return String(data:data,encoding:.utf8) ?? ""}
}
