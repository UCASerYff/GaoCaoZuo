import AppKit
import SwiftUI

@MainActor struct AutomationPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sample: AutomationPreview.Sample
    @State private var generated: (sample: AutomationPreview.Sample, report: AutomationPreview.Report)?
    private let title: String
    private let trigger: String?
    private let plan: (AutomationPreview.Sample) -> AutomationPreview.Report

    init(rule: InputBinding, store: OperationStore, paused: Bool) {
        let settings = store.settings
        let inputs = store.automationPreviewCatalog, healthy = store.dataHealthy
        self.init(title: L10n.text("规则试跑"), trigger: rule.triggerDescription, app: rule.appBundleID,
                  basicInput: .init(rule)) { sample in
            AutomationPreview.basic(rule, bindings: settings.bindings, excludedApps: settings.inputExcludedApps,
                                    paused: paused, healthy: healthy, sample: sample, catalog: inputs)
        }
    }

    init(rule: EnhancedInputRule, configuration: InputEnhancementConfiguration, excludedApps: [String],
         paused: Bool, healthy: Bool, catalog: AutomationPreview.Catalog) {
        self.init(title: L10n.text("规则试跑"), trigger: rule.trigger.title, app: rule.appBundleID) { sample in
            AutomationPreview.enhanced(rule, configuration: configuration, excludedApps: excludedApps,
                                       paused: paused, healthy: healthy, sample: sample, catalog: catalog)
        }
    }

    init(workflow: OperationWorkflow, store: OperationStore) {
        let healthy = store.dataHealthy, busy = store.busy || store.workflowRunning || store.archive.isRunning
        self.init(title: L10n.text("组合操作试跑")) { _ in
            AutomationPreview.workflow(workflow, busy: busy, healthy: healthy)
        }
    }

    private init(title: String, trigger: String? = nil, app: String = "", basicInput: AutomationPreview.BasicInput? = nil,
                 plan: @escaping (AutomationPreview.Sample) -> AutomationPreview.Report) {
        self.title = title
        self.trigger = trigger
        self.plan = plan
        let initial = AutomationPreview.Sample(application: app.isEmpty ? "com.example.preview" : app, basicInput: basicInput)
        _sample = State(initialValue: initial)
        _generated = State(initialValue: trigger == nil ? (initial, plan(initial)) : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(L10n.text("试跑只生成计划，不访问输入路径、不执行动作，也不保存规则。"))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let trigger {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(L10n.text("模拟应用 Bundle ID"), text: $sample.application)
                            if let input = Binding($sample.basicInput) {
                                BasicPreviewTriggerFields(input: input)
                            } else {
                                Picker(L10n.text("模拟触发"), selection: $sample.configuredTrigger) {
                                    Text(verbatim: trigger).tag(true)
                                    Text(L10n.text("不同的触发")).tag(false)
                                }
                            }
                            TextField(L10n.text("模拟文件绝对路径，每行一个（可选）"), text: $sample.fileLines, axis: .vertical)
                                .lineLimit(2...5)
                            TextField(L10n.text("模拟目标目录（可选）"), text: $sample.directory)
                        }.textFieldStyle(.roundedBorder)
                    } else {
                        Text(L10n.text("组合操作使用各步骤保存的参数；此处不会读取文件选择。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let generated, generated.sample == sample {
                        let report = generated.report
                        reportGroup("命中条件", lines: report.checks, numbered: false)
                        if !report.steps.isEmpty {
                            reportGroup("预计动作与文件", lines: report.steps, numbered: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                if trigger != nil {
                    Button(L10n.text("生成试跑计划")) { generated = (sample, plan(sample)) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 570)
    }

    private func reportGroup(_ heading: String, lines: [AutomationPreview.Line], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(heading)).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: numbered ? L10n.format("步骤 %@ · %@", String(index + 1), line.title) : line.title)
                            .fontWeight(.medium)
                        Spacer(minLength: 12)
                        Text(line.state.title).font(.caption).foregroundStyle(tint(line.state))
                    }
                    Text(verbatim: line.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(line.paths.indices, id: \.self) { index in
                        Text(verbatim: line.paths[index]).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func tint(_ state: AutomationPreview.State) -> Color {
        switch state {
        case .matched, .planned: return .accentColor
        case .blocked: return .orange
        case .mismatch, .skipped, .unknown: return .secondary
        }
    }
}

@MainActor private struct BasicPreviewTriggerFields: View {
    @Binding var input: AutomationPreview.BasicInput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.text("模拟触发"), selection: $input.trigger) {
                ForEach(InputTrigger.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text(L10n.text("修饰键"))
                modifier("⌃", .control)
                modifier("⌥", .option)
                modifier("⇧", .shift)
                modifier("⌘", .command)
                modifier("Fn", .function)
            }
            switch input.trigger {
            case .hotkey:
                LabeledContent(L10n.text("键码")) {
                    HStack {
                        TextField(L10n.text("键码"), value: $input.keyCode, format: .number).labelsHidden().frame(width: 65)
                        Text(InputBinding.keyLabel(input.keyCode)).foregroundStyle(.secondary)
                    }
                }
            case .mouseButton:
                Stepper(L10n.format("鼠标按钮 %ld", input.mouseButton + 1), value: $input.mouseButton, in: 2...31)
            case .gesture:
                Picker(L10n.text("拖动方向"), selection: $input.direction) {
                    Text(L10n.text("向左")).tag("left")
                    Text(L10n.text("向右")).tag("right")
                    Text(L10n.text("向上")).tag("up")
                    Text(L10n.text("向下")).tag("down")
                }
                Stepper(L10n.format("模拟拖动距离 %@ 点", String(input.dragDistance)), value: $input.dragDistance, in: 0...500)
            }
        }
    }

    private func modifier(_ label: String, _ flag: NSEvent.ModifierFlags) -> some View {
        let mask = UInt64(flag.rawValue)
        return Toggle(label, isOn: Binding(get: { input.modifiers & mask != 0 }, set: { enabled in
            if enabled { input.modifiers |= mask } else { input.modifiers &= ~mask }
        })).toggleStyle(.button)
    }
}

extension OperationStore {
    /// Copy only cached configuration. In particular, `actionChoices` verifies
    /// installed providers and registers descriptors, so preview does not call it.
    var automationPreviewCatalog: AutomationPreview.Catalog {
        var actions = OperationAction.all
        var templates: [String: String] = [:]
        for layout in settings.windowEnhancements.customLayouts {
            actions.append(.init(id: "window.custom." + layout.id.uuidString, title: layout.name, detail: "", icon: "",
                                 section: .windows, localizeTitle: false))
        }
        for application in fileEnhancements.settings.apps where application.isEnabled {
            actions.append(.init(id: "file.open." + application.id.uuidString, title: application.name, detail: "", icon: "",
                                 section: .files, files: true, localizeTitle: false))
        }
        for template in fileEnhancements.settings.templates where template.isEnabled {
            let id = "binaryTemplate." + template.id.uuidString
            actions.append(.init(id: id, title: template.name, detail: "", icon: "", section: .files, localizeTitle: false))
            templates[id] = template.filename
        }
        for snippet in snippetLibrary.snippets {
            actions.append(.init(id: "snippet.run." + snippet.id.uuidString, title: snippet.name, detail: "", icon: "",
                                 section: .clipboard, localizeTitle: false))
        }
        return .init(actions: actions, archive: archiveEnhancements.preferences, templates: templates)
    }
}
