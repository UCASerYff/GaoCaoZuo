import AppKit
import QuickLookUI

/// Interactive Quick Look content remains inside the extension. The optional
/// main-app handoff is independent of selection, preview, extraction and edits.
class NativeArchiveBrowserController: NSViewController, QLPreviewingController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private final class Node: NSObject {
        let path: String
        var item: NativeArchive.Item?
        var children: [Node] = []
        init(path: String) { self.path = path }
        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        var isDirectory: Bool { item?.kind == .directory || (item == nil && !children.isEmpty) }
    }
    private let outline = NSOutlineView(), search = NSSearchField(), preview = NativeArchivePreview()
    private let heading = NSTextField(labelWithString: ""), status = NSTextField(wrappingLabelWithString: "")
    private let extractName = NSTextField(string: ""), copyName = NSTextField(string: "")
    private let archivePassword=NSSecureTextField(string:"")
    private let cleanHidden = NSButton(checkboxWithTitle: L10n.text("清理隐藏项目"), target: nil, action: nil)
    private var actionButtons: [NSButton] = [], selectedButtons: [NSButton] = [], editButtons: [NSButton] = []
    private var copyButton:NSButton?,originalButton:NSButton?,unlockButton:NSButton?
    private var roots: [Node] = [], allNodes: [String: Node] = [:]
    private var document: NativeArchive.Document?, archiveURL: URL?
    private var access: ArchiveQuickLookResourceAccess?, additions: [ArchiveQuickLookResourceAccess] = [], deletions = Set<String>()
    private var generation = UUID(), activeJob = UUID(), cancellation: NativeArchive.Cancellation?, working = false
    private var selectionPanel: NSOpenPanel?
    private let group = DispatchGroup()
    override func loadView() {
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("archive-name")))
        outline.outlineTableColumn = outline.tableColumns[0]; outline.headerView = nil
        outline.dataSource = self; outline.delegate = self; outline.allowsMultipleSelection = true
        outline.rowHeight = 24; outline.autoresizesOutlineColumn = true
        outline.setAccessibilityLabel(L10n.text("压缩包目录"))
        let tree = NSScrollView(); tree.documentView = outline; tree.hasVerticalScroller = true
        tree.hasHorizontalScroller = true; tree.borderType = .bezelBorder
        tree.translatesAutoresizingMaskIntoConstraints = false; tree.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        preview.translatesAutoresizingMaskIntoConstraints = false; preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        preview.showMessage(L10n.text("选择一个普通文件以预览内容。"))
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin; split.addArrangedSubview(tree); split.addArrangedSubview(preview)
        split.translatesAutoresizingMaskIntoConstraints = false; split.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        search.placeholderString = L10n.text("搜索包内路径"); search.delegate = self
        let expand = button("展开全部", #selector(expandAll)), collapse = button("折叠全部", #selector(collapseAll))
        let content = button("预览内容", #selector(previewSelected)), extract = button("提取所选…", #selector(extractSelected)), all = button("全部提取…", #selector(extractAll))
        selectedButtons = [content, extract]; actionButtons = [content, extract, all]
        let unlock=button("读取加密目录…",#selector(unlockArchive));unlockButton=unlock
        let browse = row([search, expand, collapse, content, extract, all])
        archivePassword.placeholderString=L10n.text("输入此压缩包密码")
        archivePassword.setAccessibilityLabel(L10n.text("输入此压缩包密码"))
        archivePassword.toolTip=L10n.text("密码仅用于本次读取或保存，不会保存密码。不支持的加密格式会明确失败。")
        archivePassword.widthAnchor.constraint(greaterThanOrEqualToConstant:200).isActive=true
        let passwordRow=row([NSTextField(labelWithString:L10n.text("输入此压缩包密码")),archivePassword,unlock])
        let remove = button("计划删除所选", #selector(deleteSelected)), add = button("添加文件…", #selector(addFiles)), clear = button("撤销编辑计划", #selector(clearPlan)), save = button("保存编辑副本…", #selector(saveEditedCopy))
        cleanHidden.target = self; cleanHidden.action = #selector(planChanged)
        let original=button("保存到原压缩包…",#selector(saveOriginal));originalButton=original;copyButton=save
        editButtons = [remove, add, clear, save,original]; selectedButtons.append(remove)
        let edit = row([remove, add, cleanHidden, clear, save,original])
        extractName.setAccessibilityLabel(L10n.text("提取目录名称")); copyName.setAccessibilityLabel(L10n.text("编辑副本名称"))
        extractName.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        copyName.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let names = row([NSTextField(labelWithString: L10n.text("提取目录名称")), extractName, NSTextField(labelWithString: L10n.text("编辑副本名称")), copyName])
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("ZIP/7Z 可在此输入密码读取目录并保存到原包；原位保存先核验重建结果并保留安全备份。也可另存未加密编辑副本。其他格式按实际支持提供预览或提取。"))
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        let cancel = button("取消操作", #selector(cancelArchiveOperation)), main = button("用搞操作打开", #selector(openInMainApp))
        let bottom = row([explanation, cancel, main]); heading.font = .boldSystemFont(ofSize: 14)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3
        heading.maximumNumberOfLines = 1; heading.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [heading,passwordRow,browse,split,edit,names,status,bottom])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for child in [passwordRow,browse,split,edit,names,status,bottom] {
            child.translatesAutoresizingMaskIntoConstraints = false; child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        view = stack; preferredContentSize = NSSize(width:1_100,height:700);updateButtons()
    }
    private func button(_ key: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: L10n.text(key), target: self, action: action); result.bezelStyle = .rounded; result.controlSize = .small
        return result
    }
    private func row(_ views: [NSView]) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 8; return stack }
    override func viewWillAppear() {
        super.viewWillAppear(); if access == nil, let archiveURL { access = ArchiveQuickLookResourceAccess(url: archiveURL) }
    }
    override func viewDidDisappear() {
        super.viewDidDisappear(); generation = UUID(); selectionPanel?.cancel(nil); selectionPanel = nil
        cancellation?.cancel();archivePassword.stringValue="";access = nil; additions = []; document = nil; roots = []; allNodes = [:]; outline.reloadData(); updateButtons()
    }
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        _ = view
        generation = UUID(); selectionPanel?.cancel(nil); selectionPanel = nil
        document = nil;archivePassword.stringValue="";archiveURL = url; access = nil
        roots = []; allNodes = [:]; outline.reloadData(); updateButtons()
        startPreview(url, request: NativeArchivePreviewRequest(token: generation, completion: handler))
    }
    private func startPreview(_ url: URL, request: NativeArchivePreviewRequest) {
        guard request.proceed(ifLatest: generation) else { return }
        if working {
            cancellation?.cancel()
            group.notify(queue: .main) { [weak self] in
                guard let self else { request.finish(); return }
                self.startPreview(url, request: request)
            }
            return
        }
        archiveURL = url; access = ArchiveQuickLookResourceAccess(url: url)
        additions = []; deletions = []; cleanHidden.state = .off; document = nil; roots = []; allNodes = [:]
        search.stringValue = ""; outline.reloadData(); heading.stringValue = url.lastPathComponent
        extractName.stringValue = url.deletingPathExtension().lastPathComponent + "-" + L10n.text("提取")
        copyName.stringValue = url.deletingPathExtension().lastPathComponent + "-" + L10n.text("编辑") + "." + url.pathExtension
        perform("正在读取压缩目录…", retaining: access.map { [$0] } ?? [], work: { stop in try NativeArchivePreviewContent.load(url,cancellation:stop) }) { [weak self] result in
            // Every host request finishes once, including superseded requests.
            defer { request.finish() }
            guard let self, request.proceed(ifLatest: self.generation) else { return }
            switch result {
            case .success(.interactive(let value)):
                do {
                    try self.buildTree(value.items); self.document = value
                    self.status.stringValue = L10n.format("已读取 %ld 项；原压缩包保持不变。", value.items.count)
                    if let reason = value.editCopyUnavailableReason { self.status.stringValue += "\n" + L10n.text(reason) }
                    self.preview.showMessage(L10n.text("选择一个普通文件以预览内容。"))
                } catch { self.document = nil; self.preview.showMessage(error.localizedDescription); self.status.stringValue = error.localizedDescription }
            case .success(.readOnly(let listing)):
                self.document = nil
                self.status.stringValue = L10n.text("此格式当前提供只读目录；提取和编辑请使用主应用。")
                self.preview.showListing(listing)
            case .failure(let error):
                self.document = nil; self.status.stringValue = error.localizedDescription; self.preview.showMessage(error.localizedDescription)
            }
            self.updateButtons()
        }
    }
    private func currentContext() -> NativeArchiveRequestContext { NativeArchiveRequestContext(token: generation, document: document) }
    private func isCurrent(_ context: NativeArchiveRequestContext) -> Bool { context.matches(token: generation, document: document) }
    private func buildTree(_ items: [NativeArchive.Item]) throws {
        try NativeArchive.validateTree(items)
        roots = []; allNodes = [:]
        for item in items {
            var previous: Node?, path = ""
            for piece in item.path.split(separator: "/") {
                path = path.isEmpty ? String(piece) : path + "/" + piece
                let node: Node
                if let found = allNodes[path] { node = found }
                else {
                    node = Node(path: path); allNodes[path] = node
                    if let previous { previous.children.append(node) } else { roots.append(node) }
                }
                previous = node
            }
            previous?.item = item
        }
        func sort(_ nodes: inout [Node]) {
            nodes.sort { $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory }
            for node in nodes { sort(&node.children) }
        }
        sort(&roots); outline.reloadData(); outline.expandItem(nil, expandChildren: true)
    }
    private func visibleChildren(_ node: Node?) -> [Node] {
        let children = node?.children ?? roots, query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return children }
        func matches(_ node: Node) -> Bool { node.path.localizedCaseInsensitiveContains(query) || node.children.contains(where: matches) }
        return children.filter(matches)
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { visibleChildren(item as? Node).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { visibleChildren(item as? Node)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = NSTextField(labelWithString: "")
        let deleted = deletions.contains { node.path == $0 || node.path.hasPrefix($0 + "/") }
        let suffix = node.item?.encrypted == true ? " 🔒" : ""
        let size = node.item?.kind == .file ? "   " + ByteCountFormatter.string(fromByteCount: node.item!.size, countStyle: .file) : ""
        cell.stringValue = (node.isDirectory ? "▸ " : "") + node.name + suffix + size + (deleted ? "   " + L10n.text("计划删除") : "")
        cell.textColor = deleted ? .secondaryLabelColor : .labelColor
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        if !working, selectedNodes.count == 1, selectedNodes.first?.item?.kind == .file { previewSelected() }
    }
    func controlTextDidChange(_ notification: Notification) { outline.reloadData(); outline.expandItem(nil, expandChildren: true); updateButtons() }
    private var selectedNodes: [Node] { outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node } }
    private func updateButtons() {
        let ready = !working && selectionPanel == nil && document != nil
        actionButtons.forEach { $0.isEnabled = ready }; editButtons.forEach { $0.isEnabled = ready && canEditOriginal }
        cleanHidden.isEnabled = ready && canEditOriginal
        copyButton?.isEnabled=ready && document?.canEditCopy == true
        unlockButton?.isEnabled = !working && selectionPanel == nil && archiveURL.map{["zip","7z"].contains($0.pathExtension.lowercased())} == true
        let reason = document?.editCopyUnavailableReason.map { L10n.text($0) }
        editButtons.forEach { $0.toolTip = canEditOriginal ? nil:reason }; cleanHidden.toolTip = canEditOriginal ? nil:reason; copyName.toolTip = reason;copyButton?.toolTip=reason
        selectedButtons.forEach { $0.isEnabled = $0.isEnabled && !selectedNodes.isEmpty }
        extractName.isEnabled = !working && selectionPanel == nil; copyName.isEnabled = !working && selectionPanel == nil
        archivePassword.isEnabled = !working && selectionPanel == nil
    }
    private var canEditOriginal:Bool {document.map{["zip","7z"].contains($0.format) && !$0.items.contains{$0.kind == .unsupported}} ?? false}
    @objc private func expandAll() { outline.expandItem(nil, expandChildren: true) }
    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }
    @objc private func cancelArchiveOperation() {
        if let selectionPanel { selectionPanel.cancel(nil); return }
        cancellation?.cancel(); if working { status.stringValue = L10n.text("正在停止；请等待后台操作结束后核对结果。") }
    }
    @objc private func previewSelected() {
        guard !working, let document, selectedNodes.count == 1, let item = selectedNodes.first?.item, item.kind == .file else { return }
        let context = currentContext()
        guard let password = requestedPassword(for: item.encrypted, context: context), isCurrent(context), !working else { return }
        perform("正在预览所选内容…", retaining: access.map { [$0] } ?? [], work: { stop in
            try NativeArchive.memberData(document, path: item.path, password: password.isEmpty ? nil : password, cancellation: stop)
        }) { [weak self] result in
            guard let self, self.isCurrent(context) else { return }
            switch result {
            case .success(let bytes):
                do { try self.preview.show(data: bytes, filename: item.path); self.status.stringValue = item.path }
                catch { self.preview.showMessage(error.localizedDescription); self.status.stringValue = error.localizedDescription }
            case .failure(let error): self.preview.showMessage(error.localizedDescription); self.status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func extractSelected() { extract(selected: Set(selectedNodes.map(\.path))) }
    @objc private func extractAll() { extract(selected: nil) }
    private func extract(selected: Set<String>?) {
        guard !working, let document, selected == nil || !selected!.isEmpty else { return }
        let encrypted = document.items.contains { item in item.encrypted && (selected == nil || selected!.contains { item.path == $0 || item.path.hasPrefix($0 + "/") }) }
        let context = currentContext()
        guard let password = requestedPassword(for: encrypted, context: context), isCurrent(context), !working else { return }
        let name = extractName.stringValue
        chooseDirectory(context: context) { [weak self] directory, scope in
            guard let self, self.isCurrent(context) else { return }
            self.perform("正在核验并提取内容…", retaining: (self.access.map { [$0] } ?? []) + [scope], work: { stop in
                try NativeArchive.extract(document, selected: selected, directory: directory, name: name, password: password.isEmpty ? nil : password, cancellation: stop)
            }) { [weak self] result in guard let self, self.isCurrent(context) else { return }; self.showOutput(result) }
        }
    }
    @objc private func deleteSelected() { guard !working,canEditOriginal else { return }; deletions.formUnion(selectedNodes.map(\.path)); outline.reloadData(); planChanged() }
    @objc private func addFiles() {
        guard !working,canEditOriginal else { return }
        let context = currentContext()
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("加入编辑计划"); panel.message = L10n.text("文件只加入编辑计划；确认保存前不会写入原压缩包。")
        presentSelectionPanel(panel, context: context) { [weak self] urls in
            guard let self else { return }
            self.additions += urls.map { ArchiveQuickLookResourceAccess(url: $0) }; self.planChanged()
        }
    }
    @objc private func clearPlan() { guard !working else { return }; deletions = []; additions = []; cleanHidden.state = .off; outline.reloadData(); planChanged() }
    @objc private func planChanged() { status.stringValue = L10n.format("计划删除 %ld 项，添加 %ld 项；原压缩包尚未改变。", deletions.count, additions.count); updateButtons() }
    @objc private func saveEditedCopy() {
        guard !working, let document, document.canEditCopy else { return }
        let context = currentContext()
        let deleted = deletions, added = additions, hidden = cleanHidden.state == .on, name = copyName.stringValue
        guard !deleted.isEmpty || !added.isEmpty || hidden else { status.stringValue = L10n.text("请先选择增删或隐藏项目清理计划。") ; return }
        chooseDirectory(context: context) { [weak self] directory, scope in
            guard let self, self.isCurrent(context) else { return }
            self.perform("正在生成并完整核验编辑副本…", retaining: (self.access.map { [$0] } ?? []) + added + [scope], work: { stop in
                try NativeArchive.editedCopy(document, deleting: deleted, adding: added.map(\.url), cleanHidden: hidden, directory: directory, name: name, cancellation: stop)
            }) { [weak self] result in guard let self, self.isCurrent(context) else { return }; self.showOutput(result) }
        }
    }
    @objc private func unlockArchive() {
        guard !working,let archiveURL else{return}
        let context=currentContext()
        guard let password=requestedPassword(for:true,context:context),isCurrent(context) else{return}
        perform("正在读取加密目录…",retaining:access.map{[$0]} ?? [],work:{stop in
            let request=try QuickLookEditEngine.request(kind:.inspect,url:archiveURL,password:password,cancellation:stop)
            let response=try QuickLookEditEngine.run(request,cancellation:stop)
            return try Self.document(archiveURL,response:response,digest:request.sha256,stop:stop)
        }){[weak self] result in
            guard let self,self.isCurrent(context) else{return}
            switch result {
            case .success(let value):
                do {try self.buildTree(value.items);self.document=value;self.preview.showMessage(L10n.text("选择一个普通文件以预览内容。"));self.status.stringValue=L10n.format("已读取 %ld 项；原压缩包保持不变。",value.items.count)}catch{self.status.stringValue=error.localizedDescription}
            case .failure(let error):self.status.stringValue=error.localizedDescription
            };self.updateButtons()
        }
    }
    private static func document(_ url:URL,response:QuickLookArchiveEditResponse,digest:String,stop:NativeArchive.Cancellation)throws->NativeArchive.Document {
        let items=response.members.map{NativeArchive.Item(path:$0.path,size:Int64(clamping:$0.size),kind:$0.directory ? .directory:.file,mode:$0.permissions ?? ($0.directory ? 0o700:0o600),modified:0,encrypted:$0.encrypted)}
        return try NativeArchive.documentFromVerifiedManifest(url,items:items,digest:digest,cancellation:stop)
    }
    @objc private func saveOriginal() {
        guard !working,canEditOriginal,let document else{return}
        let context=currentContext(),deleted=deletions,added=additions,hidden=cleanHidden.state == .on
        guard !deleted.isEmpty || !added.isEmpty || hidden else {status.stringValue=L10n.text("请先选择增删或隐藏项目清理计划。");return}
        guard let password=requestedPassword(for:document.items.contains(where:\.encrypted),context:context),isCurrent(context) else{return}
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=false
        panel.directoryURL=document.url.deletingLastPathComponent();panel.prompt=L10n.text("授权并保存到原包")
        panel.message=L10n.text("请选择原压缩包所在文件夹。保存前会保留原件备份；不会覆盖编辑期间被其他程序更改的文件。")
        presentSelectionPanel(panel,context:context){[weak self] urls in
            guard let self,let directory=urls.first,self.isCurrent(context),directory.resolvingSymlinksInPath()==document.url.deletingLastPathComponent().resolvingSymlinksInPath() else {self?.status.stringValue=L10n.text("所选文件夹不是原压缩包目录，未执行保存。");return}
            let scope=ArchiveQuickLookResourceAccess(url:directory)
            self.perform("正在核验并保存原压缩包…",retaining:(self.access.map{[$0]} ?? [])+added+[scope],originalMayChange:true,work:{stop in
                let request=try QuickLookEditEngine.request(kind:.saveOriginal,url:document.url,password:password.isEmpty ? nil:password,adding:added.map(\.url),removing:Array(deleted),removeHidden:hidden,cancellation:stop)
                guard request.sha256==document.digest else {throw NativeArchive.Failure(message:L10n.text("压缩包在编辑期间发生变化，未保存到原包。"))}
                let response=try QuickLookEditEngine.run(request,directory:directory,cancellation:stop)
                guard let digest=response.resultSHA256 else {throw CocoaError(.fileReadCorruptFile)}
                return (try Self.document(document.url,response:response,digest:digest,stop:NativeArchive.Cancellation()),response.backup)
            }){[weak self] result in
                guard let self,self.isCurrent(context) else{return}
                switch result {
                case .success(let (value,backup)):
                    do {self.deletions=[];self.additions=[];self.cleanHidden.state = .off;try self.buildTree(value.items);self.document=value;self.preview.showMessage(L10n.text("选择一个普通文件以预览内容。"));self.status.stringValue=L10n.text("已核验并保存到原压缩包。")+(backup.map{"\n"+L10n.text("安全备份：")+$0.path} ?? "")}catch{self.status.stringValue=error.localizedDescription}
                case .failure(let error):self.status.stringValue=error.localizedDescription
                };self.updateButtons()
            }
        }
    }
    private func chooseDirectory(context: NativeArchiveRequestContext, _ completion: @escaping (URL, ArchiveQuickLookResourceAccess) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = L10n.text("选择结果目录"); panel.message = L10n.text("仅访问你选中的目录；同名结果停止，原压缩包保留。")
        presentSelectionPanel(panel, context: context) { urls in
            guard urls.count == 1, let url = urls.first else { return }
            completion(url, ArchiveQuickLookResourceAccess(url: url))
        }
    }
    private func presentSelectionPanel(_ panel: NSOpenPanel, context: NativeArchiveRequestContext, completion: @escaping ([URL]) -> Void) {
        guard !working, selectionPanel == nil, isCurrent(context) else { return }
        guard let parent = view.window, parent.isVisible, parent.attachedSheet == nil else {
            status.stringValue = L10n.text("当前预览窗口不可用，请关闭预览后用搞操作打开。")
            return
        }
        // Finder hosts a remote view. An unattached modeless open panel can
        // abort without becoming key; attach the Powerbox to this preview.
        selectionPanel = panel; updateButtons()
        panel.beginSheetModal(for: parent) { [weak self, weak panel] response in
            guard let self, let panel, self.selectionPanel === panel else { return }
            panel.orderOut(nil); self.selectionPanel = nil; self.updateButtons()
            guard !self.working, self.isCurrent(context) else { return }
            switch response {
            case .OK:
                guard !panel.urls.isEmpty else {
                    self.status.stringValue = L10n.text("未获得所选位置的访问权限，未执行操作。")
                    return
                }
                completion(panel.urls)
            case .cancel:
                self.status.stringValue = L10n.text("已取消选择，未执行操作，原压缩包保持不变。")
            default:
                self.status.stringValue = L10n.text("预览宿主无法显示选择窗口，请用搞操作打开后重试。")
            }
        }
    }
    private func requestedPassword(for encrypted: Bool, context: NativeArchiveRequestContext) -> String? {
        guard isCurrent(context), !working else { return nil }
        guard encrypted else { return "" }
        guard !archivePassword.stringValue.isEmpty else {
            status.stringValue=L10n.text("输入此压缩包密码")
            view.window?.makeFirstResponder(archivePassword)
            return nil
        }
        return archivePassword.stringValue
    }
    private func showOutput(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): status.stringValue = L10n.format("已核验并保存：%@；原压缩包保持不变。", url.lastPathComponent)
        case .failure(let error): status.stringValue = error.localizedDescription
        }
    }
    private func perform<T>(_ title: String, retaining resources: [ArchiveQuickLookResourceAccess],originalMayChange:Bool=false, work: @escaping (NativeArchive.Cancellation) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        guard !working else { completion(.failure(NativeArchive.Failure(message: "正在停止；等待后台操作结束，原压缩包保持不变。"))); return }
        working = true; let stop = NativeArchive.Cancellation(seconds:120,originalMayChange:originalMayChange), job = UUID()
        cancellation = stop; activeJob = job; status.stringValue = L10n.text(title); updateButtons(); group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self, resources] in
            let result: Result<T, Error> = withExtendedLifetime(resources) {
                do { return .success(try work(stop)) }
                catch let failure {
                    // A library callback can return a generic decode error when
                    // its input callback observed cancellation. Preserve the
                    // actual cancellation/deadline reason in that case.
                    do { try stop.check(); return .failure(failure) }
                    catch { return .failure(error) }
                }
            }
            DispatchQueue.main.async {
                if self.activeJob == job { self.working = false; self.cancellation = nil; self.updateButtons() }
                completion(result)
                self.group.leave()
            }
        }
    }
    @objc private func openInMainApp() {
        guard let archiveURL, let request = ArchiveQuickLookHandoff.selectionRequest(for: archiveURL) else { return }
        let bundle = Bundle(for: type(of: self)).bundleURL
        let app = bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "appex", app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == "com.gaoseries.GaoCaoZuo",
              let handler = NSWorkspace.shared.urlForApplication(toOpen: request),
              handler.standardizedFileURL.resolvingSymlinksInPath() == app.standardizedFileURL.resolvingSymlinksInPath(),
              let context = extensionContext else { showHandoffFailure(); return }
        let requestContext = currentContext()
        let scope = access ?? ArchiveQuickLookResourceAccess(url: archiveURL)
        context.open(request) { [weak self, scope] accepted in
            withExtendedLifetime(scope) {
                ArchiveQuickLookDiagnostics.logger.notice("phase=host-open-result accepted=\(accepted,privacy:.public)")
                if !accepted { DispatchQueue.main.async { guard let self, self.isCurrent(requestContext) else { return }; self.showHandoffFailure() } }
            }
        }
    }
    private func showHandoffFailure() { status.stringValue = L10n.text("请关闭预览，在 Finder 中选择“打开方式”→“搞操作”。") }
}
