import SwiftUI
import Foundation
import AppKit

@MainActor
final class AppViewModel: ObservableObject {
    private enum Constants {
        static let errorDomain = "1132Fixer"
        static let shellPath = "/bin/zsh"
        static let osascriptPath = "/usr/bin/osascript"
    }

    private static let logTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    @Published var logs: [String] = []
    @Published var isRunning = false
    private let resetZoomDataCommand = #"/bin/bash -c 'killall "zoom.us" 2>/dev/null; rm -rf "$HOME/Library/Application Support/zoom.us" "$HOME/Library/Caches/us.zoom.xos" "$HOME/Library/Preferences/us.zoom.xos.plist" "$HOME/Library/Logs/zoom.us.log"* "$HOME/Library/Saved Application State/us.zoom.xos.savedState"; defaults delete us.zoom.xos 2>/dev/null || true'"#
    private let refreshDNSAppleScript = #"do shell script "dscacheutil -flushcache; killall -HUP mDNSResponder" with administrator privileges"#
    private let launchZoomCommand = #"/bin/bash -c 'open -a "zoom.us"'"#

    func startZoom() {
        runTask("Start Zoom") {
            let resetOutput = try self.runProcess(
                stepName: "Reset Zoom data",
                executable: Constants.shellPath,
                arguments: ["-lc", self.resetZoomDataCommand]
            )
            let dnsOutput = try self.runProcess(
                stepName: "Refresh DNS cache",
                executable: Constants.osascriptPath,
                arguments: ["-e", self.refreshDNSAppleScript]
            )
            let launchOutput = try self.runProcess(
                stepName: "Launch Zoom",
                executable: Constants.shellPath,
                arguments: ["-lc", self.launchZoomCommand]
            )

            return [resetOutput, dnsOutput, launchOutput]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
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
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        logs.append("[\(timestamp)] \(text)")
    }

    private func runProcess(stepName: String, executable: String, arguments: [String]) throws -> String {
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

        let trimmedOutput = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if !trimmedOutput.isEmpty {
            message = "\(stepName): \(trimmedOutput)"
        } else if executable == Constants.osascriptPath {
            message = "\(stepName): Admin authorization was canceled or failed."
        } else {
            message = "\(stepName): Command failed with exit code \(process.terminationStatus)."
        }

        throw NSError(
            domain: Constants.errorDomain,
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    private let repositoryURL = URL(string: "https://github.com/PrimeUpYourLife/1132-fixer")!
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    @State private var updateAlertIsPresented = false
    @State private var latestRelease: ReleaseInfo?

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
                HeaderCard(isRunning: vm.isRunning, repositoryURL: repositoryURL, appVersion: appVersion)

                HStack(spacing: 14) {
                    ActionCard(
                        title: "Start Zoom",
                        subtitle: "Resets Zoom local data and caches, refreshes DNS cache, then launches Zoom.",
                        systemImage: "video.circle.fill",
                        tint: Color(red: 0.13, green: 0.50, blue: 0.86),
                        isDisabled: vm.isRunning,
                        action: vm.startZoom
                    )
                }

                LogPanel(logs: vm.logs, onClear: vm.clearLogs)
            }
            .padding(20)
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
    }
}

private struct HeaderCard: View {
    let isRunning: Bool
    let repositoryURL: URL
    let appVersion: String

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

                Text("Bypass Error 1132 with one action. No more messing with config files or terminal commands.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                Text("Version \(appVersion)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
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
