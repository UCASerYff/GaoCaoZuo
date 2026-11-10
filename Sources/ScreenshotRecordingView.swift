import SwiftUI
import AppKit

struct ScreenshotRecordingView:View {
    @ObservedObject var model:ScreenshotAppModel
    @ObservedObject var controller:ScreenshotRecordingController
    @State private var audioOnly=false
    @State private var systemAudio=true
    @State private var microphone=false
    @State private var sourceID=""
    @State private var fps=30
    @State private var cursor=true
    @State private var clicks=false
    @State private var regionSource:ScreenshotRecordingSource?
    @State private var gifStart=0.0
    @State private var gifEnd=5.0
    @State private var gifFPS=10
    @State private var gifWidth=640
    @State private var gifStatus=""
    @State private var gifToken:ScreenshotGIFCancellationToken?
    @State private var saturation=1.0
    @State private var contrast=1.0
    @State private var brightness=0.0
    @State private var useCrop=false
    @State private var cropX=0.0
    @State private var cropY=0.0
    @State private var cropW=1.0
    @State private var cropH=1.0
    var availableSources:[ScreenshotRecordingSource]{controller.sources + (regionSource.map{[$0]} ?? [])}
    var active:Bool{[.recording,.paused,.preparing,.stopping].contains(controller.state)}
    var gifOptions:ScreenshotGIFOptions{ScreenshotGIFOptions(startSeconds:gifStart,durationSeconds:gifEnd-gifStart,framesPerSecond:gifFPS,maximumWidth:gifWidth,maximumHeight:gifWidth,crop:useCrop ? CGRect(x:cropX,y:cropY,width:cropW,height:cropH):nil,saturation:saturation,contrast:contrast,brightness:brightness)}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                HStack {Text("录屏与独立录音").font(.title);Spacer();Text(controller.state.title).foregroundStyle(active ? Color.red:Color.secondary);Text(String(format:"%.1f 秒",controller.elapsed)).monospacedDigit()}
                Toggle("仅录音（不保存视频）",isOn:$audioOnly).disabled(active)
                HStack {Toggle("系统内部声音",isOn:$systemAudio);Toggle("麦克风",isOn:$microphone);Toggle("鼠标",isOn:$cursor);Toggle("点击高亮（15+）",isOn:$clicks)}.disabled(active)
                HStack {Picker("捕获来源",selection:$sourceID){Text("选择屏幕或窗口").tag("");ForEach(availableSources){s in Text(s.name).tag(s.id)}};Button("刷新来源"){guard model.canBeginOperation()else{return};Task{await controller.refreshSources()}};Button("选择区域"){region()}}.disabled(active)
                Stepper("帧率 \(fps) fps",value:$fps,in:1...60).disabled(active || audioOnly)
                controls
                HStack{Button("请求麦克风权限"){Task{let granted=await controller.requestMicrophonePermission();model.message=granted ? "麦克风已获权。":"麦克风未获权，请在系统设置中允许后重试。"}}.disabled(active);Button("麦克风系统设置"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)}}
                Text(controller.statusMessage).textSelection(.enabled)
                if audioOnly && microphone && !systemAudio {Text(String(format:"麦克风电平 %.0f dB",controller.microphonePowerDB)).font(.caption)}
                if let url=controller.lastOutputURL {HStack{Text("已完成：\(url.lastPathComponent)");Button("显示文件"){NSWorkspace.shared.activateFileViewerSelecting([url])};Button("混音导出 M4A…"){exportAudio(url)}}}
                if let recovery=controller.recoveryURL {Button("显示恢复材料"){NSWorkspace.shared.activateFileViewerSelecting([recovery])}}
                HStack {Text("视频帧 \(controller.metrics.videoFrames) · 掉帧 \(controller.metrics.droppedVideoFrames) · 系统音缓冲 \(controller.metrics.systemAudioBuffers) · 麦克风缓冲 \(controller.metrics.microphoneBuffers) · 丢弃音频缓冲 \(controller.metrics.droppedAudioBuffers)").font(.caption);Spacer();Button("恢复中断录制…"){recover()}.disabled(active)}
                Divider()
                gifControls
                Text("系统声音输出设备变化会暂停，核对音源后可继续；所选麦克风丢失、独立录音的系统输入变化、权限撤销或磁盘不足会停止并保留恢复说明。系统音与麦克风分别成轨；仅麦克风支持 M4A。崩溃中断的 MOV 不保证可修复。").foregroundStyle(.secondary).font(.callout)
            }.padding(24)
        }
    }
    var controls:some View {
        HStack {
            Button("开始\(audioOnly ? "录音":"录屏")"){start()}.buttonStyle(.borderedProminent).disabled(active)
                .accessibilityLabel(audioOnly ? "开始录音":"开始录屏").accessibilityIdentifier("recording.start")
            Button(controller.state == .paused ? "继续":"暂停"){if controller.state == .paused{controller.resume()}else{controller.pause()}}.disabled(![.recording,.paused].contains(controller.state))
                .accessibilityLabel(controller.state == .paused ? "继续":"暂停").accessibilityIdentifier("recording.pauseResume")
            Button("停止并完成"){Task{await controller.stop()}}.disabled(![.recording,.paused].contains(controller.state))
                .accessibilityLabel("停止并完成").accessibilityIdentifier("recording.stop")
            Button("取消并保留恢复材料"){Task{await controller.cancel()}}.disabled(![.recording,.paused].contains(controller.state))
        }
    }
    var gifControls:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("视频转 GIF").font(.headline)
            HStack {Text("起止秒");TextField("开始",value:$gifStart,format:.number).frame(width:55);TextField("结束",value:$gifEnd,format:.number).frame(width:55);Stepper("\(gifFPS) fps",value:$gifFPS,in:1...30);Stepper("最长边 \(gifWidth) px",value:$gifWidth,in:64...1920,step:64)}
            HStack {Text("饱和度");Slider(value:$saturation,in:0...2);Text("对比度");Slider(value:$contrast,in:0.5...2);Text("亮度");Slider(value:$brightness,in: -0.5...0.5)}
            HStack {Toggle("裁剪（左上归一化）",isOn:$useCrop);TextField("X",value:$cropX,format:.number);TextField("Y",value:$cropY,format:.number);TextField("宽",value:$cropW,format:.number);TextField("高",value:$cropH,format:.number)}
            Text("估计 \(gifOptions.estimate.frameCount) 帧，\(gifOptions.estimate.estimatedMinimumBytes/1024)–\(gifOptions.estimate.estimatedMaximumBytes/1024) KiB。实际容量取决于画面；GIF 最多256色、不含音频。").font(.caption).foregroundStyle(.secondary)
            HStack {Button("选择视频并转换…"){gif()}.disabled(gifToken != nil);Button("取消转换"){gifToken?.cancel()}.disabled(gifToken==nil);Text(gifStatus).font(.caption)}
        }.disabled(active)
    }
    func start(){if let reason=model.recordingStartBlockingReason{model.message=reason;model.showMain();return};model.willBeginExclusiveInput?();let selectionWork=model.beginAuxiliaryWork("选择录制输出",exclusiveInput:true);defer{model.endAuxiliaryWork(selectionWork)};let p=NSSavePanel();p.nameFieldStringValue=audioOnly && microphone && !systemAudio ? "录音.m4a":"\(audioOnly ? "录音":"录屏").mov";guard p.runModal() == .OK,let url=p.url else{return};let source=availableSources.first{$0.id==sourceID};let config=ScreenshotRecordingConfiguration(mode:audioOnly ? .audioOnly:.video,source:source,outputURL:url,systemAudio:systemAudio,microphone:microphone,frameRate:fps,showsCursor:cursor,highlightsMouseClicks:clicks);Task{await controller.start(configuration:config)}}
    func region(){guard model.canBeginOperation(),!model.busy,!model.exchangeIsExecuting,!controller.isActive else{return};let work=model.beginAuxiliaryWork("选择录制区域",cancel:{model.selection.cancel()},exclusiveInput:true);Task{defer{model.endAuxiliaryWork(work);model.showMain()};do{let catalog=try await model.capture.refreshCatalog();model.willBeginExclusiveInput?();model.hideMain();guard let r=await model.selection.selectRegion(),r.displayIDs.count==1,let id=r.displayIDs.first,let display=catalog.displays.first(where:{$0.id==id})else{model.message="录屏区域目前需位于同一显示器。";model.showMain();return};let source=ScreenshotRecordingSource(kind:.region,displayID:id,region:r.desktopRect.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY),name:"所选区域");regionSource=source;sourceID=source.id;model.showMain()}catch{model.fail(error)}}}
    func exportAudio(_ url:URL){guard model.canBeginOperation()else{return};let p=NSSavePanel();p.nameFieldStringValue="音频.m4a";if p.runModal() == .OK,let dest=p.url{let work=model.beginAuxiliaryWork("导出 M4A");Task{defer{model.endAuxiliaryWork(work)};do{try await ScreenshotRecordingAudioExporter.exportM4A(input:url,output:dest);model.message="已导出 M4A。"}catch{model.fail(error)}}}}
    func gif(){guard model.canBeginOperation()else{return};do{try gifOptions.validate()}catch{gifStatus=error.localizedDescription;return};let p=NSOpenPanel();p.allowedContentTypes=[.movie];guard p.runModal() == .OK,let input=p.url else{return};let s=NSSavePanel();s.nameFieldStringValue="动图.gif";guard s.runModal() == .OK,let output=s.url else{return};let options=gifOptions,token=ScreenshotGIFCancellationToken();gifToken=token;let work=model.beginAuxiliaryWork("转换 GIF",cancel:{token.cancel()});Task{defer{gifToken=nil;model.endAuxiliaryWork(work)};do{let result=try await ScreenshotGIFExporter.convert(input:input,output:output,options:options,cancellation:token,progress:{done,total in Task{@MainActor in gifStatus="\(done)/\(total) 帧";model.message="GIF：\(done)/\(total) 帧"}});gifStatus="GIF \(result.frameCount) 帧 · \(result.byteCount/1024) KiB 已导出。";model.message=gifStatus}catch{gifStatus=error.localizedDescription;model.message=error.localizedDescription}}}
    func recover(){guard model.canBeginOperation()else{return};let p=NSOpenPanel();p.allowedContentTypes=[.json];p.showsHiddenFiles=true;p.message="选择录制输出目录中的 .gao-recording-…recovery.json";guard p.runModal() == .OK,let journal=p.url else{return};let work=model.beginAuxiliaryWork("检查并恢复中断录制");Task{defer{model.endAuxiliaryWork(work)};do{let inspection=try await ScreenshotRecordingRecovery.inspect(journal:journal);let a=NSAlert();a.messageText="中断录制检查";a.informativeText=inspection.reason;a.addButton(withTitle:inspection.canRecover ? "另存恢复副本":"保留原件");a.addButton(withTitle:"取消");guard a.runModal() == .alertFirstButtonReturn,inspection.canRecover else{return};let save=NSSavePanel();save.nameFieldStringValue="恢复录制."+inspection.mediaURL.pathExtension;guard save.runModal() == .OK,let output=save.url else{return};_ = try await ScreenshotRecordingRecovery.recover(journal:journal,to:output);model.message="已另存可解码恢复副本，请完整回放核对。"}catch{model.fail(error)}}}
}
