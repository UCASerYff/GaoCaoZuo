import AppKit

@MainActor extension OperationStore {
    func showFinderPopup() {
        // Finder selection is requested only for this explicit action. No clipboard or UI scraping.
        let script="""
        tell application "Finder"
            set picked to selection as alias list
            set hadSelection to (count of picked) > 0
            if (count of windows) > 0 then
                set containerAlias to target of front window as alias
            else
                set containerAlias to desktop as alias
            end if
            set output to {hadSelection, POSIX path of containerAlias}
            repeat with fileAlias in picked
                set end of output to POSIX path of fileAlias
            end repeat
            return output
        end tell
        """
        var failure:NSDictionary?
        guard let result=NSAppleScript(source:script)?.executeAndReturnError(&failure),failure == nil,result.numberOfItems>=2 else {notify("无法读取访达当前选择，请允许自动化控制 Finder，或直接使用右键菜单。",failed:true);return}
        let hasSelection=result.atIndex(1)?.booleanValue ?? false
        guard let containerPath=result.atIndex(2)?.stringValue,containerPath.hasPrefix("/") else {notify("访达目录不可用",failed:true);return}
        let container=URL(fileURLWithPath:containerPath,isDirectory:true)
        let selected=result.numberOfItems>2 ? (3...result.numberOfItems).compactMap{result.atIndex($0)?.stringValue}.map{URL(fileURLWithPath:$0)} : []
        let urls=selected.isEmpty ? [container] : selected
        guard !urls.isEmpty,urls.count<=1000 else {notify("访达没有可操作的位置",failed:true);return}
        finderPopupContainer=container;finderPopupSelection=selected;selection=urls
        let snapshot=FinderMenuSnapshot.read() ?? FinderMenuSnapshot()
        guard !FinderMenuContext.isExcluded(urls+[container],preferences:snapshot.preferences) else {notify("此目录已排除访达菜单",failed:true);return}
        let menu=FinderMenuBuilder.menu(snapshot:snapshot,urls:urls,hasSelection:hasSelection,target:self,selector:#selector(finderPopupAction(_:)))
        menu.popUp(positioning:nil,at:NSEvent.mouseLocation,in:nil)
    }
    @objc private func finderPopupAction(_ sender:NSMenuItem) {
        if let id=sender.representedObject as? String,FinderActionRequest.isAllowed(id) {let files=FinderMenuContext.usesContainer(id) ? finderPopupContainer.map{[$0]} ?? [] : finderPopupSelection.isEmpty ? finderPopupContainer.map{[$0]} ?? [] : finderPopupSelection;prepare(id,files:files)}
    }
}
