import Foundation

enum BugReportService {
    private static let errorDomain = "1132Fixer.BugReportService"
    private static let userAgent = "1132Fixer-BugReportClient"
    private static let endpointEnvVar = "FIXER_BUG_REPORT_ENDPOINT"
    private static let tokenEnvVar = "FIXER_BUG_REPORT_TOKEN"
    private static let defaultEndpoint = "https://1132-bug-report-production.up.railway.app/api/bug-report"

    private struct BugReportRequest: Encodable {
        let title: String
        let email: String?
        let message: String
        let systemInfo: String
        let recentLogs: String

        enum CodingKeys: String, CodingKey {
            case title = "Title"
            case email = "Email"
            case message = "Message"
            case systemInfo = "System Info"
            case recentLogs = "Recent Logs"
        }
    }

    private static func resolveConfigValue(envVar: String, fallback: String = "") -> String {
        let envValue = ProcessInfo.processInfo.environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envValue.isEmpty {
            return envValue
        }

        guard let resourceURL = Bundle.module.url(forResource: envVar, withExtension: nil),
              let data = try? Data(contentsOf: resourceURL),
              let bundledValue = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !bundledValue.isEmpty else {
            return fallback
        }

        return bundledValue
    }

    static func sendBugReport(
        title: String,
        email: String?,
        message: String,
        systemInfo: String,
        recentLogs: String
    ) async throws {
        let endpoint = resolveConfigValue(envVar: endpointEnvVar, fallback: defaultEndpoint)
        let token = resolveConfigValue(envVar: tokenEnvVar)

        guard !token.isEmpty else {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bug report token in env/resource \(tokenEnvVar)."]
            )
        }

        guard let url = URL(string: endpoint) else {
            throw NSError(
                domain: errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid bug report endpoint URL."]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(
            BugReportRequest(
                title: title,
                email: email,
                message: message.isEmpty ? "No user message provided." : message,
                systemInfo: systemInfo,
                recentLogs: recentLogs
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: errorDomain,
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Bug report API returned an invalid response."]
            )
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (detail?.isEmpty == false) ? detail! : "HTTP \(http.statusCode)"
            let endpointHint = "Check \(endpointEnvVar) value."
            let contextMessage: String
            if http.statusCode == 404, message.contains("Application not found") {
                contextMessage = "Bug report endpoint is unreachable on Railway. \(endpointHint) Response: \(message)"
            } else {
                contextMessage = "Bug report submission failed (\(endpoint)). \(endpointHint) Response: \(message)"
            }
            throw NSError(
                domain: errorDomain,
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: contextMessage]
            )
        }
    }
}
