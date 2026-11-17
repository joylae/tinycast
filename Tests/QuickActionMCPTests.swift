import AppKit

@main
@MainActor
struct QuickActionMCPTests {
    static func main() async throws {
        let state = RecordingState()
        let tool = AITool(
            name: "stub__read", description: "Read", parameters: .object([:]), origin: "Stub")
        let provider = AIToolLoopProvider(
            base: Model(state: state), tools: [tool], maxRounds: 3
        ) { call in
            await state.invoke(call)
        }
        let result = try await QuickActionRunner.run(
            .custom(CustomQuickAction(name: "Test", instructions: "Use the read tool.")),
            selection: "selected text", using: provider, instructionOverride: nil)
        precondition(result == "tool-assisted result", "a quick action finishes after the tool reply")
        precondition(state.requests.count == 2, "the tool result triggers a second model request")
        precondition(state.requests[0].tools == [tool], "the model receives the MCP tool list")
        precondition(state.calls.map(\.name) == ["stub__read"], "the requested tool is invoked")
        precondition(
            state.requests[1].messages.last?.toolResult?.content == "tool reply",
            "the tool reply is fed back to the model")
        precondition(
            state.requests.allSatisfy { $0.instructions == "Use the read tool." },
            "tool injection leaves the action's editable system prompt intact")
        precondition(
            state.requests[0].messages == [AIMessage(role: .user, text: "Text:\nselected text")],
            "the selected text remains a separate user message")
        print("Quick action MCP tests passed")
    }

    @MainActor
    final class RecordingState {
        var requests: [AIRequest] = []
        var calls: [AIToolCall] = []

        func invoke(_ call: AIToolCall) -> AIToolResult {
            calls.append(call)
            return AIToolResult(callID: call.id, content: "tool reply", isError: false)
        }
    }

    struct Model: AIProvider {
        let state: RecordingState

        func stream(_ request: AIRequest) -> AIProviderStream {
            AIProviderStream { continuation in
                let task = Task { @MainActor in
                    state.requests.append(request)
                    if request.messages.last?.role == .tool {
                        continuation.yield(.text("tool-assisted result"))
                    } else {
                        continuation.yield(.text("I will inspect the selected text first. "))
                        continuation.yield(
                            .toolCallRequested(AIToolCall(id: "read-1", name: "stub__read", arguments: "{}")))
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

@MainActor
enum Permissions {
    static func ensureAccessibility() -> Bool { false }
}

@MainActor
enum AccessibilityText {
    enum Result: Equatable {
        case text(String)
        case empty
    }
    static func read(in app: NSRunningApplication) -> Result { .empty }
}

@MainActor
struct TextInjector {
    func copySelection(from app: NSRunningApplication) async -> String? { nil }
}

struct AppleIntelligenceProvider: AIProvider {
    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { $0.finish() }
    }
}
