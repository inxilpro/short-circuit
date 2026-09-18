import Foundation

/// Reads real handlers but refuses every change, for runs that look at live data unattended.
nonisolated struct RefusingHandlerWriter: HandlerWriting {
    private let reader = HandlerService()

    func plan(app: AppRef, targets: [KindMember.Target]) async -> WritePlan {
        var current: [KindMember.Target: URL?] = [:]
        for target in targets + WritePlan.browserTargets where current[target] == nil {
            current[target] = await currentHandler(for: target)?.url
        }
        return WritePlan(app: app.url, targets: targets) { current[$0] ?? nil }
    }

    func execute(_ approved: WritePlan) async -> WriteExecution {
        .completed(approved.affectedTargets.map {
            MemberResult(target: $0, outcome: .failed(domain: "ShortCircuit", code: 0, message: "Changes are disabled in this run."))
        })
    }

    func currentHandler(for target: KindMember.Target) async -> AppRef? {
        switch target {
        case .uti(let identifier): reader.defaultApplication(forContentType: identifier)
        case .scheme(let scheme): reader.defaultApplication(forScheme: scheme)
        }
    }
}
