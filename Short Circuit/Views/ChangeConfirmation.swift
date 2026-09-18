import Foundation

/// Text for the confirmation shown before a write. It lists every call in the approved plan,
/// because that plan is exactly what will run.
enum ChangeConfirmation {
    static func title(for change: KindStore.PendingChange) -> String {
        change.plan.changesBrowser && change.plan.steps.count == 1
            ? "Make \(change.appName) your default browser?"
            : "Open \(change.kindName) with \(change.appName)?"
    }

    static func message(for change: KindStore.PendingChange) -> String {
        let plan = change.plan
        var lines: [String] = []
        if change.isRevised {
            lines.append("Something changed since you last confirmed, so here is the updated list.")
        }
        lines.append(plan.promptCount == 1
                     ? "macOS will ask you to confirm this change:"
                     : "macOS will ask you to confirm each of \(plan.promptCount) changes:")
        for step in plan.steps {
            if step.changesBrowser {
                lines.append("• Default browser — \(step.covers.map(\.displayName).joined(separator: ", "))")
            } else {
                lines.append("• \(step.call.displayName)")
            }
        }
        if plan.changesBrowser {
            lines.append("macOS treats these as your default browser. Each is checked again afterward, since XHTML may not follow.")
        }
        return lines.joined(separator: "\n")
    }
}
