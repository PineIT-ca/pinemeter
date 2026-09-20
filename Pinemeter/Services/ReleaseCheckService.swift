import Foundation

actor ReleaseCheckService: ReleaseCheckServiceProtocol {
    private struct GitHubRelease: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    private let session: URLSession
    private let releaseURL: URL

    init(
        session: URLSession = .shared,
        releaseURL: URL = URL(string: "https://api.github.com/repos/PineIT-ca/pinemeter/releases/latest")!
    ) {
        self.session = session
        self.releaseURL = releaseURL
    }

    func latestRelease() async throws -> AvailableUpdate {
        var request = URLRequest(url: releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pinemeter", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName
        guard !version.isEmpty else { throw URLError(.cannotParseResponse) }
        return AvailableUpdate(version: version)
    }
}
