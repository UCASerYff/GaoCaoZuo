import AppKit
import SwiftUI

struct WindowEnhancementConfiguration: Codable, Equatable {
    var targetUnderPointer = false
    var restoreWhenUnsnapped = true
    var showSnapPreview = true
    var showSnapLabel = true
    var animatePreview = true
    var hapticFeedback = false
    var movePointerWithWindow = false
    var cycleRepeatedLayouts = false
    var warnConflictingApps = true
    var snapThreshold: Double = 24
    var windowGap: Double = 0
    var nearMaximizeInset: Double = 40
    var reservedLeft: Double = 0
    var reservedRight: Double = 0
    var customLayouts: [CustomWindowLayout] = []
    init() {}
    enum CodingKeys: String, CodingKey { case targetUnderPointer,restoreWhenUnsnapped,showSnapPreview,showSnapLabel,animatePreview,hapticFeedback,movePointerWithWindow,cycleRepeatedLayouts,warnConflictingApps,snapThreshold,windowGap,nearMaximizeInset,reservedLeft,reservedRight,customLayouts }
    init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        targetUnderPointer = try c.decodeIfPresent(Bool.self, forKey: .targetUnderPointer) ?? false
        restoreWhenUnsnapped = try c.decodeIfPresent(Bool.self, forKey: .restoreWhenUnsnapped) ?? true
        showSnapPreview = try c.decodeIfPresent(Bool.self, forKey: .showSnapPreview) ?? true
        showSnapLabel = try c.decodeIfPresent(Bool.self, forKey: .showSnapLabel) ?? true
        animatePreview = try c.decodeIfPresent(Bool.self, forKey: .animatePreview) ?? true
        hapticFeedback = try c.decodeIfPresent(Bool.self, forKey: .hapticFeedback) ?? false
        movePointerWithWindow = try c.decodeIfPresent(Bool.self, forKey: .movePointerWithWindow) ?? false
        cycleRepeatedLayouts = try c.decodeIfPresent(Bool.self, forKey: .cycleRepeatedLayouts) ?? false
        warnConflictingApps = try c.decodeIfPresent(Bool.self, forKey: .warnConflictingApps) ?? true
        snapThreshold = try c.decodeIfPresent(Double.self, forKey: .snapThreshold) ?? 24
        windowGap = try c.decodeIfPresent(Double.self, forKey: .windowGap) ?? 0
        nearMaximizeInset = try c.decodeIfPresent(Double.self, forKey: .nearMaximizeInset) ?? 40
        reservedLeft = try c.decodeIfPresent(Double.self, forKey: .reservedLeft) ?? 0
        reservedRight = try c.decodeIfPresent(Double.self, forKey: .reservedRight) ?? 0
        customLayouts = try c.decodeIfPresent([CustomWindowLayout].self, forKey: .customLayouts) ?? []
    }
}
struct CustomWindowLayout: Codable, Equatable, Identifiable {
    var id = UUID(); var name = "自定义布局"
    var x: Double = 0; var y: Double = 0; var width: Double = 0.5; var height: Double = 1
    var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.001 && y + height <= 1.001 }
    func frame(in screen: CGRect) throws -> CGRect {
        guard isValid else { throw SystemControlError.message("自定义布局必须位于工作区内，尺寸必须大于零。") }
        return CGRect(x:screen.minX + x * screen.width,y:screen.minY + y * screen.height,width:width * screen.width,height:height * screen.height)
    }
}
enum WindowEnhancementGeometry {
    static func workArea(_ screen: CGRect, configuration c: WindowEnhancementConfiguration) -> CGRect {
        let left = min(max(0,c.reservedLeft.isFinite ? c.reservedLeft : 0),screen.width * 0.4)
        let right = min(max(0,c.reservedRight.isFinite ? c.reservedRight : 0),screen.width * 0.4)
        return CGRect(x:screen.minX+left,y:screen.minY,width:screen.width-left-right,height:screen.height)
    }
    static func inset(_ frame: CGRect, gap: Double) -> CGRect {
        let value = min(max(0,gap.isFinite ? gap : 0), min(frame.width,frame.height)/4)
        return frame.insetBy(dx:value/2,dy:value/2)
    }
    static func restoredDragFrame(original: CGRect, snapped: CGRect, pointer: CGPoint) -> CGRect {
        let ratio = min(1,max(0,(pointer.x-snapped.minX)/max(1,snapped.width)))
        return CGRect(x:pointer.x-original.width*ratio,y:pointer.y-min(24,original.height/2),width:original.width,height:original.height)
    }
    static func cycle(_ action: WindowAction, count: Int) -> WindowAction {
        if action == .leftHalf { return [.leftHalf,.leftTwoThirds,.thirdLeft][count % 3] }
        if action == .rightHalf { return [.rightHalf,.rightTwoThirds,.thirdRight][count % 3] }
        return action
    }
}
@MainActor final class WindowSnapPreview {
    private var panel: NSPanel?
    private var previous: CGRect?
    func show(frame: CGRect, title: String, animated: Bool, haptic: Bool, showLabel: Bool = true) {
        guard frame != previous else { return }; previous = frame
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let appKitFrame = CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height)
        let window: NSPanel
        if let panel { window = panel } else {
            window = NSPanel(contentRect:appKitFrame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear
            window.ignoresMouseEvents = true; window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
            panel = window
        }
        window.contentView = NSHostingView(rootView:ZStack {
            RoundedRectangle(cornerRadius:12).fill(Color.accentColor.opacity(0.16))
            RoundedRectangle(cornerRadius:12).stroke(Color.accentColor.opacity(0.8),lineWidth:3)
            if showLabel { Text(title).font(.title2.bold()).padding(16).background(.regularMaterial,in:Capsule()) }
        }.padding(3))
        window.setFrame(appKitFrame,display:true,animate:animated && window.isVisible)
        window.orderFrontRegardless()
        if haptic { NSHapticFeedbackManager.defaultPerformer.perform(.alignment,performanceTime:.now) }
    }
    func hide() { panel?.orderOut(nil); previous = nil }
}
@MainActor struct WindowEnhancementSettingsView: View {
    @Binding var configuration: WindowEnhancementConfiguration
    var body: some View {
        Form {
            Toggle("操作鼠标指向的窗口",isOn:$configuration.targetUnderPointer)
            Toggle("拖离吸附区域时恢复原尺寸",isOn:$configuration.restoreWhenUnsnapped)
            Toggle("显示吸附范围和文字",isOn:$configuration.showSnapPreview)
            Toggle("显示吸附提示文字",isOn:$configuration.showSnapLabel).disabled(!configuration.showSnapPreview)
            Toggle("预览范围动画",isOn:$configuration.animatePreview)
            Toggle("触控板触感反馈",isOn:$configuration.hapticFeedback)
            Toggle("跨屏时将光标移到目标窗口",isOn:$configuration.movePointerWithWindow)
            Toggle("连续半屏动作循环 1/2 → 2/3 → 1/3",isOn:$configuration.cycleRepeatedLayouts)
            Toggle("提示其他运行中的窗口工具",isOn:$configuration.warnConflictingApps)
            HStack { Text("吸附距离"); Slider(value:$configuration.snapThreshold,in:8...80); Text("\(Int(configuration.snapThreshold)) pt") }
            HStack { Text("窗口间距"); Slider(value:$configuration.windowGap,in:0...40); Text("\(Int(configuration.windowGap)) pt") }
            HStack { Text("接近最大化留白"); Slider(value:$configuration.nearMaximizeInset,in:8...120); Text("\(Int(configuration.nearMaximizeInset)) pt") }
            HStack { TextField("左侧预留(pt)",value:$configuration.reservedLeft,format:.number); TextField("右侧预留(pt)",value:$configuration.reservedRight,format:.number) }
            Text("预留区可用于台前调度或待办窗口。全屏控制使用应用公开的辅助功能属性；不支持的窗口会报错。跨屏和触感反馈须有相应硬件。") .font(.caption).foregroundStyle(.secondary)
            ForEach($configuration.customLayouts) { $layout in
                VStack(alignment:.leading) {
                    HStack { TextField("布局名",text:$layout.name); Button("删除",role:.destructive) { configuration.customLayouts.removeAll { $0.id == layout.id } } }
                    HStack { TextField("X(0–1)",value:$layout.x,format:.number); TextField("Y",value:$layout.y,format:.number); TextField("宽",value:$layout.width,format:.number); TextField("高",value:$layout.height,format:.number) }
                    if !layout.isValid { Text("布局超出工作区或尺寸无效").foregroundStyle(.orange) }
                }
            }
            Button("添加自定义百分比布局") { configuration.customLayouts.append(CustomWindowLayout()) }
        }.formStyle(.grouped)
    }
}
