import AppKit
import Testing
@testable import MeterUI

@Suite struct BrandTests {
    @Test func glyphIsAnEighteenPointTemplateInBothStates() {
        for attention in [false, true] {
            let image = Brand.glyph(attention: attention)
            #expect(image.size == NSSize(width: 18, height: 18))
            #expect(image.isTemplate)
            #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        }
    }

    @Test func attentionGlyphDiffersFromTheNormalOne() {
        let a = Brand.glyph(attention: false).tiffRepresentation
        let b = Brand.glyph(attention: true).tiffRepresentation
        #expect(a != nil && b != nil && a != b)
    }
}
