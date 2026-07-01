import Testing
@testable import ForgedBrew

// The CVSS v3.x base-score calculator. Scores were hand-verified against the
// official FIRST.org examples. This only ever refines the severity RANK — it
// never decides whether a package is flagged vulnerable — but a wrong score
// would mis-bucket a Critical CVE, so the canonical vectors are pinned here.
struct CVSSTests {

    // Tolerant compare — base scores are rounded to one decimal, but keep FP
    // noise from ever failing a correct result.
    private func expectScore(_ vector: String, _ expected: Double) {
        let score = CVSS.baseScore(fromVector: vector)
        #expect(score != nil, "expected a score for \(vector)")
        if let score {
            #expect(abs(score - expected) < 0.001,
                    "\(vector) → \(score), expected \(expected)")
        }
    }

    // MARK: - Canonical FIRST.org vectors

    @Test func fullImpactNetworkVectorScores9_8() {
        expectScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H", 9.8)
    }

    @Test func lowPrivilegeNetworkVectorScores8_8() {
        expectScore("CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H", 8.8)
    }

    @Test func scopeChangedXSSVectorScores6_1() {
        expectScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N", 6.1)
    }

    @Test func noImpactScoresZero() {
        // Zero impact → base score 0.0 (CVSS "None"), a real assessed rating.
        expectScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N", 0.0)
    }

    @Test func cvss30PrefixIsAccepted() {
        expectScore("CVSS:3.0/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H", 9.8)
    }

    @Test func metricOrderDoesNotMatter() {
        // Same metrics, shuffled token order → same score.
        expectScore("CVSS:3.1/C:H/A:H/AV:N/I:H/S:U/AC:L/PR:N/UI:N", 9.8)
    }

    // MARK: - Wrong / incomplete vectors return nil

    @Test func unprefixedV2VectorIsRejected() {
        // No "CVSS:3.x" prefix → must not be run through the v3 formula.
        #expect(CVSS.baseScore(fromVector: "AV:N/AC:L/Au:N/C:P/I:P/A:P") == nil)
    }

    @Test func v4VectorIsRejected() {
        #expect(CVSS.baseScore(fromVector: "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N") == nil)
    }

    @Test func missingRequiredMetricReturnsNil() {
        // Availability (A) missing.
        #expect(CVSS.baseScore(fromVector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H") == nil)
    }

    @Test func emptyStringReturnsNil() {
        #expect(CVSS.baseScore(fromVector: "") == nil)
    }

    // MARK: - score(fromOSVScore:) — vector first, then bare number

    @Test func osvScoreParsesVector() {
        let s = CVSS.score(fromOSVScore: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
        #expect(s != nil && abs(s! - 9.8) < 0.001)
    }

    @Test func osvScoreParsesBareNumber() {
        #expect(CVSS.score(fromOSVScore: "7.5") == 7.5)
    }

    @Test func osvScoreRejectsGarbage() {
        #expect(CVSS.score(fromOSVScore: "not-a-score") == nil)
    }
}
