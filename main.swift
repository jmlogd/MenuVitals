import AppKit
import ServiceManagement

final class Monitor: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let names = ["CPU", "Memory", "Network"]
    var enabled = [Bool]()
    var sections = [[NSMenuItem]]()
    var rows = [NSMenuItem]()
    var ticks: [UInt32]?
    var link: Link?
    var timestamp = ProcessInfo.processInfo.systemUptime
    var received = 0.0, sent = 0.0
    var timer: Timer?
    let images = ["cpu", "ram-memory", "arrow-data-transfer-vertical"].map { name -> NSImage? in
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"), let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 15, height: 15)
        return image
    }
    let appGlyph: NSImage? = {
        guard let url = Bundle.main.url(forResource: "activity-04", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = NSMenu(title: "Settings")
        for (index, name) in names.enumerated() {
            let key = "show" + name
            UserDefaults.standard.register(defaults: [key: true])
            let visible = UserDefaults.standard.bool(forKey: key)
            enabled.append(visible)
            let heading = menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
            let details = (0..<2).map { _ in menu.addItem(withTitle: "Sampling…", action: nil, keyEquivalent: "") }
            rows.append(contentsOf: details)
            let divider = NSMenuItem.separator()
            menu.addItem(divider)
            let section = [heading] + details + [divider]
            section.forEach { $0.isHidden = !visible }
            sections.append(section)
            let toggle = settings.addItem(withTitle: name, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            toggle.target = self
            toggle.tag = index
            toggle.state = visible ? .on : .off
        }
        settings.addItem(.separator())
        loginItem.target = self
        settings.addItem(loginItem)
        settings.delegate = self
        menu.addItem(withTitle: "Settings", action: nil, keyEquivalent: "").submenu = settings
        menu.addItem(withTitle: "Quit MenuVitals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        refresh()
        let clock = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        clock.tolerance = 0.2
        RunLoop.main.add(clock, forMode: .common)
        timer = clock
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginItem.title = status == .requiresApproval ? "Launch at Login (Approval Required)…" : "Launch at Login"
    }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t change Launch at Login"
            alert.runModal()
        }
    }

    @objc func toggleMetric(_ sender: NSMenuItem) {
        let index = sender.tag
        enabled[index].toggle()
        let visible = enabled[index]
        UserDefaults.standard.set(visible, forKey: "show" + names[index])
        sender.state = visible ? .on : .off
        sections[index].forEach { $0.isHidden = !visible }
        refresh()
    }

    func refresh() {
        var cpu = "—"
        rows[0].title = "Sampling…"
        rows[1].title = "User —   System —   Idle —"
        let nextTicks = enabled[0] ? cpuTicks() : nil
        if let current = nextTicks, let old = ticks {
            let delta = zip(current, old).map { Double($0.0 &- $0.1) }
            let total = delta.reduce(0, +)
            if total > 0 {
                let user = (delta[0] + delta[3]) * 100 / total
                let system = delta[1] * 100 / total
                cpu = String(format: "%.0f%%", user + system)
                rows[0].title = "Total usage   \(cpu)"
                rows[1].title = String(format: "User %.0f%%   System %.0f%%   Idle %.0f%%", user, system, 100-user-system)
            }
        }
        ticks = nextTicks
        var memory = "—"
        if enabled[1] {
            memory = memoryUsed().map(gb) ?? "—"
            let pressure = kernelValue("kern.memorystatus_vm_pressure_level", Int32(0)).flatMap { [1:"Normal", 2:"Warning", 4:"Critical"][Int($0)] } ?? "Unavailable"
            let swap = kernelValue("vm.swapusage", xsw_usage()).map { gb($0.xsu_used) } ?? "—"
            rows[2].title = "\(memory) used of \(gb(ProcessInfo.processInfo.physicalMemory))"
            rows[3].title = "Pressure \(pressure)   ·   Swap \(swap)"
        }
        let now = ProcessInfo.processInfo.systemUptime
        let current = enabled[2] ? physicalLink() : nil
        var download = "—", upload = "—"
        if let current, let old = link, old.name == current.name, now > timestamp, now - timestamp < 10 {
            let down = Double(current.input &- old.input), up = Double(current.output &- old.output)
            received += down
            sent += up
            download = rateLabel(down / (now - timestamp))
            upload = rateLabel(up / (now - timestamp))
        }
        timestamp = now
        link = current
        let rate = "↓ \(download)  ↑ \(upload)"
        rows[4].title = "\(current?.name ?? "No active link")   \(rate)"
        rows[5].title = "Session   ↓ \(traffic(received))   ↑ \(traffic(sent))"
        let values = [cpu, memory, "Download \(download), upload \(upload)"]
        let selected = names.indices.filter { enabled[$0] }
        guard let button = item.button else { return }
        if selected.isEmpty {
            button.image = appGlyph
            button.imagePosition = appGlyph == nil ? .noImage : .imageOnly
            button.title = appGlyph == nil ? "MenuVitals" : ""
            button.setAccessibilityLabel("MenuVitals settings")
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            button.image = statusImage(cpu: cpu, memory: memory, download: download, upload: upload)
            button.setAccessibilityLabel(selected.map { names[$0] + " " + values[$0] }.joined(separator: ", "))
        }
    }

    // Reserve each field so the icons and network separator stay in place.
    func statusImage(cpu: String, memory: String, download: String, upload: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        var glyphs: [(image: NSImage, frame: NSRect)] = []
        var labels: [(text: NSAttributedString, origin: NSPoint)] = []
        var x: CGFloat = 0
        func appendLabel(_ value: String, reserving sample: String,
                         font: NSFont? = nil, alignRight: Bool = false) {
            var style = attributes
            if let font { style[.font] = font }
            let text = NSAttributedString(string: value, attributes: style)
            let width = ceil((sample as NSString).size(withAttributes: style).width)
            let size = text.size()
            let originX = alignRight ? x + width - ceil(size.width) : x
            labels.append((text, NSPoint(x: originX, y: floor((18 - size.height) / 2))))
            x += width
        }
        for index in names.indices where enabled[index] {
            if x > 0 { x += 4 }
            if let icon = images[index] {
                glyphs.append((icon, NSRect(x: x, y: 1.5, width: 15, height: 15)))
                x += 17
            }
            switch index {
            case 0: appendLabel(cpu, reserving: "100%")
            case 1: appendLabel(memory, reserving: gb(ProcessInfo.processInfo.physicalMemory))
            default:
                let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                func compact(_ rate: String) -> String {
                    rate.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/s", with: "")
                }
                appendLabel(compact(download), reserving: "999MB", font: font, alignRight: true)
                appendLabel("/", reserving: "/", font: font)
                appendLabel(compact(upload), reserving: "999MB", font: font)
            }
        }
        let result = NSImage(size: NSSize(width: x, height: 18), flipped: false) { _ in
            for glyph in glyphs { glyph.image.draw(in: glyph.frame) }
            for label in labels { label.text.draw(at: label.origin) }
            return true
        }
        result.isTemplate = true
        return result
    }

}
let app = NSApplication.shared
let delegate = Monitor()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
