import SwiftUI
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var logs: [String] = []
    @Published var isRunning = false

    private let spoofScript = """
    #!/bin/zsh
    set -euo pipefail

    # Find the hardware port named "Wi-Fi" (or "AirPort" on older macOS) and grab its device (en0/en1/...)
    WIFI_DEV="$(
      networksetup -listallhardwareports \
      | awk '\''
          $0 ~ /Hardware Port: (Wi-Fi|AirPort)/ {found=1}
          found && $0 ~ /Device:/ {print $2; exit}
        '\''
    )"

    if [[ -z "${WIFI_DEV:-}" ]]; then
      echo "Couldn't find a Wi-Fi interface (Wi-Fi/AirPort)."
      echo "Open System Settings and make sure Wi-Fi exists, then try again."
      exit 1
    fi

    echo "Wi-Fi interface detected: $WIFI_DEV"

    # Generate a valid locally administered MAC:
    # - First octet 02 => locally administered + unicast
    NEW_MAC=$(printf "02:%02X:%02X:%02X:%02X:%02X" \
      $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
    )

    echo "Setting new MAC: $NEW_MAC"

    # Toggle Wi-Fi power off/on on the detected device
    networksetup -setairportpower "$WIFI_DEV" off

    # Apply MAC (requires sudo)
    sudo ifconfig "$WIFI_DEV" ether "$NEW_MAC"

    networksetup -setairportpower "$WIFI_DEV" on

    echo "Done. New MAC address on $WIFI_DEV is: $NEW_MAC"
    echo "You can now open Zoom."
    """

    private let zoomCommand = """
    nohup sandbox-exec -p '(version 1)
    (allow default)
    (deny file-read*
        (regex
            #"^/Users/[^.]+/Library/Application Support/zoom.us/data/.*\\.db$"
            #"^/Users/[^.]+/Library/Application Support/zoom.us/data/.*\\.db-journal$"
        )
    )' /Applications/zoom.us.app/Contents/MacOS/zoom.us &
    """

    func spoofMacAddress() {
        runTask("Spoof MAC address") {
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

    private func runTask(_ title: String, action: @escaping () throws -> String) {
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
            domain: "SpoofZoomApp",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zoom Network Helper")
                .font(.title2)
                .bold()

            HStack(spacing: 12) {
                Button("Spoof MAC Address") {
                    vm.spoofMacAddress()
                }
                .disabled(vm.isRunning)

                Button("Start Zoom") {
                    vm.startZoom()
                }
                .disabled(vm.isRunning)
            }

            ScrollView {
                Text(vm.logs.joined(separator: "\n\n"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 260)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 380)
    }
}

