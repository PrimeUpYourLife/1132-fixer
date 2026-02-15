import SwiftUI
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var logs: [String] = []
    @Published var isRunning = false
    @Published var hasSpoofedMacAddress = false

    private let spoofScript = """
    #!/bin/zsh
    set -euo pipefail

    # Find the hardware port named "Wi-Fi" (or "AirPort" on older macOS) and grab its device (en0/en1/...)
    INTERFACE="$(
      networksetup -listallhardwareports \
      | awk '\''
          $0 ~ /Hardware Port: (Wi-Fi|AirPort)/ {found=1; next}
          found && $0 ~ /Device:/ && dev == "" {dev=$2; found=0}
          END {if (dev != "") print dev}
        '\''
    )"

    if [[ -z "${INTERFACE:-}" ]]; then
      echo "Couldn't find a Wi-Fi interface (Wi-Fi/AirPort)."
      echo "Open System Settings and make sure Wi-Fi exists, then try again."
      exit 1
    fi

    echo "Using Wi-Fi interface: $INTERFACE"

    CURRENT_MAC=$(ifconfig "$INTERFACE" | awk "/ether/ {print \\$2; exit}")
    if [[ -z "${CURRENT_MAC:-}" ]]; then
      echo "Couldn't read current MAC address for $INTERFACE."
      exit 1
    fi
    echo "Current MAC: $CURRENT_MAC"

    AIRPORT_CMD="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    if [[ ! -x "$AIRPORT_CMD" ]]; then
      AIRPORT_CMD="/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport"
    fi

    disconnect_wifi() {
      networksetup -setairportpower "$INTERFACE" on
      sleep 1
      if [[ -x "$AIRPORT_CMD" ]]; then
        "$AIRPORT_CMD" -z || true
      else
        networksetup -setairportpower "$INTERFACE" off
        sleep 2
        networksetup -setairportpower "$INTERFACE" on
      fi
      sleep 2
    }

    generate_current_prefix_candidate() {
      local o1 o2 o3
      IFS=":" read -r o1 o2 o3 _ <<< "$CURRENT_MAC"
      local first=$(( (16#$o1 | 2) & 254 ))
      printf "%02x:%s:%s:%02x:%02x:%02x" \
        "$first" "$o2" "$o3" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
    }

    generate_local_candidate() {
      local prefixes=(02 06 0a 0e)
      local idx=$((RANDOM % ${#prefixes[@]}))
      local pfx="${prefixes[$((idx + 1))]}"
      printf "%s:%02x:%02x:%02x:%02x:%02x" \
        "$pfx" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
    }

    apply_mac() {
      local mac="$1"
      if ifconfig "$INTERFACE" lladdr "$mac" >/dev/null 2>&1; then
        return 0
      fi
      if ifconfig "$INTERFACE" ether "$mac" >/dev/null 2>&1; then
        return 0
      fi
      return 1
    }

    echo "Step 1: Disconnecting from Wi-Fi while keeping interface available..."
    disconnect_wifi

    # Some drivers only accept specific patterns. Try a current-prefix variant first,
    # then additional locally administered random candidates.
    CANDIDATES=()
    CANDIDATES+=("$(generate_current_prefix_candidate)")
    CANDIDATES+=("$(generate_local_candidate)")
    CANDIDATES+=("$(generate_local_candidate)")
    CANDIDATES+=("$(generate_local_candidate)")
    CANDIDATES+=("$(generate_local_candidate)")

    APPLIED_MAC=""
    for candidate in "${CANDIDATES[@]}"; do
      echo "Step 2: Trying MAC candidate: $candidate"
      if apply_mac "$candidate"; then
        APPLIED_MAC="$candidate"
        break
      fi
      disconnect_wifi
    done

    if [[ -z "$APPLIED_MAC" ]]; then
      echo "ERROR: macOS rejected all generated MAC candidates for $INTERFACE."
      echo "This can happen on newer hardware/OS builds that block Wi-Fi MAC changes."
      exit 1
    fi

    echo "SUCCESS: Applied MAC candidate: $APPLIED_MAC"

    echo "Step 3: Refreshing network hardware..."
    networksetup -detectnewhardware

    FINAL_MAC=$(ifconfig "$INTERFACE" | awk "/ether/ {print \\$2; exit}")
    echo "Final Check: Current MAC on $INTERFACE is: $FINAL_MAC"
    echo "You can now open Zoom."
    """

    // Redirect stdio to fully detach Zoom from this process so shell pipes can close immediately.
    private let zoomCommand = """
    nohup sandbox-exec -p '(version 1)
    (allow default)
    (deny file-read*
        (regex
            #"^/Users/[^.]+/Library/Application Support/zoom.us/data/.*\\.db$"
            #"^/Users/[^.]+/Library/Application Support/zoom.us/data/.*\\.db-journal$"
        )
    )' /Applications/zoom.us.app/Contents/MacOS/zoom.us </dev/null >/dev/null 2>&1 &
    """

    func spoofMacAddress() {
        runTask("Spoof MAC address", onSuccess: { self.hasSpoofedMacAddress = true }) {
            let scriptURL = try self.writeTempScript(contents: self.spoofScript)
            defer { try? FileManager.default.removeItem(at: scriptURL) }

            let command = "/bin/zsh \(self.shellQuote(scriptURL.path))"
            let appleScript = "do shell script \(self.appleScriptString(command)) with administrator privileges"
            return try self.runProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-e", appleScript]
            )
        }
    }

    func startZoom() {
        runTask("Start Zoom") {
            try self.runProcess(
                executable: "/bin/zsh",
                arguments: ["-lc", self.zoomCommand]
            )
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func runTask(
        _ title: String,
        onSuccess: (() -> Void)? = nil,
        action: @escaping () throws -> String
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
                let output = try action()
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendLog("Done.")
                } else {
                    appendLog(output)
                }
                onSuccess?()
            } catch {
                appendLog("Error: \(error.localizedDescription)")
            }
        }
    }

    private func appendLog(_ text: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(timestamp)] \(text)")
    }

    private func writeTempScript(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoof-mac-\(UUID().uuidString).zsh")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let combined = [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if process.terminationStatus == 0 {
            return combined
        }

        throw NSError(
            domain: "1132Fixer",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: combined.isEmpty ? "Command failed with exit code \(process.terminationStatus)." : combined]
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    private let repositoryURL = URL(string: "https://github.com/PrimeUpYourLife/1132-fixer")!

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

            VStack(spacing: 18) {
                HeaderCard(isRunning: vm.isRunning, repositoryURL: repositoryURL)

                HStack(spacing: 14) {
                    ActionCard(
                        title: "1. Spoof MAC Address",
                        subtitle: "Generates a locally administered Wi-Fi MAC and reapplies it using admin privileges.",
                        systemImage: "network.badge.shield.half.filled",
                        tint: Color(red: 0.12, green: 0.60, blue: 0.52),
                        isDisabled: vm.isRunning,
                        action: vm.spoofMacAddress
                    )

                    ActionCard(
                        title: "2. Start Zoom",
                        subtitle: "Launches Zoom with a focused sandbox policy that blocks selected local DB reads.",
                        systemImage: "video.circle.fill",
                        tint: Color(red: 0.13, green: 0.50, blue: 0.86),
                        isDisabled: vm.isRunning || !vm.hasSpoofedMacAddress,
                        action: vm.startZoom
                    )
                }

                LogPanel(logs: vm.logs, onClear: vm.clearLogs)
            }
            .padding(20)
        }
        .frame(width: 760, height: 520)
    }
}

private struct HeaderCard: View {
    let isRunning: Bool
    let repositoryURL: URL

    var body: some View {
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

                Text("Bypass Error 1132 in 2 steps. No more messing with config files or terminal commands.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
            }

            Spacer()

            Link(destination: repositoryURL) {
                Label("GitHub", systemImage: "link.circle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.black.opacity(0.24), in: Capsule())
            }
            .buttonStyle(.plain)

            StatusBadge(isRunning: isRunning)
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

private struct StatusBadge: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRunning ? Color.orange : Color.green)
                .frame(width: 10, height: 10)
            Text(isRunning ? "Task Running" : "Ready")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.24), in: Capsule())
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
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(tint)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text(title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
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
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Activity Log", systemImage: "terminal")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

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
