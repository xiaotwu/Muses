import Testing
import Foundation
@testable import Muses

/// Sparkle 集成冒烟:验证 appcast.xml 模板可被 XMLParser 解析。
/// Sparkle 框架链接本身由 `swift build` 成功(主 target 依赖 Sparkle)保证。
@Suite("SparkleUpdates")
struct SparkleUpdatesTests {

    /// appcast.xml 是随包资源(Bundle.main);测试 target 经 @testable 链接 Muses,
    /// 资源仍定位到主 bundle。
    @Test("appcast.xml 模板可被 XMLParser 解析")
    func appcastParses() throws {
        // 经 Muses 内部 `MusesResources.appcastURL` 定位 SPM `.copy("Resources")` 拷入的 appcast。
        let url = MusesResources.appcastURL
        let resolved = try #require(url, "appcast.xml 资源未找到")
        let data = try Data(contentsOf: resolved)

        let parser = XMLParser(data: data)
        let parsed = parser.parse()
        #expect(parsed, "appcast.xml 解析失败: \(parser.parserError?.localizedDescription ?? "unknown")")
    }
}