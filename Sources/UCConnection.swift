import AppKit
import ApplicationServices
import Foundation

private enum UCMenuState { case connected, disconnected, absent, unknown, selected }
private let ucRepairLock = NSLock()
private var ucRepairBusy = false
private func startRepair() -> Bool {
    ucRepairLock.lock(); defer { ucRepairLock.unlock() }
    if ucRepairBusy { return false }
    ucRepairBusy = true; return true
}
private func finishRepair() { ucRepairLock.lock(); ucRepairBusy = false; ucRepairLock.unlock() }
private func ucName(_ value: String) -> String {
    value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined().lowercased()
}
private func matchingUCIndex(_ titles: [String], target: String) -> Int? {
    var inSection = false; var matches: [Int] = []
    for (index,title) in titles.enumerated() {
        let lower = title.lowercased()
        if lower.contains("连接键盘和鼠标至") || lower.contains("link keyboard and mouse to") || lower.contains("connect keyboard and mouse to") { inSection = true; continue }
        if lower.contains("镜像或扩展至") || lower.contains("mirror or extend") { inSection = false; continue }
        if inSection && ucName(title) == ucName(target) { matches.append(index) }
    }
    return matches.count == 1 ? matches[0] : nil
}
private func ucMenuState(target: String, selectIfDisconnected: Bool) -> UCMenuState {
    guard AXIsProcessTrusted(), let app = openDisplays() else { return .unknown }
    let buttons = tree(app).filter { e in
        let role = str(e,kAXRoleAttribute)
        let title = str(e,kAXTitleAttribute).trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let d = description(e).lowercased()
        return (role == "AXPopUpButton" || role == "AXMenuButton" || role == "AXButton") && (d.contains("添加显示器") || d.contains("add display") || d.contains("添加显示") || d.trimmingCharacters(in:.whitespaces) == "+" || (role == "AXPopUpButton" && (title == "添加" || title == "add")))
    }
    guard buttons.count == 1, press(buttons[0]) else { return .unknown }
    pause(0.6)
    let items = tree(app).filter { str($0,kAXRoleAttribute) == "AXMenuItem" }
    let titles = items.map { str($0,kAXTitleAttribute) }
    guard let index = matchingUCIndex(titles,target:target) else { return .absent }
    let item = items[index]
    var attributeNames: CFArray?
    guard AXUIElementCopyAttributeNames(item, &attributeNames) == .success,
          let names = attributeNames as? [String], names.contains("AXMenuItemMarkChar") else { return .unknown }
    var mark: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(item, "AXMenuItemMarkChar" as CFString, &mark)
    if result == .success, let value = mark as? String, !value.isEmpty { return .connected }
    let isUnmarked = result == .noValue || (result == .success && (mark as? String) == "")
    guard isUnmarked else { return .unknown }
    guard selectIfDisconnected else { return .disconnected }
    guard (attr(item,kAXEnabledAttribute) as? Bool) == true, press(item) else { return .unknown }
    return .selected
}
private func tryUCConnection(target: String) -> UCMenuState {
    let first = ucMenuState(target:target,selectIfDisconnected:true)
    guard first == .selected else { return first }
    log("UniversalControl", "Requested keyboard and mouse connection")
    pause(2)
    // Only the system's checked state is reported as confirmed.
    let after = ucMenuState(target:target,selectIfDisconnected:false)
    return after == .connected ? .connected : .selected
}
func repairUCManually(force: Bool) {
    guard startRepair() else { log("UniversalControl", "Manual repair already running"); return }
    watcher.queue.async { watcher.recoveryStage = 0; watcher.lastRecovery = Date() }
    let target = defaults.string(forKey:"target") ?? defaultTarget
    DispatchQueue.global(qos:.userInitiated).async {
        defer {
            NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.systempreferences").first?.hide()
            finishRepair()
        }
        guard AXIsProcessTrusted() else { notice("需要辅助功能权限", "请允许 MiniControl 操作系统设置，以检查并恢复键盘和鼠标连接。") ; return }
        log("UniversalControl", "ACTION: manual repair; target=\(target); force=\(force)")
        if force {
            let code = shell("/usr/bin/killall",["UniversalControl"])
            log("UniversalControl", "Local force signal exit=\(code)")
            pause(3)
        }
        var state = tryUCConnection(target:target)
        if state != .connected && state != .selected {
            let code = shell("/usr/bin/pkill",["-HUP","-x","UniversalControl"])
            log("UniversalControl", "Local HUP exit=\(code)")
            pause(4)
            state = tryUCConnection(target:target)
        }
        if state != .connected && state != .selected {
            let code = rescanMiniUC()
            log("UniversalControl", "Mini HUP exit=\(code)")
            pause(6)
            state = tryUCConnection(target:target)
        }
        switch state {
        case .connected:
            log("UniversalControl", "RESULT: System reports target checked")
            DispatchQueue.main.async { controller.flashUC("键盘和鼠标已连接到 Mac mini") }
        case .selected:
            log("UniversalControl", "RESULT: connection requested; not confirmed")
            notice("UC 连接尚未确认", "已请求连接 Mini，但系统未能确认连接状态。")
        case .absent, .unknown, .disconnected:
            log("UniversalControl", "RESULT: Target connection not confirmed")
            notice("UC 未能连接", "系统未能确认 Mini 的键盘和鼠标连接；请检查两台设备是否解锁及系统设置。")
        }
    }
}
func ucSelfTests() -> Bool {
    let target = "Example Mac mini"
    let tests: [(Bool,String)] = [
        (matchingUCIndex(["镜像或扩展至","ExampleMacmini","连接键盘和鼠标至","ExampleMacmini"],target:target) == 3, "select keyboard section"),
        (matchingUCIndex(["镜像或扩展至","ExampleMacmini"],target:target) == nil, "ignore AirPlay target"),
        (matchingUCIndex(["连接键盘和鼠标至","ExampleMacmini","ExampleMacmini"],target:target) == nil, "reject ambiguous target"),
        (matchingUCIndex(["Link Keyboard and Mouse to","ExampleMacmini"],target:target) == 1, "English section")
    ]
    for (ok,name) in tests { print("\(ok ? "PASS" : "FAIL") \(name)") }
    return tests.allSatisfy { $0.0 }
}
