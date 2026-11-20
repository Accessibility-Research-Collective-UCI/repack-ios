import Foundation
import Testing
@testable import repack

@MainActor
@Suite("Output rendering emphasis")
struct OutputRenderingFormattingTests {
    @Test("Percentages, group prefixes, and bracketed hedges receive visual emphasis")
    func emphasis() {
        let cases: [(OutputRenderingsController.Rendering, String, [String])] = [
            (.atomic, "99%: A bottle.\n87%: A label says 50% off.", ["99%:", "87%:"]),
            (.stratified, "We think it is highly likely that a bottle is visible.\n\nWe think it is somewhat likely that it is green.\n\nWe are unsure whether it is glass.", ["We think it is highly likely (90% certain or more) that", "We think it is somewhat likely (80% to 90% certain) that", "We are unsure (less than 80% certain) whether"]),
            (.hedged, "Étiquette: it [may] be red and [APPEARS TO] have a label. Mayfair [text] remains plain.", ["[may]", "[APPEARS TO]"]),
            (.repack, "99%: A bottle [may] be red.", []),
            (.stratified, "We did not identify any highly likely information.", [])
        ]
        #expect(OutputRenderingsController.Rendering.hedged.title == "Hedging Language when less than 90% certain")
        for (rendering, text, expected) in cases {
            let attributed = OutputRenderings.emphasizedText(text, rendering: rendering)
            var expectedText = text
            if rendering == .stratified {
                for (prefix, displayPrefix) in zip(OutputRenderingsController.prefixes, expected) {
                    expectedText = expectedText.replacingOccurrences(of: prefix, with: displayPrefix)
                }
            }
            #expect(String(attributed.characters) == expectedText)
            let emphasized = attributed.runs.compactMap { run -> String? in
                guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else { return nil }
                return String(attributed[run.range].characters)
            }
            #expect(emphasized == expected)
        }
    }
}
