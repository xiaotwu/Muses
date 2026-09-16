import Testing
@testable import Muses

@MainActor
struct CommandRegistryTests {
    @Test func executionRechecksCurrentCapability() {
        let registry = CommandRegistry()
        var connected = false
        var executions = 0
        registry.register("play", handler: { executions += 1 }, enabled: { connected })
        registry.execute("play")
        #expect(executions == 0)
        connected = true
        #expect(registry.isEnabled("play"))
        registry.execute("play")
        #expect(executions == 1)
        connected = false
        registry.execute("play")
        #expect(executions == 1)
    }

    @Test func unknownCommandsAndReplacementAreSafe() {
        let registry = CommandRegistry()
        #expect(!registry.isEnabled("missing"))
        registry.execute("missing")
        var executions = 0
        registry.register("action", handler: { executions += 1 })
        registry.register("action", handler: { executions += 10 }, enabled: { false })
        registry.execute("action")
        #expect(executions == 0)
    }
}
