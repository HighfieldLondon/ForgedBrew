import Testing
@testable import ForgedBrew

// AppVersion.isNewer is what decides whether a row shows "update available".
// It regressed twice historically — a build suffix on one side conjured a
// phantom update, and the over-correction then MISSED real patch releases — so
// these lock the marketing-vs-build contract down hard.
struct AppVersionTests {

    // MARK: - Real patch releases must be detected

    @Test func patchReleaseWithExtraComponentIsNewer() {
        // 2.0 → 2.0.1 is a genuine patch: an extra marketing component.
        #expect(AppVersion.isNewer("2.0.1", than: "2.0"))
    }

    @Test func higherComponentIsNewer() {
        #expect(AppVersion.isNewer("2.0.1", than: "2.0.0"))
        #expect(AppVersion.isNewer("26.084.0504", than: "26.084.0503"))
    }

    @Test func componentsCompareNumericallyNotLexically() {
        // 10 > 9, even though "1.10" sorts before "1.9" as text.
        #expect(AppVersion.isNewer("1.10", than: "1.9"))
    }

    @Test func vPrefixIsTolerated() {
        #expect(AppVersion.isNewer("v2", than: "v1"))
    }

    // MARK: - Build suffixes must NOT conjure phantom updates

    @Test func asymmetricBuildSuffixIsNotNewer() {
        // The original phantom-update bug: a build-tagged release of the same
        // marketing version must read as the SAME version, not an update.
        #expect(!AppVersion.isNewer("2.0.1 (4521)", than: "2.0.1"))
        #expect(!AppVersion.isNewer("2.0.1", than: "2.0.1 (4521)"))
        #expect(!AppVersion.isNewer("1.4.3+101", than: "1.4.3"))
    }

    @Test func buildNumberBreaksTieOnlyWhenBothSidesHaveOne() {
        #expect(AppVersion.isNewer("2.0.1 (4522)", than: "2.0.1 (4521)"))
        #expect(!AppVersion.isNewer("2.0.1 (4521)", than: "2.0.1 (4522)"))
        #expect(AppVersion.isNewer("1.4.3+101", than: "1.4.3+100"))
    }

    // MARK: - Equality / older

    @Test func equalVersionsAreNotNewer() {
        #expect(!AppVersion.isNewer("2.0.1", than: "2.0.1"))
        // Trailing-zero components don't manufacture a difference.
        #expect(!AppVersion.isNewer("1.0.0", than: "1.0"))
    }

    @Test func olderVersionIsNotNewer() {
        #expect(!AppVersion.isNewer("2.0", than: "2.0.1"))
    }

    // MARK: - Unparseable strings fall back to "different means newer"

    @Test func unparseableDifferentStringsCountAsNewer() {
        // We'd rather surface an update we can't parse than silently hide it.
        #expect(AppVersion.isNewer("beta", than: "alpha"))
    }

    @Test func unparseableIdenticalStringsAreNotNewer() {
        #expect(!AppVersion.isNewer("beta", than: "beta"))
    }

    // MARK: - parse() splits marketing from build

    @Test func parseSeparatesMarketingAndBuild() {
        let parenthesised = AppVersion.parse("2.0.1 (4521)")
        #expect(parenthesised.marketing == [2, 0, 1])
        #expect(parenthesised.build == 4521)

        let plus = AppVersion.parse("1.4.3+101")
        #expect(plus.marketing == [1, 4, 3])
        #expect(plus.build == 101)

        #expect(AppVersion.parse("2.0.1").build == nil)
    }
}
