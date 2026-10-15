import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct InputEnhancementSettingsView:View {
    @Binding var configuration:InputEnhancementConfiguration
    let actions:[InputActionChoice]
    var status:String=""
    var devices:[String]=[]
    @State private var message:String?
    var body:some View {
        Form {
            Section("高级输入") {
                Toggle("启用高级规则与滚轮调校",isOn:$configuration.enabled)
                Toggle("启用实验原始多点触控",isOn:$configuration.experimentalRawTouch)
                Text("原始触点使用系统未公开接口，默认关闭；若系统变更或数据不符会停止。它不能阻止系统原有触控手势。压力使用系统 pressure/stage 事件，须在实际目标应用测试投递。") .font(.caption).foregroundStyle(.secondary)
                if !status.isEmpty {Text(L10n.text(status)).font(.caption)}
                ForEach(devices,id:\.self) {Text($0).font(.caption.monospaced())}
                HStack {
                    Button("添加规则") {configuration.rules.append(EnhancedInputRule())}
                    Menu("添加入门规则") {
                        Button("⌥方向键分屏（暂停状态）") {configuration.rules.append(contentsOf:EnhancedRuleFiles.beginnerRules())}
                        Button("Fn 单指绘图示例（暂停状态）") {configuration.rules.append(EnhancedRuleFiles.drawingExample())}
                    }
                    Button("导入规则/脚本") {importRules()}
                    Button("导出规则/脚本") {exportRules()}
                }
                if let message {Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            }
            Section("规则") {
                if configuration.rules.isEmpty {Text("添加规则后选择触发方式和动作；新规则默认暂停。").foregroundStyle(.secondary)}
                ForEach($configuration.rules) { $rule in
                    DisclosureGroup {
                        EnhancedInputRuleEditor(rule:$rule,actions:actions,devices:devices,scripts:configuration.scriptLibrary)
                        HStack {
                            Button("复制规则") {var copy=rule;copy.id=UUID();copy.name += " 副本";copy.enabled=false;copy.migrationOrigin=nil;configuration.rules.append(copy)}
                            Button("删除规则",role:.destructive) {configuration.rules.removeAll{$0.id==rule.id}}
                        }
                    } label: {HStack {Toggle("",isOn:$rule.enabled).labelsHidden().disabled(EnhancedInputValidation.migrationBlockReason(rule) != nil);Text(rule.name);Spacer();Text(L10n.text(rule.trigger.title)).foregroundStyle(.secondary)}}
                }
            }
            if !configuration.migrationSources.isEmpty {
                Section("原输入规则迁移审计") {
                    Text("全部来源规则均保留。精确转换只表示语义已核对；未通过设备或动作验收的规则继续暂停。").font(.caption).foregroundStyle(.secondary)
                    ForEach(configuration.migrationSources) {source in
                        DisclosureGroup(String(format:L10n.text("来源规则 %d 条"),source.rows.count)) {
                            ForEach(source.rows) {row in
                                VStack(alignment:.leading,spacing:4) {
                                    HStack {Text(row.module+" · "+String(row.groupIndex+1)+"/"+String(row.rowIndex+1)).font(.caption.monospaced());Spacer();Text(L10n.text(migrationTitle(row.disposition))).font(.caption).foregroundStyle(row.disposition == .exact ? Color.secondary : Color.orange)}
                                    Text(row.reason).font(.caption).textSelection(.enabled)
                                }.padding(.vertical,3)
                            }
                        }
                    }
                }
            }
            Section("滚轮") {
                ForEach($configuration.scrollProfiles) { $profile in
                    DisclosureGroup {
                        TextField("名称",text:$profile.name)
                        Picker("输入类型",selection:$profile.deviceID) {Text("普通鼠标滚轮").tag("allWheel");Text("触控板连续滚动").tag("allPrecise")}
                        Toggle("水平反向",isOn:$profile.reverseX);Toggle("垂直反向",isOn:$profile.reverseY)
                        LabeledContent("速度") {Slider(value:$profile.speed,in:0.1...8);Text(profile.speed,format:.number.precision(.fractionLength(2))).monospacedDigit()}
                        LabeledContent("加速度") {Slider(value:$profile.acceleration,in:0...3);Text(profile.acceleration,format:.number.precision(.fractionLength(2))).monospacedDigit()}
                        Toggle("普通鼠标滚轮平滑",isOn:$profile.smooth)
                        if profile.smooth {LabeledContent("平滑时长") {Slider(value:$profile.smoothingDuration,in:0.04...0.8);Text("\(Int(profile.smoothingDuration*1000)) ms")}}
                        ModifierSelection(value:$profile.bypassModifiers,title:"按住时临时绕过")
                        AppExclusionEditor(values:$profile.excludedApps)
                        Text("CGEvent 没有可靠的物理鼠标编号；这里按普通滚轮/连续滚动分类，不声称逐型号硬件驱动或跟踪速度适配。").font(.caption).foregroundStyle(.secondary)
                        Button("删除滚轮配置",role:.destructive){configuration.scrollProfiles.removeAll{$0.id==profile.id}}
                    } label:{Toggle(profile.name,isOn:$profile.enabled)}
                }
                Button("添加滚轮配置") {configuration.scrollProfiles.append(ScrollDeviceProfile())}
            }
            Section("脚本库") {
                ForEach($configuration.scriptLibrary) { $script in
                    DisclosureGroup(script.name) {
                        TextField("脚本名称",text:$script.name)
                        TextEditor(text:$script.source).font(.system(.body,design:.monospaced)).frame(minHeight:100)
                        Button("删除脚本",role:.destructive){configuration.scriptLibrary.removeAll{$0.id==script.id}}
                    }
                }
                Button("添加 AppleScript") {configuration.scriptLibrary.append(InputScript())}
                Text("脚本按绑定运行，最长15秒；系统自动化授权由目标应用按需请求。导入的脚本默认不执行，请先审阅。").font(.caption).foregroundStyle(.secondary)
            }
            Section("文件夹同步") {
                TextField("同步目录",text:$configuration.syncFolder)
                HStack {
                    Button("选择 iCloud Drive 或其他同步文件夹") {let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;if panel.runModal() == .OK,let url=panel.url {configuration.syncFolder=url.path}}
                    Button("写入同步副本") {writeSync()}.disabled(configuration.syncFolder.isEmpty)
                    Button("读取同步副本") {readSync()}.disabled(configuration.syncFolder.isEmpty)
                }
                Text("同步副本由所选文件夹的云服务传输。读取采用合并并保持新规则暂停；不会静默覆盖本机规则。此处不等同于 BAB 私有云服务或无损格式兼容。").font(.caption).foregroundStyle(.secondary)
            }
            Section("HID 鼠标设备") {HIDDeviceConfigurationView(profiles:$configuration.hidProfiles,actions:actions)}
            Section("设备实测") {InputDeviceTestView()}
        }.formStyle(.grouped)
    }
    private func importRules() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json,.propertyList];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {let result=try EnhancedRuleFiles.read(url);message=try merge(result.configuration) ?? result.note} catch {message=error.localizedDescription}
    }
    private func exportRules() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="搞操作输入规则.json"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try EnhancedRuleFiles.write(configuration,to:url);message="已导出规则与脚本。"} catch {message=error.localizedDescription}
    }
    private func merge(_ value:InputEnhancementConfiguration) throws -> String? {
        let result=try EnhancedRuleFiles.mergeInputConfiguration(value,into:configuration)
        configuration=result.configuration
        return result.note
    }
    private func migrationTitle(_ value:InputMigrationDisposition)->String {
        switch value {case .exact:return "精确转换";case .requiresReview:return "待语义或设备核验";case .unavailable:return "保真保留，尚未转换";case .preservedUserChange:return "保留用户修改"}
    }
    private func syncURL()throws->URL {
        let directory=URL(fileURLWithPath:configuration.syncFolder,isDirectory:true)
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:directory.path,isDirectory:&isDirectory),isDirectory.boolValue else{throw SystemControlError.message("同步目录不存在或无法读取，请重新选择。")}
        return directory.appendingPathComponent("搞操作输入规则.json")
    }
    private func writeSync() {do {let url=try syncURL();if FileManager.default.fileExists(atPath:url.path) {let old=try Data(contentsOf:url);let backup=url.deletingLastPathComponent().appendingPathComponent("搞操作输入规则-备份-"+UUID().uuidString+".json");try old.write(to:backup,options:.withoutOverwriting)};try EnhancedRuleFiles.write(configuration,to:url);message="同步副本已写入；原有副本已备份。"} catch {message=error.localizedDescription}}
    private func readSync() {do {let result=try EnhancedRuleFiles.read(syncURL());message=try merge(result.configuration) ?? result.note} catch {message=error.localizedDescription}}
}

@MainActor private struct EnhancedInputRuleEditor:View {
    @Binding var rule:EnhancedInputRule
    let actions:[InputActionChoice];let devices:[String];let scripts:[InputScript]
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            TextField("规则名称",text:$rule.name)
            if let origin=rule.migrationOrigin {
                Text(origin.reason).font(.caption).foregroundStyle(.secondary)
                if let reason=EnhancedInputValidation.migrationBlockReason(rule) {Text(reason).font(.caption).foregroundStyle(.orange)}
            }
            Picker("触发方式",selection:$rule.trigger) {ForEach(EnhancedInputTrigger.allCases) {Text(L10n.text($0.title)).tag($0)}}
            TextField("限定应用 Bundle ID（空白为所有应用）",text:$rule.appBundleID)
            AppExclusionEditor(values:$rule.excludedApps)
            ModifierSelection(value:$rule.modifiers,title:"触发修饰键")
            if [.keyDown,.keyUp,.keyHold,.keyReplacement].contains(rule.trigger) {
                HStack {InputKeyRecorder(code:$rule.keyCode,modifiers:$rule.modifiers);TextField("键码",value:$rule.keyCode,format:.number).frame(width:75);Button("Fn") {rule.keyCode=63;rule.modifiers=0}}
            }
            if [.buttonDown,.buttonUp,.buttonHold,.drawing,.screenEdge].contains(rule.trigger) {Stepper("鼠标按钮：\(rule.button)（左0/右1/中2）",value:$rule.button,in:0...31)}
            if [.buttonDown,.buttonUp,.buttonHold,.scroll,.drawing].contains(rule.trigger) {
                TextField("组合按住按钮（逗号分隔）",text:Binding(get:{rule.heldButtons.map(String.init).joined(separator:",")},set:{rule.heldButtons=$0.split(separator:",").compactMap{Int($0.trimmingCharacters(in:.whitespaces))}}))
            }
            if rule.trigger == .keyDown {Toggle("允许系统按键自动重复",isOn:$rule.allowKeyRepeat)}
            TextField("规则最短执行间隔（秒，0为不节流）",value:$rule.minimumIntervalSeconds,format:.number)
            if [.keyHold,.buttonHold,.hotCorner].contains(rule.trigger) {LabeledContent("长按/停留秒数") {Slider(value:$rule.holdSeconds,in:0.2...3);Text(rule.holdSeconds,format:.number.precision(.fractionLength(1)))}}
            if [.hotCorner,.screenEdge].contains(rule.trigger) {Picker("屏幕边角",selection:$rule.corner) {Text("左上角").tag("topLeft");Text("右上角").tag("topRight");Text("左下角").tag("bottomLeft");Text("右下角").tag("bottomRight");if rule.trigger == .screenEdge {Text("左边").tag("left");Text("右边").tag("right");Text("上边").tag("top");Text("下边").tag("bottom")}}}
            if rule.trigger == .screenEdge {
                HStack {TextField("边段起点(0–1)",value:$rule.edgeStart,format:.number);TextField("终点(0–1)",value:$rule.edgeEnd,format:.number);TextField("边缘宽度(pt)",value:$rule.edgeWidth,format:.number)}
                Text("左右边从上到下、上下边从左到右；例如0.33–0.67限定中间段。相邻段只触发其中一个；角落使用宽度范围。").font(.caption).foregroundStyle(.secondary)
            }
            if rule.trigger == .screenEdge {Picker("触发",selection:$rule.direction) {Text("点击").tag("click");Text("向上滚动").tag("scrollUp");Text("向下滚动").tag("scrollDown");Text("向左滚动").tag("scrollLeft");Text("向右滚动").tag("scrollRight")}}
            if rule.trigger == .scroll || rule.trigger == .touch && rule.touchGesture == "swipe" {Picker("方向",selection:$rule.direction){Text("上").tag("up");Text("下").tag("down");Text("左").tag("left");Text("右").tag("right")}}
            if rule.trigger == .touch {
                Picker("设备",selection:$rule.touchDevice) {Text("任意触控设备").tag("any");ForEach(devices,id:\.self) {name in Text(name).tag(name.components(separatedBy:" · ").last ?? name)};if rule.touchDevice != "any",!devices.contains(where:{$0.hasSuffix(rule.touchDevice)}) {Text("原设备："+rule.touchDevice).tag(rule.touchDevice)}}
                Stepper("手指数：\(rule.fingers)",value:$rule.fingers,in:1...5)
                Picker("触控手势",selection:$rule.touchGesture) {Text("轻点").tag("tap");Text("双拍").tag("doubleTap");Text("点按").tag("click");Text("滑动").tag("swipe");Text("捏合").tag("pinchIn");Text("张开").tag("pinchOut");Text("左旋转").tag("rotateLeft");Text("右旋转").tag("rotateRight");Text("自由绘图").tag("drawing");Text("锚指＋其他指轻拍 TipTap").tag("tipTap");Text("模拟中键拖移").tag("middleDrag")}
                Picker("起始区域",selection:$rule.touchRegion) {ForEach(["any","left","right","top","bottom","topLeft","topRight","bottomLeft","bottomRight"],id:\.self){Text(["any":"任意","left":"左侧","right":"右侧","top":"顶边","bottom":"底边","topLeft":"左上","topRight":"右上","bottomLeft":"左下","bottomRight":"右下"][$0]!).tag($0)}}
                Toggle("需要另一个触点停留底边（拇指锚点）",isOn:$rule.thumbAtBottom)
                Text("设备编号仅在当前监听会话内有效；断接后需重选。多指系统手势仍会同时生效。Magic Mouse 与其他外置设备需分别实测。").font(.caption).foregroundStyle(.secondary)
            }
            if rule.trigger == .pressure {Stepper("压力阶段：\(rule.pressureStage)",value:$rule.pressureStage,in:1...2);LabeledContent("阶段内压力阈值") {Slider(value:$rule.pressureThreshold,in:0.05...1);Text(rule.pressureThreshold,format:.number.precision(.fractionLength(2)))};Text("压力事件由目标应用/系统决定是否投递，全局可用性须实际验收。").font(.caption).foregroundStyle(.secondary)}
            if rule.trigger == .drawing || rule.trigger == .touch && rule.touchGesture == "drawing" {GestureDrawingPad(points:$rule.drawing).frame(height:160).background(.quaternary,in:RoundedRectangle(cornerRadius:8));Button("清空轨迹"){rule.drawing=[]};LabeledContent("识别容差") {Slider(value:$rule.recognitionThreshold,in:0.05...0.5)}}
            if ![.touch,.pressure,.hotCorner].contains(rule.trigger) {Toggle("阻止原始输入（需辅助功能权限）",isOn:$rule.consume)}
            if rule.trigger == .touch && rule.touchGesture == "middleDrag" {Text("这个触控手势直接发送中键按下、拖动和松开；需要辅助功能权限，建议设置Fn条件避免与系统滚动重叠。").font(.caption).foregroundStyle(.secondary)} else {
            Picker("执行",selection:$rule.effect.kind){ForEach(InputEffectKind.allCases){Text(L10n.text($0.title)).tag($0)}}
            switch rule.effect.kind {
            case .action:
                Picker("动作",selection:$rule.effect.actionID){ForEach(actions){Text($0.title).tag($0.id)}}
                if rule.effect.actionID.hasPrefix("window.") {
                    Picker("窗口目标",selection:$rule.effect.windowTargetMode) {Text("跟随窗口设置").tag(InputWindowTargetMode.inheritSettings);Text("前台窗口").tag(InputWindowTargetMode.frontmost);Text("鼠标指向窗口").tag(InputWindowTargetMode.underPointer)}
                }
            case .shortcut:InputKeyRecorder(code:$rule.effect.keyCode,modifiers:$rule.effect.modifiers);ModifierSelection(value:$rule.effect.modifiers,title:"输出修饰键")
            case .mouseClick:Stepper("输出鼠标按钮：\(rule.effect.mouseButton)",value:$rule.effect.mouseButton,in:0...31);ModifierSelection(value:$rule.effect.mouseModifiers,title:"输出修饰键")
            case .scroll:HStack {TextField("水平像素",value:$rule.effect.scrollX,format:.number);TextField("垂直像素",value:$rule.effect.scrollY,format:.number)}
            case .systemPreset:Picker("系统控制",selection:$rule.effect.systemPreset){ForEach(EnhancedSystemPreset.allCases){Text(L10n.text($0.title)).tag($0.rawValue)}};Text("媒体/亮度控制取决于硬件和前台播放器；系统桌面动作使用你的实际系统快捷键。").font(.caption).foregroundStyle(.secondary)
            case .menuItem:InputMenuSelectionView(bundleID:$rule.effect.menuBundleID,path:$rule.effect.menuPath,evidence:$rule.effect.menuEvidence)
            case .appleScript:
                Menu("从脚本库复制") {ForEach(scripts) {script in Button(script.name){rule.effect.script=script.source}}}
                TextEditor(text:$rule.effect.script).font(.system(.body,design:.monospaced)).frame(minHeight:100)
            case .openTargets:
                TextField("每行一个绝对路径或 HTTP(S) 网址",text:Binding(get:{rule.effect.openTargets.joined(separator:"\n")},set:{rule.effect.openTargets=$0.components(separatedBy:.newlines).filter{!$0.isEmpty}}),axis:.vertical).lineLimit(3...8)
            }
            }
            if let error=EnhancedInputValidation.error(rule) {Text(L10n.text(error)).font(.caption).foregroundStyle(.orange)}
        }.padding(.vertical,8)
        .onChange(of:rule.trigger) {_,value in if value == .screenEdge {rule.direction="click"};if [.touch,.pressure,.hotCorner].contains(value) {rule.consume=false}}
    }
}
@MainActor private struct ModifierSelection:View {
    @Binding var value:UInt64;var title:String
    var body:some View {HStack {Text(L10n.text(title));ForEach([("⌘",NSEvent.ModifierFlags.command),("⌃",.control),("⌥",.option),("⇧",.shift),("Fn",.function)],id:\.0){label,flag in Toggle(label,isOn:Binding(get:{value & UInt64(flag.rawValue) != 0},set:{if $0 {value |= UInt64(flag.rawValue)} else {value &= ~UInt64(flag.rawValue)}})).toggleStyle(.button)}}}
}
@MainActor private struct AppExclusionEditor:View {
    @Binding var values:[String]
    var body:some View {TextField("排除应用 Bundle ID（逗号分隔）",text:Binding(get:{values.joined(separator:",")},set:{values=$0.split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}}))}
}
@MainActor private struct InputKeyRecorder:NSViewRepresentable {
    @Binding var code:UInt16;@Binding var modifiers:UInt64
    func makeNSView(context:Context)->KeyRecorderView {let v=KeyRecorderView();v.onChange={code=$0;modifiers=$1};return v}
    func updateNSView(_ v:KeyRecorderView,context:Context){v.label=InputBinding.keyLabel(code);v.onChange={code=$0;modifiers=$1}}
}
private final class KeyRecorderView:NSView {
    var label="点击后按快捷键" {didSet{needsDisplay=true}};var recording=false;var onChange:((UInt16,UInt64)->Void)?
    override var acceptsFirstResponder:Bool {true}
    override var intrinsicContentSize:NSSize {NSSize(width:160,height:28)}
    override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);recording=true;needsDisplay=true}
    override func keyDown(with event:NSEvent){guard recording else{return};onChange?(event.keyCode,UInt64(event.modifierFlags.rawValue)&EnhancedInputValidation.modifiers);recording=false;needsDisplay=true}
    override func flagsChanged(with event:NSEvent){if recording,event.keyCode==63,event.modifierFlags.contains(.function){onChange?(63,0);recording=false;needsDisplay=true}}
    override func draw(_ dirtyRect:NSRect){NSColor.controlBackgroundColor.setFill();NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill();(recording ? "请按快捷键…":label+" · 点击录制").draw(in:bounds.insetBy(dx:8,dy:5),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.labelColor])}
}
@MainActor private struct GestureDrawingPad:NSViewRepresentable {
    @Binding var points:[GesturePoint]
    func makeNSView(context:Context)->DrawingPadView {let v=DrawingPadView();v.onChange={points=$0.map(GesturePoint.init)};return v}
    func updateNSView(_ v:DrawingPadView,context:Context){v.points=points.map(\.point);v.onChange={points=$0.map(GesturePoint.init)}}
}
private final class DrawingPadView:NSView {
    var points:[CGPoint]=[] {didSet{needsDisplay=true}};var onChange:(([CGPoint])->Void)?
    override var isFlipped:Bool {true}
    override func mouseDown(with event:NSEvent){points=[convert(event.locationInWindow,from:nil)]}
    override func mouseDragged(with event:NSEvent){if points.count<2048 {points.append(convert(event.locationInWindow,from:nil))}}
    override func mouseUp(with event:NSEvent){points.append(convert(event.locationInWindow,from:nil));onChange?(points)}
    override func draw(_ dirtyRect:NSRect){guard let first=points.first else {"按住鼠标或触控板绘制单笔轨迹".draw(at:CGPoint(x:12,y:12),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.secondaryLabelColor]);return};let path=NSBezierPath();path.move(to:first);for p in points.dropFirst(){path.line(to:p)};NSColor.controlAccentColor.setStroke();path.lineWidth=3;path.stroke()}
}
@MainActor struct InputDeviceTestView:View {
    @State private var observation="将光标移入下方，再轻点、滑动或按压触控板。这里只测量实际传感器输入，不代替其他应用中的全局触发验收。"
    var body:some View {VStack(alignment:.leading){Text(observation).font(.caption.monospaced());TouchTestPad(onObservation:{observation=$0}).frame(height:150).background(.quaternary,in:RoundedRectangle(cornerRadius:8))}}
}
@MainActor private struct TouchTestPad:NSViewRepresentable {
    let onObservation:(String)->Void
    func makeNSView(context:Context)->TouchTestView {let v=TouchTestView();v.onObservation=onObservation;return v}
    func updateNSView(_ v:TouchTestView,context:Context){v.onObservation=onObservation}
}
private final class TouchTestView:NSView {
    var onObservation:((String)->Void)?;var samples=0;var maxFingers=0
    override init(frame:NSRect){super.init(frame:frame);wantsRestingTouches=true;allowedTouchTypes=[.indirect]}
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override var acceptsFirstResponder:Bool {true}
    override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self)}
    override func touchesBegan(with event:NSEvent){show(event)}
    override func touchesMoved(with event:NSEvent){show(event)}
    override func touchesEnded(with event:NSEvent){show(event)}
    override func touchesCancelled(with event:NSEvent){show(event)}
    private func show(_ event:NSEvent){let contacts=event.touches(matching:.touching,in:self);samples+=1;maxFingers=max(maxFingers,contacts.count);onObservation?("公开局部触控样本 \(samples) · 当前 \(contacts.count) 指 · 最多 \(maxFingers) 指\n"+contacts.map{String(format:"(%.2f, %.2f)",$0.normalizedPosition.x,$0.normalizedPosition.y)}.sorted().joined(separator:" "))}
    override func pressureChange(with event:NSEvent){samples+=1;onObservation?(String(format:"真实压力样本 %d · stage %d · pressure %.3f · transition %.3f",samples,event.stage,event.pressure,event.stageTransition))}
    override func draw(_ dirtyRect:NSRect){"触控板 / 压力实测区域".draw(at:CGPoint(x:12,y:12),withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.secondaryLabelColor])}
}
