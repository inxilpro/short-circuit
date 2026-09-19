import Foundation

/// Arrow-key movement over a grid laid out in sections, each starting on a fresh row. Up and down
/// keep the column where the next row has one, the way Finder's icon view does, and cross into the
/// neighbouring section rather than stopping at its edge.
struct GridNavigator<ID: Hashable> {
    enum Move {
        case left, right, up, down, first, last
    }

    let sections: [[ID]]
    let columns: Int

    init(sections: [[ID]], columns: Int) {
        self.sections = sections.filter { !$0.isEmpty }
        self.columns = max(1, columns)
    }

    /// How many columns `GridItem(.adaptive(minimum:))` fits into `width`: n tiles and n-1 gaps
    /// must fit, so n ≤ (width + spacing) / (minimum + spacing). `width` is the grid's own width,
    /// inside any padding, or arrow keys move by a different number of tiles than the eye sees.
    static func columnCount(fitting width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        return max(1, Int((width + spacing) / (minimum + spacing)))
    }

    private var flat: [ID] { sections.flatMap { $0 } }

    /// With nothing selected, any move starts at the first item, as in Finder.
    func target(from current: ID?, _ move: Move) -> ID? {
        let flat = flat
        guard !flat.isEmpty else { return nil }
        guard let current, let position = position(of: current) else {
            return move == .last ? flat.last : flat.first
        }

        switch move {
        case .first:
            return flat.first
        case .last:
            return flat.last
        case .left:
            let index = flat.firstIndex(of: current)!
            return flat[max(index - 1, 0)]
        case .right:
            let index = flat.firstIndex(of: current)!
            return flat[min(index + 1, flat.count - 1)]
        case .up:
            return vertical(from: position, step: -1) ?? current
        case .down:
            return vertical(from: position, step: 1) ?? current
        }
    }

    private struct Position {
        var section: Int
        var row: Int
        var column: Int
    }

    private func position(of id: ID) -> Position? {
        for (sectionIndex, section) in sections.enumerated() {
            if let index = section.firstIndex(of: id) {
                return Position(section: sectionIndex, row: index / columns, column: index % columns)
            }
        }
        return nil
    }

    private func rowCount(_ section: Int) -> Int {
        (sections[section].count + columns - 1) / columns
    }

    /// The item in the same column of the adjacent row, or the last item of a shorter row.
    private func item(section: Int, row: Int, column: Int) -> ID {
        let items = sections[section]
        let index = min(row * columns + column, items.count - 1)
        return items[index]
    }

    private func vertical(from position: Position, step: Int) -> ID? {
        let row = position.row + step
        if row >= 0, row < rowCount(position.section) {
            return item(section: position.section, row: row, column: position.column)
        }
        let section = position.section + step
        guard sections.indices.contains(section) else { return nil }
        return item(section: section, row: step > 0 ? 0 : rowCount(section) - 1, column: position.column)
    }
}

/// Finder-style type-to-select: keystrokes typed in quick succession build one prefix.
struct TypeSelectBuffer {
    private(set) var text = ""
    private var lastKey: Date = .distantPast
    var timeout: TimeInterval = 1

    mutating func append(_ characters: String, at now: Date = .now) -> String {
        if now.timeIntervalSince(lastKey) > timeout { text = "" }
        lastKey = now
        text += characters
        return text
    }

    /// The first name starting with the prefix; failing that, the first one that sorts after it,
    /// so a typo still lands nearby.
    static func match<Item>(_ prefix: String, in items: [Item], name: (Item) -> String) -> Item? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let exact = items.first(where: { name($0).range(of: prefix, options: options.union(.anchored)) != nil }) {
            return exact
        }
        return items
            .filter { name($0).localizedStandardCompare(prefix) == .orderedDescending }
            .min { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
}
