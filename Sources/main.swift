import Cocoa
import SwiftUI
import ApplicationServices
import Carbon
import ServiceManagement
import UserNotifications

let defaults = UserDefaults.standard
defaults.register(defaults:["target":"Example Mac mini","miniHost":"mac-mini.local","autoRepair":true,"loginDesired":true])
let defaultTarget = "Example Mac mini"
let logDir: URL = CommandLine.arguments.contains("--self-test-log")
    ? URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/MiniControl-self-test")
    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MiniControl", isDirectory:true)
let logQueue = DispatchQueue(label:"MiniControl.logs")
let maxLogSize = 5 * 1024 * 1024
func log(_ file: String, _ message: String) {
    logQueue.sync {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let f = logDir.appendingPathComponent(file + ".log")
        let raw = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let d = Data(raw.utf8.prefix(maxLogSize))
        let size = (try? FileManager.default.attributesOfItem(atPath:f.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + d.count > maxLogSize {
            let oldest = logDir.appendingPathComponent(file + ".log.5")
            try? FileManager.default.removeItem(at:oldest)
            for n in stride(from:4, through:1, by:-1) {
                let src = logDir.appendingPathComponent(file + ".log.\(n)")
                let dst = logDir.appendingPathComponent(file + ".log.\(n+1)")
                if FileManager.default.fileExists(atPath:src.path) { try? FileManager.default.moveItem(at:src,to:dst) }
            }
            if FileManager.default.fileExists(atPath:f.path) { try? FileManager.default.moveItem(at:f,to:logDir.appendingPathComponent(file + ".log.1")) }
        }
        if !FileManager.default.fileExists(atPath:f.path) { _ = FileManager.default.createFile(atPath:f.path, contents:nil) }
        if let h = try? FileHandle(forWritingTo:f) { h.seekToEndOfFile(); h.write(d); h.closeFile() }
        // Enforce a global cap across all log files, including exported trees.
        let entries = (try? FileManager.default.contentsOfDirectory(at:logDir, includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey],options:[.skipsHiddenFiles])) ?? []
        let files = entries.filter { $0.lastPathComponent != f.lastPathComponent }.sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total = entries.reduce(0) { $0 + ((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
        for old in files where total > 30 * 1024 * 1024 { let size = (try? old.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0; if (try? FileManager.default.removeItem(at:old)) != nil { total -= size } }
    }
}
func clearLogs() {
    logQueue.sync { for url in (try? FileManager.default.contentsOfDirectory(at:logDir,includingPropertiesForKeys:nil)) ?? [] { try? FileManager.default.removeItem(at:url) } }
}
var recentNotices: [String: Date] = [:]
func notice(_ title: String, _ body: String) {
    DispatchQueue.main.async {
        let now = Date()
        if let last = recentNotices[title], now.timeIntervalSince(last) < 30 { return }
        recentNotices[title] = now
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
    log("MiniControl", "\(title): \(body)")
}
func shell(_ executable: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { log("MiniControl", "Process error: \(error)"); return -1 }
}
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func tree(_ root: AXUIElement, max: Int = 12) -> [AXUIElement] {
    var result: [AXUIElement] = []; var queue: [(AXUIElement,Int)] = [(root,0)]; var index = 0
    while index < queue.count && index < 5000 { let (e, d) = queue[index]; index += 1; result.append(e); if d < max { queue += children(e).map { ($0,d+1) } } }
    return result
}
func description(_ e: AXUIElement) -> String { [str(e,kAXTitleAttribute), str(e,kAXDescriptionAttribute), str(e,kAXHelpAttribute), str(e,kAXIdentifierAttribute)].joined(separator: " ") }
func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }
func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }
func settingsApp() -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}
func openDisplays() -> AXUIElement? {
    NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    for _ in 0..<30 { pause(0.2); if let app = settingsApp(), !children(app).isEmpty { pause(1); return app } }
    return nil
}
func dumpAX(_ app: AXUIElement) {
    var lines: [String] = []; var queue: [(AXUIElement,Int)] = [(app,0)]; var i = 0
    while i < queue.count && i < 5000 { let (e,d) = queue[i]; i += 1
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute, kAXValueAttribute, "AXMenuItemMarkChar"]
        lines.append(String(repeating:"  ", count:d) + names.map { "\($0)=\(str(e,$0))" }.joined(separator:" | "))
        if d < 14 { queue += children(e).map { ($0,d+1) } }
    }
    log("AccessibilityTree", lines.joined(separator:"\n"))
}
func exportTree() {
    guard AXIsProcessTrusted() else { notice("需要辅助功能权限", "请在隐私与安全性中允许 MiniControl。") ; return }
    DispatchQueue.global(qos:.userInitiated).async { guard let app = openDisplays() else { notice("无法打开显示器设置", "请查看日志。" ); return }; dumpAX(app); NSWorkspace.shared.open(logDir.appendingPathComponent("AccessibilityTree.log")) }
}
final class UCWatcher {
    var process: Process?; var buffer = ""; var lastRecovery = Date.distantPast; var recoveryStage = 0; var lastReasonLog = Date.distantPast; var startedAt = Date.distantPast
    let queue = DispatchQueue(label:"MiniControl.UCWatcher")
    func start() {
        guard process == nil else { return }
        let p = Process(); let pipe = Pipe(); p.executableURL = URL(fileURLWithPath:"/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--level", "info", "--predicate", "(process == 'UniversalControl' OR ((process == 'rapportd' OR process == 'sharingd') AND (eventMessage CONTAINS[c] 'UniversalControl' OR subsystem CONTAINS[c] 'UniversalControl'))) AND (eventMessage CONTAINS[c] 'device unavailable' OR eventMessage CONTAINS[c] 'connection lost' OR eventMessage CONTAINS[c] 'no data connection' OR eventMessage CONTAINS[c] 'lost awdl device')"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData; guard !data.isEmpty, let s = String(data:data,encoding:.utf8) else { return }
            self?.queue.async { self?.consume(s) }
        }
        do { try p.run(); process = p; queue.sync { startedAt = Date() }; log("UniversalControl", "Watcher started; startup grace 30s") } catch { notice("UC 监控启动失败", "\(error)") }
    }
    func stop() { process?.terminate(); process = nil; queue.async { self.recoveryStage = 0 }; log("UniversalControl", "Watcher stopped") }
    func consume(_ chunk: String) {
        buffer += chunk; if buffer.utf8.count > 65536 { buffer = "" }; let lines = buffer.components(separatedBy:"\n"); buffer = lines.last ?? ""
        for line in lines.dropLast() {
            let l = line.lowercased()
            guard ["device unavailable", "connection lost", "no data connection", "lost awdl device"].contains(where: { l.contains($0) }) else { continue }
            if model.debug { log("UniversalControl", "Debug: matching disconnect event received") }
            let reason = ["device unavailable", "connection lost", "no data connection", "lost awdl device"].first(where: { l.contains($0) }) ?? "disconnect"
            if Date().timeIntervalSince(lastReasonLog) >= 30 { log("UniversalControl", "Disconnect reason: \(reason)"); lastReasonLog = Date() }
            guard defaults.bool(forKey:"autoRepair"), Date().timeIntervalSince(startedAt) >= 30 else { continue }
            let elapsed = Date().timeIntervalSince(lastRecovery)
            if elapsed >= 30 && recoveryStage == 1 {
                // A fresh disconnect after the first attempt is evidence of a continuing problem.
                recoveryStage = 2; lastRecovery = Date(); recover(true, automatic:true)
                notice("UC 持续出现断线", "已执行强制修复；请检查设备连接及日志。")
            } else if elapsed >= 30 && recoveryStage == 0 { recoveryStage = 1; lastRecovery = Date(); recover(false, automatic:true) }
        }
    }
}
let watcher = UCWatcher()
func recover(_ force: Bool, automatic: Bool = false) {
    if !automatic { repairUCManually(force:force); return }
    DispatchQueue.global(qos:.utility).async {
        let code = force ? shell("/usr/bin/killall",["UniversalControl"]) : shell("/usr/bin/pkill",["-HUP","-x","UniversalControl"])
        log("UniversalControl", "ACTION: \(force ? "killall" : "HUP") automatic=true exit=\(code); recovery not verified")
        if code != 0 { notice("UC 自动修复未完成", "未能向 UniversalControl 发送信号（退出码 \(code)）。") }
    }
}
final class SettingsModel: ObservableObject {
    @Published var target: String = defaults.string(forKey:"target") ?? defaultTarget { didSet { defaults.set(target,forKey:"target") } }
    @Published var miniHost: String = defaults.string(forKey:"miniHost") ?? "mac-mini.local" { didSet { defaults.set(miniHost,forKey:"miniHost") } }
    @Published var miniUser: String = defaults.string(forKey:"miniUser") ?? "" { didSet { defaults.set(miniUser,forKey:"miniUser") } }
    @Published var autoRepair: Bool = defaults.bool(forKey:"autoRepair") { didSet { defaults.set(autoRepair,forKey:"autoRepair"); autoRepair ? watcher.start() : watcher.stop() } }
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published var debug = false
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; login = SMAppService.mainApp.status == .enabled; defaults.set(enabled, forKey:"loginDesired") }
        catch { login = SMAppService.mainApp.status == .enabled; notice("登录项设置失败", "\(error)") }
    }
}
let model = SettingsModel()
struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    var body: some View {
        Form {
            Group {
                TextField("Mini 设备名称", text:$m.target)
                TextField("SSH 主机名", text:$m.miniHost)
                TextField("SSH 用户名", text:$m.miniUser)
            }
            LabeledContent("唤醒 Mini 快捷键", value:"⌃⌥M")
            LabeledContent("修复 UC 快捷键", value:"⌃⌥U")
            Toggle("自动修复 Universal Control", isOn:$m.autoRepair)
            Toggle("登录时启动", isOn:Binding(get:{m.login},set:{m.setLogin($0)}))
            Toggle("Debug 模式（重启后关闭）", isOn:$m.debug)
            HStack { Button("打开日志") { NSWorkspace.shared.open(logDir) }; Button("导出辅助功能树") { exportTree() }; Button("清空日志") { clearLogs() } }
            HStack { Button("测试唤醒 Mini") { wakeMini() }; Button("测试 UC 修复") { recover(false) } }
            Button("打开辅助功能权限设置") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
        }.padding(24).frame(width:480)
    }
}
final class Controller: NSObject, NSApplicationDelegate {
    var display: NSStatusItem!; var uc: NSStatusItem!; var window: NSWindow?; var refs: [EventHotKeyRef] = []; var flashVersion: [ObjectIdentifier:Int] = [:]; var hotkeyMonitor: Any?; var localMonitor: Any?; var lastHotkey: [Int:Date] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults:["target":defaultTarget,"autoRepair":true])
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { _,_ in }
        display = item("display", action:#selector(displayClick)); display.button?.toolTip = "唤醒 Mac mini 显示器"; uc = item("cursorarrow", action:#selector(ucClick))
        installHotkeys(); if defaults.bool(forKey:"autoRepair") { watcher.start() }
        startDisplayGuard()
        DispatchQueue.global(qos:.utility).async { inspectExistingAirPlay() }
        if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary); notice("需要辅助功能权限", "MiniControl 需要辅助功能权限以自动操作显示器设置。请打开设置授权。") }
        if defaults.bool(forKey:"loginDesired") && SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register(); model.login = SMAppService.mainApp.status == .enabled; log("MiniControl", "Login item registration requested; status=\(SMAppService.mainApp.status.rawValue)") }
            catch { log("MiniControl", "Login item registration failed: \(error)"); notice("登录启动未开启", "请在 MiniControl 设置中重试：\(error)") }
        }
        log("MiniControl", "Started; login status=\(SMAppService.mainApp.status.rawValue)")
    }
    func applicationWillTerminate(_ notification: Notification) { stopDisplayGuard(); watcher.stop() }
    func item(_ symbol: String, action: Selector) -> NSStatusItem {
        let i = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        i.button?.image = NSImage(systemSymbolName:symbol, accessibilityDescription:symbol); i.button?.image?.isTemplate = true
        i.button?.target = self; i.button?.action = action; i.button?.sendAction(on:[.leftMouseUp,.rightMouseUp]); return i
    }
    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem { let i = NSMenuItem(title:title,action:action,keyEquivalent:""); i.target = self; return i }
    func showMenu(_ item: NSStatusItem, _ menu: NSMenu) { item.menu = menu; item.button?.performClick(nil); item.menu = nil }
    @objc func displayClick() { if NSApp.currentEvent?.type == .rightMouseUp { let m = NSMenu(); m.addItem(menuItem("唤醒 Mini 显示器",#selector(doExtend))); m.addItem(menuItem("备用唤醒：临时 AirPlay",#selector(doWakeFallback))); m.addItem(menuItem("目标设备设置…",#selector(settings))); m.addItem(menuItem("打开日志",#selector(openLogs))); m.addItem(menuItem("设置…",#selector(settings))); m.addItem(.separator()); m.addItem(menuItem("退出",#selector(quit))); showMenu(display,m) } else { wakeMini() } }
    @objc func ucClick() { if NSApp.currentEvent?.type == .rightMouseUp { let m = NSMenu(); m.addItem(menuItem("修复 Universal Control",#selector(doUC))); m.addItem(menuItem("强制修复 Universal Control",#selector(forceUC))); let toggle = menuItem("自动修复",#selector(toggleUC)); toggle.state = model.autoRepair ? .on : .off; m.addItem(toggle); m.addItem(menuItem("查看最近一次 UC 状态",#selector(openUCLog))); m.addItem(menuItem("打开日志",#selector(openLogs))); showMenu(uc,m) } else { recover(false) } }
    @objc func doExtend() { wakeMini() }; @objc func doWakeFallback() { wakeMiniUsingFallback() }; @objc func doUC() { recover(false) }; @objc func forceUC() { recover(true) }
    @objc func toggleUC() { model.autoRepair.toggle() }; @objc func openLogs() { NSWorkspace.shared.open(logDir) }
    @objc func openUCLog() { let f = logDir.appendingPathComponent("UniversalControl.log"); if FileManager.default.fileExists(atPath:f.path) { NSWorkspace.shared.open(f) } else { openLogs() } }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func settings() { if window == nil { let w = NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:360),styleMask:[.titled,.closable],backing:.buffered,defer:false); w.title = "MiniControl 设置"; w.contentView = NSHostingView(rootView:SettingsView(m:model)); w.center(); w.isReleasedWhenClosed = false; window = w }; window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    func flashDisplay(_ text: String) { flash(display,text) }; func flashUC(_ text: String) { flash(uc,text) }
    func flash(_ item: NSStatusItem, _ text: String) { let key = ObjectIdentifier(item); let version = (flashVersion[key] ?? 0) + 1; flashVersion[key] = version; item.button?.toolTip = text; item.button?.image = NSImage(systemSymbolName:"checkmark",accessibilityDescription:text); DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self, weak item] in guard let self = self, let item = item, self.flashVersion[key] == version else { return }; item.button?.image = NSImage(systemSymbolName:item === self.display ? "display" : "cursorarrow",accessibilityDescription:nil); item.button?.image?.isTemplate = true } }
    func hotkeyFire(_ id: Int, source: String) {
        DispatchQueue.main.async {
            let now = Date()
            if let last = self.lastHotkey[id], now.timeIntervalSince(last) < 0.8 { return }
            self.lastHotkey[id] = now
            log("MiniControl", "Hotkey \(id == 1 ? "M" : "U") received via \(source)")
            if id == 1 { wakeMini() } else if id == 2 { recover(false) }
        }
    }
    func observeKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.option), !flags.contains(.command), !flags.contains(.shift), !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_ANSI_M) { hotkeyFire(1, source:"event monitor") }
        if event.keyCode == UInt16(kVK_ANSI_U) { hotkeyFire(2, source:"event monitor") }
    }
    func installHotkeys() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching:.keyDown) { [weak self] event in self?.observeKey(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in self?.observeKey(event); return event }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _,event,_ in
            var id = EventHotKeyID(); GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if id.id == 1 || id.id == 2 { controller.hotkeyFire(Int(id.id), source:"Carbon") }; return noErr
        },1,&spec,nil,nil)
        log("MiniControl", "Hotkey handler status=\(handlerStatus), global monitor=\(hotkeyMonitor != nil)")
        for (idx,key) in [(1,kVK_ANSI_M),(2,kVK_ANSI_U)] {
            var ref: EventHotKeyRef?; let status = RegisterEventHotKey(UInt32(key),UInt32(controlKey | optionKey),EventHotKeyID(signature:0x4d434e54,id:UInt32(idx)),GetApplicationEventTarget(),0,&ref)
            if let r = ref { refs.append(r) }; log("MiniControl", "Hotkey \(idx == 1 ? "M" : "U") registration status=\(status)"); if status != noErr { notice("快捷键注册失败", "⌃⌥\(idx == 1 ? "M" : "U") 可能已被占用（\(status)）。") }
        }
    }
}
if CommandLine.arguments.contains("--self-test-uc") { exit(ucSelfTests() ? 0 : 1) }
if CommandLine.arguments.contains("--self-test-wake") { exit(wakeSelfTests() ? 0 : 1) }
if CommandLine.arguments.contains("--self-test-log") {
    clearLogs()
    for i in 0..<8 { log("Rotation", "\(i) " + String(repeating:"x",count:4 * 1024 * 1024)) }
    let files = (try? FileManager.default.contentsOfDirectory(atPath:logDir.path)) ?? []
    let size = files.reduce(0) { total, name in total + (((try? FileManager.default.attributesOfItem(atPath:logDir.appendingPathComponent(name).path)[.size]) as? NSNumber)?.intValue ?? 0) }
    let rotated = files.contains("Rotation.log.1") && files.count <= 6 && size <= 30 * 1024 * 1024
    clearLogs()
    let empty = ((try? FileManager.default.contentsOfDirectory(atPath:logDir.path)) ?? []).isEmpty
    print("rotation=\(rotated) files=\(files.count) bytes=\(size) clear=\(empty)")
    exit(rotated && empty ? 0 : 1)
}
let controller = Controller()
let app = NSApplication.shared
app.setActivationPolicy(.accessory); app.delegate = controller; app.run()
