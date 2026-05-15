//
//  AppDelegate.swift
//  Portsly
//
//  Copyright © 2025 Greg Hinkle. All rights reserved.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    let portScanner = PortScanner()
    var showSystemProcesses = UserDefaults.standard.bool(forKey: "showSystemProcesses")
    var showOnlyDevProcesses = UserDefaults.standard.bool(forKey: "showOnlyDevProcesses")
    var hiddenProcessNames: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenProcessNames") ?? [])
    var cachedProcesses: [ProcessInfo] = []

    private let scanQueue = DispatchQueue(label: "dev.brightbase.portsly.scan", qos: .userInitiated)
    private var menuIsOpen = false
    private var hasScannedAtLeastOnce = false

    private func createInfoMenuItem(title: String, value: String, font: NSFont, color: NSColor, maxLength: Int = 0) -> NSMenuItem {
        let text: String
        if maxLength > 0 && value.count > maxLength {
            // Word wrap for long values
            let words = value.components(separatedBy: " ")
            var lines: [String] = []
            var currentLine = ""

            for word in words {
                if currentLine.isEmpty {
                    currentLine = word
                } else if (currentLine + " " + word).count <= maxLength {
                    currentLine += " " + word
                } else {
                    lines.append(currentLine)
                    currentLine = word
                }
            }
            if !currentLine.isEmpty {
                lines.append(currentLine)
            }

            // Format with title on first line, indented continuation lines
            text = title + ": " + lines.joined(separator: "\n" + String(repeating: " ", count: title.count + 2))
        } else {
            text = title.isEmpty ? value : "\(title): \(value)"
        }

        let item = NSMenuItem()
        item.isEnabled = true  // Keep enabled to preserve color
        item.action = #selector(copyToClipboard(_:))
        item.target = self
        item.representedObject = value  // Store the raw value for copying
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        item.attributedTitle = NSAttributedString(string: text, attributes: attributes)
        return item
    }

    @objc private func copyToClipboard(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func displayLabel(for process: ProcessInfo) -> String {
        guard let suffix = gitInfoValue(for: process) else { return process.name }
        return "\(process.name) [\(suffix)]"
    }

    // Worktree directories are often named the same as the branch they hold
    // (e.g. `git worktree add ../feature feature`); drop the duplicate when so.
    private func gitInfoValue(for process: ProcessInfo) -> String? {
        switch (process.gitBranch, process.gitWorktree) {
        case (let branch?, let worktree?) where worktree != branch:
            return "\(branch) @ \(worktree)"
        case (let branch?, _):
            return branch
        case (nil, let worktree?):
            return worktree
        default:
            return nil
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        // Ensure we're running as an accessory app
        NSApp.setActivationPolicy(.accessory)

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard statusItem != nil else {
            return
        }

        if let button = statusItem?.button {

            // Try multiple ways to load the icon
            var iconLoaded = false

            // Try loading from Resources
            if let imagePath = Bundle.main.path(forResource: "menuIconTemplate@3x", ofType: "png"),
               let image = NSImage(contentsOfFile: imagePath) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
                iconLoaded = true
            }

            // Try asset catalog
            if !iconLoaded, let image = NSImage(named: "menuIconTemplate") {
                image.isTemplate = true
                button.image = image
                iconLoaded = true
            }

            // Fallback to text
            if !iconLoaded {
                button.title = "P"
            }

            button.toolTip = "Portsly - Port Manager"
            button.isHidden = false
        }

        // Create initial menu
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.menu = menu

        // Pre-warm the cache so the first menu click is instant
        refreshMenuAsync(rebuildIfOpen: false)
    }

    private func refreshMenuAsync(rebuildIfOpen: Bool) {
        let startTime = Date()
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let processes = self.portScanner.scanPorts(showSystemProcesses: true)
            DispatchQueue.main.async {
                self.cachedProcesses = processes
                self.hasScannedAtLeastOnce = true
                if rebuildIfOpen && self.menuIsOpen {
                    self.filterAndUpdateMenu()
                }
                let totalTimeMs = Date().timeIntervalSince(startTime) * 1000
                print(String(format: "[%.0fms] Portsly: refreshMenuAsync end-to-end", totalTimeMs))
            }
        }
    }

    @objc func killProcess(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let pid = info["pid"] as? Int,
              let force = info["force"] as? Bool else { return }

        let alert = NSAlert()
        alert.messageText = force ? "Force Quit Process?" : "Kill Process?"
        alert.informativeText = "Are you sure you want to \(force ? "force quit" : "kill") this process (PID: \(pid))?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: force ? "Force Quit" : "Kill")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if portScanner.killProcess(pid: pid, force: force) {
                refreshMenuAsync(rebuildIfOpen: false)
            } else {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Failed to \(force ? "force quit" : "kill") process"
                errorAlert.informativeText = "Could not \(force ? "force quit" : "kill") the process. You may need administrator privileges."
                errorAlert.alertStyle = .critical
                errorAlert.runModal()
            }
        }
    }

    @objc func toggleSystemProcesses(_ sender: NSMenuItem) {
        showSystemProcesses.toggle()
        sender.state = showSystemProcesses ? .on : .off

        // If showing system processes, turn off dev-only mode
        if showSystemProcesses {
            showOnlyDevProcesses = false
            UserDefaults.standard.set(false, forKey: "showOnlyDevProcesses")
        }

        // Save preference
        UserDefaults.standard.set(showSystemProcesses, forKey: "showSystemProcesses")

        filterAndUpdateMenu()
    }

    @objc func hideProcess(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, !name.isEmpty else { return }
        hiddenProcessNames.insert(name)
        persistHiddenProcessNames()
        filterAndUpdateMenu()
    }

    @objc func unhideProcess(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        hiddenProcessNames.remove(name)
        persistHiddenProcessNames()
        filterAndUpdateMenu()
    }

    @objc func clearHiddenProcesses(_ sender: NSMenuItem) {
        hiddenProcessNames.removeAll()
        persistHiddenProcessNames()
        filterAndUpdateMenu()
    }

    private func persistHiddenProcessNames() {
        UserDefaults.standard.set(Array(hiddenProcessNames), forKey: "hiddenProcessNames")
    }

    @objc func toggleDevProcesses(_ sender: NSMenuItem) {
        showOnlyDevProcesses.toggle()
        sender.state = showOnlyDevProcesses ? .on : .off

        // If showing only dev processes, turn off system processes
        if showOnlyDevProcesses {
            showSystemProcesses = false
            UserDefaults.standard.set(false, forKey: "showSystemProcesses")
        }

        // Save preference
        UserDefaults.standard.set(showOnlyDevProcesses, forKey: "showOnlyDevProcesses")

        filterAndUpdateMenu()
    }

    private func filterAndUpdateMenu() {
        // Use cached data for instant update
        guard let menu = statusItem?.menu else { return }

        // Filter cached processes based on settings
        let baseProcesses: [ProcessInfo]
        if showOnlyDevProcesses {
            baseProcesses = cachedProcesses.filter { portScanner.isDevProcess($0) }
        } else if showSystemProcesses {
            baseProcesses = cachedProcesses
        } else {
            baseProcesses = cachedProcesses.filter { !portScanner.isSystemProcess($0.name) }
        }

        // User-hidden process names always take precedence over the toggles
        let processes = hiddenProcessNames.isEmpty
            ? baseProcesses
            : baseProcesses.filter { !hiddenProcessNames.contains($0.name) }

        // Update menu with cached data (super fast)
        rebuildMenuWithProcesses(menu: menu, processes: processes)
    }

    private func rebuildMenuWithProcesses(menu: NSMenu, processes: [ProcessInfo]) {
        // Clear existing items
        menu.removeAllItems()
        menu.autoenablesItems = false

        if processes.isEmpty {
            let item = NSMenuItem(title: "No applications listening on ports", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // Create a map of ports to processes for easier lookup
            var portToProcesses: [Int: [ProcessInfo]] = [:]

            for process in processes {
                for port in process.ports {
                    if portToProcesses[port] == nil {
                        portToProcesses[port] = []
                    }
                    portToProcesses[port]?.append(process)
                }
            }

            // Sort ports and create menu items
            let sortedPorts = portToProcesses.keys.sorted()

            for port in sortedPorts {
                guard let processesOnPort = portToProcesses[port] else { continue }

                // Format the menu item with port on left, process name(s) on right
                let processNames = processesOnPort.map { displayLabel(for: $0) }.joined(separator: ", ")
                let title = String(format: "%-8d %@", port, processNames)

                let portItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                // Use attributed title for monospaced font
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                ]
                portItem.attributedTitle = NSAttributedString(string: title, attributes: attributes)

                // Set icon if we have one (use the first process's icon)
                if let firstProcess = processes.first(where: { $0.ports.contains(port) }),
                   let icon = firstProcess.icon {
                    portItem.image = icon
                } else {
                    // Create a blank icon for alignment
                    let blankIcon = NSImage(size: NSSize(width: 16, height: 16))
                    blankIcon.lockFocus()
                    NSColor.clear.set()
                    NSRect(x: 0, y: 0, width: 16, height: 16).fill()
                    blankIcon.unlockFocus()
                    portItem.image = blankIcon
                }

                // If multiple processes on same port, or user wants to see details
                if processesOnPort.count > 1 || true {  // Always show submenu for consistency
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false

                    // Add "Open in Browser" at the top
                    let openItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
                    openItem.representedObject = port
                    openItem.target = self
                    openItem.isEnabled = true
                    submenu.addItem(openItem)

                    submenu.addItem(NSMenuItem.separator())

                    for process in processesOnPort {
                        submenu.addItem(createInfoMenuItem(
                            title: "PID",
                            value: String(process.pid),
                            font: .systemFont(ofSize: 12),
                            color: .secondaryLabelColor
                        ))

                        if let cwd = process.workingDirectory {
                            submenu.addItem(createInfoMenuItem(
                                title: "Directory",
                                value: cwd,
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                color: .secondaryLabelColor,
                                maxLength: 50
                            ))
                        }

                        if let branchValue = gitInfoValue(for: process) {
                            submenu.addItem(createInfoMenuItem(
                                title: "Branch",
                                value: branchValue,
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                color: .secondaryLabelColor
                            ))
                        }

                        if let cmd = process.fullCommand {
                            submenu.addItem(createInfoMenuItem(
                                title: "Command",
                                value: cmd,
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                color: .secondaryLabelColor,
                                maxLength: 50
                            ))
                        }

                        let killItem = NSMenuItem(title: "Kill \(process.name)", action: #selector(killProcess(_:)), keyEquivalent: "")
                        killItem.representedObject = ["pid": process.pid, "force": false]
                        killItem.target = self
                        killItem.isEnabled = true
                        submenu.addItem(killItem)

                        let forceKillItem = NSMenuItem(title: "Force Quit \(process.name)", action: #selector(killProcess(_:)), keyEquivalent: "")
                        forceKillItem.representedObject = ["pid": process.pid, "force": true]
                        forceKillItem.target = self
                        forceKillItem.isEnabled = true
                        submenu.addItem(forceKillItem)

                        let hideItem = NSMenuItem(title: "Hide \"\(process.name)\"", action: #selector(hideProcess(_:)), keyEquivalent: "")
                        hideItem.representedObject = process.name
                        hideItem.target = self
                        hideItem.isEnabled = true
                        hideItem.toolTip = "Hide every process with this name from the menu"
                        submenu.addItem(hideItem)

                        if processesOnPort.count > 1,
                           let last = processesOnPort.last,
                           (process.name != last.name || process.pid != last.pid) {
                            submenu.addItem(NSMenuItem.separator())
                        }
                    }

                    portItem.submenu = submenu
                }

                menu.addItem(portItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let devToggleItem = NSMenuItem(title: "Show Only Dev Processes",
                                   action: #selector(toggleDevProcesses),
                                   keyEquivalent: "")
        devToggleItem.target = self
        devToggleItem.isEnabled = true
        devToggleItem.state = showOnlyDevProcesses ? .on : .off
        menu.addItem(devToggleItem)

        let systemToggleItem = NSMenuItem(title: "Show System Processes",
                                   action: #selector(toggleSystemProcesses),
                                   keyEquivalent: "")
        systemToggleItem.target = self
        systemToggleItem.isEnabled = true
        systemToggleItem.state = showSystemProcesses ? .on : .off
        menu.addItem(systemToggleItem)

        let hiddenItem = NSMenuItem(title: "Hidden Processes", action: nil, keyEquivalent: "")
        if hiddenProcessNames.isEmpty {
            hiddenItem.isEnabled = false
            hiddenItem.toolTip = "Use the Hide action inside a port's submenu to add entries here"
        } else {
            hiddenItem.isEnabled = true
            hiddenItem.submenu = buildHiddenProcessesSubmenu()
        }
        menu.addItem(hiddenItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Portsly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func buildHiddenProcessesSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let header = NSMenuItem(title: "Click an entry to unhide", action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        submenu.addItem(NSMenuItem.separator())

        for name in hiddenProcessNames.sorted() {
            let item = NSMenuItem(title: name, action: #selector(unhideProcess(_:)), keyEquivalent: "")
            item.representedObject = name
            item.target = self
            item.isEnabled = true
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        let clearAll = NSMenuItem(title: "Unhide All", action: #selector(clearHiddenProcesses(_:)), keyEquivalent: "")
        clearAll.target = self
        clearAll.isEnabled = true
        submenu.addItem(clearAll)

        return submenu
    }


    @objc func openInBrowser(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int else { return }

        let urlString = "http://localhost:\(port)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true

        if !hasScannedAtLeastOnce {
            // First-ever click before the pre-warm scan finished: show a placeholder
            // and rebuild the menu when the scan returns.
            menu.removeAllItems()
            let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
            refreshMenuAsync(rebuildIfOpen: true)
        } else {
            // Show the cached menu instantly; quietly refresh for next time.
            filterAndUpdateMenu()
            refreshMenuAsync(rebuildIfOpen: false)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }
}
