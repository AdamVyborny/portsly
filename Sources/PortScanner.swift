//
//  PortScanner.swift
//  Portsly
//
//  Copyright © 2025 Greg Hinkle. All rights reserved.
//

import Foundation
import AppKit
import Darwin

struct ProcessInfo {
    let pid: Int
    let name: String
    let fullCommand: String?
    let ports: [Int]
    let workingDirectory: String?
    let icon: NSImage?
}

class PortScanner {
    // Cache for process icons to avoid repeated lookups
    private var iconCache: [String: NSImage] = [:]

    // Debug flag for timing logs
    private let debugTiming = true

    // On-disk persistence for the icon cache so it survives app restarts
    private let iconCacheDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("Portsly").appendingPathComponent("iconCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let iconCacheIOQueue = DispatchQueue(label: "dev.brightbase.portsly.iconCacheIO", qos: .utility)

    init() {
        loadIconCacheFromDisk()
    }

    private func loadIconCacheFromDisk() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: iconCacheDirectory, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "png" {
            let name = url.deletingPathExtension().lastPathComponent
            if let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 16, height: 16)
                iconCache[name] = image
            }
        }
    }

    private func saveIconToCache(_ image: NSImage, forName name: String) {
        iconCache[name] = image
        // Only persist names that are safe to use as a filename directly
        guard isFilenameSafe(name) else { return }
        let dir = iconCacheDirectory
        iconCacheIOQueue.async {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let pngData = rep.representation(using: .png, properties: [:]) else { return }
            let url = dir.appendingPathComponent(name + ".png")
            try? pngData.write(to: url)
        }
    }

    private func isFilenameSafe(_ name: String) -> Bool {
        if name.isEmpty || name.hasPrefix(".") { return false }
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        return name.rangeOfCharacter(from: unsafe) == nil
    }

    // Common development process patterns
    private let devProcessPatterns = [
        "node", "python", "java", "ruby", "go", "rust", "cargo",
        "npm", "yarn", "pnpm", "bun", "deno",
        "rails", "django", "flask", "spring",
        "webpack", "vite", "parcel", "rollup",
        "php", "dotnet", "dart", "flutter",
        "elixir", "mix", "iex", "phoenix",
        "gradle", "mvn", "sbt", "lein",
        "julia", "r", "matlab", "octave"
    ]

    // Common development directory patterns
    private let devDirectoryPatterns = [
        "/Development", "/Projects", "/Code", "/Sites",
        "/dev", "/workspace", "/repos", "/git",
        "/src", "/source", "/sources", "/work",
        "/Desktop", "/Documents"
    ]

    // Processes to exclude from dev filter (IDEs, tools, etc)
    private let devExcludePatterns = [
        "webstorm", "intellij", "pycharm", "rubymine", "goland", "phpstorm",
        "datagrip", "clion", "rider", "appcode", "android studio",
        "visual studio", "vscode", "code", "sublime", "atom", "brackets",
        "eclipse", "netbeans", "xcode", "cursor",
        "docker desktop", "github desktop", "sourcetree",
        "postman", "insomnia", "tableplus", "sequel", "dbeaver",
        "tower", "fork", "kaleidoscope", "beyond compare",
        "iterm", "terminal", "warp", "hyper", "alacritty"
    ]

    private let systemProcesses = Set([
        "mDNSResponder",
        "launchd",
        "kernel_task",
        "systemd",
        "syslogd",
        "airportd",
        "WindowServer",
        "loginwindow",
        "CoreServicesUIAgent",
        "SystemUIServer",
        "Dock",
        "Finder",
        "Safari Networking",
        "nsurlsessiond",
        "trustd",
        "rapportd",
        "sharingd",
        "bluetoothd",
        "coreaudiod",
        "powerd",
        "distnoted",
        "cfprefsd",
        "UserEventAgent",
        "CommCenter",
        "locationd",
        "identityservicesd",
        "cloudd",
        "bird",
        "apsd",
        "akd",
        "coreduetd",
        "assistantd",
        "siriactionsd",
        "com.apple.",
        "VTDecoderXPCService",
        "diagnosticd",
        "logd",
        "notifyd",
        "securityd",
        "opendirectoryd",
        "timed",
        "configd",
        "hidd",
        "coreservicesd",
        "diskarbitrationd",
        "kextd",
        "fseventsd",
        "thermald",
        "warmd",
        "endpointsecurityd",
        "syspolicyd",
        "sandboxd"
    ])

    func isSystemProcess(_ processName: String) -> Bool {
        // Check exact match first
        if systemProcesses.contains(processName) {
            return true
        }

        // Check for Apple processes
        if processName.hasPrefix("com.apple.") {
            return true
        }

        // Check for prefix matches, but exclude Docker from Dock prefix check
        for systemProcess in systemProcesses {
            if systemProcess == "Dock" && (processName.hasPrefix("Docker") || processName.contains("docker")) {
                continue // Don't filter out Docker processes
            }
            if processName.hasPrefix(systemProcess) {
                return true
            }
        }

        return false
    }

    func isDevProcess(_ process: ProcessInfo) -> Bool {
        let lowerName = process.name.lowercased()

        // First check if it's an excluded process (IDE, tool, etc)
        for excludePattern in devExcludePatterns {
            if lowerName.contains(excludePattern) {
                return false
            }
        }

        // Check for explicit dev process patterns
        for pattern in devProcessPatterns {
            if lowerName.contains(pattern) {
                // Special case: if it contains "java", make sure it's not an IDE
                if pattern == "java" && (lowerName.contains("jetbrains") || lowerName.contains("idea")) {
                    continue
                }
                return true
            }
        }

        // Check if running from a development directory
        if let workingDir = process.workingDirectory {
            let expandedDir = workingDir.replacingOccurrences(of: "~", with: NSHomeDirectory())
            for pattern in devDirectoryPatterns {
                if expandedDir.contains(pattern) {
                    // But exclude if it's an IDE/tool based on the name
                    for excludePattern in devExcludePatterns {
                        if lowerName.contains(excludePattern) {
                            return false
                        }
                    }
                    return true
                }
            }
        }

        // Docker containers running dev services
        if process.name.starts(with: "docker:") {
            return true
        }

        return false
    }

    func scanPorts(showSystemProcesses: Bool = false) -> [ProcessInfo] {
        let startTime = Date()
        var processMap: [Int: (name: String, fullCommand: String?, ports: Set<Int>, workingDirectory: String?, icon: NSImage?)] = [:]
        var dockerContainerMap: [String: (pid: Int, ports: Set<Int>, workingDirectory: String?, icon: NSImage?)] = [:]
        var dockerPorts: [Int: String] = [:] // Map of port to container name for Docker

        // Stage 1: list listening sockets (gates everything else)
        let lsofOutput = run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-n", "-P"])
        let lines = lsofOutput.components(separatedBy: .newlines)

        // Walk the output once to collect PIDs and detect docker presence
        var allPids = Set<Int>()
        var hasDockerProcess = false
        for line in lines {
            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if components.count >= 10, let pid = Int(components[1]) {
                allPids.insert(pid)
                if components[0] == "com.docke" {
                    hasDockerProcess = true
                }
            }
        }

        // Stage 2: parallel batch fetches that all depend only on the PID set
        var pidToFullName: [Int: String] = [:]
        var pidToWorkingDir: [Int: String] = [:]
        var pidToArgs: [Int: String] = [:]
        var dockerInfo: [(container: String, ports: String)] = []

        if !allPids.isEmpty {
            let pidsArg = allPids.map { String($0) }.joined(separator: ",")
            let group = DispatchGroup()
            let queue = DispatchQueue.global(qos: .userInitiated)

            group.enter()
            queue.async {
                let out = self.run("/bin/ps", ["-p", pidsArg, "-o", "pid,comm"])
                for line in out.components(separatedBy: .newlines).dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    if let spaceIndex = trimmed.firstIndex(of: " ") {
                        let pidStr = String(trimmed[..<spaceIndex])
                        if let pid = Int(pidStr) {
                            let comm = String(trimmed[trimmed.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
                            pidToFullName[pid] = comm.components(separatedBy: "/").last ?? comm
                        }
                    }
                }
                group.leave()
            }

            group.enter()
            queue.async {
                let out = self.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pidsArg])
                for line in out.components(separatedBy: .newlines) {
                    let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if components.count >= 9, let pid = Int(components[1]) {
                        let path = components[8...].joined(separator: " ")
                        if let homeDir = Foundation.ProcessInfo.processInfo.environment["HOME"] {
                            pidToWorkingDir[pid] = path.replacingOccurrences(of: homeDir, with: "~")
                        } else {
                            pidToWorkingDir[pid] = path
                        }
                    }
                }
                group.leave()
            }

            group.enter()
            queue.async {
                let out = self.run("/bin/ps", ["-p", pidsArg, "-o", "pid,args"])
                for line in out.components(separatedBy: .newlines).dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    if let spaceIndex = trimmed.firstIndex(of: " ") {
                        let pidStr = String(trimmed[..<spaceIndex])
                        if let pid = Int(pidStr) {
                            let args = String(trimmed[trimmed.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
                            pidToArgs[pid] = args
                        }
                    }
                }
                group.leave()
            }

            // Only consult Docker if at least one listener actually belongs to it
            if hasDockerProcess {
                group.enter()
                queue.async {
                    dockerInfo = self.getDockerInfo()
                    group.leave()
                }
            }

            group.wait()
        }

        // First pass: map docker ports to container names using the docker info we fetched
        for line in lines {
            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 10 else { continue }

            let processName = components[0]
            guard Int(components[1]) != nil else { continue }

            let portInfo = components[8]
            if let portRange = portInfo.split(separator: ":").last,
               let port = Int(portRange.split(separator: "-").first ?? portRange) {

                if processName == "com.docke" {
                    for (container, ports) in dockerInfo {
                        if ports.contains(":\(port)->") || ports.contains("0.0.0.0:\(port)->") {
                            dockerPorts[port] = container
                            break
                        }
                    }
                }
            }
        }

        // Second pass: build the process map (names already enhanced from ps args)
        for line in lines {
            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 10 else { continue }

            let processName = components[0]
            guard let pid = Int(components[1]) else { continue }

            let portInfo = components[8]
            if let portRange = portInfo.split(separator: ":").last,
               let port = Int(portRange.split(separator: "-").first ?? portRange) {

                if processName == "com.docke" {
                    let containerName = dockerPorts[port] ?? "Docker Desktop"
                    let containerKey = "docker: \(containerName)"

                    if dockerContainerMap[containerKey] == nil {
                        let workingDir = pidToWorkingDir[pid]
                        dockerContainerMap[containerKey] = (pid: pid, ports: Set<Int>(), workingDirectory: workingDir, icon: nil)
                    }
                    dockerContainerMap[containerKey]?.ports.insert(port)
                } else {
                    if processMap[pid] == nil {
                        let fullName = pidToFullName[pid] ?? processName
                        let workingDir = pidToWorkingDir[pid]
                        let args = pidToArgs[pid]
                        let enhancedName: String
                        if let args = args {
                            enhancedName = getEnhancedProcessNameFromArgs(
                                baseName: fullName,
                                fullName: fullName,
                                psOutput: args,
                                workingDirectory: workingDir
                            )
                        } else {
                            enhancedName = fullName
                        }
                        processMap[pid] = (name: enhancedName, fullCommand: args, ports: Set<Int>(), workingDirectory: workingDir, icon: nil)
                    }
                    processMap[pid]?.ports.insert(port)
                }
            }
        }

        // Icon lookup. Group PIDs by name so we only resolve each name once.
        var pidToIcon: [Int: NSImage?] = [:]
        var processNameToPids: [String: [Int]] = [:]
        for (pid, info) in processMap {
            // Skip icon work for processes that won't be displayed anyway
            if !showSystemProcesses && isSystemProcess(info.name) {
                continue
            }
            let baseName = info.name.components(separatedBy: ":").first ?? info.name
            if processNameToPids[baseName] == nil {
                processNameToPids[baseName] = []
            }
            processNameToPids[baseName]?.append(pid)
        }

        for (processName, pids) in processNameToPids {
            // Memory cache (already includes anything loaded from disk at init)
            if let cachedIcon = iconCache[processName] {
                for pid in pids {
                    pidToIcon[pid] = cachedIcon
                }
                continue
            }

            // Known CLI tools have no useful GUI icon
            let lowerName = processName.lowercased()
            if lowerName == "node" || lowerName.contains("python") || lowerName == "java" ||
               lowerName == "ruby" || lowerName == "go" || lowerName == "rust" || lowerName == "php" {
                continue
            }

            // Fast path: NSRunningApplication (in-process workspace lookup)
            var icon: NSImage?
            for pid in pids {
                if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                    icon = app.icon
                    if icon != nil {
                        icon?.size = NSSize(width: 16, height: 16)
                        break
                    }
                }
            }

            // Slow path: only worth attempting for processes that could plausibly
            // be wrapped in a .app bundle. Daemons matched by isSystemProcess never are.
            if icon == nil
                && !processName.contains(".")
                && !processName.contains("/")
                && !isSystemProcess(processName) {
                if let firstPid = pids.first {
                    // `-d txt` limits lsof to the executable text descriptor — orders of
                    // magnitude faster than dumping every open fd for the process.
                    let txtOutput = run("/usr/sbin/lsof", ["-p", String(firstPid), "-d", "txt"])
                    if let line = txtOutput.components(separatedBy: .newlines).first(where: { $0.contains(".app/Contents/MacOS") }),
                       let appRange = line.range(of: #"(/[^:]+\.app)/Contents/MacOS"#, options: .regularExpression) {
                        let appBundlePath = String(line[appRange]).replacingOccurrences(of: "/Contents/MacOS", with: "")
                        icon = getProcessIconFromAppPath(appPath: appBundlePath)
                    }
                }
            }

            if let icon = icon {
                saveIconToCache(icon, forName: processName)
                for pid in pids {
                    pidToIcon[pid] = icon
                }
            }
        }

        // Docker containers all share one icon
        if !dockerContainerMap.isEmpty {
            let dockerPids = Set(dockerContainerMap.values.map { $0.pid })
            if let dockerPid = dockerPids.first {
                if let cachedIcon = iconCache["Docker"] {
                    for pid in dockerPids {
                        pidToIcon[pid] = cachedIcon
                    }
                } else {
                    var dockerIcon: NSImage?
                    if let app = NSRunningApplication(processIdentifier: pid_t(dockerPid)) {
                        dockerIcon = app.icon
                        dockerIcon?.size = NSSize(width: 16, height: 16)
                    }
                    if dockerIcon == nil {
                        let dockerAppPaths = [
                            "/Applications/Docker.app",
                            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Docker.app",
                            NSHomeDirectory() + "/Applications/Docker.app"
                        ]
                        for path in dockerAppPaths where FileManager.default.fileExists(atPath: path) {
                            let icon = NSWorkspace.shared.icon(forFile: path)
                            icon.size = NSSize(width: 16, height: 16)
                            dockerIcon = icon
                            break
                        }
                    }
                    if let dockerIcon = dockerIcon {
                        saveIconToCache(dockerIcon, forName: "Docker")
                        for pid in dockerPids {
                            pidToIcon[pid] = dockerIcon
                        }
                    }
                }
            }
        }

        // Combine regular processes and Docker containers
        var allProcesses = processMap.map { pid, info in
            ProcessInfo(pid: pid, name: info.name, fullCommand: info.fullCommand, ports: Array(info.ports).sorted(), workingDirectory: info.workingDirectory, icon: pidToIcon[pid] ?? nil)
        }

        allProcesses += dockerContainerMap.map { containerName, info in
            ProcessInfo(pid: info.pid, name: containerName, fullCommand: nil, ports: Array(info.ports).sorted(), workingDirectory: info.workingDirectory, icon: pidToIcon[info.pid] ?? nil)
        }

        let result: [ProcessInfo]
        if showSystemProcesses {
            result = allProcesses.sorted { $0.name < $1.name }
        } else {
            result = allProcesses
                .filter { process in
                    !isSystemProcess(process.name)
                }
                .sorted { $0.name < $1.name }
        }

        if debugTiming {
            let totalTime = Date().timeIntervalSince(startTime)
            let totalTimeMs = totalTime * 1000
            print(String(format: "[%.0fms] Portsly: Total scanPorts", totalTimeMs))
        }

        return result
    }

    func killProcess(pid: Int, force: Bool = false) -> Bool {
        let signal: Int32 = force ? SIGKILL : SIGTERM
        return Darwin.kill(pid_t(pid), signal) == 0
    }

    private func getEnhancedProcessNameFromArgs(baseName: String, fullName: String, psOutput: String, workingDirectory: String? = nil) -> String {
        // Skip Docker process enhancement here - it will be handled during port scanning
        if fullName.contains("docker") || fullName.contains("com.docker") {
            return fullName
        }

        if psOutput.isEmpty {
            return fullName
        }

        // Handle node processes
        if fullName == "node" {
            return getEnhancedNodeProcessName(psOutput: psOutput, workingDirectory: workingDirectory)
        }

        // Handle Python processes
        if fullName == "Python" || fullName.starts(with: "python") {
            // First try to get project name from pyproject.toml or setup.py
            if let cwd = workingDirectory {
                let expandedCwd = cwd.replacingOccurrences(of: "~", with: NSHomeDirectory())

                // Check pyproject.toml
                let pyprojectPath = expandedCwd + "/pyproject.toml"
                if let data = FileManager.default.contents(atPath: pyprojectPath),
                   let content = String(data: data, encoding: .utf8) {
                    // Simple regex to find project name in pyproject.toml
                    if let match = content.range(of: #"name\s*=\s*[\"']([^\"']+)[\"']"#, options: .regularExpression) {
                        let projectName = String(content[match]).replacingOccurrences(of: #"name\s*=\s*[\"']"#, with: "", options: .regularExpression).replacingOccurrences(of: #"[\"']"#, with: "", options: .regularExpression)
                        return "python: \(projectName)"
                    }
                }

                // Check setup.py
                let setupPath = expandedCwd + "/setup.py"
                if let data = FileManager.default.contents(atPath: setupPath),
                   let content = String(data: data, encoding: .utf8) {
                    // Simple regex to find name in setup()
                    if let match = content.range(of: #"name\s*=\s*[\"']([^\"']+)[\"']"#, options: .regularExpression) {
                        let projectName = String(content[match]).replacingOccurrences(of: #"name\s*=\s*[\"']"#, with: "", options: .regularExpression).replacingOccurrences(of: #"[\"']"#, with: "", options: .regularExpression)
                        return "python: \(projectName)"
                    }
                }
            }

            // Look for script name
            if let match = psOutput.range(of: #"(?:python[0-9.]*\s+)?(?:.*?/)?([\\w\\-\\.]+\\.py)"#, options: .regularExpression) {
                let scriptName = String(psOutput[match]).components(separatedBy: "/").last ?? fullName
                return "python: \(scriptName)"
            }
            // Look for -m module
            if let match = psOutput.range(of: #"-m\s+([\\w\\.]+)"#, options: .regularExpression) {
                let moduleName = String(psOutput[match]).replacingOccurrences(of: "-m", with: "").trimmingCharacters(in: .whitespaces)
                return "python: \(moduleName)"
            }
        }

        // Handle Java processes
        if fullName == "java" {
            // First try to get project name from pom.xml or build.gradle
            if let cwd = workingDirectory {
                let expandedCwd = cwd.replacingOccurrences(of: "~", with: NSHomeDirectory())

                // Check pom.xml
                let pomPath = expandedCwd + "/pom.xml"
                if let data = FileManager.default.contents(atPath: pomPath),
                   let content = String(data: data, encoding: .utf8) {
                    // Simple regex to find artifactId in pom.xml
                    if let match = content.range(of: #"<artifactId>([^<]+)</artifactId>"#, options: .regularExpression) {
                        let projectName = String(content[match]).replacingOccurrences(of: "<artifactId>", with: "").replacingOccurrences(of: "</artifactId>", with: "")
                        return "java: \(projectName)"
                    }
                }

                // Check build.gradle
                let gradlePath = expandedCwd + "/build.gradle"
                if FileManager.default.fileExists(atPath: gradlePath) {
                    // Use directory name as project name for Gradle projects
                    let projectName = URL(fileURLWithPath: expandedCwd).lastPathComponent
                    return "java: \(projectName)"
                }
            }

            // Look for jar files
            if let match = psOutput.range(of: #"-jar\s+(?:.*?/)?([\\w\\-\\.]+\\.jar)"#, options: .regularExpression) {
                let jarName = String(psOutput[match]).replacingOccurrences(of: "-jar", with: "").trimmingCharacters(in: .whitespaces).components(separatedBy: "/").last ?? fullName
                return "java: \(jarName)"
            }
            // Look for main class
            if let match = psOutput.range(of: #"(?:^|\s)([\\w\\.]+\\.[A-Z]\\w*)"#, options: .regularExpression) {
                let className = String(psOutput[match]).trimmingCharacters(in: .whitespaces)
                return "java: \(className)"
            }
        }

        // If no enhancement found, return full name
        return fullName
    }

    private func getEnhancedProcessName(pid: Int, baseName: String, fullName: String, workingDirectory: String? = nil) -> String {

        // Skip Docker process enhancement here - it will be handled during port scanning
        if fullName.contains("docker") || fullName.contains("com.docker") {
            return fullName
        }

        // Get process arguments using ps
        let psOutput = shell("ps -p \(pid) -o args= | head -1").trimmingCharacters(in: .whitespacesAndNewlines)

        if psOutput.isEmpty {
            return fullName
        }

        // Handle node processes
        if fullName == "node" {
            return getEnhancedNodeProcessName(psOutput: psOutput, workingDirectory: workingDirectory)
        }


        // Handle Python processes
        if fullName == "Python" || fullName.starts(with: "python") {
            // First try to get project name from pyproject.toml or setup.py
            if let cwd = workingDirectory {
                let expandedCwd = cwd.replacingOccurrences(of: "~", with: NSHomeDirectory())

                // Check pyproject.toml
                let pyprojectPath = expandedCwd + "/pyproject.toml"
                if let data = FileManager.default.contents(atPath: pyprojectPath),
                   let content = String(data: data, encoding: .utf8) {
                    // Simple regex to find project name in pyproject.toml
                    if let match = content.range(of: #"name\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
                        let projectName = String(content[match]).replacingOccurrences(of: #"name\s*=\s*["']"#, with: "", options: .regularExpression).replacingOccurrences(of: #"["']"#, with: "", options: .regularExpression)
                        return "python: \(projectName)"
                    }
                }

                // Check setup.py
                let setupPath = expandedCwd + "/setup.py"
                if let data = FileManager.default.contents(atPath: setupPath),
                   let content = String(data: data, encoding: .utf8) {
                    // Simple regex to find name in setup()
                    if let match = content.range(of: #"name\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
                        let projectName = String(content[match]).replacingOccurrences(of: #"name\s*=\s*["']"#, with: "", options: .regularExpression).replacingOccurrences(of: #"["']"#, with: "", options: .regularExpression)
                        return "python: \(projectName)"
                    }
                }
            }

            // Look for script name
            if let match = psOutput.range(of: #"(?:python[0-9.]*\s+)?(?:.*?/)?([\w\-\.]+\.py)"#, options: .regularExpression) {
                let scriptName = String(psOutput[match]).components(separatedBy: "/").last ?? fullName
                return "python: \(scriptName)"
            }
            // Look for -m module
            if let match = psOutput.range(of: #"-m\s+([\w\.]+)"#, options: .regularExpression) {
                let moduleName = String(psOutput[match]).replacingOccurrences(of: "-m", with: "").trimmingCharacters(in: .whitespaces)
                return "python: \(moduleName)"
            }
        }

        // Handle Java processes
        if fullName == "java" {
            // First try to get project name from pom.xml or build.gradle
            if let cwd = workingDirectory {
                let expandedCwd = cwd.replacingOccurrences(of: "~", with: NSHomeDirectory())

                // Check pom.xml
                let pomPath = expandedCwd + "/pom.xml"
                if let data = FileManager.default.contents(atPath: pomPath),
                   let content = String(data: data, encoding: .utf8) {
                    // Simple regex to find artifactId in pom.xml
                    if let match = content.range(of: #"<artifactId>([^<]+)</artifactId>"#, options: .regularExpression) {
                        let projectName = String(content[match]).replacingOccurrences(of: "<artifactId>", with: "").replacingOccurrences(of: "</artifactId>", with: "")
                        return "java: \(projectName)"
                    }
                }

                // Check build.gradle
                let gradlePath = expandedCwd + "/build.gradle"
                if FileManager.default.fileExists(atPath: gradlePath) {
                    // Use directory name as project name for Gradle projects
                    let projectName = URL(fileURLWithPath: expandedCwd).lastPathComponent
                    return "java: \(projectName)"
                }
            }

            // Look for jar files
            if let match = psOutput.range(of: #"-jar\s+(?:.*?/)?([\w\-\.]+\.jar)"#, options: .regularExpression) {
                let jarName = String(psOutput[match]).replacingOccurrences(of: "-jar", with: "").trimmingCharacters(in: .whitespaces).components(separatedBy: "/").last ?? fullName
                return "java: \(jarName)"
            }
            // Look for main class
            if let match = psOutput.range(of: #"(?:^|\s)([\w\.]+\.[A-Z]\w*)"#, options: .regularExpression) {
                let className = String(psOutput[match]).trimmingCharacters(in: .whitespaces)
                return "java: \(className)"
            }
        }

        // If no enhancement found, return full name
        return fullName
    }

    private func getProcessIconFromAppPath(appPath: String) -> NSImage? {
        // Get icon from app bundle
        if let bundle = Bundle(path: appPath),
           let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let iconPath = bundle.path(forResource: iconFile.replacingOccurrences(of: ".icns", with: ""), ofType: "icns")
                ?? bundle.path(forResource: iconFile, ofType: nil)

            if let iconPath = iconPath,
               let icon = NSImage(contentsOfFile: iconPath) {
                icon.size = NSSize(width: 16, height: 16)
                return icon
            }
        }

        // Try to get icon using NSWorkspace
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }


    private func shell(_ command: String, timeout: TimeInterval? = nil) -> String {
        let startTime = debugTiming ? Date() : nil

        let task = Process()
        let pipe = Pipe()

        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/bash"
        task.standardInput = nil

        // Add PATH to ensure docker command is found
        var env = Foundation.ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        task.environment = env

        do {
            try task.run()

            if let timeout = timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if task.isRunning {
                        task.terminate()
                    }
                }
            }

            // Drain the pipe before waitUntilExit. macOS pipe buffers are 64KB —
            // children that print more than that block on write, which would
            // deadlock the wait below. readDataToEndOfFile returns when the
            // child closes its end (i.e. exits or is terminated).
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let result = String(data: data, encoding: .utf8) ?? ""

            if let startTime = startTime {
                let elapsed = Date().timeIntervalSince(startTime)
                let elapsedMs = elapsed * 1000
                print(String(format: "[%.0fms] Portsly Shell Command: '%@'", elapsedMs, command))
            }

            return result
        } catch {
            return ""
        }
    }

    // Direct-exec variant — no shell layer. Use when no pipes/redirects needed.
    private func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval? = nil) -> String {
        let startTime = debugTiming ? Date() : nil

        let task = Process()
        let pipe = Pipe()

        task.standardOutput = pipe
        task.standardError = pipe
        task.launchPath = launchPath
        task.arguments = arguments
        task.standardInput = nil

        var env = Foundation.ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        task.environment = env

        do {
            try task.run()

            if let timeout = timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if task.isRunning {
                        task.terminate()
                    }
                }
            }

            // Drain the pipe before waitUntilExit. macOS pipe buffers are 64KB —
            // children that print more than that block on write, which would
            // deadlock the wait below. readDataToEndOfFile returns when the
            // child closes its end (i.e. exits or is terminated).
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let result = String(data: data, encoding: .utf8) ?? ""

            if let startTime = startTime {
                let elapsedMs = Date().timeIntervalSince(startTime) * 1000
                print(String(format: "[%.0fms] Portsly run: %@ %@", elapsedMs, launchPath, arguments.joined(separator: " ")))
            }

            return result
        } catch {
            return ""
        }
    }


    func getDockerInfo() -> [(container: String, ports: String)] {
        // Locate docker binary directly — much faster than `which docker`
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        guard let dockerPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return []
        }

        // Hard timeout: if the daemon is unresponsive, never block the menu for it
        let dockerOutput = run(dockerPath, ["ps", "--format", "{{.Names}}: {{.Ports}}"], timeout: 1.0)

        if dockerOutput.isEmpty {
            return []
        }

        return dockerOutput.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .map { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                let container = parts.count > 0 ? String(parts[0]) : ""
                let ports = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                return (container: container, ports: ports)
            }
    }

    private func getEnhancedNodeProcessName(psOutput: String, workingDirectory: String? = nil) -> String {
        // First try to get the project name from package.json
        if let cwd = workingDirectory {
            let packageJsonPath = cwd.replacingOccurrences(of: "~", with: NSHomeDirectory()) + "/package.json"
            if let data = FileManager.default.contents(atPath: packageJsonPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let projectName = json["name"] as? String {
                return "node: \(projectName)"
            }
        }

        // Check for package.json script name
        if let packageJsonScript = extractPackageJsonScript(from: psOutput) {
            return "node: \(packageJsonScript)"
        }

        // Check for npm/yarn/pnpm/bun
        if psOutput.contains("npm run") {
            if let scriptName = psOutput.range(of: #"npm run (\S+)"#, options: .regularExpression) {
                let script = String(psOutput[scriptName]).replacingOccurrences(of: "npm run ", with: "")
                return "node: npm run \(script)"
            }
            return "node: npm"
        }

        if psOutput.contains("yarn") {
            if let scriptName = psOutput.range(of: #"yarn (?:run )?(\S+)"#, options: .regularExpression) {
                let script = String(psOutput[scriptName]).replacingOccurrences(of: "yarn ", with: "").replacingOccurrences(of: "run ", with: "")
                return "node: yarn \(script)"
            }
            return "node: yarn"
        }

        if psOutput.contains("pnpm") {
            return "node: pnpm"
        }

        if psOutput.contains("bun") {
            return "node: bun"
        }

        // Check for common frameworks
        if psOutput.contains("next") || psOutput.contains("nextjs") {
            return "node: Next.js"
        }

        if psOutput.contains("react-scripts") {
            return "node: React"
        }

        if psOutput.contains("vue-cli-service") {
            return "node: Vue"
        }

        if psOutput.contains("ng serve") || psOutput.contains("angular") {
            return "node: Angular"
        }

        if psOutput.contains("vite") {
            return "node: Vite"
        }

        if psOutput.contains("webpack") {
            return "node: Webpack"
        }

        if psOutput.contains("nodemon") {
            // Try to get the actual script being run by nodemon
            if let match = psOutput.range(of: #"nodemon\s+(?:.*?\s+)?([^\s]+\.js)"#, options: .regularExpression) {
                let script = String(psOutput[match]).components(separatedBy: " ").last ?? "nodemon"
                return "node: nodemon → \(script)"
            }
            return "node: nodemon"
        }

        if psOutput.contains("ts-node") {
            // Try to get the TypeScript file
            if let match = psOutput.range(of: #"ts-node\s+(?:.*?\s+)?([^\s]+\.ts)"#, options: .regularExpression) {
                let script = String(psOutput[match]).components(separatedBy: " ").last ?? "ts-node"
                return "node: \(script)"
            }
            return "node: ts-node"
        }

        // Look for .js/.mjs/.cjs files
        if let match = psOutput.range(of: #"(?:node\s+)?(?:.*?/)?([\w\-\.]+\.[mc]?js)"#, options: .regularExpression) {
            let scriptName = String(psOutput[match]).components(separatedBy: "/").last ?? "node"
            return "node: \(scriptName)"
        }

        // Try to extract any meaningful script name
        let components = psOutput.components(separatedBy: .whitespaces)
        for component in components {
            // Look for common entry points
            if component.hasSuffix("server.js") || component.hasSuffix("app.js") ||
               component.hasSuffix("index.js") || component.hasSuffix("main.js") ||
               component.hasSuffix("server.ts") || component.hasSuffix("app.ts") ||
               component.hasSuffix("index.ts") || component.hasSuffix("main.ts") {
                let scriptName = component.components(separatedBy: "/").last ?? component
                return "node: \(scriptName)"
            }

            // Check if this looks like a script path
            if component.contains("/") && (component.hasSuffix(".js") || component.hasSuffix(".ts") || component.hasSuffix(".mjs") || component.hasSuffix(".cjs")) {
                let scriptName = component.components(separatedBy: "/").last ?? component
                return "node: \(scriptName)"
            }
        }

        return "node"
    }

    private func extractPackageJsonScript(from psOutput: String) -> String? {
        // Look for node process running from node_modules/.bin
        if let match = psOutput.range(of: #"node_modules/\.bin/(\S+)"#, options: .regularExpression) {
            let scriptName = String(psOutput[match]).replacingOccurrences(of: "node_modules/.bin/", with: "")
            return scriptName
        }
        return nil
    }

}
