// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A release of Clipz as reported by the GitHub Releases API.
public struct ReleaseInfo: Sendable, Equatable {
    /// Marketing version without the leading `v` (e.g. "1.0.2").
    public let version: String
    /// The release's GitHub page.
    public let releaseURL: URL
    /// Direct link to the `.dmg` asset, when present.
    public let downloadURL: URL?
    /// Release notes (GitHub `body`), if any.
    public let notes: String?

    public init(version: String, releaseURL: URL, downloadURL: URL?, notes: String?) {
        self.version = version
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.notes = notes
    }
}

/// The current state of the update check, surfaced to the UI.
public enum UpdateState: Sendable, Equatable {
    case unknown
    case checking
    case upToDate
    case available(ReleaseInfo)
    case failed(String)
}

/// Lightweight update checker: asks the public GitHub Releases API for the
/// latest published release and compares it to the running version. No
/// account, no telemetry — a single GET to api.github.com. Deliberately *not*
/// Sparkle: the app is sandboxed and shipped as a single-binary notarized
/// DMG, so we notify + hand off to the download rather than self-install.
public struct UpdateChecker: Sendable {
    private let latestReleaseURL: URL
    private let session: URLSession

    public init(
        owner: String = "muthu-pro",
        repo: String = "clipz",
        session: URLSession = .shared
    ) {
        self.latestReleaseURL = URL(
            string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        )!
        self.session = session
    }

    /// Fetch the latest release. `/latest` already excludes drafts and
    /// pre-releases. Throws on transport/decoding errors.
    public func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 10
        // GitHub requires a User-Agent; the Accept header pins the API version.
        request.setValue("Clipz", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }
        return try Self.parse(data)
    }

    /// Decode a GitHub "release" JSON payload into `ReleaseInfo`. Split out
    /// from the network call so it can be unit-tested without a server.
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let releaseURL = URL(string: release.html_url) else {
            throw UpdateError.malformed
        }
        let version = normalize(release.tag_name)
        let dmg = release.assets
            .first { $0.browser_download_url.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browser_download_url) }
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReleaseInfo(
            version: version,
            releaseURL: releaseURL,
            downloadURL: dmg,
            notes: (notes?.isEmpty == false) ? notes : nil
        )
    }

    /// Strip a leading `v`/`V` and surrounding whitespace from a tag.
    public static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if let first = s.first, first == "v" || first == "V" {
            s.removeFirst()
        }
        return s
    }

    /// True when `latest` is a strictly higher semantic version than
    /// `current`. Compares dot-separated numeric components left-to-right;
    /// missing components count as 0 (so "1.0" == "1.0.0"). Non-numeric
    /// components are treated as 0.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = components(normalize(latest))
        let b = components(normalize(current))
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    public enum UpdateError: Error, Sendable {
        case badResponse
        case malformed
    }

    // Minimal shape of the GitHub release payload we care about.
    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable { let browser_download_url: String }
    }
}
