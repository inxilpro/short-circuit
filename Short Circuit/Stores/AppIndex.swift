import Foundation

/// How one app relates to one Kind, from the app's point of view.
enum AppKindRelation: Int, CaseIterable, Comparable {
    /// Every effective member already opens with the app.
    case defaultFor
    /// Some effective members open with it, others don't.
    case partlyDefault
    /// The app declares the format but isn't its default.
    case canOpen
    /// macOS offers the app only through broad conformance (plain text and the like).
    case offered

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .defaultFor: "Default for"
        case .partlyDefault: "Partly default"
        case .canOpen: "Can open"
        case .offered: "Also offered by macOS"
        }
    }
}

struct AppSummary: Identifiable, Hashable {
    var app: AppRef
    var label: String
    var defaultCount: Int
    /// Kinds the app is default for, partly default for, or explicitly declares.
    var explicitCount: Int
    var offeredCount: Int

    var id: URL { app.url }
}

enum AppSortOrder: String, CaseIterable, Identifiable {
    case name, defaultCount

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .name: "Name"
        case .defaultCount: "Number of Defaults"
        }
    }
}

extension [AppSummary] {
    func sorted(by order: AppSortOrder) -> [AppSummary] {
        sorted { lhs, rhs in
            if order == .defaultCount, lhs.defaultCount != rhs.defaultCount {
                return lhs.defaultCount > rhs.defaultCount
            }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }
}

/// Every app that appears as a candidate anywhere, and how it relates to each Kind. Built once
/// per load, since the Applications view reads it constantly and Kinds number in the hundreds.
struct AppIndex {
    private(set) var summaries: [AppSummary] = []
    private var entries: [URL: [(kindID: Kind.ID, relation: AppKindRelation)]] = [:]

    /// `explicitApps` returns the apps that declare a Kind's format outright. When it's empty for
    /// every Kind the distinction is unknown, and every candidate counts as able to open it.
    init(kinds: [Kind], explicitApps: (Kind) -> Set<URL> = { $0.explicitCandidateURLs }) {
        let explicit = Dictionary(uniqueKeysWithValues: kinds.map { ($0.id, explicitApps($0)) })
        let explicitKnown = explicit.values.contains { !$0.isEmpty }

        var apps: [URL: AppRef] = [:]
        for kind in kinds {
            for app in kind.candidates + kind.members.compactMap(\.defaultApp) where apps[app.url] == nil {
                apps[app.url] = app
            }
            var seen = Set<URL>()
            for app in (kind.members.compactMap(\.defaultApp) + kind.candidates) where seen.insert(app.url).inserted {
                let declared = !explicitKnown || explicit[kind.id]?.contains(app.url) == true
                entries[app.url, default: []].append((kind.id, Self.relation(of: app, to: kind, declared: declared)))
            }
        }

        let labels = AppLabels(Array(apps.values))
        summaries = apps.values.map { app in
            let relations = entries[app.url, default: []].map(\.relation)
            return AppSummary(
                app: app,
                label: labels.label(for: app),
                defaultCount: relations.count { $0 == .defaultFor },
                explicitCount: relations.count { $0 != .offered },
                offeredCount: relations.count { $0 == .offered }
            )
        }
        .sorted(by: .name)
    }

    static func relation(of app: AppRef, to kind: Kind, declared: Bool) -> AppKindRelation {
        let effective = kind.effectiveMembers
        let onApp = effective.count { $0.defaultApp?.url == app.url }
        if !effective.isEmpty, onApp == effective.count { return .defaultFor }
        if onApp > 0 { return .partlyDefault }
        return declared ? .canOpen : .offered
    }

    func relations(for app: URL) -> [(kindID: Kind.ID, relation: AppKindRelation)] {
        entries[app] ?? []
    }
}

/// What "Make default for…" would do for one app across the checked Kinds, computed from the
/// displayed handlers so the footer can say how many prompts to expect before anything runs.
struct AppBatchPlan {
    struct Item: Identifiable {
        var kind: Kind
        /// Effective members the app can take and that aren't on it yet.
        var changing: [KindMember]
        /// Effective members macOS doesn't list the app for; they'll be reported, not attempted.
        var unsupported: [KindMember]

        var id: Kind.ID { kind.id }

        var changingExtensions: [String] {
            changing.flatMap { member -> [String] in
                switch member.target {
                case .scheme(let scheme): return ["\(scheme):"]
                case .fileExtension(let ext): return [".\(ext)"]
                case .uti: return (member.governedExtensions ?? kind.extensions).map { ".\($0)" }
                }
            }
        }
    }

    var app: AppRef
    var items: [Item]
    /// Setter calls macOS will ask about; today that is every call.
    var promptCount: Int
    var changeCount: Int

    init(app: AppRef, kinds: [Kind]) {
        self.app = app
        items = kinds.map { kind in
            let (supported, unsupported) = kind.eligibility(of: kind.effectiveMembers, for: app)
            return Item(
                kind: kind,
                changing: supported.filter { $0.defaultApp?.url != app.url },
                unsupported: unsupported
            )
        }
        // One plan over every target, so shared targets and the browser role are counted once.
        let current = Dictionary(kinds.flatMap(\.members).map { ($0.target, $0.defaultApp?.url) }, uniquingKeysWith: { first, _ in first })
        let targets = items.flatMap { $0.changing.map(\.target) }
        let plan = WritePlan(app: app.url, targets: targets) { current[$0] ?? nil }
        promptCount = plan.promptCount
        changeCount = plan.changeCount
    }
}
