import Foundation
import Darwin
import MusesWebHomeCore
import MusesWebHomeProtocol

@main
struct MusesWebHomeHelper {
    private static let maximumRequestBytes = 64 * 1024

    static func main() async {
        // A dedicated process group lets the main app terminate the helper and
        // any short-lived yt-dlp child together on timeout or cancellation.
        _ = setpgid(0, 0)
        let response: WebHomeResponse
        do {
            let input = try readStandardInput(limit: maximumRequestBytes)
            let request = try JSONDecoder().decode(WebHomeRequest.self, from: input)
            response = await WebHomeCommand(ytdlpURL: bundledYTDlpURL()).execute(request)
        } catch {
            response = WebHomeResponse(
                helperVersion: WebHomeCommand.helperVersion,
                parserSchemaVersion: WebHomeCommand.parserSchemaVersion,
                capability: .rejected,
                error: WebHomeError(code: .malformedResponse))
        }

        guard let output = try? JSONEncoder().encode(response) else {
            exit(EXIT_FAILURE)
        }
        FileHandle.standardOutput.write(output)
    }

    private static func readStandardInput(limit: Int) throws -> Data {
        var result = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 16 * 1024),
              !chunk.isEmpty {
            guard result.count + chunk.count <= limit else {
                throw HelperInputError.tooLarge
            }
            result.append(chunk)
        }
        return result
    }

    private static func bundledYTDlpURL() -> URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent() // Helpers
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Resources/yt-dlp")
    }

    private enum HelperInputError: Error {
        case tooLarge
    }
}
