import SwiftUI
import Foundation
import AppKit

@MainActor
final class AppViewModel: ObservableObject {
    struct BugReportDraft {
        let title: String
        let systemInfo: String
        let recentLogs: String
    }

    private struct NetworkInterfaceInfo {
        enum Kind: String {
            case wifi = "Wi-Fi"
            case ethernet = "Ethernet"
        }

        let device: String
        let hardwarePort: String
        let networkService: String
        let kind: Kind
    }

    private enum Constants {
        static let errorDomain = "1132Fixer"
        static let bashPath = "/bin/bash"
        static let osascriptPath = "/usr/bin/osascript"
    }

    private final class LockedDataBuffer {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let copy = data
            lock.unlock()
            return copy
        }
    }

    private static let logTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
    private static let bugTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    @Published var logs: [String] = []
    @Published var isRunning = false
    private let stopZoomCommand = #"""
if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
  /usr/bin/killall "zoom.us" 2>/dev/null || true
  echo "Zoom was running and has been closed."
  for i in {1..10}; do
    /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 || break
    /bin/sleep 0.5
  done
  if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
    /usr/bin/killall -9 "zoom.us" 2>/dev/null || true
    /bin/sleep 1
  fi
fi
"""#
    private let resetZoomDataCommand = #"rm -rf "$HOME/Library/Application Support/zoom.us" "$HOME/Library/Caches/us.zoom.xos" "$HOME/Library/Preferences/us.zoom.xos.plist" "$HOME/Library/Logs/zoom.us.log"* "$HOME/Library/Saved Application State/us.zoom.xos.savedState"; defaults delete us.zoom.xos 2>/dev/null || true"#
    private let stopZoomUpdatersCommand = #"""
for proc in zAutoUpdate zPTUpdaterUI ZoomUpdater; do
  /usr/bin/pkill -x "$proc" 2>/dev/null || true
done

for domain in gui/"$(/usr/bin/id -u)" user; do
  for label in us.zoom.zAutoUpdate us.zoom.ZoomUpdater us.zoom.zPTUpdaterUI; do
    /bin/launchctl bootout "$domain" "/Library/LaunchAgents/$label.plist" 2>/dev/null || true
    /bin/launchctl bootout "$domain" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null || true
    /bin/launchctl disable "$domain/$label" 2>/dev/null || true
  done
done
"""#
    private let refreshDNSAppleScript = #"do shell script "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder" with administrator privileges"#
    private let zoomBinaryPath = "/Applications/zoom.us.app/Contents/MacOS/zoom.us"

    func startZoom() {
        runTask("Start Zoom") {
            self.appendLog("Step: Close Zoom if it is running")
            let stopZoomOutput = try await self.runProcess(
                stepName: "Close Zoom",
                executable: Constants.bashPath,
                arguments: ["-c", self.stopZoomCommand]
            )
            self.appendLog("Step: Spoof MAC and reconnect active network (admin prompt expected)")
            let macSpoofOutput: String
            do {
                macSpoofOutput = try await self.spoofMACAndReconnectActiveInterface()
            } catch {
                macSpoofOutput = "MAC spoofing skipped: \(error.localizedDescription)"
            }
            self.appendLog("Step: Reset Zoom data")
            let resetOutput = try await self.runProcess(
                stepName: "Reset Zoom data",
                executable: Constants.bashPath,
                arguments: ["-c", self.resetZoomDataCommand]
            )
            self.appendLog("Step: Refresh DNS cache (admin prompt may appear)")
            let dnsOutput = try await self.runProcess(
                stepName: "Refresh DNS cache",
                executable: Constants.osascriptPath,
                arguments: ["-e", self.refreshDNSAppleScript]
            )
            self.appendLog("Step: Stop Zoom updaters")
            let stopUpdatersOutput = try await self.runProcess(
                stepName: "Stop Zoom updaters",
                executable: Constants.bashPath,
                arguments: ["-c", self.stopZoomUpdatersCommand]
            )
            self.appendLog("Step: Launch Zoom")
            let launchOutput = try await self.runProcess(
                stepName: "Launch Zoom",
                executable: Constants.bashPath,
                arguments: ["-c", self.makeLaunchZoomCommand()]
            )

            return [stopZoomOutput, macSpoofOutput, resetOutput, dnsOutput, stopUpdatersOutput, launchOutput]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs.joined(separator: "\n"), forType: .string)
    }

    func logMessage(_ text: String) {
        appendLog(text)
    }

    func makeBugReportDraft(appVersion: String, maxLogLines: Int = 200) -> BugReportDraft {
        let now = Date()
        let title = "Bug Report \(Self.bugTitleFormatter.string(from: now))"
        let timestamp = Self.logTimestampFormatter.string(from: now)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let architecture = machineArchitecture()
        let lastStatus = inferLastActionStatus()
        let recentLogs = Array(logs.suffix(maxLogLines))
        let logsBlock = recentLogs.isEmpty ? "No logs captured." : recentLogs.joined(separator: "\n")
        let systemInfo = """
App version: \(appVersion)
OS: \(osVersion)
Architecture: \(architecture)
Timestamp: \(timestamp)
Last action status: \(lastStatus)
"""
        return BugReportDraft(title: title, systemInfo: systemInfo, recentLogs: logsBlock)
    }

    private func runTask(
        _ title: String,
        onSuccess: (() -> Void)? = nil,
        action: @escaping () async throws -> String
    ) {
        guard !isRunning else {
            appendLog("Another task is already running.")
            return
        }

        isRunning = true
        appendLog("=== \(title) ===")

        Task {
            defer { isRunning = false }
            do {
                let output = try await action()
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendLog(output)
                }
                appendLog("Done.")
                onSuccess?()
            } catch {
                appendLog("Error: \(error.localizedDescription)")
            }
        }
    }

    private func appendLog(_ text: String) {
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        logs.append("[\(timestamp)] \(text)")
    }

    private func inferLastActionStatus() -> String {
        for line in logs.reversed() {
            if line.contains("Error:") {
                return "Error"
            }
            if line.contains("Done.") {
                return "Completed"
            }
            if line.contains("=== Start Zoom ===") {
                return "In Progress"
            }
        }
        return "Unknown"
    }

    private func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let values = mirror.children.compactMap { child -> UInt8? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return UInt8(value)
        }
        return String(bytes: values, encoding: .ascii) ?? "unknown"
    }

    private func isMacSpoofingBlockedOnWiFi() -> Bool {
        // macOS 14 (Sonoma) and later block Wi-Fi MAC spoofing at the driver level on Apple Silicon.
        let isAppleSilicon = machineArchitecture() == "arm64"
        let isMacOS14OrLater = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        return isAppleSilicon && isMacOS14OrLater
    }

    private func spoofMACAndReconnectActiveInterface() async throws -> String {
        let interface = try await resolveActiveSupportedInterface()

        if interface.kind == .wifi && isMacSpoofingBlockedOnWiFi() {
            return """
MAC spoofing skipped: Wi-Fi MAC spoofing is not supported on Apple Silicon Macs running macOS Sonoma (14) or later. \
Zoom will be launched in a restricted sandbox environment instead, which forces it to generate a fresh device identity.
"""
        }

        let spoofedMAC = try generateRandomMACAddress()

        let setMACCommand = "(/sbin/ifconfig \(shellSingleQuote(interface.device)) lladdr \(shellSingleQuote(spoofedMAC)) || /sbin/ifconfig \(shellSingleQuote(interface.device)) ether \(shellSingleQuote(spoofedMAC)))"
        let interfaceDownCommand = "/sbin/ifconfig \(shellSingleQuote(interface.device)) down"
        let interfaceUpCommand = "/sbin/ifconfig \(shellSingleQuote(interface.device)) up"
        let disableServiceCommand = "/usr/sbin/networksetup -setnetworkserviceenabled \(shellSingleQuote(interface.networkService)) off"
        let enableServiceCommand = "/usr/sbin/networksetup -setnetworkserviceenabled \(shellSingleQuote(interface.networkService)) on"
        let sleepShort = "/bin/sleep 1"
        let sleepReconnect = "/bin/sleep 2"

        // Attempt MAC change with interface briefly down. Use semicolons (not &&) to ensure
        // the interface and service are always restored even when MAC spoofing is blocked
        // (e.g. by macOS restrictions). This prevents the Wi-Fi being left in a broken state.
        let macAttempt = "(\(interfaceDownCommand) && \(sleepShort) && \(setMACCommand)) 2>/dev/null || true"
        let restoreUp = "\(interfaceUpCommand) 2>/dev/null || true"
        let recycleService = "\(disableServiceCommand) 2>/dev/null || true; \(sleepShort); \(enableServiceCommand)"
        let spoofScript = "\(macAttempt); \(restoreUp); \(sleepShort); \(recycleService); \(sleepReconnect)"

        let appleScript = appleScriptDoShellScript(spoofScript, administratorPrivileges: true)
        let commandOutput = try await runProcess(
            stepName: "Spoof MAC and reconnect \(interface.kind.rawValue)",
            executable: Constants.osascriptPath,
            arguments: ["-e", appleScript]
        )

        // Verify the MAC was actually changed. macOS or some network adapters silently
        // ignore ifconfig MAC changes, which would leave Zoom with the same banned MAC.
        let verifyScript = "/sbin/ifconfig \(shellSingleQuote(interface.device)) | /usr/bin/awk '/^[[:space:]]*ether /{print $2; exit}'"
        let actualMAC = (try? await runProcess(
            stepName: "Verify MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let macVerified = !actualMAC.isEmpty && actualMAC == spoofedMAC.lowercased()

        let summary: String
        if macVerified {
            summary = "MAC spoofed on \(interface.kind.rawValue) (\(interface.device), service: \(interface.networkService)) -> \(spoofedMAC); network service restarted"
        } else {
            let detail = actualMAC.isEmpty
                ? "Could not read the current MAC address after spoofing."
                : "Current MAC (\(actualMAC)) does not match target (\(spoofedMAC))."
            summary = """
Warning: MAC address was not changed on \(interface.kind.rawValue) (\(interface.device)). \(detail)
This is a known macOS limitation on Apple Silicon Macs (macOS Sonoma 14 and later): \
the OS blocks Wi-Fi MAC spoofing at the driver level. Zoom will likely still show error 1132.
What you can try:
  1. Connect via Ethernet — MAC spoofing still works on Ethernet adapters.
  2. Use your phone as a hotspot — this gives you a different network identity entirely.
  3. Turn on Private Wi-Fi Address for your network in System Settings > Wi-Fi, \
disconnect, and reconnect before running Start Zoom again.
"""
        }

        let trimmedCommandOutput = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedCommandOutput.isEmpty {
            return summary
        }

        return "\(summary)\n\(trimmedCommandOutput)"
    }

    private func resolveActiveSupportedInterface() async throws -> NetworkInterfaceInfo {
        let defaultRouteOutput = try await runProcess(
            stepName: "Detect active network interface",
            executable: Constants.bashPath,
            arguments: ["-c", "/sbin/route -n get default"]
        )
        let activeDevice = try parseDefaultRouteInterface(from: defaultRouteOutput)

        let hardwarePortsOutput = try await runProcess(
            stepName: "Inspect hardware ports",
            executable: Constants.bashPath,
            arguments: ["-c", "/usr/sbin/networksetup -listallhardwareports"]
        )
        let hardwarePortMap = parseHardwarePorts(from: hardwarePortsOutput)

        guard let hardwarePortName = hardwarePortMap[activeDevice] else {
            throw appError("Detect active network interface: Could not map interface '\(activeDevice)' to a hardware port.")
        }

        let kind = try classifySupportedInterface(hardwarePortName: hardwarePortName)

        let serviceOrderOutput = try await runProcess(
            stepName: "Inspect network services",
            executable: Constants.bashPath,
            arguments: ["-c", "/usr/sbin/networksetup -listnetworkserviceorder"]
        )
        let serviceMap = parseNetworkServiceOrder(from: serviceOrderOutput)

        guard let networkService = serviceMap[activeDevice], !networkService.isEmpty else {
            throw appError("Detect active network interface: Could not resolve network service for interface '\(activeDevice)'.")
        }

        return NetworkInterfaceInfo(
            device: activeDevice,
            hardwarePort: hardwarePortName,
            networkService: networkService,
            kind: kind
        )
    }

    private func parseDefaultRouteInterface(from output: String) throws -> String {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("interface:") else { continue }

            let value = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            guard isSafeInterfaceName(value) else {
                throw appError("Detect active network interface: Invalid interface name '\(value)'.")
            }
            try ensureVPNIsNotActive(interfaceName: value)
            return value
        }

        throw appError("Detect active network interface: No default route interface was found. Connect to Wi-Fi or Ethernet and try again.")
    }

    private func ensureVPNIsNotActive(interfaceName: String) throws {
        let normalized = interfaceName.lowercased()
        let vpnPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

        if vpnPrefixes.contains(where: normalized.hasPrefix) {
            throw appError("VPN detected on interface '\(interfaceName)'. Turn off your VPN and run Start Zoom again.")
        }
    }

    private func parseHardwarePorts(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentHardwarePort: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Hardware Port:") {
                currentHardwarePort = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("Device:"), let hardwarePort = currentHardwarePort {
                let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if isSafeInterfaceName(device) {
                    result[device] = hardwarePort
                }
            }
        }

        return result
    }

    private func classifySupportedInterface(hardwarePortName: String) throws -> NetworkInterfaceInfo.Kind {
        let normalized = hardwarePortName.lowercased()

        if normalized.contains("wi-fi") || normalized.contains("wifi") {
            return .wifi
        }
        if normalized.contains("ethernet") {
            return .ethernet
        }

        throw appError("Detect active network interface: Active interface '\(hardwarePortName)' is not supported. Only Wi-Fi and Ethernet are supported.")
    }

    private func parseNetworkServiceOrder(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        var pendingServiceName: String?

        let pattern = #"\(Hardware Port: .*?, Device: ([^)]+)\)"#
        let regex = try? NSRegularExpression(pattern: pattern)

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("("), let closingParen = line.firstIndex(of: ")"), line.index(after: closingParen) < line.endIndex {
                let nameStart = line.index(after: closingParen)
                let serviceName = line[nameStart...].trimmingCharacters(in: .whitespaces)
                if !serviceName.isEmpty && !serviceName.hasPrefix("*") {
                    pendingServiceName = serviceName
                } else {
                    pendingServiceName = nil
                }
                continue
            }

            guard line.hasPrefix("(Hardware Port:"), let serviceName = pendingServiceName, let regex else { continue }
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges > 1 else { continue }

            let deviceRange = match.range(at: 1)
            guard deviceRange.location != NSNotFound else { continue }

            let device = nsLine.substring(with: deviceRange).trimmingCharacters(in: .whitespaces)
            if isSafeInterfaceName(device) {
                result[device] = serviceName
            }
        }

        return result
    }

    private func makeLaunchZoomCommand() -> String {
        guard FileManager.default.fileExists(atPath: zoomBinaryPath) else {
            return #"open -a "zoom.us""#
        }
        // Launch Zoom under a sandbox that blocks reads of its entire stored device-fingerprint
        // data directory. This forces Zoom to generate a fresh device identity, helping bypass
        // error 1132 on systems where ifconfig MAC spoofing is blocked (e.g. Apple Silicon
        // with macOS Sonoma 14+).
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/zoom.us/data")
            .path
        let profile = """
(version 1)
(allow default)
(deny file-read*
  (subpath "\(dataDir)")
)
"""
        return "nohup /usr/bin/sandbox-exec -p \(shellSingleQuote(profile)) \(shellSingleQuote(zoomBinaryPath)) >/dev/null 2>&1 &"
    }

    private func generateRandomMACAddress() throws -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE // locally administered + unicast

        let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        guard isValidMACAddress(mac) else {
            throw appError("Generate MAC address: Failed to generate a valid MAC address.")
        }

        return mac
    }

    private func isValidMACAddress(_ value: String) -> Bool {
        let pattern = #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func isSafeInterfaceName(_ value: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9]+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\"'\"'"#) + "'"
    }

    private func appleScriptDoShellScript(_ command: String, administratorPrivileges: Bool) -> String {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let privilegeClause = administratorPrivileges ? " with administrator privileges" : ""
        return "do shell script \"\(escapedCommand)\"\(privilegeClause)"
    }

    private func appError(_ message: String) -> NSError {
        NSError(
            domain: Constants.errorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func runProcess(stepName: String, executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            let stdoutBuffer = LockedDataBuffer()
            let stderrBuffer = LockedDataBuffer()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
            }

            do {
                process.terminationHandler = { terminatedProcess in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil

                    let outData = stdoutBuffer.snapshot()
                    let errData = stderrBuffer.snapshot()

                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    let combined = [stdout, stderr]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")

                    if terminatedProcess.terminationStatus == 0 {
                        continuation.resume(returning: combined)
                        return
                    }

                    let trimmedOutput = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message: String
                    if !trimmedOutput.isEmpty {
                        message = "\(stepName): \(trimmedOutput)"
                    } else if executable == Constants.osascriptPath {
                        message = "\(stepName): Admin authorization was canceled or failed."
                    } else {
                        message = "\(stepName): Command failed with exit code \(terminatedProcess.terminationStatus)."
                    }

                    continuation.resume(throwing: NSError(
                        domain: Constants.errorDomain,
                        code: Int(terminatedProcess.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                }

                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    private let repositoryURL = URL(string: "https://github.com/PrimeUpYourLife/1132-fixer")!
    private let websiteURL = URL(string: "https://1132-fixer.xyz")!
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    @State private var updateAlertIsPresented = false
    @State private var latestRelease: ReleaseInfo?
    @State private var isReportingBug = false
    @State private var showBugReportForm = false
    @State private var bugReportEmail = ""
    @State private var bugReportMessage = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.16),
                    Color(red: 0.08, green: 0.19, blue: 0.30),
                    Color(red: 0.16, green: 0.27, blue: 0.38)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                HeaderCard(
                    repositoryURL: repositoryURL,
                    websiteURL: websiteURL,
                    onReportBug: { showBugReportForm = true },
                    isReportBugDisabled: isReportingBug,
                    appVersion: appVersion
                )

                HStack(spacing: 14) {
                    ActionCard(
                        title: "Start Zoom",
                        subtitle: "Spoofs MAC on active Wi-Fi/Ethernet and reconnects it, then resets Zoom data, refreshes DNS cache, and launches Zoom.",
                        systemImage: "video.circle.fill",
                        tint: Color(red: 0.13, green: 0.50, blue: 0.86),
                        isDisabled: vm.isRunning,
                        action: vm.startZoom
                    )
                }

                LogPanel(logs: vm.logs, onCopy: vm.copyLogs, onClear: vm.clearLogs)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 760, height: 520)
        .task {
            // Only check for updates in packaged apps that have a real version.
            guard appVersion != "dev" else { return }
            guard latestRelease == nil else { return }

            do {
                let release = try await UpdateChecker.fetchLatestRelease()
                if UpdateChecker.isUpdateAvailable(currentVersion: appVersion, latestVersion: release.version) {
                    latestRelease = release
                    updateAlertIsPresented = true
                }
            } catch {
                // Silent failure: update checks should never block app usage.
            }
        }
        .alert("Update Available", isPresented: $updateAlertIsPresented) {
            if let release = latestRelease {
                Button("Open Release") {
                    NSWorkspace.shared.open(release.htmlURL)
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            if let release = latestRelease {
                Text("Version \(release.version) is available. You have \(appVersion).")
            } else {
                Text("A newer version is available.")
            }
        }
        .sheet(isPresented: $showBugReportForm) {
            BugReportFormSheet(
                email: $bugReportEmail,
                message: $bugReportMessage,
                isSubmitting: isReportingBug,
                onCancel: { showBugReportForm = false },
                onSubmit: {
                    Task {
                        await reportBug(email: bugReportEmail, message: bugReportMessage)
                    }
                }
            )
        }
    }

    @MainActor
    private func reportBug(email: String, message: String) async {
        guard !isReportingBug else { return }
        isReportingBug = true
        defer { isReportingBug = false }

        vm.logMessage("=== Report a Bug ===")
        let draft = vm.makeBugReportDraft(appVersion: appVersion)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await BugReportService.sendBugReport(
                title: draft.title,
                email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                message: trimmedMessage,
                systemInfo: draft.systemInfo,
                recentLogs: draft.recentLogs
            )
            vm.logMessage("Bug report submitted successfully.")
            showBugReportForm = false
            bugReportEmail = ""
            bugReportMessage = ""
        } catch {
            vm.logMessage("Bug report failed: \(error.localizedDescription)")
        }
    }
}

private struct BugReportFormSheet: View {
    @Binding var email: String
    @Binding var message: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a bug")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Add an optional email and a message.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Email (optional)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                TextField("user@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Message")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                TextEditor(text: $message)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.08))
                    )
                    .disabled(isSubmitting)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Sending..." : "Send Report", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

private struct HeaderCard: View {
    let repositoryURL: URL
    let websiteURL: URL
    let onReportBug: () -> Void
    let isReportBugDisabled: Bool
    let appVersion: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 58, height: 58)
                Image(systemName: "video.badge.waveform.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("1132 Fixer")
                    .font(.system(size: 29, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("Bypass Error 1132 with one action. No more messing with config files or terminal commands.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                Text("Version \(appVersion)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }

                Spacer()
            }

            HStack(spacing: 10) {
                HeaderLinkButton(title: "GitHub", systemImage: "link.circle.fill", destination: repositoryURL)
                HeaderLinkButton(title: "Website", systemImage: "globe", destination: websiteURL)
                HeaderActionButton(
                    title: "Report a bug",
                    systemImage: "ladybug.fill",
                    isDisabled: isReportBugDisabled,
                    action: onReportBug
                )
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct HeaderLinkButton: View {
    let title: String
    let systemImage: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome())
    }
}

private struct HeaderActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.58 : 1.0)
        .modifier(HeaderButtonChrome())
    }
}

private struct HeaderButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct ActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(tint)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.26))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint.opacity(0.65), lineWidth: 1)
            )
            .opacity(isDisabled ? 0.58 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct LogPanel: View {
    let logs: [String]
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Activity Log", systemImage: "terminal")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Button("Copy") {
                    onCopy()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white.opacity(0.2))
                .disabled(logs.isEmpty)

                Button("Clear") {
                    onClear()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white.opacity(0.2))
                .disabled(logs.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if logs.isEmpty {
                        Text("No logs yet. Run an action to see output.")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.72))
                            .padding(.top, 2)
                    } else {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.92))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}
