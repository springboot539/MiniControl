import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// All display mutations are serialized and bounded to an explicit operation.
private let wakeLock = NSLock()
private var wakeBusy = false
private var lastWake = Date.distantPast
private var reconcileScheduled = false
private let wakeCooldown: TimeInterval = 15
private func beginWake() -> Bool {
    wakeLock.lock(); defer { wakeLock.unlock() }
    guard !wakeBusy, Date().timeIntervalSince(lastWake) >= wakeCooldown else { return false }
    wakeBusy = true; return true
}
private func endWake(applyCooldown: Bool = true) { wakeLock.lock(); wakeBusy = false; if applyCooldown { lastWake = Date() }; wakeLock.unlock() }
private func normalized(_ name: String) -> String {
    name.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined().lowercased()
}
private func matchesAirPlay(_ screen: String, target: String) -> Bool {
    normalized(screen) == normalized(target) + "(airplay)"
}
private enum DisplayState { case present, absent, unknown }
private func displayState(target: String) -> DisplayState {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return .unknown }
    var ids = [CGDirectDisplayID](repeating:0, count:Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return .unknown }
    ids = Array(ids.prefix(Int(count)))
    let screens: [(CGDirectDisplayID,String)] = DispatchQueue.main.sync {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        }
    }
    if screens.contains(where: { ids.contains($0.0) && matchesAirPlay($0.1,target:target) }) { return .present }
    // A sleeping or unmapped display is not proof of absence.
    if ids.allSatisfy({ id in screens.contains(where: { $0.0 == id }) }) { return .absent }
    return .unknown
}
private func onlyBuiltInOnline() -> Bool {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count == 1 else { return false }
    var id: CGDirectDisplayID = 0
    return CGGetOnlineDisplayList(1, &id, &count) == .success && count == 1 && CGDisplayIsBuiltin(id) != 0
}
private func displayMenuItem(target: String) -> AXUIElement? {
    guard AXIsProcessTrusted(), let app = openDisplays() else { return nil }
    let buttons = tree(app).filter { e in
        let role = str(e,kAXRoleAttribute), title = str(e,kAXTitleAttribute).trimmingCharacters(in:.whitespacesAndNewlines).lowercased(), d = description(e).lowercased()
        return (role == "AXPopUpButton" || role == "AXMenuButton" || role == "AXButton") && (d.contains("添加显示器") || d.contains("add display") || d.contains("添加显示") || d.trimmingCharacters(in:.whitespaces) == "+" || (role == "AXPopUpButton" && (title == "添加" || title == "add")))
    }
    guard buttons.count == 1, press(buttons[0]) else { return nil }
    pause(0.6)
    var inSection = false; var matches: [AXUIElement] = []
    for e in tree(app).filter({ str($0,kAXRoleAttribute) == "AXMenuItem" }) {
        let title = str(e,kAXTitleAttribute), lower = title.lowercased()
        if ["镜像或扩展至","mirror or extend to","mirror or extend"].contains(where: { lower.contains($0) }) { inSection = true; continue }
        if lower.contains("连接键盘") || lower.contains("link keyboard") || lower.contains("connect keyboard") { inSection = false }
        if inSection && normalized(title) == normalized(target) { matches.append(e) }
    }
    return matches.count == 1 ? matches[0] : nil
}
private func hideSettings() { NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.systempreferences").first?.hide() }
private func marker(_ item: AXUIElement) -> (AXError,String?) {
    var v: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(item, "AXMenuItemMarkChar" as CFString, &v)
    return (result,v as? String)
}
private func waitForState(_ desired: DisplayState, target: String, seconds: Int) -> Bool {
    for _ in 0..<(seconds * 2) { if displayState(target:target) == desired { return true }; pause(0.5) }
    return displayState(target:target) == desired
}
private func disconnectTarget(target: String) -> Bool {
    guard displayState(target:target) == .present, let item = displayMenuItem(target:target) else { return false }
    let (result, mark) = marker(item)
    // Never toggle an item unless it is explicitly marked as connected.
    guard result == .success, let mark = mark, !mark.isEmpty, press(item) else { return false }
    return waitForState(.absent,target:target,seconds:12)
}
private func cleanupExisting(target: String) -> Bool {
    switch displayState(target:target) {
    case .absent: return true
    case .unknown: log("DisplayAutomation", "AirPlay state unknown"); return false
    case .present:
        log("DisplayAutomation", "Existing target AirPlay detected; attempting disconnect")
        let ok = disconnectTarget(target:target); hideSettings()
        log("DisplayAutomation", "Existing target AirPlay disconnect: \(ok ? "verified" : "failed")")
        return ok
    }
}
func inspectExistingAirPlay() {
    guard beginWake() else { return }
    defer { endWake(applyCooldown:false) }
    let target = defaults.string(forKey:"target") ?? defaultTarget
    switch displayState(target:target) {
    case .absent: return
    case .present:
        guard AXIsProcessTrusted(), cleanupExisting(target:target) else { notice("需要清理 AirPlay", "发现目标显示连接，但未能安全断开；请在系统设置中停止该连接。") ; return }
        notice("已结束旧显示连接", "Mac mini 已不再作为 Air 的扩展显示器。")
    case .unknown: log("DisplayAutomation", "Startup AirPlay status unknown")
    }
}
private func validIdentity(_ user: String, _ host: String) -> Bool {
    guard !user.isEmpty, !host.isEmpty, user.count <= 64, host.count <= 253,
          user.range(of:"^[A-Za-z_][A-Za-z0-9._-]*[$]?$",options:.regularExpression) != nil,
          host.range(of:"^[A-Za-z0-9][A-Za-z0-9.-]*$",options:.regularExpression) != nil else { return false }
    return true
}
private func sshCommand(user: String, host: String, command: String) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/ssh")
    p.arguments = ["-o","BatchMode=yes", "-o","ConnectTimeout=6", "-o","ServerAliveInterval=3", "-o","ServerAliveCountMax=1", "-o","StrictHostKeyChecking=yes", "-l",user,host,command]
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+15) { if p.isRunning { p.terminate() } }
        p.waitUntilExit(); return p.terminationStatus
    } catch { log("DisplayAutomation", "SSH process error: \(error.localizedDescription)"); return -1 }
}
private func airPlayPulse(target: String) -> Bool {
    guard AXIsProcessTrusted(), displayState(target:target) == .absent, onlyBuiltInOnline(), let item = displayMenuItem(target:target) else { hideSettings(); return false }
    let (r, mark) = marker(item)
    guard (r == .noValue || (r == .success && mark == "")), press(item) else { hideSettings(); return false }
    log("DisplayAutomation", "AirPlay wake pulse: connect requested")
    guard waitForState(.present,target:target,seconds:60) else {
        // A late appearance must never be reported as cleaned up.
        let state = displayState(target:target)
        if state == .present { _ = disconnectTarget(target:target) }
        hideSettings(); return false
    }
    log("DisplayAutomation", "AirPlay wake pulse: connected; disconnecting")
    pause(2)
    let disconnected = disconnectTarget(target:target)
    hideSettings()
    log("DisplayAutomation", "AirPlay wake pulse: disconnect \(disconnected ? "verified" : "failed")")
    return disconnected
}
func wakeMini() {
    guard beginWake() else { log("DisplayAutomation", "Wake request suppressed: busy/cooldown"); return }
    let target = defaults.string(forKey:"target") ?? defaultTarget
    let host = (defaults.string(forKey:"miniHost") ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
    let user = (defaults.string(forKey:"miniUser") ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
    DispatchQueue.global(qos:.userInitiated).async {
        defer { endWake() }
        log("DisplayAutomation", "ACTION: Wake Mini Display; HOST: \(host)")
        guard cleanupExisting(target:target) else { notice("无法确认显示连接", "请在系统设置中检查并停止 Mini 的 AirPlay 扩展后重试。"); return }
        guard validIdentity(user,host) else { notice("请设置 SSH 信息", "在 MiniControl 设置中填写 Mini 的 SSH 用户名和主机名。"); return }
        let code = sshCommand(user:user,host:host,command:"/usr/bin/caffeinate -u -t 3")
        log("DisplayAutomation", "METHOD: SSH caffeinate; EXIT CODE: \(code); \(code == 0 ? "command sent" : "failed")")
        if code == 0 { DispatchQueue.main.async { controller.flashDisplay("已发送显示器唤醒请求") }; return }
        log("DisplayAutomation", "SSH failed; attempting temporary AirPlay pulse")
        if airPlayPulse(target:target) { DispatchQueue.main.async { controller.flashDisplay("已完成临时唤醒操作") } }
        else { notice("Mini 唤醒未完成", "SSH 或临时唤醒失败。请检查远程登录、SSH 信任和 AirPlay 状态；确保 Mini 已恢复独立显示。") }
    }
}

func wakeSelfTests() -> Bool {
    let tests: [(Bool,String)] = [
        (validIdentity("exampleuser","mac-mini.local"), "normal SSH identity"),
        (!validIdentity("","mini.local"), "empty user"),
        (!validIdentity("-oProxyCommand=x","mini.local"), "option injection"),
        (!validIdentity("user","mini.local;touch /tmp/x"), "host injection"),
        (normalized("Example Mac mini") == normalized("ExampleMacmini"), "device name spaces"),
        (matchesAirPlay("ExampleMacmini (AirPlay)", target:"Example Mac mini"), "AirPlay display name"),
        (!matchesAirPlay("ExampleMacmini", target:"Example Mac mini"), "do not match physical displays")
    ]
    for (ok,name) in tests { print("\(ok ? "PASS" : "FAIL") \(name)") }
    return tests.allSatisfy { $0.0 }
}

// Use only when the user observes that a successful SSH command did not light the display.
func wakeMiniUsingFallback() {
    guard beginWake() else { log("DisplayAutomation", "Fallback suppressed: busy/cooldown"); return }
    let target = defaults.string(forKey:"target") ?? defaultTarget
    DispatchQueue.global(qos:.userInitiated).async {
        defer { endWake() }
        log("DisplayAutomation", "ACTION: User-requested temporary AirPlay wake pulse")
        guard cleanupExisting(target:target) else { notice("无法确认显示连接", "请检查并停止 Mini 的 AirPlay 扩展后重试。") ; return }
        if airPlayPulse(target:target) { DispatchQueue.main.async { controller.flashDisplay("临时唤醒操作已完成") } }
        else { notice("备用唤醒未完成", "未能确认临时连接已清理，请在系统设置中检查 AirPlay 状态。") }
    }
}

// Event-driven guard for displays that connect after an AirPlay request timed out.
// There is no periodic scan during normal idle operation.
func scheduleDisplayReconcile() {
    wakeLock.lock()
    if reconcileScheduled { wakeLock.unlock(); return }
    reconcileScheduled = true; wakeLock.unlock()
    DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+2) { reconcileDisplay() }
}
private func reconcileDisplay() {
    wakeLock.lock()
    if wakeBusy {
        wakeLock.unlock()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+2) { reconcileDisplay() }
        return
    }
    wakeBusy = true; reconcileScheduled = false; wakeLock.unlock()
    defer { endWake(applyCooldown:false) }
    let target = defaults.string(forKey:"target") ?? defaultTarget
    if displayState(target:target) == .present {
        log("DisplayAutomation", "Display-change guard detected target AirPlay")
        if AXIsProcessTrusted() && cleanupExisting(target:target) {
            log("DisplayAutomation", "Display-change guard verified cleanup")
        } else {
            notice("需要手动结束 AirPlay", "检测到 Mini 的 AirPlay 连接，自动断开失败，请在系统设置中停止共享。")
        }
    }
}
private let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    if !flags.contains(.beginConfigurationFlag) { scheduleDisplayReconcile() }
}
func startDisplayGuard() {
    let status = CGDisplayRegisterReconfigurationCallback(displayCallback,nil)
    log("DisplayAutomation", "Display-change guard registration: \(status.rawValue)")
}
func stopDisplayGuard() { CGDisplayRemoveReconfigurationCallback(displayCallback,nil) }

func rescanMiniUC() -> Int32 {
    let host = (defaults.string(forKey:"miniHost") ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
    let user = (defaults.string(forKey:"miniUser") ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
    guard validIdentity(user,host) else { return -1 }
    return sshCommand(user:user,host:host,command:"/usr/bin/pkill -HUP -x UniversalControl")
}
