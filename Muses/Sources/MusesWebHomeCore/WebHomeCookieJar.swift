import Foundation
import Darwin
import MusesWebHomeProtocol

enum WebHomeCoreError: Error, Equatable {
    case code(WebHomeErrorCode)

    var code: WebHomeErrorCode {
        if case .code(let value) = self { return value }
        return .malformedResponse
    }
}

protocol YTDlpCookieExporting: Sendable {
    func export(browserSpecification: String, to destination: URL) async throws
}

struct ProcessYTDlpCookieExporter: YTDlpCookieExporting, @unchecked Sendable {
    let executableURL: URL

    func export(browserSpecification: String, to destination: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WebHomeCoreError.code(.cookieSourceUnavailable)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--ignore-config",
            "--quiet",
            "--no-warnings",
            "--cookies-from-browser", browserSpecification,
            "--cookies", destination.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let box = CookieExportProcessBox(process)
        do {
            try process.run()
        } catch {
            throw WebHomeCoreError.code(.cookieSourceUnavailable)
        }

        do {
            try await withTaskCancellationHandler {
                while process.isRunning {
                    try await Task.sleep(for: .milliseconds(25))
                }
            } onCancel: {
                box.terminate()
            }
        } catch is CancellationError {
            box.terminate()
            throw WebHomeCoreError.code(.cancelled)
        }
        // yt-dlp's documented export-only invocation may still exit with its
        // no-URL usage status after writing the requested jar. Accept only a
        // destination that grew beyond the seeded Netscape header; the manager
        // immediately applies its size, domain, format, and auth-cookie checks.
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: destination.path)
        let exportedSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard process.terminationStatus == EXIT_SUCCESS
                || exportedSize > WebHomeCookieJarManager.netscapeCookieHeader.utf8.count else {
            throw WebHomeCoreError.code(.cookieSourceUnavailable)
        }
    }
}

private final class CookieExportProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

struct WebHomeCookie: Sendable, Equatable {
    let domain: String
    let path: String
    let secure: Bool
    let expiresAt: Date?
    let name: String
    let value: String

    func applies(to host: String, now: Date) -> Bool {
        let normalizedDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let domainMatches = host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)")
        return domainMatches && (expiresAt == nil || expiresAt! > now)
    }
}

struct WebHomeCookieJar: Sendable {
    let cookies: [WebHomeCookie]

    func header(for host: String, now: Date = .init()) -> String {
        cookies
            .filter { $0.applies(to: host, now: now) }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    var sapisid: String? {
        for name in ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"] {
            if let value = cookies.first(where: { $0.name == name })?.value,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

final class WebHomeCookieJarManager: @unchecked Sendable {
    static let maximumCookieFileBytes = 10 * 1024 * 1024
    static let orphanLifetime: TimeInterval = 60 * 60
    static let netscapeCookieHeader = "# Netscape HTTP Cookie File\n"

    let rootDirectory: URL
    private let exporter: any YTDlpCookieExporting
    private let fileManager: FileManager

    init(
        rootDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.muses.web-home-helper", isDirectory: true),
        exporter: any YTDlpCookieExporting,
        fileManager: FileManager = .default
    ) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.exporter = exporter
        self.fileManager = fileManager
        try createPrivateDirectory(rootDirectory)
        try cleanupOrphans()
    }

    func withCookieJar<T: Sendable>(
        source: WebHomeCookieSourceDescriptor,
        operation: (WebHomeCookieJar) async throws -> T
    ) async throws -> T {
        switch source.kind {
        case .browser:
            let workspace = rootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try createPrivateDirectory(workspace)
            defer { try? fileManager.removeItem(at: workspace) }
            let jarURL = workspace.appendingPathComponent("cookies.txt")
            guard fileManager.createFile(
                atPath: jarURL.path,
                // yt-dlp treats --cookies as both input and output. Seed a
                // valid Netscape jar so it can import browser cookies into the
                // already permission-restricted destination.
                contents: Data(Self.netscapeCookieHeader.utf8),
                attributes: [.posixPermissions: 0o600]) else {
                throw WebHomeCoreError.code(.cookieSourceUnavailable)
            }
            _ = chmod(jarURL.path, S_IRUSR | S_IWUSR)
            let browser = try browserSpecification(from: source)
            try await exporter.export(browserSpecification: browser, to: jarURL)
            _ = chmod(jarURL.path, S_IRUSR | S_IWUSR)
            let jar = try parseCookieFile(at: jarURL)
            return try await operation(jar)

        case .file:
            guard let path = source.filePath,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WebHomeCoreError.code(.cookieSourceUnavailable)
            }
            let jar = try parseCookieFile(at: URL(fileURLWithPath: path))
            return try await operation(jar)
        }
    }

    func cleanupOrphans(now: Date = .init()) throws {
        guard rootDirectory.path != "/", rootDirectory.path.count > 8 else { return }
        let children = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        for child in children {
            let values = try? child.resourceValues(forKeys: [
                .contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true,
                  let modified = values?.contentModificationDate,
                  now.timeIntervalSince(modified) > Self.orphanLifetime else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw WebHomeCoreError.code(.cookieSourceUnavailable)
        }
    }

    private func browserSpecification(
        from source: WebHomeCookieSourceDescriptor
    ) throws -> String {
        let allowed = Set(["safari", "chrome", "firefox", "brave", "edge"])
        let browser = source.browserName?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard allowed.contains(browser) else {
            throw WebHomeCoreError.code(.cookieSourceUnavailable)
        }
        guard let profile = source.browserProfile,
              !profile.isEmpty else { return browser }
        guard profile.utf8.count <= 512,
              profile.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw WebHomeCoreError.code(.cookieSourceUnavailable)
        }
        return "\(browser):\(profile)"
    }

    private func parseCookieFile(at url: URL) throws -> WebHomeCookieJar {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= Self.maximumCookieFileBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let text = String(data: data, encoding: .utf8) else {
            throw WebHomeCoreError.code(.cookieSourceUnavailable)
        }

        let cookies = text.split(whereSeparator: \.isNewline).compactMap { rawLine -> WebHomeCookie? in
            var line = String(rawLine)
            if line.hasPrefix("#HttpOnly_") {
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") {
                return nil
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 7 else { return nil }
            let domain = String(fields[0]).lowercased()
            guard domain == "youtube.com" || domain.hasSuffix(".youtube.com") else {
                return nil
            }
            let expirySeconds = TimeInterval(fields[4]) ?? 0
            return WebHomeCookie(
                domain: domain,
                path: String(fields[2]),
                secure: String(fields[3]).uppercased() == "TRUE",
                expiresAt: expirySeconds > 0
                    ? Date(timeIntervalSince1970: expirySeconds) : nil,
                name: String(fields[5]),
                value: String(fields[6]))
        }
        guard !cookies.isEmpty else {
            throw WebHomeCoreError.code(.cookieSourceUnavailable)
        }
        return WebHomeCookieJar(cookies: cookies)
    }
}
