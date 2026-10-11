import AppKit
@preconcurrency import ApplicationServices
import Combine
import FinderSync

/// Reads each system authorization independently; never writes the TCC database.
@MainActor final class PermissionsStatus: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var finderExtensionEnabled = false
    @Published private(set) var message: String?
    private enum RequestedPermission { case accessibility, inputMonitoring, finderExtension }
    private var requestedPermission: RequestedPermission?

    var readyCount: Int {
        [accessibilityGranted, inputMonitoringGranted, finderExtensionEnabled].filter { $0 }.count
    }
    var allReady: Bool { readyCount == 3 }
    var inputListeningAvailable: Bool { accessibilityGranted || inputMonitoringGranted }

    init() { refresh() }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        finderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        let requestedReady: Bool
        switch requestedPermission {
        case .accessibility: requestedReady = accessibilityGranted
        case .inputMonitoring: requestedReady = inputMonitoringGranted
        case .finderExtension: requestedReady = finderExtensionEnabled
        case nil: requestedReady = false
        }
        if allReady || requestedReady { message = nil; requestedPermission = nil }
    }

    func continueSetup() {
        refresh()
        if !accessibilityGranted { openAccessibility() }
        else if !inputMonitoringGranted { openInputMonitoring() }
        else if !finderExtensionEnabled { openFinderExtension() }
    }

    func openAccessibility() {
        refresh()
        if !accessibilityGranted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        requestedPermission = .accessibility
        message = "在“辅助功能”中开启搞操作，再返回此处继续。"
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoring() {
        refresh()
        if !inputMonitoringGranted { _ = CGRequestListenEventAccess() }
        requestedPermission = .inputMonitoring
        message = "在“输入监控”中开启搞操作；系统若要求重新打开应用，请按提示操作。"
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func openFinderExtension() {
        requestedPermission = .finderExtension
        message = "在系统扩展管理中启用“搞操作访达扩展”，再返回此处检查。"
        // Apple provides this interface to the extension's containing application.
        FIFinderSyncController.showExtensionManagementInterface()
    }

    private func openSettings(_ address: String) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
            message = "未能打开系统设置，请手动进入“隐私与安全性”开启对应权限。"
            return
        }
    }
}
