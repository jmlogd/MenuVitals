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
        var rate = "↓ —  ↑ —"
        if let current, let old = link, old.name == current.name, now > timestamp, now - timestamp < 10 {
            let down = Double(current.input &- old.input), up = Double(current.output &- old.output)
            received += down
            sent += up
            rate = "↓ \(traffic(down/(now-timestamp)))/s  ↑ \(traffic(up/(now-timestamp)))/s"
        }
        timestamp = now
        link = current
        rows[4].title = "\(current?.name ?? "No active link")   \(rate)"
        rows[5].title = "Session   ↓ \(traffic(received))   ↑ \(traffic(sent))"
        let values = [cpu, memory, rate]
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
            button.image = statusImage(for: selected.map { values[$0] }, icons: selected.map { images[$0] })
            button.setAccessibilityLabel(selected.map { names[$0] + " " + values[$0] }.joined(separator: ", "))
        }
    }

    // AppKit applies menu-bar contrast to the button image as a whole.
    func statusImage(for readings: [String], icons: [NSImage?]) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let labels = readings.map { NSAttributedString(string: $0, attributes: attributes) }
        let iconSide: CGFloat = 15
        let gap: CGFloat = 7
        let width = zip(icons, labels).reduce(CGFloat.zero) { total, pair in
            total + (pair.0 == nil ? 0 : iconSide + 3) + ceil(pair.1.size().width)
        } + gap * CGFloat(labels.count - 1)
        let result = NSImage(size: NSSize(width: width, height: 18), flipped: false) { bounds in
            var x: CGFloat = 0
            for (icon, label) in zip(icons, labels) {
                if let icon {
                    icon.draw(in: NSRect(x: x, y: (bounds.height - iconSide) / 2,
                                         width: iconSide, height: iconSide))
                    x += iconSide + 3
                }
                label.draw(at: NSPoint(x: x, y: floor((bounds.height - label.size().height) / 2)))
                x += ceil(label.size().width) + gap
            }
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
