import Testing
@testable import MeetingVox

/// Tag values for Hindsight (`pais:` / `cliente:`): case and diacritics
/// folded, every run of characters outside `[a-z0-9]` becomes one `-`, no
/// leading or trailing `-`, nothing left = no tag.
@Suite struct HindsightTagNormalizerTests {
    @Test(arguments: [
        ("México", "mexico"),
        ("Mexico", "mexico"),
        ("Cliente Principal", "cliente-principal"),
        ("Grupo S.A. / Chile", "grupo-s-a-chile"),
        ("  PROVEEDOR  ", "proveedor"),
        ("Perú", "peru"),
        ("Ñandú—Co", "nandu-co"),
        ("---x---", "x"),
        ("Área 51", "area-51"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(HindsightTagNormalizer.value(input) == expected)
    }

    @Test(arguments: ["¿?", "   ", "", "---", "…", "日本"])
    func nothingLeftMeansNoTag(input: String) {
        #expect(HindsightTagNormalizer.value(input) == nil)
    }

    @Test func aLongValueIsCappedWithoutATrailingDash() throws {
        let long = String(repeating: "abcd ", count: 40)
        let value = try #require(HindsightTagNormalizer.value(long))
        #expect(value.count <= HindsightTagNormalizer.maxLength)
        #expect(!value.hasSuffix("-"))
        #expect(value.hasPrefix("abcd-abcd"))
        // Cut exactly on a separator: the dash goes too.
        let onSeparator = String(repeating: "a", count: HindsightTagNormalizer.maxLength) + " tail"
        #expect(HindsightTagNormalizer.value(onSeparator) == String(repeating: "a", count: HindsightTagNormalizer.maxLength))
        let dashAtCut = String(repeating: "a", count: HindsightTagNormalizer.maxLength - 1) + " tail"
        #expect(HindsightTagNormalizer.value(dashAtCut) == String(repeating: "a", count: HindsightTagNormalizer.maxLength - 1))
    }

    @Test func nilInputIsNil() {
        #expect(HindsightTagNormalizer.value(nil) == nil)
    }
}
