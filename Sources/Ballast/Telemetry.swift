import Foundation
import os
import WidgetKit

// Anonymous usage data, sent to PostHog only if the user opts in.
//
// This file is the whole of it, so it can be audited in one place: every
// event and every property Ballast can send is defined below, the Settings
// "What's sent" list is generated from these definitions, and the queue on
// disk (telemetry-queue.json) holds exactly the items a request carries.
//
// - Off by default. Before the user says yes, nothing is recorded, queued
//   or sent, and no identifier exists.
// - The identifier is a random UUID made at opt-in, with nothing behind it.
//   Turning sharing off deletes it and everything queued.
// - Values come only from closed enums (buckets, fixed names) or booleans,
//   plus the app version, build, macOS version and language code, which are
//   checked against a pattern. There is no way to put a path, a file or app
//   name, or an exact size into an event.
// - Every event asks PostHog not to build a person profile and not to look
//   up a location. PostHog still sees the IP address a request comes from,
//   like any server does.
// - Only the app sends, over HTTPS. The command-line modes (the daily
//   auto-clean run) can only add to the queue.

// MARK: - Values

/// A closed set of strings: the only kind of string an event can carry.
protocol TelemetryToken: RawRepresentable, CaseIterable, Sendable where RawValue == String {}

/// One property value: a boolean or a string.
struct TelemetryValue: Codable, Equatable, Hashable, Sendable {
    enum Stored: Equatable, Hashable, Sendable {
        case bool(Bool)
        case string(String)
    }

    let stored: Stored

    private init(_ stored: Stored) { self.stored = stored }

    static func flag(_ value: Bool) -> TelemetryValue { TelemetryValue(.bool(value)) }

    static func token<T: TelemetryToken>(_ token: T) -> TelemetryValue { TelemetryValue(.string(token.rawValue)) }

    /// Only for this file's context values (versions, language code), which
    /// are checked against their property's pattern before they're queued.
    fileprivate static func text(_ string: String) -> TelemetryValue { TelemetryValue(.string(string)) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            stored = .bool(bool)
        } else {
            stored = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch stored {
        case .bool(let bool): try container.encode(bool)
        case .string(let string): try container.encode(string)
        }
    }
}

// MARK: - Buckets

/// Bytes freed by a cleanup, in decimal gigabytes like every figure Ballast shows.
enum SizeBucket: String, TelemetryToken {
    case none = "0"
    case under1GB = "<1 GB"
    case gb1to10 = "1-10 GB"
    case gb10to50 = "10-50 GB"
    case gb50to200 = "50-200 GB"
    case over200GB = ">200 GB"

    init(bytes: Int64) {
        let gb = Double(bytes) / 1e9
        self = switch gb {
        case ...0: .none
        case ..<1: .under1GB
        case ..<10: .gb1to10
        case ..<50: .gb10to50
        case ..<200: .gb50to200
        default: .over200GB
        }
    }
}

/// The startup disk's capacity, by the size it was sold as (a "512 GB" Mac
/// reports about 494 GB).
enum DiskSizeBucket: String, TelemetryToken {
    case upTo256GB = "256 GB or less"
    case gb512 = "512 GB"
    case tb1 = "1 TB"
    case tb2 = "2 TB"
    case tb4 = "4 TB"
    case tb8OrMore = "8 TB or more"

    init(bytes: Int64) {
        let gb = Double(bytes) / 1e9
        self = switch gb {
        case ..<300: .upTo256GB
        case ..<600: .gb512
        case ..<1_200: .tb1
        case ..<2_400: .tb2
        case ..<4_800: .tb4
        default: .tb8OrMore
        }
    }
}

enum DurationBucket: String, TelemetryToken {
    case under10s = "<10 s"
    case s10to60 = "10-60 s"
    case min1to5 = "1-5 min"
    case min5to15 = "5-15 min"
    case over15min = ">15 min"

    init(seconds: Double) {
        self = switch seconds {
        case ..<10: .under10s
        case ..<60: .s10to60
        case ..<300: .min1to5
        case ..<900: .min5to15
        default: .over15min
        }
    }
}

/// Folder and item counts. Ranges include their lower bound.
enum CountBucket: String, TelemetryToken {
    case zero = "0"
    case one = "1"
    case upTo10 = "2-10"
    case upTo100 = "11-100"
    case upTo1K = "101-1K"
    case upTo10K = "1K-10K"
    case upTo100K = "10K-100K"
    case upTo1M = "100K-1M"
    case over1M = "1M+"

    init(_ count: Int) {
        self = switch count {
        case ..<1: .zero
        case 1: .one
        case ...10: .upTo10
        case ...100: .upTo100
        case ...1_000: .upTo1K
        case ...10_000: .upTo10K
        case ...100_000: .upTo100K
        case ...1_000_000: .upTo1M
        default: .over1M
        }
    }
}

// MARK: - Fixed names

enum ScanKind: String, TelemetryToken {
    case full, incremental
}

enum CleanMethod: String, TelemetryToken {
    case trash, delete
    /// Auto-clean rules, some moving to the Trash and some deleting.
    case mixed
}

enum CleanSource: String, TelemetryToken {
    /// The Cleanup List.
    case manual
    /// Auto-clean rules: the daily background run or Clean Now in Settings.
    case autoClean = "auto_clean"
    /// The Run Auto-Clean action in Shortcuts.
    case shortcut
}

/// Sections of Suggestions.
enum SuggestionSectionID: String, TelemetryToken {
    case caches
    case buildFiles = "build_files"
    case installers
    case untouched
    case duplicates
    case unusedApps = "unused_apps"
    case developerTools = "developer_tools"
    case appData = "app_data"
    case personalFiles = "personal_files"

    init(_ category: Category) {
        self = switch category {
        case .caches: .caches
        case .artifacts: .buildFiles
        case .stale: .untouched
        case .developer: .developerTools
        case .appData: .appData
        case .personal: .personalFiles
        }
    }
}

enum WidgetSize: String, TelemetryToken, Codable {
    case small, medium, large, other

    init(_ family: WidgetFamily) {
        self = switch family {
        case .systemSmall: .small
        case .systemMedium: .medium
        case .systemLarge: .large
        default: .other
        }
    }
}

enum TelemetryFeature: String, TelemetryToken {
    case explorerSearch = "explorer_search"
    case export
    case duplicatesRun = "duplicates_run"
    case diskScanned = "disk_scanned"
    case whatGrewViewed = "what_grew_viewed"
    case quickLook = "quick_look"
}

/// Settings whose changes are counted. Folder lists and rules send that
/// they changed, never what's in them.
enum TelemetrySetting: String, TelemetryToken {
    case deletePermanentlyByDefault = "delete_permanently_by_default"
    case menuBarItem = "menu_bar_item"
    case menuBarFreeSpace = "menu_bar_free_space"
    case lowSpaceAlert = "low_space_alert"
    case lowSpaceThreshold = "low_space_threshold"
    case staleMonths = "stale_months"
    case removableDrives = "removable_drives"
    case excludedFolders = "excluded_folders"
    case protectedFolders = "protected_folders"
    case appearance
    case autoCleanBackground = "auto_clean_background"
    case autoCleanRules = "auto_clean_rules"
}

/// The new value of a setting that's a choice from a fixed list.
enum SettingChoice: String, TelemetryToken {
    case gb5 = "5 GB", gb10 = "10 GB", gb20 = "20 GB", gb50 = "50 GB", gb100 = "100 GB"
    case months3 = "3 months", months6 = "6 months", months12 = "12 months", months24 = "24 months"
    case system, light, dark
    /// Anything off the list, e.g. from an edited settings.json.
    case other

    static func lowSpace(gigabytes: Int) -> SettingChoice {
        switch gigabytes {
        case 5: .gb5
        case 10: .gb10
        case 20: .gb20
        case 50: .gb50
        case 100: .gb100
        default: .other
        }
    }

    static func stale(months: Int) -> SettingChoice {
        switch months {
        case 3: .months3
        case 6: .months6
        case 12: .months12
        case 24: .months24
        default: .other
        }
    }
}

enum SettingValue: Equatable, Sendable {
    case on(Bool)
    case choice(SettingChoice)
}

enum CPUArch: String, TelemetryToken {
    case arm64, x86_64, other

    static var current: CPUArch {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .other
        #endif
    }
}

// MARK: - Properties

/// Every property key Ballast can send. Nothing else reaches the queue.
enum TelemetryProperty: String, CaseIterable, Sendable {
    // On every event: PostHog's own switches and the random identifier.
    case distinctID = "distinct_id"
    case processPersonProfile = "$process_person_profile"
    case geoipDisable = "$geoip_disable"
    // On every event: about this copy of Ballast and the Mac.
    case appVersion = "app_version"
    case build
    case osVersion = "os_version"
    case arch
    case language
    case fullDiskAccess = "full_disk_access"
    case diskSize = "disk_size"
    // Per event.
    case menuBarItem = "menu_bar_item"
    case scanKind = "scan_kind"
    case duration
    case folderCount = "folder_count"
    case fellBackToFull = "fell_back_to_full"
    case itemCount = "item_count"
    case freed
    case method
    case source
    case section
    case widgetSize = "widget_size"
    case setting
    case value
    case feature

    /// What values the property may have. Checked for every item that's
    /// queued, and again for everything read back from disk.
    enum Domain: Equatable, Sendable {
        case bool
        case always(Bool)
        case tokens([String])
        /// A pattern for values that aren't from a list, like "0.2.1".
        case pattern(String)
        /// A string or a boolean.
        case tokensOrBool([String])
        /// An ISO 639 language code, like "en".
        case languageCode
    }

    private static let languageCodes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))

    var domain: Domain {
        switch self {
        case .distinctID: .pattern(#"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#)
        case .processPersonProfile: .always(false)
        case .geoipDisable: .always(true)
        case .appVersion: .pattern(#"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#)
        case .build: .pattern(#"^[0-9]{1,9}$"#)
        case .osVersion: .pattern(#"^[0-9]{1,3}\.[0-9]{1,3}$"#)
        case .language: .languageCode
        case .arch: .tokens(Self.names(CPUArch.self))
        case .fullDiskAccess, .menuBarItem, .fellBackToFull: .bool
        case .diskSize: .tokens(Self.names(DiskSizeBucket.self))
        case .scanKind: .tokens(Self.names(ScanKind.self))
        case .duration: .tokens(Self.names(DurationBucket.self))
        case .folderCount, .itemCount: .tokens(Self.names(CountBucket.self))
        case .freed: .tokens(Self.names(SizeBucket.self))
        case .method: .tokens(Self.names(CleanMethod.self))
        case .source: .tokens(Self.names(CleanSource.self))
        case .section: .tokens(Self.names(SuggestionSectionID.self))
        case .widgetSize: .tokens(Self.names(WidgetSize.self))
        case .setting: .tokens(Self.names(TelemetrySetting.self))
        case .value: .tokensOrBool(Self.names(SettingChoice.self))
        case .feature: .tokens(Self.names(TelemetryFeature.self))
        }
    }

    private static func names<T: TelemetryToken>(_: T.Type) -> [String] { T.allCases.map(\.rawValue) }

    func accepts(_ value: TelemetryValue) -> Bool {
        switch (domain, value.stored) {
        case (.bool, .bool), (.tokensOrBool, .bool): true
        case (.always(let expected), .bool(let bool)): bool == expected
        case (.tokens(let names), .string(let string)), (.tokensOrBool(let names), .string(let string)):
            names.contains(string)
        case (.pattern(let pattern), .string(let string)):
            string.range(of: pattern, options: .regularExpression) != nil
        case (.languageCode, .string(let string)):
            Self.languageCodes.contains(string)
        default: false
        }
    }

    /// For Settings: what the property means.
    var explanation: String {
        switch self {
        case .distinctID: "A random identifier made when you opted in. Reset it any time."
        case .processPersonProfile: "Always false: PostHog doesn't build a profile of you."
        case .geoipDisable: "Always true: PostHog doesn't look up a location."
        case .appVersion: "Ballast's version"
        case .build: "Ballast's build number"
        case .osVersion: "macOS version, major and minor only"
        case .arch: "Apple silicon or Intel"
        case .language: "Your language, as a two-letter code"
        case .fullDiskAccess: "Whether Ballast has Full Disk Access"
        case .diskSize: "The startup disk's size, rounded to a common size"
        case .menuBarItem: "Whether the menu bar item is on"
        case .scanKind: "Full scan or update from the change log"
        case .duration: "How long it took, as a range"
        case .folderCount: "Folders measured, as a range"
        case .fellBackToFull: "Whether an update had to become a full scan"
        case .itemCount: "Items cleaned, as a range"
        case .freed: "Size of what was cleaned, as a range"
        case .method: "Moved to the Trash or deleted"
        case .source: "Cleanup List, auto-clean or Shortcuts"
        case .section: "Which Suggestions section"
        case .widgetSize: "Which widget size"
        case .setting: "Which setting"
        case .value: "Its new value, for on/off switches and fixed choices only"
        case .feature: "Which feature"
        }
    }

    /// For Settings: the values it can have, when they're a short list.
    var possibleValues: [String]? {
        switch domain {
        case .bool: ["true", "false"]
        case .always(let value): [String(value)]
        case .tokens(let names): names
        case .tokensOrBool(let names): ["true", "false"] + names
        case .pattern, .languageCode: nil
        }
    }

    /// Sent with every event.
    static let envelope: [TelemetryProperty] = [.distinctID, .processPersonProfile, .geoipDisable]
    static let context: [TelemetryProperty] = [.appVersion, .build, .osVersion, .arch, .language, .fullDiskAccess, .diskSize]
}

// MARK: - Events

/// Every event Ballast can send. An event's properties come only from its
/// case's typed values, so nothing else can be attached.
enum TelemetryEvent: Equatable, Sendable {
    case appOpened(menuBarItem: Bool)
    case scanCompleted(ScanKind, duration: DurationBucket, folders: CountBucket, fellBackToFull: Bool)
    case cleanupCompleted(items: CountBucket, freed: SizeBucket, method: CleanMethod, source: CleanSource)
    case putBackUsed
    case suggestionSectionViewed(SuggestionSectionID)
    case widgetInstalled(WidgetSize)
    case settingChanged(TelemetrySetting, SettingValue?)
    case featureUsed(TelemetryFeature)

    enum Kind: String, CaseIterable, Sendable {
        case appOpened = "app_opened"
        case scanCompleted = "scan_completed"
        case cleanupCompleted = "cleanup_completed"
        case putBackUsed = "put_back_used"
        case suggestionSectionViewed = "suggestion_section_viewed"
        case widgetInstalled = "widget_installed"
        case settingsChanged = "settings_changed"
        case featureUsed = "feature_used"

        /// The properties this event may carry besides the ones every event has.
        var properties: [TelemetryProperty] {
            switch self {
            case .appOpened: [.menuBarItem]
            case .scanCompleted: [.scanKind, .duration, .folderCount, .fellBackToFull]
            case .cleanupCompleted: [.itemCount, .freed, .method, .source]
            case .putBackUsed: []
            case .suggestionSectionViewed: [.section]
            case .widgetInstalled: [.widgetSize]
            case .settingsChanged: [.setting, .value]
            case .featureUsed: [.feature]
            }
        }

        /// For Settings: when it's sent.
        var explanation: String {
            switch self {
            case .appOpened: "Ballast opened."
            case .scanCompleted: "A scan of the startup disk finished."
            case .cleanupCompleted: "A cleanup finished."
            case .putBackUsed: "Put Back moved a cleanup back from the Trash."
            case .suggestionSectionViewed: "A Suggestions section came into view, once per section each time Ballast runs."
            case .widgetInstalled: "A widget size was added to the desktop, once per size."
            case .settingsChanged: "A setting changed."
            case .featureUsed: "A feature was used, once per feature each time Ballast runs."
            }
        }

        var allowed: Set<TelemetryProperty> {
            Set(TelemetryProperty.envelope + TelemetryProperty.context + properties)
        }
    }

    var kind: Kind {
        switch self {
        case .appOpened: .appOpened
        case .scanCompleted: .scanCompleted
        case .cleanupCompleted: .cleanupCompleted
        case .putBackUsed: .putBackUsed
        case .suggestionSectionViewed: .suggestionSectionViewed
        case .widgetInstalled: .widgetInstalled
        case .settingChanged: .settingsChanged
        case .featureUsed: .featureUsed
        }
    }

    var properties: [TelemetryProperty: TelemetryValue] {
        switch self {
        case .appOpened(let menuBarItem):
            [.menuBarItem: .flag(menuBarItem)]
        case .scanCompleted(let kind, let duration, let folders, let fellBack):
            [.scanKind: .token(kind), .duration: .token(duration), .folderCount: .token(folders), .fellBackToFull: .flag(fellBack)]
        case .cleanupCompleted(let items, let freed, let method, let source):
            [.itemCount: .token(items), .freed: .token(freed), .method: .token(method), .source: .token(source)]
        case .putBackUsed:
            [:]
        case .suggestionSectionViewed(let section):
            [.section: .token(section)]
        case .widgetInstalled(let size):
            [.widgetSize: .token(size)]
        case .settingChanged(let setting, let value):
            switch value {
            case .on(let on): [.setting: .token(setting), .value: .flag(on)]
            case .choice(let choice): [.setting: .token(setting), .value: .token(choice)]
            case nil: [.setting: .token(setting)]
            }
        case .featureUsed(let feature):
            [.feature: .token(feature)]
        }
    }

    /// The item as queued and sent: PostHog's batch format.
    func item(distinctID: UUID, context: TelemetryContext, at date: Date = .now, uuid: UUID = UUID()) -> TelemetryItem? {
        var properties: [String: TelemetryValue] = [
            TelemetryProperty.distinctID.rawValue: .text(distinctID.uuidString),
            TelemetryProperty.processPersonProfile.rawValue: .flag(false),
            TelemetryProperty.geoipDisable.rawValue: .flag(true),
        ]
        for (key, value) in context.properties { properties[key.rawValue] = value }
        for (key, value) in self.properties { properties[key.rawValue] = value }
        return TelemetryItem(uuid: uuid, event: kind.rawValue, timestamp: date, properties: properties).sanitized()
    }
}

extension TelemetryEvent {
    /// An auto-clean run that cleaned something; nil for a dry run or one
    /// that cleaned nothing. Rules choose Trash or Delete each, so a run
    /// can be both.
    static func autoClean(_ run: AutoCleanRun, settings: AutoCleanSettings, source: CleanSource) -> TelemetryEvent? {
        guard !run.dryRun, !run.cleaned.isEmpty else { return nil }
        let permanent = Set(run.cleaned.map { settings.rule(for: $0.kind).permanent })
        let method: CleanMethod = permanent.count > 1 ? .mixed : permanent.contains(true) ? .delete : .trash
        return .cleanupCompleted(items: CountBucket(run.cleaned.count), freed: SizeBucket(bytes: run.cleanedBytes),
                                 method: method, source: source)
    }
}

/// What every event says about this copy of Ballast and the Mac.
struct TelemetryContext: Equatable, Sendable {
    var appVersion: String?
    var build: String?
    var osVersion: String
    var arch: CPUArch
    var language: String?
    var fullDiskAccess: Bool
    var diskSize: DiskSizeBucket?

    static func current() -> TelemetryContext {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return TelemetryContext(
            appVersion: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            osVersion: "\(os.majorVersion).\(os.minorVersion)",
            arch: .current,
            language: Locale.current.language.languageCode?.identifier.lowercased(),
            fullDiskAccess: Access.hasFullDiskAccess,
            diskSize: Volume.capacity.map { DiskSizeBucket(bytes: $0.total) }
        )
    }

    var properties: [TelemetryProperty: TelemetryValue] {
        var properties: [TelemetryProperty: TelemetryValue] = [
            .osVersion: .text(osVersion),
            .arch: .token(arch),
            .fullDiskAccess: .flag(fullDiskAccess),
        ]
        if let appVersion { properties[.appVersion] = .text(appVersion) }
        if let build { properties[.build] = .text(build) }
        if let language { properties[.language] = .text(language) }
        if let diskSize { properties[.diskSize] = .token(diskSize) }
        return properties
    }
}

/// One event in PostHog's batch format, as queued on disk and sent.
struct TelemetryItem: Codable, Equatable, Sendable {
    /// Lets PostHog drop a copy if a batch is sent twice.
    let uuid: UUID
    let event: String
    let timestamp: Date
    var properties: [String: TelemetryValue]

    /// Only known events, only the properties that event allows, only
    /// values those properties accept, and always with the envelope. Nil
    /// when the item can't be sent as it is.
    func sanitized() -> TelemetryItem? {
        guard let kind = TelemetryEvent.Kind(rawValue: event) else { return nil }
        let allowed = kind.allowed
        var clean: [String: TelemetryValue] = [:]
        for (key, value) in properties {
            guard let property = TelemetryProperty(rawValue: key), allowed.contains(property), property.accepts(value) else { continue }
            clean[key] = value
        }
        for property in TelemetryProperty.envelope where clean[property.rawValue] == nil { return nil }
        return TelemetryItem(uuid: uuid, event: event, timestamp: timestamp, properties: clean)
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A request body for `POST {host}/batch/`.
struct TelemetryBatch: Encodable {
    let apiKey: String
    let batch: [TelemetryItem]

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case batch
    }

    func encoded() throws -> Data { try TelemetryItem.encoder().encode(self) }
}

// MARK: - Configuration

/// PostHog's project key and host, built into the app by scripts/bundle.sh
/// (from Resources/telemetry.json or POSTHOG_API_KEY and POSTHOG_HOST).
struct TelemetryConfig: Equatable, Sendable {
    let apiKey: String
    let host: URL

    var batchURL: URL { host.appending(path: "batch/") }
}

/// Whether this build can send usage data at all. Without a key it can't,
/// Settings says so, and the prompt never appears.
enum TelemetrySupport: Equatable, Sendable {
    case available(TelemetryConfig)
    case unavailable(Reason)

    enum Reason: Equatable, Sendable {
        case notBundled
        case noKey
        case badHost
    }

    static let keyKey = "BallastTelemetryKey"
    static let hostKey = "BallastTelemetryHost"

    static var current: TelemetrySupport {
        check(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:])
    }

    var config: TelemetryConfig? {
        if case .available(let config) = self { config } else { nil }
    }

    static func check(bundleURL: URL, info: [String: Any]) -> TelemetrySupport {
        guard bundleURL.pathExtension == "app" else { return .unavailable(.notBundled) }
        guard let key = info[keyKey] as? String, isProjectKey(key) else { return .unavailable(.noKey) }
        guard let host = (info[hostKey] as? String).flatMap(hostURL) else { return .unavailable(.badHost) }
        return .available(TelemetryConfig(apiKey: key, host: host))
    }

    /// A PostHog project key: "phc_" and letters, digits, "_" or "-".
    static func isProjectKey(_ key: String) -> Bool {
        key.range(of: #"^phc_[A-Za-z0-9_-]{8,100}$"#, options: .regularExpression) != nil
    }

    /// HTTPS only. Plain HTTP is accepted for this Mac alone (127.0.0.1,
    /// localhost, ::1), which is how a local test server is reached.
    static func hostURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty,
              url.query == nil, url.fragment == nil, url.user == nil
        else { return nil }
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        return url
    }
}

// MARK: - Storage

/// The user's answer and the identifier.
enum TelemetryDecision: String, Codable, Sendable {
    case shared, declined
}

/// telemetry.json (the answer, the identifier, widget sizes already
/// reported) and telemetry-queue.json (events waiting to be sent), in the
/// support folder. Neither exists until the user answers.
final class TelemetryStore: Sendable {
    struct State: Codable, Equatable, Sendable {
        var decision: TelemetryDecision
        var distinctID: UUID?
        var reportedWidgets: [WidgetSize] = []
    }

    static let queueCap = 500
    static let maxAge: TimeInterval = 3 * 86_400

    let directory: String
    private let lock = OSAllocatedUnfairLock()

    init(directory: String = Paths.supportDir) {
        self.directory = directory
    }

    var stateURL: URL { URL(fileURLWithPath: directory + "/telemetry.json") }
    var queueURL: URL { URL(fileURLWithPath: directory + "/telemetry-queue.json") }

    /// Nil until the user has answered.
    func state() -> State? {
        lock.withLockUnchecked { readState() }
    }

    func setState(_ state: State) {
        lock.withLockUnchecked { write(state, to: stateURL) }
    }

    func update(_ change: (inout State) -> Void) {
        lock.withLockUnchecked {
            guard var state = readState() else { return }
            change(&state)
            write(state, to: stateURL)
        }
    }

    /// Queued items, oldest first, without any too old to send.
    func queue(now: Date = .now) -> [TelemetryItem] {
        lock.withLockUnchecked { readQueue(now: now) }
    }

    /// Adds an item, dropping the oldest past the cap.
    func append(_ item: TelemetryItem, now: Date = .now) {
        lock.withLockUnchecked {
            var queue = readQueue(now: now)
            queue.append(item)
            if queue.count > Self.queueCap { queue.removeFirst(queue.count - Self.queueCap) }
            write(queue, to: queueURL, pretty: false)
        }
    }

    /// Takes sent (or refused) items off the queue. Items added meanwhile stay.
    func remove(_ ids: Set<UUID>, now: Date = .now) {
        lock.withLockUnchecked {
            let queue = readQueue(now: now)
            let kept = queue.filter { !ids.contains($0.uuid) }
            if kept.isEmpty {
                try? FileManager.default.removeItem(at: queueURL)
            } else {
                write(kept, to: queueURL, pretty: false)
            }
        }
    }

    func clearQueue() {
        lock.withLockUnchecked { _ = try? FileManager.default.removeItem(at: queueURL) }
    }

    // Unlocked helpers.

    private func readState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// Anything unreadable, unknown or too old is dropped here.
    private func readQueue(now: Date) -> [TelemetryItem] {
        guard let data = try? Data(contentsOf: queueURL),
              let items = try? TelemetryItem.decoder.decode([TelemetryItem].self, from: data)
        else { return [] }
        return items.compactMap { $0.sanitized() }.filter { now.timeIntervalSince($0.timestamp) < Self.maxAge }
    }

    /// The queue is written compactly: it's rewritten on every event, and
    /// Settings pretty-prints it when shown.
    private func write<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? TelemetryItem.encoder(pretty: pretty).encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - Recording

/// Records events while the user shares usage data. The app also sends
/// them; the command-line modes only queue, and the app sends those later.
final class Telemetry: Sendable {
    enum Mode: Sendable {
        case app
        /// `--auto-clean` and friends: never touch the network.
        case commandLine
    }

    static let shared = Telemetry(mode: .app)
    /// For the command-line modes in main.swift.
    static var commandLine: Telemetry { Telemetry(mode: .commandLine) }

    /// Where the definitions live, linked from Settings.
    static let sourceURL = URL(string: "https://github.com/reloadlife/ballast/blob/main/Sources/Ballast/Telemetry.swift")!

    let mode: Mode
    let support: TelemetrySupport
    let store: TelemetryStore
    private let transport: any TelemetryTransport
    private let contextProvider: @Sendable () -> TelemetryContext
    private let sessionState = OSAllocatedUnfairLock<Session>(initialState: Session())

    private struct Session {
        /// Events recorded once per run (sections viewed, features used).
        var once: Set<String> = []
        var uploader: TelemetryUploader?
    }

    init(
        mode: Mode,
        support: TelemetrySupport = .current,
        store: TelemetryStore = TelemetryStore(),
        transport: any TelemetryTransport = URLSessionTransport(),
        context: @escaping @Sendable () -> TelemetryContext = { .current() }
    ) {
        self.mode = mode
        self.support = support
        self.store = store
        self.transport = transport
        contextProvider = context
    }

    var isAvailable: Bool { support.config != nil }

    /// Nil until the user answers.
    var decision: TelemetryDecision? { store.state()?.decision }

    var isSharing: Bool {
        guard isAvailable, let state = store.state() else { return false }
        return state.decision == .shared && state.distinctID != nil
    }

    var distinctID: UUID? { isSharing ? store.state()?.distinctID : nil }

    /// The uploader, once the app has started one. Always nil on the command line.
    var uploader: TelemetryUploader? { sessionState.withLock { $0.uploader } }

    /// Queues an event, only while the user shares usage data. Does nothing
    /// otherwise: no file is read into an event, none is written.
    func record(_ event: TelemetryEvent) {
        guard isAvailable, let state = store.state(), state.decision == .shared, let id = state.distinctID,
              let item = event.item(distinctID: id, context: contextProvider())
        else { return }
        store.append(item)
    }

    /// Records an event the first time it happens while Ballast runs.
    func recordOncePerRun(_ event: TelemetryEvent) {
        guard isSharing else { return }
        let key = "\(event)"
        let first = sessionState.withLock { $0.once.insert(key).inserted }
        if first { record(event) }
    }

    /// A widget size the first time it's seen on the desktop.
    func recordWidgets(_ sizes: Set<WidgetSize>) {
        guard isSharing, let state = store.state() else { return }
        let new = sizes.subtracting(state.reportedWidgets).sorted { $0.rawValue < $1.rawValue }
        guard !new.isEmpty else { return }
        store.update { $0.reportedWidgets = Array(Set($0.reportedWidgets).union(new)).sorted { $0.rawValue < $1.rawValue } }
        for size in new { record(.widgetInstalled(size)) }
    }

    /// Asks WidgetKit which of Ballast's widget sizes are on the desktop.
    func checkWidgets() {
        guard isSharing else { return }
        WidgetCenter.shared.getCurrentConfigurations { [self] result in
            guard case .success(let widgets) = result else { return }
            recordWidgets(Set(widgets.map { WidgetSize($0.family) }))
        }
    }

    // MARK: The user's answer

    /// Share: a new random identifier, then a first send.
    func optIn() {
        guard isAvailable else { return }
        store.setState(.init(decision: .shared, distinctID: UUID()))
        checkWidgets()
        Task { await uploader?.flush(force: true) }
    }

    /// No Thanks, or sharing turned off: the identifier and anything queued
    /// are deleted, and a send in progress is stopped.
    func optOut() {
        let uploader = self.uploader
        Task { await uploader?.cancel() }
        store.setState(.init(decision: .declined, distinctID: nil))
        store.clearQueue()
        sessionState.withLock { $0.once.removeAll() }
    }

    /// A new identifier. Queued events carry the old one, so they go too.
    func resetIdentifier() {
        guard isSharing else { return }
        let uploader = self.uploader
        Task { await uploader?.cancel() }
        store.clearQueue()
        store.update {
            $0.distinctID = UUID()
            $0.reportedWidgets = []
        }
        sessionState.withLock { $0.once.removeAll() }
    }

    /// What's waiting to be sent, exactly as it will be sent.
    func queuedJSON() -> String {
        let items = store.queue()
        guard let data = try? TelemetryItem.encoder(pretty: true).encode(items) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Sending (the app only)

    /// Starts sending every half hour. The command-line modes never do.
    func startUploading(every interval: Duration = .seconds(30 * 60)) {
        guard mode == .app, let config = support.config else { return }
        let uploader = sessionState.withLock { session -> TelemetryUploader? in
            guard session.uploader == nil else { return nil }
            let uploader = TelemetryUploader(store: store, config: config, transport: transport)
            session.uploader = uploader
            return uploader
        }
        guard let uploader else { return }
        Task.detached(priority: .utility) { [weak self] in
            // Events the command line queued since the app last ran go out
            // soon after launch, then every half hour.
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                if self?.isSharing == true { await uploader.flush() }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Sends what's queued now, e.g. at quit, giving up after `timeout`.
    func flush(timeout: Duration? = nil, force: Bool = false) async {
        guard isSharing, let uploader else { return }
        guard let timeout else {
            await uploader.flush(force: force)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await uploader.flush(force: force) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
            await uploader.cancel()
        }
    }

    /// Whether quitting should wait a moment to send.
    var hasPendingUpload: Bool {
        isSharing && uploader != nil && !store.queue().isEmpty
    }
}

// MARK: - Sending

protocol TelemetryTransport: Sendable {
    /// Sends one request; returns the HTTP status.
    func send(_ request: URLRequest) async throws -> Int
}

/// No cookies, no cache, no credentials: a plain HTTPS POST.
struct URLSessionTransport: TelemetryTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await Self.session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// Sends the queue in batches, backing off after failures. Never throws,
/// never blocks the main thread; what can't be sent waits in the queue
/// until it's three days old.
actor TelemetryUploader {
    static let batchSize = 100

    let store: TelemetryStore
    let config: TelemetryConfig
    private let transport: any TelemetryTransport
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var running: Task<Void, Never>?

    init(store: TelemetryStore, config: TelemetryConfig, transport: any TelemetryTransport) {
        self.store = store
        self.config = config
        self.transport = transport
    }

    /// Waits after failures: 1, 2, 4… minutes, up to 6 hours.
    static func backoff(failures: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(failures - 1, 0))), 6 * 3_600)
    }

    func flush(force: Bool = false, now: Date = .now) async {
        if let running {
            await running.value
            return
        }
        guard force || now >= nextAttempt else { return }
        let task = Task { await send() }
        running = task
        await task.value
        running = nil
    }

    /// Stops a send in progress; whatever it hadn't sent stays queued.
    func cancel() {
        running?.cancel()
    }

    private func send() async {
        // HTTPS, or HTTP to this Mac only.
        guard TelemetrySupport.hostURL(config.host.absoluteString) != nil else { return }
        while !Task.isCancelled {
            let items = Array(store.queue().prefix(Self.batchSize))
            guard !items.isEmpty, let body = try? TelemetryBatch(apiKey: config.apiKey, batch: items).encoded() else { return }
            var request = URLRequest(url: config.batchURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Ballast", forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            let status = try? await transport.send(request)
            if Task.isCancelled { return }
            switch status {
            case .some(200..<300):
                failures = 0
                store.remove(Set(items.map(\.uuid)))
            case .some(let code) where (400..<500).contains(code) && code != 408 && code != 429:
                // Refused as malformed: sending it again would only fail again.
                store.remove(Set(items.map(\.uuid)))
            default:
                failures += 1
                nextAttempt = .now.addingTimeInterval(Self.backoff(failures: failures))
                return
            }
        }
    }
}
