import SwiftUI
import AppKit

struct ScreenshotMainView:View {
    @ObservedObject var model:ScreenshotAppModel
    var body:some View {
        VStack(spacing:0) {
            Picker("截图工作台",selection:$model.tab){Text("截图").tag("截图");Text("标注").tag("标注");Text("OCR").tag("OCR");Text("录屏与录音").tag("录制");Text("翻译").tag("翻译");Text("历史与交接").tag("历史")}.pickerStyle(.segmented).padding(12)
            Divider()
            VStack(spacing:0){content.frame(maxWidth:.infinity,maxHeight:.infinity);Divider();HStack{if model.busy || !model.activeAuxiliaryWork.isEmpty{ProgressView().controlSize(.small)};if model.canCancelCaptureWork{Button(model.longCaptureOperation != nil ? "取消长截图":"取消处理"){model.cancelCaptureWork()}};Text(model.message).font(.callout).textSelection(.enabled);Spacer();if model.canCancelExchange{Button("取消交接"){model.exchange.cancelPending()}};Menu("当前工作"){if model.canCancelAuxiliaryWork || model.translationIsRunning || model.ocr.isRunning{Button("取消当前处理"){model.cancelActiveWork()}};Button("保留当前工作…"){model.saveSessionWork()};Button("结束当前工作…"){model.endCurrentWork()};Button("关闭所有贴图…"){model.closePins()}}}.padding(12).frame(minHeight:48)}
        }
        .sheet(isPresented:$model.chooser,onDismiss:{if model.choiceContinuation != nil{model.choose(nil)}}){ScreenshotCaptureChooser(model:model).frame(width:640,height:450)}
    }
    private var translationPanel:some View {
        let operationID=model.translationOperationID
        return ScreenshotTranslationPanel(initialText:model.translationText,sourceLanguage:model.translationSource,targetLanguage:model.translationTarget,operationID:operationID,requestID:model.externalTranslation?.manifest.requestID,initialResult:model.translationResult,startBlockingReason:{model.operationStartBlockingReason},onActivityChanged:{active in guard model.translationOperationID==operationID else{return};model.translationIsRunning=active},onDraftChanged:{text,source,target in guard model.translationOperationID==operationID else{return};model.updateTranslationDraft(text:text,source:source,target:target)},onCompletion:{result,id,requestID in model.translationCompleted(result,operationID:id,requestID:requestID)},onCancel:{id,requestID in model.exchange.cancelTranslation(operationID:id,requestID:requestID)}).id(operationID)
    }
    @ViewBuilder var content:some View {
        switch model.tab {
        case "截图":ScreenshotCaptureHome(model:model)
        case "标注":ScreenshotAnnotationView(model:model)
        case "OCR":ScreenshotOCRView(model:model,controller:model.ocr)
        case "录制":ScreenshotRecordingView(model:model,controller:model.recording)
        case "翻译":translationPanel
        case "历史":ScreenshotHistoryView(model:model,store:model.store)
        default:EmptyView()
        }
    }
}
struct ScreenshotCaptureHome:View {
    @ObservedObject var model:ScreenshotAppModel
    var body:some View {
        VStack(alignment:.leading,spacing:24){Text("捕获所选内容").font(.largeTitle.bold());Text("截图后按设置保存、复制或进入标注。快捷键可在搞操作的“快捷键与手势”中配置。").foregroundStyle(.secondary)
            HStack{Button("区域截图",systemImage:"rectangle.dashed"){model.captureRegion()};Button("窗口截图",systemImage:"macwindow"){model.captureWindow()};Button("屏幕截图",systemImage:"display"){model.captureDisplay()}}.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
            HStack{Button("截图翻译"){model.captureRegion(translateOCR:true)};Button("多窗口合成"){model.multiWindow()};Button("长截图"){model.startLongCapture()};Button("取色"){model.sampleColor()};Button("打开图像 / PDF…"){model.openFiles()};Button("贴图恢复交互"){model.pins.makeAllInteractive()}}
            GroupBox("捕获选项"){HStack{Text("延时");Slider(value:$model.delay,in:0...60,step:1);Text("\(Int(model.delay)) 秒").frame(width:50);Toggle("鼠标",isOn:$model.cursor);Toggle("窗口阴影",isOn:$model.shadow)}.padding(10)}
            GroupBox("权限与范围"){VStack(alignment:.leading,spacing:12){Text(CGPreflightScreenCaptureAccess() ? "本次程序屏幕捕获权限：已获权":"本次程序屏幕捕获权限：未获权");HStack{Button("请求屏幕捕获权限"){model.requestScreen()};Button("打开系统设置"){model.screenSettings()}};Text("受保护内容可能为空白。外接屏幕与外置音频设备专项验收不做（用户取消）。").font(.callout).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading).padding(8)}
            Spacer()
        }.padding(32)
    }
}
struct ScreenshotCaptureChooser:View {
    @ObservedObject var model:ScreenshotAppModel
    var body:some View{VStack(alignment:.leading){Text("选择\(model.chooserMode)").font(.title2);if let catalog=model.captureCatalog{if model.chooserMode=="多窗口"{List(catalog.windows){w in Toggle("\(w.applicationName) · \(w.title)",isOn:Binding(get:{model.selectedWindows.contains(w.id)},set:{if $0{model.selectedWindows.insert(w.id)}else{model.selectedWindows.remove(w.id)}}))};Button("合成所选窗口"){model.finishMulti()}.disabled(model.selectedWindows.isEmpty)}else{List(catalog.displays){d in Button("\(d.name) · \(Int(d.frame.width)) × \(Int(d.frame.height)) 点 · \(d.scale, specifier:"%.1f")x"){model.choose(.display(d.id))}}}};Button("取消"){model.choose(nil)}}.padding(24)}
}
struct ScreenshotAnnotationView:View {
    @ObservedObject var model:ScreenshotAppModel
    @State private var tool=ScreenshotAnnotationTool.arrow;@State private var text="";@State private var color=Color.red;@State private var width=4.0;@State private var preview=false
    var body:some View {
        if let doc=model.annotation{VStack(spacing:10){HStack{Picker("工具",selection:$tool){ForEach(ScreenshotAnnotationTool.allCases,id:\.self){Text($0.rawValue).tag($0)}}.frame(width:180);ColorPicker("颜色",selection:$color).labelsHidden();Slider(value:$width,in:1...24).frame(width:90);TextField("文字 / 编号",text:$text).frame(width:140);Button("撤销"){doc.undo()};Button("重做"){doc.redo()};Button("旋转"){doc.rotate()};Button("最终预览"){preview=true}}
            ScreenshotAnnotationCanvas(document:doc,tool:tool,text:text,color:NSColor(color),width:width).frame(maxWidth:.infinity,maxHeight:.infinity).border(.separator)
            HStack{Button("复制"){model.copyImage()};Button("贴图"){model.pinImage()};Button("OCR"){if let image=try? doc.flatten(){model.ocrImage(image)}};Button("另存图像…"){model.saveAnnotation()};Button("保存编辑稿…"){model.saveAnnotation(editable:true)};Menu("更多"){Button("原创桌面壳导出…"){model.saveAnnotation(framed:true)};Button("圆角与阴影导出…"){model.saveAnnotation(framed:true,shell:false)};Button("当前屏幕壁纸底板导出…"){model.saveAnnotation(framed:true,wallpaper:true)};Button("保存并交编辑 App…"){model.saveAnnotation(openEditor:true)};Button("保存为持久贴图"){model.persistPin()}}}
            HStack{Text("导出质量");Slider(value:$model.exportQuality,in:0.1...1).frame(width:100);Text("最长边（0 为原像素）");TextField("像素",value:$model.exportMaximumDimension,format:.number).frame(width:70);Spacer();Text("模糊不能保证保密；敏感内容使用实心遮盖并导出栅格图。").font(.caption).foregroundStyle(.secondary)}
        }.padding(12).sheet(isPresented:$preview){VStack{if let image=try? doc.flatten(){Image(nsImage:NSImage(cgImage:image,size:.zero)).resizable().scaledToFit().frame(maxWidth:900,maxHeight:650)};Button("关闭预览"){preview=false}}.padding(20)}}else{ContentUnavailableView("打开图像后标注",systemImage:"pencil.tip.crop.circle",description:Text("原图保持完整。支持图层、撤销、裁剪、旋转与栅格导出。"))}
    }
}
struct ScreenshotHistoryView: View {
    @ObservedObject var model: ScreenshotAppModel
    @ObservedObject var store: ScreenshotLocalStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("历史与交接").font(.title)
                if let issue = store.issue { Text(issue).foregroundStyle(.red) }
                Text(store.settings.historyEnabled ? "历史已启用。到期记录在下一次主动保存时清理。" : "历史默认关闭。临时处理内容仅保留在当前会话或私有交接目录。")
                    .foregroundStyle(.secondary)
                List(store.assets) { asset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(asset.createdAt, style: .date)
                            Text("\(asset.pixelWidth)×\(asset.pixelHeight) · \(asset.source)").font(.caption)
                        }
                        Spacer()
                        Button("打开") { Task { await model.receive([store.root.appendingPathComponent(asset.outputPath)]) } }
                    }
                }.frame(height: 180)
                HStack {
                    Button("完整备份并恢复演练…") { model.backupData() }
                    Button("恢复持久贴图") { model.restorePins() }
                    Button("显示私有交接目录") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.exchange.path) }
                }
                IntegratedScreenshotActivityView(model: model)
                ForEach(model.pendingResults) { result in
                    HStack {
                        Text("\(result.action) · \(result.status)")
                        Spacer()
                        Button("发送结果") { model.exchange.sendResult(result) }
                        Button("显示包") { NSWorkspace.shared.activateFileViewerSelecting([result.packageURL]) }
                    }
                }
                Text("外部请求先核验并确认。已执行请求不会因重复包或重启自动重放。未完成请求需要重新复核。").font(.callout)
            }.padding(24)
        }
    }
}
