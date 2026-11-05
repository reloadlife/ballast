import Foundation

/// How much of something is already on the Cleanup List.
enum PlanMembership: Sendable, Equatable {
    /// None of it.
    case none
    /// Some of its folders.
    case partial
    /// All of it; `removable` is false when it's only there because
    /// something bigger on the list (User caches) cleans it too.
    case all(removable: Bool)
}

/// What the Cleanup List inspector is showing.
enum CleanupPhase: Equatable {
    case working
    case result
    case empty
    case list
}

/// Helpers for Suggestions and the Cleanup List. Computed only: the
/// model's stored state stays in AppModel.swift.
extension AppModel {
    /// Whether cleaning something already on the list also cleans `path`
    /// (it's on the list itself, or inside a folder that is).
    func isPlannedOrCovered(_ path: String) -> Bool {
        isPlanned(path) || plan.contains { Catalog.covers($0.path, action: $0.action, path) }
    }

    /// How much of a set of paths is on the list.
    func membership(of paths: [String]) -> PlanMembership {
        guard !paths.isEmpty else { return .none }
        var direct = 0
        var covered = 0
        for path in paths {
            if isPlanned(path) { direct += 1 } else if isPlannedOrCovered(path) { covered += 1 }
        }
        if direct + covered == paths.count { return .all(removable: direct > 0) }
        return direct + covered == 0 ? .none : .partial
    }

    func membership(of breakdown: AppCacheBreakdown) -> PlanMembership {
        membership(of: breakdown.folders.map(\.path))
    }

    func membership(of location: MediaLocation) -> PlanMembership {
        membership(of: [location.path])
    }

    /// Takes these paths off the list, where they're on it themselves.
    func removeFromPlan(paths: [String]) {
        let remove = Set(paths)
        for item in plan where remove.contains(item.path) {
            removeFromPlan(item)
        }
    }

    /// Whether a cleanup, Put Back or auto-clean is moving files. Reads
    /// `isScanning` too: `isCleaning` alone isn't observed, and both
    /// change together when a run starts or ends.
    var isCleaningObserved: Bool {
        isScanning && isCleaning
    }

    /// Index-based suggestions are on their way: nothing listed yet and
    /// a scan or update is running.
    var isLoadingSuggestions: Bool {
        cleanup.isEmpty && isScanning
    }

    /// Safe suggestions not on the list yet ("Add All Safe Items").
    var hasUnplannedSafeSuggestions: Bool {
        safeSuggestions.contains { !isPlannedOrCovered($0.target.path) }
    }

    /// Adds every safe cache and build folder that isn't on the list yet.
    func addAllSafeSuggestions() {
        for result in safeSuggestions where !isPlannedOrCovered(result.target.path) {
            toggle(result)
        }
    }
}
