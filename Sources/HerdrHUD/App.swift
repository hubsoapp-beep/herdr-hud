import AppKit
import WebKit
import Carbon
import ServiceManagement

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class BubbleView: NSView {
    weak var app: HUDApp?
    var start = NSPoint.zero, origin = NSPoint.zero, dragged = false
    var count = 0 { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let s = bounds.width/64
        NSColor(calibratedRed:0.09, green:0.10, blue:0.13, alpha:0.97).setFill()
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx:3*s, dy:3*s)); circle.fill()
        NSColor(calibratedRed:0.91, green:0.72, blue:0.36, alpha:1).setStroke(); circle.lineWidth = 2*s; circle.stroke()
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:28*s, weight:.bold), .foregroundColor:NSColor(calibratedRed:0.97,green:0.79,blue:0.43,alpha:1)]
        ("H" as NSString).draw(at:NSPoint(x:20*s,y:16*s), withAttributes:attrs)
        if count > 0 {
            NSColor.systemGreen.setFill(); NSBezierPath(ovalIn:NSRect(x:43*s,y:43*s,width:17*s,height:17*s)).fill()
            (String(min(count,9)) as NSString).draw(at:NSPoint(x:48*s,y:45*s),withAttributes:[.font:NSFont.systemFont(ofSize:10*s,weight:.bold),.foregroundColor:NSColor.black])
        }
    }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; origin = window?.frame.origin ?? .zero; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if hypot(point.x-start.x,point.y-start.y) > 4 { dragged = true }
        guard dragged else { return }
        window?.setFrameOrigin(NSPoint(x:origin.x+point.x-start.x,y:origin.y+point.y-start.y))
        app?.positionPanel()
    }
    override func mouseUp(with event: NSEvent) { if dragged { app?.savePosition() } else { app?.togglePanel() } }
    override func rightMouseDown(with event: NSEvent) { if let menu = app?.status.menu { NSMenu.popUpContextMenu(menu,with:event,for:self) } }
}
final class ResizeGrip: NSView {
    weak var app: HUDApp?
    var start = NSPoint.zero, base = NSRect.zero
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite:0.78,alpha:0.5).setStroke()
        for offset in stride(from:CGFloat(1),through:9,by:4) {
            let path = NSBezierPath()
            path.move(to:NSPoint(x:bounds.width-offset-5,y:2)); path.line(to:NSPoint(x:bounds.width-2,y:offset+5))
            path.lineWidth = 1.5; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; base = window?.frame ?? .zero }
    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let point = NSEvent.mouseLocation, visible = window.screen?.visibleFrame ?? .zero
        let width = min(max(base.width + point.x - start.x,640),max(visible.width-24,640))
        let height = min(max(base.height + start.y - point.y,430),max(visible.height-24,430))
        window.setFrame(NSRect(x:base.minX,y:base.maxY-height,width:width,height:height),display:true)
    }
    override func mouseUp(with event: NSEvent) { app?.savePanelSize() }
}
final class HUDApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let client = HerdrClient(), work = DispatchQueue(label:"herdr-hud.transport",qos:.userInitiated)
    let defaults = UserDefaults.standard
    var bubble: NSPanel!, panel: OverlayPanel!, bubbleView: BubbleView!, web: WKWebView!, grip: ResizeGrip!, status: NSStatusItem!
    var timer: Timer?, hotkeys: [EventHotKeyRef] = [], handler: EventHandlerRef?
    var visible = true, panelOpen = false, ready = false, polling = false
    var lastSnapshot: Row = [:], readBusy = false, selected = ""
    var promptIDs = Set<String>(), hotkeyWarning = ""
    var toast: NSPanel?, toastTimer: Timer?, toastHover = false
    var shortcuts: [NSMenuItem] = []
    static let channel = Notification.Name("org.herdr.community.hud.control")
    var support: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD") }
    var bubbleOpacity: Double { defaults.object(forKey:"bubbleOpacity") == nil ? 100 : max(30,min(100,defaults.double(forKey:"bubbleOpacity"))) }
    var side: CGFloat { defaults.object(forKey:"bubbleSize") == nil ? 64 : max(40,min(140,defaults.double(forKey:"bubbleSize"))) }
    func savePanelSize() { guard panel != nil else { return }; defaults.set(NSStringFromSize(panel.frame.size),forKey:"panelSize"); diagnostics() }
    func applyOpacity() { bubble?.alphaValue = CGFloat(bubbleOpacity/100) }
    @objc func changeOpacity(_ item: NSMenuItem) { defaults.set(Double(item.tag),forKey:"bubbleOpacity"); applyOpacity(); diagnostics() }
    @objc func changeBubbleSize(_ item: NSMenuItem) {
        defaults.set(Double(item.tag),forKey:"bubbleSize")
        guard bubble != nil else { return }
        bubble.setFrame(NSRect(origin:bubble.frame.origin,size:NSSize(width:side,height:side)),display:true)
        bubbleView.frame = NSRect(x:0,y:0,width:side,height:side); bubbleView.needsDisplay = true
        positionPanel(); savePosition()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at:support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        visible = defaults.object(forKey:"visible") == nil || defaults.bool(forKey:"visible")
        panel = OverlayPanel(contentRect:NSRect(origin:NSPoint(x:100,y:100),size:defaults.string(forKey:"panelSize").map(NSSizeFromString) ?? NSSize(width:940,height:650)), styleMask:[.borderless,.nonactivatingPanel,.resizable], backing:.buffered,defer:false)
        configure(panel); panel.title = "Herdr HUD Agents"; panel.minSize = NSSize(width:640,height:430)
        let config = WKWebViewConfiguration()
        config.userContentController.add(self,name:"hud")
        config.websiteDataStore = .nonPersistent()
        let host = NSView(frame:panel.contentView!.bounds)
        host.autoresizingMask = [.width,.height]
        web = WKWebView(frame:host.bounds,configuration:config)
        web.autoresizingMask = [.width,.height]; web.navigationDelegate = self
        web.setValue(false,forKey:"drawsBackground")
        host.addSubview(web)
        grip = ResizeGrip(frame:NSRect(x:host.bounds.width-16,y:0,width:16,height:16))
        grip.autoresizingMask = [.minXMargin,.maxYMargin]; grip.app = self
        host.addSubview(grip)
        panel.contentView = host
        web.loadFileURL(HUDResources.root.appendingPathComponent("index.html"),allowingReadAccessTo:HUDResources.root)
        bubble = NSPanel(contentRect:NSRect(x:32,y:180,width:side,height:side),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        configure(bubble); bubble.title = "Herdr HUD H Button"; bubble.level = NSWindow.Level(rawValue:panel.level.rawValue+1)
        bubbleView = BubbleView(frame:NSRect(x:0,y:0,width:side,height:side)); bubbleView.app = self
        bubbleView.setAccessibilityRole(.button); bubbleView.setAccessibilityLabel("Herdr HUD. Click to open agents; drag to move.")
        bubble.contentView = bubbleView; applyOpacity()
        restorePosition()
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.title = "H"; status.button?.toolTip = "Herdr HUD"
        buildMenu(); registerHotkeys()
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(control(_:)),name:Self.channel,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(spaceChanged),name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(screensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 && self.panelOpen { self.closePanel(); return nil }
            return event
        }
        if visible { bubble.orderFrontRegardless() }
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.refresh() }
        refresh(); diagnostics()
    }
    func configure(_ window: NSPanel) {
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .statusBar; window.hidesOnDeactivate = false; window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        if #available(macOS 13.0, *) { window.collectionBehavior.insert(.canJoinAllApplications) }
    }
    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem { let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; return item }
    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem("Open / close agents",#selector(togglePanel)))
        menu.addItem(menuItem("Show / hide H button",#selector(toggleVisibility)))
        menu.addItem(submenu("H icon transparency",[("100%",100),("85%",85),("70%",70),("55%",55),("40%",40),("30%",30)],#selector(changeOpacity(_:)),current:Int(bubbleOpacity)))
        menu.addItem(submenu("H button size",[("Small · 48 px",48),("Medium · 64 px",64),("Large · 88 px",88),("Extra large · 112 px",112)],#selector(changeBubbleSize(_:)),current:Int(side)))
        menu.addItem(.separator())
        let root = NSMenuItem(title:"Keyboard shortcuts",action:nil,keyEquivalent:""), submenu = NSMenu()
        for (index,title) in ["⌘⌥H panel · ⌘⌥⇧H hide", "⌃⌥H panel · ⌃⌥⇧H hide", "Shortcuts off"].enumerated() {
            let item = menuItem(title,#selector(changeShortcut(_:))); item.tag = index; shortcuts.append(item); submenu.addItem(item)
        }
        root.submenu = submenu; menu.addItem(root)
        let login = menuItem("Launch at login",#selector(toggleLogin(_:))); login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        menu.addItem(menuItem("Refresh agents",#selector(refresh)))
        menu.addItem(menuItem("About Herdr HUD",#selector(about)))
        menu.addItem(.separator()); menu.addItem(menuItem("Quit Herdr HUD",#selector(quit)))
        status.menu = menu
    }
    @objc func changeShortcut(_ item: NSMenuItem) { defaults.set(item.tag,forKey:"shortcutMode"); registerHotkeys() }
    func submenu(_ title: String, _ choices: [(String,Int)], _ action: Selector, current: Int) -> NSMenuItem {
        let root = NSMenuItem(title:title,action:nil,keyEquivalent:""), sub = NSMenu()
        for (label,tag) in choices {
            let item = menuItem(label,action); item.tag = tag; item.state = tag == current ? .on : .off; sub.addItem(item)
        }
        root.submenu = sub; return root
    }
    func registerHotkeys() {
        for key in hotkeys { UnregisterEventHotKey(key) }; hotkeys = []
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
                guard let event = event, let pointer = pointer else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
                let app = Unmanaged<HUDApp>.fromOpaque(pointer).takeUnretainedValue()
                if id.id == 1 { app.togglePanel() } else { app.toggleVisibility() }
                return noErr
            },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        }
        let mode = defaults.integer(forKey:"shortcutMode")
        for item in shortcuts { item.state = item.tag == mode ? .on : .off }
        guard mode != 2 else { hotkeyWarning = ""; return }
        let modifiers = UInt32(optionKey | (mode == 0 ? cmdKey : controlKey))
        hotkeyWarning = ""
        for id in 1...2 {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_H),modifiers | (id == 2 ? UInt32(shiftKey) : 0),EventHotKeyID(signature:0x48484431,id:UInt32(id)),GetApplicationEventTarget(),0,&ref)
            if result == noErr, let ref = ref { hotkeys.append(ref) } else { hotkeyWarning = "Shortcut already in use. Choose another combination in the H menu." }
        }
        if !hotkeyWarning.isEmpty { emit("notice",["message":hotkeyWarning]) }
    }
    @objc func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch { emit("notice",["message":"Login startup could not be enabled: " + error.localizedDescription]); openPanel() }
    }
    @objc func about() { openPanel(); emit("notice",["message":"Herdr HUD · Mac preview 0.1.0 · MIT · Community project, not affiliated with Herdr or Basecamp. Configure machines in Herdr; they appear here automatically."]) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleVisibility() {
        visible.toggle(); defaults.set(visible,forKey:"visible")
        if visible { bubble.orderFrontRegardless(); refresh() } else { closePanel(); bubble.orderOut(nil); hideToast(); emit("resetBaseline",[:]) }
        diagnostics()
    }
    @objc func togglePanel() { if panelOpen { closePanel() } else { openPanel() } }
    func openPanel() {
        visible = true; defaults.set(true,forKey:"visible"); panelOpen = true
        positionPanel(); bubble.orderFrontRegardless(); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(web); hideToast(); emit("visibility",["open":true]); refresh(); diagnostics()
    }
    func closePanel() { panelOpen = false; panel.orderOut(nil); emit("visibility",["open":false]); diagnostics() }
    func screenForBubble() -> NSScreen { NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x:bubble.frame.midX,y:bubble.frame.midY)) }) ?? NSScreen.screens.first! }
    func screenKey(_ screen: NSScreen) -> String { String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) }
    func restorePosition() {
        guard let screen = NSScreen.screens.first(where: { screenKey($0) == defaults.string(forKey:"lastScreen") }) ?? NSScreen.screens.first else { return }
        let point = defaults.string(forKey:"position." + screenKey(screen)).map(NSPointFromString) ?? NSPoint(x:32,y:180)
        bubble.setFrameOrigin(NSPoint(x:screen.frame.minX+min(max(point.x,4),screen.frame.width-side-4),y:screen.frame.minY+min(max(point.y,4),screen.frame.height-side-4)))
    }
    func savePosition() {
        let screen = screenForBubble(); let frame = screen.frame
        let point = NSPoint(x:min(max(bubble.frame.minX-frame.minX,4),frame.width-side-4),y:min(max(bubble.frame.minY-frame.minY,4),frame.height-side-4))
        defaults.set(NSStringFromPoint(point),forKey:"position." + screenKey(screen)); defaults.set(screenKey(screen),forKey:"lastScreen")
        bubble.setFrameOrigin(NSPoint(x:frame.minX+point.x,y:frame.minY+point.y)); positionPanel(); diagnostics()
    }
    func positionPanel() {
        defer { positionToast() }
        guard bubble != nil, panel != nil, !NSScreen.screens.isEmpty else { return }
        let frame = screenForBubble().visibleFrame
        let size = NSSize(width:min(panel.frame.width,frame.width-24),height:min(panel.frame.height,frame.height-24))
        let right = bubble.frame.maxX+12
        let x = right+size.width <= frame.maxX ? right : bubble.frame.minX-size.width-12
        let y = bubble.frame.maxY-size.height
        panel.setFrame(NSRect(x:min(max(x,frame.minX+12),frame.maxX-size.width-12),y:min(max(y,frame.minY+12),frame.maxY-size.height-12),width:size.width,height:size.height),display:true)
    }
    @objc func screensChanged() { restorePosition(); positionPanel() }
    @objc func spaceChanged() { if visible { bubble.orderFrontRegardless(); if panelOpen { panel.orderFrontRegardless() }; toast?.orderFrontRegardless() } }
    @objc func refresh() {
        guard visible, !polling else { return }; polling = true
        work.async { let data = self.client.snapshot(); DispatchQueue.main.async {
            self.polling = false; self.lastSnapshot = data; if self.visible { self.emit("roster",data) }; self.diagnostics()
        } }
    }
    func emit(_ type: String, _ data: Row) { guard ready else { return }; web.evaluateJavaScript("window.receive(" + encode(["type":type,"data":data]) + ")",completionHandler:nil) }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? Row, let operation = data["op"] as? String else { return }
        let requestID = data["requestID"] as? String ?? ""
        switch operation {
        case "ready": ready = true; emit("preferences",["selectedAgent":defaults.string(forKey:"selectedAgent") ?? "","rosterWidth":defaults.double(forKey:"rosterWidth"),"mode":defaults.string(forKey:"viewMode") ?? "chat"]); emit("visibility",["open":panelOpen]); if !lastSnapshot.isEmpty { emit("roster",lastSnapshot) }; if !hotkeyWarning.isEmpty { emit("notice",["message":hotkeyWarning]) }
        case "close": closePanel()
        case "hide": if visible { toggleVisibility() }
        case "refresh": refresh()
        case "preferences":
            if let id = data["selectedAgent"] as? String, id.utf8.count <= 8192 { defaults.set(id,forKey:"selectedAgent") }
            if let width = data["rosterWidth"] as? Double, width >= 155 && width <= 600 { defaults.set(width,forKey:"rosterWidth") }
            if let mode = data["mode"] as? String, ["chat","terminal"].contains(mode) { defaults.set(mode,forKey:"viewMode") }
        case "badge": bubbleView.count = data["count"] as? Int ?? 0
        case "alertPreview":
            if !panelOpen && visible, let id = data["id"] as? String {
                work.async {
                    let output = (try? self.client.output(id)) ?? ["id":id,"text":"","provider":""]
                    DispatchQueue.main.async { self.emit("alertPreview",output.merging(["title":data["title"] ?? "Agent update"],uniquingKeysWith:{_,b in b})) }
                }
            }
        case "alert": if !panelOpen && visible { showToast(data) }
        case "focus":
            guard let id = data["id"] as? String else { return }
            work.async {
                var message = ""
                do { _ = try self.client.focus(id) } catch { message = error.localizedDescription }
                DispatchQueue.main.async {
                    if message.isEmpty { self.closePanel(); self.activateTerminal() } else { self.emit("notice",["message":message]) }
                }
            }
        case "output", "prompt":
            guard let id = data["id"] as? String, !requestID.isEmpty, panelOpen else { return }
            if operation == "output" { if readBusy { return }; readBusy = true; selected = id }
            if operation == "prompt" { guard !promptIDs.contains(requestID) else { return }; promptIDs.insert(requestID) }
            work.async {
                var result: Row
                do { result = operation == "output" ? try self.client.output(id) : try self.client.prompt(id,data["message"] as? String ?? "") }
                catch { result = ["error":error.localizedDescription, "id":id] }
                result["requestID"] = requestID
                let value = result
                DispatchQueue.main.async { if operation == "output" { self.readBusy = false }; self.emit(operation,value) }
            }
        default: break
        }
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(url.isFileURL && navigationAction.navigationType != .linkActivated ? .allow : .cancel)
    }
    func showToast(_ data: Row) {
        hideToast()
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:320,height:92),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        configure(window); window.title = "Herdr HUD Alert"
        window.level = NSWindow.Level(rawValue:bubble.level.rawValue+1)
        let view = ToastView(frame:NSRect(x:0,y:0,width:320,height:92)); view.app = self; view.agentID = data["id"] as? String ?? ""
        view.title = data["title"] as? String ?? "Agent update"; view.detail = data["preview"] as? String ?? "Click to read the response"
        window.contentView = view
        toast = window; positionToast(); window.orderFrontRegardless()
        toastTimer = Timer.scheduledTimer(withTimeInterval:8,repeats:false) { [weak self] _ in if self?.toastHover != true { self?.hideToast() } }
    }
    func positionToast() {
        guard let toast = toast, bubble != nil, !NSScreen.screens.isEmpty else { return }
        toast.setFrame(notificationFrame(bubble:bubble.frame,size:toast.frame.size,visibleFrame:screenForBubble().visibleFrame),display:true)
    }
    func activateTerminal() {
        // Herdr runs inside a terminal; bring the host window to the front.
        for id in ["com.mitchellh.ghostty","com.googlecode.iterm2","net.kovidgoyal.kitty","com.github.wez.wezterm","org.alacritty","dev.warp.Warp-Stable","com.apple.Terminal","io.cmux.cmux"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier:id).first { app.activate(options:[]); return }
        }
    }
    func hideToast() { toastTimer?.invalidate(); toast?.orderOut(nil); toast = nil; toastHover = false }
    func diagnostics() {
        guard bubble != nil else { return }
        let data: Row = ["pid":ProcessInfo.processInfo.processIdentifier,"visible":visible,"panelOpen":panelOpen,"screens":NSScreen.screens.count,"panelKey":panel.isKeyWindow,"resourceRoot":HUDResources.root.path,"bubbleFrame":NSStringFromRect(bubble.frame),"panelFrame":NSStringFromRect(panel.frame),"bubbleOpacity":bubbleOpacity,"machines":lastSnapshot["machines"] ?? [],"agentCount":(lastSnapshot["agents"] as? [Row])?.count ?? 0,"shortcutWarning":hotkeyWarning]
        try? encode(data).write(to:support.appendingPathComponent("diagnostics.json"),atomically:true,encoding:.utf8)
    }
    @objc func control(_ notification: Notification) {
        switch notification.object as? String {
        case "open": openPanel()
        case "close": closePanel()
        case "toggle": togglePanel()
        case "hide": if visible { toggleVisibility() }
        case "show": if !visible { toggleVisibility() }
        case "preview-alert":
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            showToast(["id":defaults.string(forKey:"selectedAgent") ?? "","title":"Notification preview","preview":"Notifications follow H and stay clear of the button."])
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
                guard let toast = self.toast else { return }
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [Row] ?? []
                let toastIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == toast.windowNumber }
                let bubbleIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == self.bubble.windowNumber }
                let evidence: Row = ["bubbleFrame":NSStringFromRect(self.bubble.frame),"toastFrame":NSStringFromRect(toast.frame),"onScreen":self.screenForBubble().visibleFrame.contains(toast.frame),"overlapsButton":toast.frame.intersects(self.bubble.frame),"focusUnchanged":NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,"toastAboveButton":toastIndex != nil && bubbleIndex != nil && toastIndex! < bubbleIndex!,"visible":toast.isVisible]
                try? encode(evidence).write(to:self.support.appendingPathComponent("notification-preview.json"),atomically:true,encoding:.utf8)
                if let view = toast.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:rep)
                    if let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:self.support.appendingPathComponent("notification-preview.png")) }
                }
            }
        case "verify-ui":
            openPanel()
            web.callAsyncJavaScript("return await window.verifyControls()",arguments:[:],in:nil,in:.page) { result in
                let value: Any
                switch result { case .success(let data): value=data; case .failure(let error): value=["error":error.localizedDescription] }
                try? encode(value).write(to:self.support.appendingPathComponent("ui-verification.json"),atomically:true,encoding:.utf8)
            }
        case "inspect":
            web.evaluateJavaScript("JSON.stringify({title:document.title,agents:document.querySelectorAll('.agent').length,selected:document.getElementById('title').textContent,outputLength:document.getElementById('output').textContent.length,draftLength:document.getElementById('prompt').value.length,sendDisabled:document.getElementById('send').disabled,notice:document.getElementById('notice').textContent})") { value,error in
                let text = (value as? String) ?? (error?.localizedDescription ?? "unknown")
                try? text.write(to:self.support.appendingPathComponent("ui-check.json"),atomically:true,encoding:.utf8)
            }
        case "snapshot":
            web.takeSnapshot(with:nil) { image,error in
                if let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:self.support.appendingPathComponent("panel-preview.png")) }
            }
        default: break
        }
    }
}
final class ToastView: NSView {
    weak var app: HUDApp?
    var agentID = "", title = "", detail = ""
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func updateTrackingAreas() { super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways],owner:self)) }
    override func mouseEntered(with event:NSEvent) { app?.toastHover = true }
    override func mouseExited(with event:NSEvent) { app?.toastHover = false; app?.toastTimer?.invalidate(); app?.toastTimer = Timer.scheduledTimer(withTimeInterval:8,repeats:false) { [weak self] _ in self?.app?.hideToast() } }
    override func mouseUp(with event:NSEvent) { if convert(event.locationInWindow,from:nil).x > bounds.width-35 { app?.hideToast() } else { let id = agentID; app?.openPanel(); app?.emit("select",["id":id]) } }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.10,alpha:0.98).setFill(); NSBezierPath(roundedRect:bounds,xRadius:14,yRadius:14).fill()
        (title as NSString).draw(in:NSRect(x:16,y:50,width:270,height:26),withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.semibold),.foregroundColor:NSColor.systemGreen])
        (detail as NSString).draw(in:NSRect(x:16,y:12,width:282,height:36),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
        ("×" as NSString).draw(at:NSPoint(x:296,y:65),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.gray])
    }
}
