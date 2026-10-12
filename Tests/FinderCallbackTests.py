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
