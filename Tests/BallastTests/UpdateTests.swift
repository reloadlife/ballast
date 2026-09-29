import Foundation
import Testing
@testable import Ballast

/// When a build may start Sparkle: only as an app, with a feed and a valid key.
@Suite struct UpdateSupportTests {
    private let app = URL(fileURLWithPath: "/Applications/Ballast.app")
    private let feed = "https://github.com/reloadlife/ballast/releases/latest/download/appcast.xml"
    /// 32 bytes, base64: the shape `generate_keys` prints.
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private var info: [String: Any] { [UpdateSupport.feedKey: feed, UpdateSupport.publicKeyKey: key] }

    @Test func releaseBuildCanUpdate() {
        #expect(UpdateSupport.check(bundleURL: app, info: info) == .available)
    }

    @Test func bareBinaryCantUpdate() {
        let binary = URL(fileURLWithPath: "/Users/me/Ballast/.build/debug")
        #expect(UpdateSupport.check(bundleURL: binary, info: info) == .unavailable(.notBundled))
        #expect(UpdateSupport.check(bundleURL: binary, info: [:]) == .unavailable(.notBundled))
    }

    @Test func buildWithoutKeyCantUpdate() {
        var info = info
        info[UpdateSupport.publicKeyKey] = nil
        #expect(UpdateSupport.check(bundleURL: app, info: info) == .unavailable(.noPublicKey))
        info[UpdateSupport.publicKeyKey] = ""
        #expect(UpdateSupport.check(bundleURL: app, info: info) == .unavailable(.noPublicKey))
    }

    @Test func buildWithoutFeedCantUpdate() {
        var info = info
        info[UpdateSupport.feedKey] = nil
        #expect(UpdateSupport.check(bundleURL: app, info: info) == .unavailable(.noFeed))
        info[UpdateSupport.feedKey] = "appcast.xml"
        #expect(UpdateSupport.check(bundleURL: app, info: info) == .unavailable(.noFeed))
    }

    @Test func publicKeyShape() {
        #expect(UpdateSupport.isPublicKey(key))
        #expect(UpdateSupport.isPublicKey(key + "\n"), "read from a file with a trailing newline")
        #expect(!UpdateSupport.isPublicKey(Data(repeating: 7, count: 64).base64EncodedString()), "a private key export is longer")
        #expect(!UpdateSupport.isPublicKey(Data(repeating: 7, count: 31).base64EncodedString()))
        #expect(!UpdateSupport.isPublicKey("not base64!"))
        #expect(!UpdateSupport.isPublicKey(""))
    }

    @Test func feedURLShape() {
        #expect(UpdateSupport.isFeedURL(feed))
        #expect(UpdateSupport.isFeedURL("http://127.0.0.1:8123/appcast.xml"))
        #expect(!UpdateSupport.isFeedURL("file:///tmp/appcast.xml"))
        #expect(!UpdateSupport.isFeedURL("https://"))
        #expect(!UpdateSupport.isFeedURL(""))
    }
}
