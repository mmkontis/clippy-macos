import Foundation
import Combine

/// A project the user can file clipboard media into. Mirrors the
/// `coworker_projects` row but only carries what the dropdown needs.
public struct ClipboardProject: Identifiable, Equatable, Codable {
    public let id: String
    public var name: String
    public var color: String?
    public var assetCount: Int

    public init(id: String, name: String, color: String? = nil, assetCount: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.assetCount = assetCount
    }
}

/// Per-item upload lifecycle, surfaced on the tile as a ring / check / error.
public enum ClipboardSaveState: Equatable {
    case idle
    case uploading(Double) // 0...1
    case saved
    case failed(String)
}

public enum ClipboardProjectsError: LocalizedError {
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Projects aren’t available right now."
        }
    }
}

/// Bridges the UI-only ClipboardKit package to the host app, which owns auth,
/// networking, caching and uploads. The host pushes project state in and
/// implements the side-effect closures; the SwiftUI dropdown observes this.
///
/// Wire it up once at launch (host side):
///
///     ClipboardProjectsHub.shared.onRefresh = { projectsStore.refresh() }
///     ClipboardProjectsHub.shared.onCreateProject = { try await projectsStore.create($0) }
///     ClipboardProjectsHub.shared.onSaveItem = { projectsStore.save($0, to: $1) }
///     ClipboardProjectsHub.shared.setAvailable(true)
@MainActor
public final class ClipboardProjectsHub: ObservableObject {
    public static let shared = ClipboardProjectsHub()

    /// When false (signed-out / not wired), the tile keeps its legacy
    /// image-preview behavior instead of opening the save dropdown.
    @Published public private(set) var isAvailable: Bool = false
    @Published public private(set) var projects: [ClipboardProject] = []
    @Published public private(set) var isLoadingProjects: Bool = false
    @Published public private(set) var lastError: String?
    /// Save/upload state keyed by `ClipboardItem.id`.
    @Published public private(set) var saveStates: [UUID: ClipboardSaveState] = [:]

    // Host-provided side effects.
    public var onRefresh: (() -> Void)?
    public var onCreateProject: ((String) async throws -> ClipboardProject)?
    public var onSaveItem: ((ClipboardItem, ClipboardProject) -> Void)?

    private init() {}

    // MARK: Host → hub state

    public func setAvailable(_ value: Bool) {
        guard isAvailable != value else { return }
        isAvailable = value
        if value { onRefresh?() }
    }

    public func setProjects(_ value: [ClipboardProject]) { projects = value }
    public func setLoadingProjects(_ value: Bool) { isLoadingProjects = value }
    public func setError(_ message: String?) { lastError = message }

    public func upsertProject(_ project: ClipboardProject) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.insert(project, at: 0)
        }
    }

    // MARK: Save state

    public func setSaveState(_ state: ClipboardSaveState, for itemId: UUID) {
        saveStates[itemId] = state
    }

    public func saveState(for itemId: UUID) -> ClipboardSaveState {
        saveStates[itemId] ?? .idle
    }

    public func clearSaveState(for itemId: UUID) {
        saveStates[itemId] = nil
    }

    // MARK: UI → hub actions

    public func refresh() { onRefresh?() }

    public func createProject(name: String) async throws -> ClipboardProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let onCreateProject, !trimmed.isEmpty else {
            throw ClipboardProjectsError.notConfigured
        }
        let project = try await onCreateProject(trimmed)
        upsertProject(project)
        return project
    }

    public func save(_ item: ClipboardItem, to project: ClipboardProject) {
        guard let onSaveItem else { return }
        setSaveState(.uploading(0), for: item.id)
        onSaveItem(item, project)
    }
}
