import Foundation

/// Reads real handlers but refuses every change, for runs that look at live data unattended.
nonisolated struct RefusingHandlerWriter: HandlerWriting {
    private let reader = HandlerService()

    func apply(
        app: AppRef,
        targets: [KindMember.Target],
        onProgress: @escaping @MainActor @Sendable (WriteProgress) -> Bool
    ) async -> [MemberResult] {
        targets.map {
            MemberResult(target: $0, outcome: .failed(domain: "ShortCircuit", code: 0, message: "Changes are disabled in this run."))
        }
    }

    func currentHandler(for target: KindMember.Target) async -> AppRef? {
        switch target {
        case .uti(let identifier): reader.defaultApplication(forContentType: identifier)
        case .scheme(let scheme): reader.defaultApplication(forScheme: scheme)
        case .fileExtension(let ext):
            reader.defaultApplication(forFilenameExtension: ext)
        }
    }
}
