import Foundation
import Testing
@testable import ForgedBrew

// isSafeRemoteURL is the SSRF gate for URLs pulled from an arbitrary installed
// app's Info.plist (appcast feed, homepage). A malicious app could aim those at
// cloud-metadata, localhost, or internal hosts, so every loopback/private
// encoding the OS resolver accepts must be rejected — not just the obvious ones.
struct SSRFGuardTests {

    // MARK: - Legitimate public update feeds are allowed

    @Test(arguments: [
        "https://example.com",
        "http://formulae.brew.sh/api/cask/foo.json",
        "https://github.com/owner/repo/releases",
        "https://raw.githubusercontent.com/owner/repo/main/appcast.xml",
        "http://8.8.8.8",          // a public IP is fine
    ])
    func publicURLsAreAllowed(_ string: String) {
        let url = URL(string: string)!
        #expect(AppUpdateService.isSafeRemoteURL(url), "\(string) should be allowed")
    }

    // MARK: - Non-web schemes are rejected

    @Test(arguments: [
        "ftp://example.com/x",
        "file:///etc/passwd",
        "gopher://example.com",
    ])
    func nonHTTPSchemesAreRejected(_ string: String) {
        let url = URL(string: string)!
        #expect(!AppUpdateService.isSafeRemoteURL(url), "\(string) should be rejected")
    }

    // MARK: - Loopback / private / metadata targets are rejected

    @Test(arguments: [
        "http://localhost",
        "http://localhost.",               // trailing dot still resolves
        "http://something.local",          // mDNS
        "http://service.internal",         // cloud-internal
        "http://127.0.0.1",                // dotted loopback
        "http://127.1",                    // shorthand loopback
        "http://2130706433",               // decimal-encoded 127.0.0.1
        "http://0x7f000001",               // hex-encoded 127.0.0.1
        "http://169.254.169.254",          // cloud metadata (link-local)
        "http://10.1.2.3",                 // private class A
        "http://192.168.0.1",              // private class C
        "http://172.16.5.5",               // private class B
        "http://[::1]",                    // IPv6 loopback
        "http://[fe80::1]",                // IPv6 link-local
    ])
    func loopbackAndPrivateTargetsAreRejected(_ string: String) {
        let url = URL(string: string)!
        #expect(!AppUpdateService.isSafeRemoteURL(url), "\(string) should be rejected")
    }
}
