import Foundation
import os
import Testing
@testable import Ballast

/// A fixed context, so encoded output is predictable.
private let context = TelemetryContext(
    appVersion: "0.2.1", build: "42", osVersion: "26.0", arch: .arm64, language: "en",
    fullDiskAccess: true, diskSize: .gb512
)

private let config = TelemetryConfig(apiKey: "phc_testkey1234567890", host: URL(string: "https://us.i.posthog.com")!)

/// One of each event, and every value of every closed set somewhere.
private let everyEvent: [TelemetryEvent] = {
    var events: [TelemetryEvent] = [.appOpened(menuBarItem: true), .appOpened(menuBarItem: false), .putBackUsed]
    for kind in ScanKind.allCases {
        for duration in DurationBucket.allCases {
            events.append(.scanCompleted(kind, duration: duration, folders: .upTo1M, fellBackToFull: kind == .full))
        }
    }
    for count in CountBucket.allCases {
        events.append(.scanCompleted(.incremental, duration: .under10s, folders: count, fellBackToFull: false))
    }
    for method in CleanMethod.allCases {
        for source in CleanSource.allCases {
            events.append(.cleanupCompleted(items: .upTo10, freed: .gb1to10, method: method, source: source))
        }
    }
    for freed in SizeBucket.allCases {
        events.append(.cleanupCompleted(items: .one, freed: freed, method: .trash, source: .manual))
    }
    events += SuggestionSectionID.allCases.map { .suggestionSectionViewed($0) }
    events += WidgetSize.allCases.map { .widgetInstalled($0) }
    events += TelemetryFeature.allCases.map { .featureUsed($0) }
    for setting in TelemetrySetting.allCases {
        events.append(.settingChanged(setting, nil))
        events.append(.settingChanged(setting, .on(true)))
    }
    events += SettingChoice.allCases.map { .settingChanged(.staleMonths, .choice($0)) }
    return events
}()

/// Sends nothing; counts what it was asked to send.
private final class SpyTransport: TelemetryTransport, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (requests: [URLRequest](), status: 200))

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func respond(_ status: Int) { state.withLock { $0.status = status } }

    func send(_ request: URLRequest) async throws -> Int {
        state.withLock { state in
            state.requests.append(request)
            return state.status
        }
    }
}

private func temporaryDirectory() -> String {
    let path = NSTemporaryDirectory() + "ballast-telemetry-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func makeTelemetry(mode: Telemetry.Mode = .app, directory: String = temporaryDirectory(),
                           support: TelemetrySupport = .available(config),
                           transport: SpyTransport = SpyTransport()) -> Telemetry {
    Telemetry(mode: mode, support: support, store: TelemetryStore(directory: directory), transport: transport) { context }
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct TelemetryEventTests {
    @Test func everyKindIsCovered() {
        #expect(Set(everyEvent.map(\.kind)) == Set(TelemetryEvent.Kind.allCases))
    }

    /// An event carries exactly its declared properties plus the envelope
    /// and context, each with a value its property accepts: nothing is
    /// dropped on the way, and nothing undeclared can get in.
    @Test func eventsCarryOnlyAllowlistedProperties() throws {
        for event in everyEvent {
            let item = try #require(event.item(distinctID: UUID(), context: context), "\(event)")
            let keys = Set(item.properties.keys)
            let declared = Set((TelemetryProperty.envelope + TelemetryProperty.context).map(\.rawValue))
                .union(event.kind.properties.map(\.rawValue))
            if case .settingChanged(_, nil) = event {
                #expect(keys == declared.subtracting([TelemetryProperty.value.rawValue]))
            } else {
                #expect(keys == declared, "\(event)")
            }
            for (key, value) in item.properties {
                let property = try #require(TelemetryProperty(rawValue: key))
                #expect(property.accepts(value), "\(event): \(key)")
            }
            #expect(item.sanitized() == item, "\(event) survives the sanitizer unchanged")
        }
    }

    /// Every string that can be sent is from a short list or matches a
    /// narrow pattern: no path or name fits.
    @Test func noFreeTextFits() {
        let leaks = ["/Users/me/Projects", "~/Library", "node_modules", "Macintosh HD", "Xcode.app",
                     "com.apple.dt.Xcode", "me", "MacBook-Pro.local", "C02XK0AAJG5H", "123456789012"]
        for property in TelemetryProperty.allCases where property != .build {
            for leak in leaks {
                #expect(!property.accepts(.tokenForTest(leak)), "\(property.rawValue) accepted \(leak)")
            }
        }
        // A build number is digits only, nine at most: never a byte count past 999 MB.
        #expect(!TelemetryProperty.build.accepts(.tokenForTest("1234567890")))
        #expect(!TelemetryProperty.language.accepts(.tokenForTest("en-US")))
        #expect(!TelemetryProperty.osVersion.accepts(.tokenForTest("26.0.1")))
    }

    @Test func sanitizerDropsWhatIsntDeclared() throws {
        var item = try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context))
        item.properties["path"] = .tokenForTest("/Users/me/secret")
        item.properties["$ip"] = .tokenForTest("10.0.0.1")
        item.properties[TelemetryProperty.section.rawValue] = .token(SuggestionSectionID.caches)  // not this event's
        item.properties[TelemetryProperty.freed.rawValue] = .tokenForTest("12345678901")
        let clean = try #require(item.sanitized())
        #expect(clean.properties["path"] == nil)
        #expect(clean.properties["$ip"] == nil)
        #expect(clean.properties["section"] == nil)
        #expect(clean.properties["freed"] == nil)
        #expect(clean.properties["distinct_id"] != nil)
    }

    @Test func itemsWithoutEnvelopeOrKnownEventAreRefused() throws {
        let item = try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context))
        var noID = item
        noID.properties["distinct_id"] = nil
        #expect(noID.sanitized() == nil)
        var profile = item
        profile.properties["$process_person_profile"] = .flag(true)
        #expect(profile.sanitized() == nil, "an item asking for a person profile isn't sent")
        let unknown = TelemetryItem(uuid: UUID(), event: "file_deleted", timestamp: .now, properties: item.properties)
        #expect(unknown.sanitized() == nil)
    }

    @Test func badContextValuesAreDropped() throws {
        var odd = context
        odd.language = "/Users/me"
        odd.appVersion = "0.2.1 (me's build)"
        let item = try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: odd))
        #expect(item.properties["language"] == nil)
        #expect(item.properties["app_version"] == nil)
        #expect(item.properties["build"] == .tokenForTest("42"))
    }

    @Test func autoCleanEvent() {
        var run = AutoCleanRun()
        run.entries = [
            .init(path: "/Users/me/a/node_modules", kind: .nodeModules, bytes: 3_000_000_000, error: nil),
            .init(path: "/Users/me/b/.next", kind: .next, bytes: 500_000_000, error: nil),
            .init(path: "/Users/me/c/node_modules", kind: .nodeModules, bytes: 9, error: "In use"),
        ]
        var settings = AutoCleanSettings()
        #expect(TelemetryEvent.autoClean(run, settings: settings, source: .autoClean)
            == .cleanupCompleted(items: .upTo10, freed: .gb1to10, method: .delete, source: .autoClean))
        for index in settings.rules.indices { settings.rules[index].permanent = false }
        #expect(TelemetryEvent.autoClean(run, settings: settings, source: .autoClean)
            == .cleanupCompleted(items: .upTo10, freed: .gb1to10, method: .trash, source: .autoClean))
        let index = settings.rules.firstIndex { $0.kind == .next }!
        settings.rules[index].permanent = true
        #expect(TelemetryEvent.autoClean(run, settings: settings, source: .shortcut)
            == .cleanupCompleted(items: .upTo10, freed: .gb1to10, method: .mixed, source: .shortcut))
        run.dryRun = true
        #expect(TelemetryEvent.autoClean(run, settings: settings, source: .autoClean) == nil, "dry runs aren't cleanups")
        #expect(TelemetryEvent.autoClean(AutoCleanRun(), settings: settings, source: .autoClean) == nil)
    }
}

@Suite struct TelemetryBucketTests {
    @Test func sizes() {
        #expect(SizeBucket(bytes: 0) == .none)
        #expect(SizeBucket(bytes: -5) == .none)
        #expect(SizeBucket(bytes: 1) == .under1GB)
        #expect(SizeBucket(bytes: 999_999_999) == .under1GB)
        #expect(SizeBucket(bytes: 1_000_000_000) == .gb1to10)
        #expect(SizeBucket(bytes: 9_999_999_999) == .gb1to10)
        #expect(SizeBucket(bytes: 10_000_000_000) == .gb10to50)
        #expect(SizeBucket(bytes: 50_000_000_000) == .gb50to200)
        #expect(SizeBucket(bytes: 199_999_999_999) == .gb50to200)
        #expect(SizeBucket(bytes: 200_000_000_000) == .over200GB)
    }

    @Test func diskSizes() {
        #expect(DiskSizeBucket(bytes: 245_000_000_000) == .upTo256GB)
        #expect(DiskSizeBucket(bytes: 494_000_000_000) == .gb512)
        #expect(DiskSizeBucket(bytes: 994_000_000_000) == .tb1)
        #expect(DiskSizeBucket(bytes: 1_995_000_000_000) == .tb2)
        #expect(DiskSizeBucket(bytes: 3_995_000_000_000) == .tb4)
        #expect(DiskSizeBucket(bytes: 7_995_000_000_000) == .tb8OrMore)
    }

    @Test func durations() {
        #expect(DurationBucket(seconds: 0) == .under10s)
        #expect(DurationBucket(seconds: 9.9) == .under10s)
        #expect(DurationBucket(seconds: 10) == .s10to60)
        #expect(DurationBucket(seconds: 59) == .s10to60)
        #expect(DurationBucket(seconds: 60) == .min1to5)
        #expect(DurationBucket(seconds: 299) == .min1to5)
        #expect(DurationBucket(seconds: 300) == .min5to15)
        #expect(DurationBucket(seconds: 900) == .over15min)
    }

    @Test func counts() {
        #expect(CountBucket(-1) == .zero)
        #expect(CountBucket(0) == .zero)
        #expect(CountBucket(1) == .one)
        #expect(CountBucket(2) == .upTo10)
        #expect(CountBucket(10) == .upTo10)
        #expect(CountBucket(11) == .upTo100)
        #expect(CountBucket(1_000) == .upTo1K)
        #expect(CountBucket(1_001) == .upTo10K)
        #expect(CountBucket(620_000) == .upTo1M)
        #expect(CountBucket(1_000_001) == .over1M)
    }

    @Test func settingChoices() {
        #expect(SettingChoice.lowSpace(gigabytes: 20) == .gb20)
        #expect(SettingChoice.lowSpace(gigabytes: 37) == .other, "a hand-edited value isn't sent as is")
        #expect(SettingChoice.stale(months: 12) == .months12)
        #expect(SettingChoice.stale(months: 7) == .other)
    }
}

@Suite struct TelemetryPayloadTests {
    /// PostHog's batch format: {"api_key", "batch": [{event, properties:
    /// {distinct_id, …}, timestamp, uuid}]}.
    @Test func batchMatchesPostHogsFormat() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let item = try #require(TelemetryEvent.cleanupCompleted(items: .upTo10, freed: .gb1to10, method: .trash, source: .manual)
            .item(distinctID: id, context: context, at: date))
        let body = try json(TelemetryBatch(apiKey: config.apiKey, batch: [item]).encoded())

        #expect(Set(body.keys) == ["api_key", "batch"])
        #expect(body["api_key"] as? String == config.apiKey)
        let batch = try #require(body["batch"] as? [[String: Any]])
        #expect(batch.count == 1)
        let event = batch[0]
        #expect(Set(event.keys) == ["uuid", "event", "timestamp", "properties"])
        #expect(event["event"] as? String == "cleanup_completed")
        #expect(event["timestamp"] as? String == "2026-09-21T14:13:20Z")
        #expect(event["uuid"] as? String == item.uuid.uuidString)
        let properties = try #require(event["properties"] as? [String: Any])
        #expect(properties["distinct_id"] as? String == id.uuidString)
        #expect((properties["$process_person_profile"] as? NSNumber) == false)
        #expect((properties["$geoip_disable"] as? NSNumber) == true)
        #expect(properties["$ip"] == nil)
        #expect(properties["item_count"] as? String == "2-10")
        #expect(properties["freed"] as? String == "1-10 GB")
        #expect(properties["method"] as? String == "trash")
        #expect(properties["source"] as? String == "manual")
        #expect(properties["full_disk_access"] as? Bool == true)
        #expect(properties["disk_size"] as? String == "512 GB")
        #expect(properties["language"] as? String == "en")
        #expect(properties["os_version"] as? String == "26.0")
        #expect(properties["arch"] as? String == "arm64")
    }

    @Test func queueRoundTrips() throws {
        let item = try #require(TelemetryEvent.featureUsed(.export).item(distinctID: UUID(), context: context,
                                                                         at: Date(timeIntervalSince1970: 1_790_000_000)))
        let data = try TelemetryItem.encoder().encode([item])
        #expect(try TelemetryItem.decoder.decode([TelemetryItem].self, from: data) == [item])
    }
}

@Suite struct TelemetrySupportTests {
    private let app = URL(fileURLWithPath: "/Applications/Ballast.app")

    @Test func needsKeyAndHost() {
        let info: [String: Any] = [TelemetrySupport.keyKey: config.apiKey, TelemetrySupport.hostKey: "https://eu.i.posthog.com"]
        #expect(TelemetrySupport.check(bundleURL: app, info: info).config?.batchURL.absoluteString == "https://eu.i.posthog.com/batch/")
        #expect(TelemetrySupport.check(bundleURL: app, info: [:]) == .unavailable(.noKey))
        #expect(TelemetrySupport.check(bundleURL: URL(fileURLWithPath: "/tmp/.build/debug"), info: info) == .unavailable(.notBundled))
        #expect(TelemetrySupport.check(bundleURL: app, info: [TelemetrySupport.keyKey: "sk_live_x"]) == .unavailable(.noKey))
        #expect(TelemetrySupport.check(bundleURL: app, info: [TelemetrySupport.keyKey: config.apiKey]) == .unavailable(.badHost))
    }

    @Test func httpsOnlyExceptThisMac() {
        #expect(TelemetrySupport.hostURL("https://us.i.posthog.com") != nil)
        #expect(TelemetrySupport.hostURL("http://us.i.posthog.com") == nil)
        #expect(TelemetrySupport.hostURL("http://192.168.1.5:8000") == nil)
        #expect(TelemetrySupport.hostURL("http://127.0.0.1:8765") != nil)
        #expect(TelemetrySupport.hostURL("http://localhost:8765") != nil)
        #expect(TelemetrySupport.hostURL("ftp://127.0.0.1") == nil)
        #expect(TelemetrySupport.hostURL("https://us.i.posthog.com?x=1") == nil)
        #expect(TelemetrySupport.hostURL("") == nil)
    }
}

@Suite struct TelemetryQueueTests {
    @Test func capDropsOldest() throws {
        let store = TelemetryStore(directory: temporaryDirectory())
        let id = UUID()
        var first: UUID?
        for index in 0..<(TelemetryStore.queueCap + 20) {
            let item = try #require(TelemetryEvent.putBackUsed.item(distinctID: id, context: context))
            if index == 20 { first = item.uuid }
            store.append(item)
        }
        let queue = store.queue()
        #expect(queue.count == TelemetryStore.queueCap)
        #expect(queue.first?.uuid == first)
    }

    @Test func oldItemsAreDropped() throws {
        let store = TelemetryStore(directory: temporaryDirectory())
        let now = Date.now
        let old = try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context,
                                                                at: now.addingTimeInterval(-3 * 86_400 - 60)))
        let recent = try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context,
                                                                   at: now.addingTimeInterval(-2 * 86_400)))
        store.append(old, now: now)
        store.append(recent, now: now)
        #expect(store.queue(now: now).map(\.uuid) == [recent.uuid])
    }

    @Test func removingSentItemsKeepsNewOnes() throws {
        let store = TelemetryStore(directory: temporaryDirectory())
        let a = try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context))
        let b = try #require(TelemetryEvent.featureUsed(.export).item(distinctID: UUID(), context: context))
        store.append(a)
        store.append(b)
        store.remove([a.uuid])
        #expect(store.queue().map(\.uuid) == [b.uuid])
        store.remove([b.uuid])
        #expect(!FileManager.default.fileExists(atPath: store.queueURL.path))
    }

    @Test func tamperedQueueIsSanitizedOnRead() throws {
        let store = TelemetryStore(directory: temporaryDirectory())
        var item = try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context))
        item.properties["path"] = .tokenForTest("/Users/me")
        try TelemetryItem.encoder().encode([item]).write(to: store.queueURL)
        #expect(store.queue().first?.properties["path"] == nil)
    }
}

@Suite struct TelemetryConsentTests {
    @Test func nothingIsRecordedBeforeAnswering() {
        let directory = temporaryDirectory()
        let telemetry = makeTelemetry(directory: directory)
        telemetry.record(.appOpened(menuBarItem: true))
        telemetry.recordOncePerRun(.featureUsed(.export))
        #expect(telemetry.decision == nil)
        #expect(telemetry.distinctID == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory)) == [], "no file is written at all")
    }

    @Test func nothingIsRecordedAfterNoThanks() {
        let telemetry = makeTelemetry()
        telemetry.optOut()
        telemetry.record(.appOpened(menuBarItem: true))
        #expect(telemetry.decision == .declined)
        #expect(telemetry.store.queue().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: telemetry.store.queueURL.path))
        #expect(telemetry.store.state()?.distinctID == nil)
    }

    @Test func optInRecordsAndOptOutWipes() throws {
        let telemetry = makeTelemetry()
        telemetry.optIn()
        let id = try #require(telemetry.distinctID)
        telemetry.record(.appOpened(menuBarItem: false))
        telemetry.record(.putBackUsed)
        #expect(telemetry.store.queue().count == 2)
        #expect(telemetry.store.queue().allSatisfy { $0.properties["distinct_id"] == .tokenForTest(id.uuidString) })

        telemetry.optOut()
        #expect(telemetry.distinctID == nil)
        #expect(telemetry.store.state()?.distinctID == nil)
        #expect(!FileManager.default.fileExists(atPath: telemetry.store.queueURL.path))
        telemetry.record(.putBackUsed)
        #expect(telemetry.store.queue().isEmpty)
    }

    @Test func resetIdentifierClearsQueue() throws {
        let telemetry = makeTelemetry()
        telemetry.optIn()
        let before = try #require(telemetry.distinctID)
        telemetry.record(.putBackUsed)
        telemetry.resetIdentifier()
        let after = try #require(telemetry.distinctID)
        #expect(before != after)
        #expect(telemetry.store.queue().isEmpty)
    }

    @Test func onceEventsAreRecordedOnce() {
        let telemetry = makeTelemetry()
        telemetry.optIn()
        telemetry.recordOncePerRun(.featureUsed(.explorerSearch))
        telemetry.recordOncePerRun(.featureUsed(.explorerSearch))
        telemetry.recordOncePerRun(.suggestionSectionViewed(.caches))
        #expect(telemetry.store.queue().count == 2)
    }

    @Test func widgetSizesAreReportedOnce() {
        let telemetry = makeTelemetry()
        telemetry.optIn()
        telemetry.recordWidgets([.small])
        telemetry.recordWidgets([.small, .large])
        #expect(telemetry.store.queue().map(\.properties["widget_size"]) == [.token(WidgetSize.small), .token(WidgetSize.large)])
    }

    @Test func buildWithoutKeyNeverRecords() {
        let directory = temporaryDirectory()
        // Even with a "shared" answer on disk, e.g. from another build.
        TelemetryStore(directory: directory).setState(.init(decision: .shared, distinctID: UUID()))
        let telemetry = makeTelemetry(directory: directory, support: .unavailable(.noKey))
        telemetry.record(.putBackUsed)
        telemetry.optIn()
        #expect(!telemetry.isSharing)
        #expect(telemetry.store.queue().isEmpty)
        telemetry.startUploading()
        #expect(telemetry.uploader == nil)
    }
}

@Suite struct TelemetrySendingTests {
    /// The daily auto-clean run queues, for the app to send later; it has
    /// no uploader and makes no request.
    @Test func commandLineOnlyQueues() async throws {
        let spy = SpyTransport()
        let directory = temporaryDirectory()
        TelemetryStore(directory: directory).setState(.init(decision: .shared, distinctID: UUID()))
        let telemetry = makeTelemetry(mode: .commandLine, directory: directory, transport: spy)
        telemetry.record(.cleanupCompleted(items: .one, freed: .under1GB, method: .trash, source: .autoClean))
        telemetry.startUploading(every: .milliseconds(1))
        await telemetry.flush(force: true)
        #expect(telemetry.uploader == nil)
        #expect(telemetry.store.queue().count == 1)
        #expect(spy.requests.isEmpty)
    }

    @Test func flushSendsAndEmptiesQueue() async throws {
        let spy = SpyTransport()
        let telemetry = makeTelemetry(transport: spy)
        telemetry.optIn()
        telemetry.record(.putBackUsed)
        telemetry.record(.featureUsed(.quickLook))
        telemetry.startUploading()
        await telemetry.flush(force: true)

        #expect(telemetry.store.queue().isEmpty)
        let request = try #require(spy.requests.last)
        #expect(request.url?.absoluteString == "https://us.i.posthog.com/batch/")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try json(try #require(request.httpBody))
        #expect((body["batch"] as? [Any])?.count == 2)
    }

    @Test func failuresKeepTheQueueAndBackOff() async throws {
        let spy = SpyTransport()
        spy.respond(503)
        let store = TelemetryStore(directory: temporaryDirectory())
        store.setState(.init(decision: .shared, distinctID: UUID()))
        store.append(try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context)))
        let uploader = TelemetryUploader(store: store, config: config, transport: spy)

        await uploader.flush()
        #expect(store.queue().count == 1)
        #expect(spy.requests.count == 1)
        await uploader.flush()
        #expect(spy.requests.count == 1, "waits before trying again")
        spy.respond(200)
        await uploader.flush(now: .now.addingTimeInterval(TelemetryUploader.backoff(failures: 1) + 1))
        #expect(store.queue().isEmpty)
    }

    @Test func refusedBatchesAreDropped() async throws {
        let spy = SpyTransport()
        spy.respond(400)
        let store = TelemetryStore(directory: temporaryDirectory())
        store.append(try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context)))
        await TelemetryUploader(store: store, config: config, transport: spy).flush()
        #expect(store.queue().isEmpty, "a 400 would fail forever")
    }

    @Test func backoffGrowsAndCaps() {
        #expect(TelemetryUploader.backoff(failures: 1) == 60)
        #expect(TelemetryUploader.backoff(failures: 2) == 120)
        #expect(TelemetryUploader.backoff(failures: 30) == 6 * 3_600)
    }

    @Test func plainHTTPToAnotherHostIsNeverSent() async throws {
        let spy = SpyTransport()
        let store = TelemetryStore(directory: temporaryDirectory())
        store.append(try #require(TelemetryEvent.putBackUsed.item(distinctID: UUID(), context: context)))
        let insecure = TelemetryConfig(apiKey: config.apiKey, host: URL(string: "http://example.com")!)
        await TelemetryUploader(store: store, config: insecure, transport: spy).flush(force: true)
        #expect(spy.requests.isEmpty)
    }
}

extension TelemetryValue {
    /// Any string, to check that properties refuse what they should.
    static func tokenForTest(_ string: String) -> TelemetryValue {
        try! JSONDecoder().decode(TelemetryValue.self, from: JSONEncoder().encode(string))
    }
}
