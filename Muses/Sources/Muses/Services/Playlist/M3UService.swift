import Foundation

/// M3U/M3U8 播放列表文件解析与导出(纯工具,无状态)。
///
/// 格式参考:
/// - `#EXTM3U` 头行(可选)
/// - `#EXTINF:<duration>,<title>` 信息行(可选,紧跟文件路径行)
/// - 文件路径行(绝对或相对)
/// - `#` 开头的行为注释,跳过
enum M3UService {

    /// 解析 M3U/M3U8 文件,返回文件路径列表(按出现顺序)。
    /// 跳过 `#EXTM3U`、`#EXTINF`、`#` 注释行及空行。
    static func parse(url: URL) throws -> [String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(content: content)
    }

    /// 解析 M3U 文本,返回文件路径列表。
    static func parse(content: String) -> [String] {
        var paths: [String] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") { continue }  // 跳过 #EXTM3U / #EXTINF / 注释
            paths.append(line)
        }
        return paths
    }

    /// 导出 M3U 文本。
    /// - Parameters:
    ///   - entries: `(filePath, title, durationSeconds)` 元组列表,按顺序写入。
    ///   - relativeTo: 若非 nil,filePath 转为相对此目录的相对路径。
    /// - Returns: M3U 文本(`#EXTM3U` + `#EXTINF` + 路径行)。
    static func export(entries: [(filePath: String, title: String, durationSeconds: Double)],
                       relativeTo: URL? = nil) -> String {
        var lines: [String] = ["#EXTM3U"]
        for entry in entries {
            let dur = max(0, Int(entry.durationSeconds.rounded()))
            let path: String
            if let base = relativeTo {
                path = relativePath(entry.filePath, relativeTo: base)
            } else {
                path = entry.filePath
            }
            lines.append("#EXTINF:\(dur),\(entry.title)")
            lines.append(path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 将绝对 filePath 字符串转为相对于 base 目录的相对路径。
    private static func relativePath(_ filePath: String, relativeTo base: URL) -> String {
        let file = URL(fileURLWithPath: filePath)
        // 若 filePath 本身就是相对路径,直接返回
        if !filePath.hasPrefix("/") { return filePath }
        // 同目录或子目录 → 相对路径
        let baseDir = base.path
        if file.path.hasPrefix(baseDir + "/") {
            return String(file.path.dropFirst(baseDir.count + 1))
        }
        return filePath  // 不在同目录下,保留绝对路径
    }
}