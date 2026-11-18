import SwiftUI

struct QuickActionDiffView: View {
    let chunks: [TextDiffEngine.Chunk]

    var body: some View {
        Text(chunks.reduce(into: AttributedString()) { result, chunk in
            switch chunk {
            case .equal(let text): result.append(AttributedString(text))
            case .inserted(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.Colors.success
                result.append(run)
            case .deleted(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.Colors.destructive
                run.strikethroughStyle = .single
                result.append(run)
            }
        })
    }
}
