import Testing

@testable import Tiptoe

@Test(arguments: [
    ("1.5", "1.5.0"),
    ("v1.5.0", "1.5"),
    ("1.5.0", "1.5.0"),
    ("1.0-beta.1", "1.0.0-beta.1"),
    ("v1.0.0-beta.1", "1.0-beta.1"),
    ("1.0", "1.0.0.0"),
])
func theTagAndTheBundleCanSpellOneVersionDifferently(lhs: String, rhs: String) {
    #expect(sameVersion(lhs, rhs))
    #expect(sameVersion(rhs, lhs))
}

@Test(arguments: [
    ("1.5", "1.6"),
    ("1.5", "1.5.1"),
    ("1.5", "1.5-beta.1"),
    ("1.5-beta.1", "1.5-beta.2"),
    ("1.5", "1.50"),
    ("1.5", ""),
    ("", "0"),
])
func differentVersionsStayDifferent(lhs: String, rhs: String) {
    #expect(!sameVersion(lhs, rhs))
    #expect(!sameVersion(rhs, lhs))
}
