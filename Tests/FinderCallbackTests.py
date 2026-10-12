#!/usr/bin/env python3
"""Exercise the real FinderSync callback entry points from both queues."""
from pathlib import Path
import subprocess
import tempfile


PROJECT = Path(__file__).resolve().parent.parent
RUNNER = r'''
import AppKit
import FinderSync

// A CLI host has no Finder context. An unknown kind and an invalid action must
// return harmlessly, but still exercise the same Objective-C callback wrappers.
let application = NSApplication.shared
let finder = GaoFinderSync()
let unsupported = FIMenuKind(rawValue: UInt.max)!
precondition(finder.menu(for: unsupported) == nil)
let invalidAction = NSMenuItem(title: "Callback regression", action: nil, keyEquivalent: "")
finder.perform(NSSelectorFromString("openAction:"), with: invalidAction)
_ = finder.toolbarItemImage
var checks = 0
FinderCallbackMainActor.sync {
    precondition(Thread.isMainThread)
    FinderCallbackMainActor.sync {
        precondition(Thread.isMainThread)
        checks += 1
    }
}

FinderCallbackMainActor.sync {
    let selector=NSSelectorFromString("openAction:")
    var snapshot=FinderMenuSnapshot()
    snapshot.preferences.items=snapshot.preferences.items.map { value in
        var result=value;result.enabled=true;return result
    }
    let folderID=UUID().uuidString,templateID=UUID().uuidString,binaryID=UUID().uuidString,appID=UUID().uuidString
    snapshot.folders=[FinderMenuFolder(id:folderID,name:"Same title",path:"/private/tmp")]
    snapshot.templates=[FinderMenuTemplate(id:templateID,name:"Same title",binary:false),FinderMenuTemplate(id:binaryID,name:"Same title",binary:true)]
    snapshot.applications=[FinderMenuApplication(id:appID,name:"Same title")]
    let menu=FinderMenuBuilder.menu(snapshot:snapshot,urls:[URL(fileURLWithPath:"/private/tmp/callback.txt")],hasSelection:true,target:finder,selector:selector)
    let registry=FinderMenuActionRegistry(),now=Date()
    precondition(registry.assignTags(in:menu,selector:selector,now:now))
    func leaves(_ menu:NSMenu)->[NSMenuItem] {
        menu.items.flatMap { item in item.submenu.map(leaves) ?? (item.action == selector ? [item] : []) }
    }
    let items=leaves(menu),tags=items.map(\.tag)
    precondition(!items.isEmpty && tags.allSatisfy{$0>0} && Set(tags).count == tags.count)
    let actions=Set(items.compactMap{$0.representedObject as? String})
    for action in ["archive.create","folder.copy."+folderID,"folder.move."+folderID,"template."+templateID,"binaryTemplate."+binaryID,"file.open."+appID] {
        precondition(actions.contains(action),"Missing nested action sample")
    }
    for item in items {
        // Reconstruct only Finder's documented remote fields. Neither object
        // identity, title uniqueness nor representedObject may carry the command.
        let remote=NSMenuItem(title:"Same title",action:item.action,keyEquivalent:"")
        remote.tag=item.tag
        precondition(remote.representedObject == nil)
        precondition(registry.action(for:remote.tag,now:now) == item.representedObject as? String)
    }
    for tag in [0,-1,Int.max] {precondition(registry.action(for:tag,now:now) == nil)}
    precondition(registry.action(for:tags[0],now:now.addingTimeInterval(301)) == nil)
    let forged=NSMenuItem(title:"Same title",action:selector,keyEquivalent:"")
    forged.representedObject="archive.create"
    precondition(registry.action(for:forged.tag,now:now) == nil)
    precondition(registry.assignTags(in:menu,selector:selector,now:now))
    precondition(Set(tags).isDisjoint(with:Set(leaves(menu).map(\.tag))))
    for tag in tags {precondition(registry.action(for:tag,now:now) == nil)}
    let bad=NSMenuItem(title:"Unknown command",action:selector,keyEquivalent:"")
    bad.representedObject="untrusted.action"
    menu.addItem(bad)
    precondition(registry.assignTags(in:menu,selector:selector,now:now))
    precondition(bad.tag == 0 && !bad.isEnabled)
    registry.invalidate()
    for item in leaves(menu) {precondition(registry.action(for:item.tag,now:now) == nil)}
    print("FinderSync remote-copy regression passed: nested UUID actions, unique tags, stale/expired/invalid rejection")
}

var complete = false
DispatchQueue.global(qos: .userInitiated).async {
    precondition(!Thread.isMainThread)
    // Finder has delivered menu(for:) on this kind of XPC worker queue in a
    // real crash. Constructor, menu and action must all finish synchronously.
    let workerFinder = GaoFinderSync()
    precondition(workerFinder.menu(for: unsupported) == nil)
    precondition(finder.menu(for: unsupported) == nil)
    finder.perform(NSSelectorFromString("openAction:"), with: invalidAction)
    _ = finder.toolbarItemImage
    FinderCallbackMainActor.sync {
        precondition(Thread.isMainThread)
        checks += 1
    }
    DispatchQueue.main.async { complete = true }
}
let deadline = Date().addingTimeInterval(10)
while !complete && Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
}
precondition(complete, "Finder callback main-thread handoff deadlocked")
precondition(checks == 2, "Finder callback did not complete on the main thread")
print("FinderSync callback regression passed: main/nested/worker init, menu, action and image")
'''


def main():
    with tempfile.TemporaryDirectory(prefix="gaocaozuo-finder-callback-tests.", dir="/private/tmp") as staging:
        root = Path(staging)
        runner = root / "main.swift"
        runner.write_text(RUNNER)
        executable = root / "finder-callback-tests"
        sources = sorted((PROJECT / "FinderExtension").glob("*.swift"))
        sources += sorted((PROJECT / "Shared").glob("*.swift"))
        subprocess.run([
            "swiftc", "-swift-version", "5", "-Xfrontend", "-disable-sandbox",
            "-target", "arm64-apple-macos14.0", "-module-cache-path", str(root / "cache"),
            *map(str, sources), str(runner), "-framework", "FinderSync",
            "-framework", "AppKit", "-framework", "Security", "-o", str(executable)
        ], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
