import Foundation

struct IssueCreationResult: Equatable {
    let issueURL: URL
    let number: Int
}

enum BugReportService {
    static let owner = "PrimeUpYourLife"
    static let repo = "1132-fixer"
    static let tokenEnvVar = "FIXER_GITHUB_TOKEN"
    private static let errorDomain = "1132Fixer.BugReportService"
    private static let userAgent = "1132Fixer"

    private struct CreateIssueRequest: Encodable {
        let title: String
        let body: String
    }

    private struct CreateIssueResponse: Decodable {
        let number: Int
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case number
            case htmlURL = "html_url"
        }
    }

    private struct GitHubErrorResponse: Decodable {
        let message: String
    }

    static func createIssue(title: String, body: String) async throws -> IssueCreationResult {
        let token = ProcessInfo.processInfo.environment[tokenEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing GitHub token in \(tokenEnvVar)."]
            )
        }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(CreateIssueRequest(title: title, body: body))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "GitHub API returned an invalid response."]
            )
        }

        guard (200...299).contains(http.statusCode) else {
            let apiMessage = (try? JSONDecoder().decode(GitHubErrorResponse.self, from: data))?.message
            let detail = apiMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (detail?.isEmpty == false) ? detail! : "HTTP \(http.statusCode)"
            throw NSError(
                domain: errorDomain,
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub issue creation failed: \(message)"]
            )
        }

        let decoded = try JSONDecoder().decode(CreateIssueResponse.self, from: data)
        guard let issueURL = URL(string: decoded.htmlURL),
              issueURL.scheme == "https",
              issueURL.host?.contains("github.com") == true else {
            throw NSError(
                domain: errorDomain,
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "GitHub API returned an invalid issue URL."]
            )
        }

        return IssueCreationResult(issueURL: issueURL, number: decoded.number)
    }
}
