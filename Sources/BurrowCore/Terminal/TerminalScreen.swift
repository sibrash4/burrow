import Foundation

/// A small virtual terminal: applies the cursor, erase and scroll sequences Mole's menus use
/// so `frame()` shows what a person would see on screen, including partial redraws.
struct TerminalScreen {
    typealias Grid = [[Unicode.Scalar]]

    let rows: Int
    let columns: Int
    private var main: Grid
    private var alternate: Grid
    private var onAlternate = false
    private var row = 0
    private var column = 0
    private var saved = (row: 0, column: 0)
    private var parser = VTParser()

    init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        main = Self.blank(rows: self.rows, columns: self.columns)
        alternate = main
    }

    mutating func feed<S: Sequence>(_ scalars: S) where S.Element == Unicode.Scalar {
        for scalar in scalars {
            var events: [VTEvent] = []
            parser.feed(scalar) { events.append($0) }
            for event in events { apply(event) }
        }
    }

    /// Screen text, trailing whitespace trimmed per line, trailing blank lines dropped.
    func frame() -> String {
        var lines = grid.map { cells -> String in
            var end = cells.count
            while end > 0, cells[end - 1] == " " || cells[end - 1] == "\t" { end -= 1 }
            return String(String.UnicodeScalarView(cells[0..<end]))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Events

    private var grid: Grid {
        get { onAlternate ? alternate : main }
        set { if onAlternate { alternate = newValue } else { main = newValue } }
    }

    private mutating func apply(_ event: VTEvent) {
        switch event {
        case .print(let scalar):
            if column >= columns { column = 0; lineFeed() }
            grid[row][column] = scalar
            column += 1
        case .control(let byte):
            switch byte {
            case 0x0A, 0x0B, 0x0C: lineFeed()
            case 0x0D: column = 0
            case 0x08: column = max(0, column - 1)
            case 0x09: column = min(columns - 1, (column / 8 + 1) * 8)
            default: break
            }
        case .csi(let params, let final):
            csi(params, final)
        case .escape(let scalar):
            switch scalar {
            case "7": saved = (row, column)
            case "8": (row, column) = saved
            case "D": lineFeed()
            case "E": column = 0; lineFeed()
            case "M": reverseIndex()
            case "c": clearAll(); row = 0; column = 0
            default: break
            }
        }
    }

    private mutating func csi(_ raw: String, _ final: Unicode.Scalar) {
        let isPrivate = raw.hasPrefix("?")
        let numbers = raw.drop { !$0.isNumber && $0 != ";" }.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        func n(_ index: Int, _ fallback: Int) -> Int {
            guard index < numbers.count, let value = numbers[index], value > 0 else { return fallback }
            return value
        }
        let mode = numbers.first.flatMap { $0 } ?? 0

        if isPrivate {
            guard final == "h" || final == "l", [1049, 1047, 47].contains(mode) else { return }
            switchScreen(toAlternate: final == "h")
            return
        }

        switch final {
        case "A": row = max(0, row - n(0, 1))
        case "B": row = min(rows - 1, row + n(0, 1))
        case "C": column = min(columns - 1, column + n(0, 1))
        case "D": column = max(0, column - n(0, 1))
        case "E": row = min(rows - 1, row + n(0, 1)); column = 0
        case "F": row = max(0, row - n(0, 1)); column = 0
        case "G": column = min(columns - 1, n(0, 1) - 1)
        case "d": row = min(rows - 1, n(0, 1) - 1)
        case "H", "f":
            row = min(rows - 1, n(0, 1) - 1)
            column = min(columns - 1, n(1, 1) - 1)
        case "J": eraseDisplay(mode)
        case "K": eraseLine(mode)
        case "X": erase(row: row, from: column, to: min(columns, column + n(0, 1)))
        case "P": deleteCharacters(n(0, 1))
        case "@": insertCharacters(n(0, 1))
        case "L": for _ in 0..<min(n(0, 1), rows) { insertLine() }
        case "M": for _ in 0..<min(n(0, 1), rows) { deleteLine() }
        case "s": saved = (row, column)
        case "u": (row, column) = saved
        default: break
        }
    }

    // MARK: - Screen operations

    private static func blank(rows: Int, columns: Int) -> Grid {
        Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    private mutating func lineFeed() {
        if row == rows - 1 {
            grid.removeFirst()
            grid.append(Array(repeating: " ", count: columns))
        } else {
            row += 1
        }
    }

    private mutating func reverseIndex() {
        if row == 0 { insertLine() } else { row -= 1 }
    }

    private mutating func insertLine() {
        grid.insert(Array(repeating: " ", count: columns), at: row)
        grid.removeLast()
    }

    private mutating func deleteLine() {
        grid.remove(at: row)
        grid.append(Array(repeating: " ", count: columns))
    }

    private mutating func clearAll() {
        grid = Self.blank(rows: rows, columns: columns)
    }

    private mutating func erase(row: Int, from: Int, to: Int) {
        guard from < to else { return }
        for index in from..<to { grid[row][index] = " " }
    }

    private mutating func eraseLine(_ mode: Int) {
        switch mode {
        case 1: erase(row: row, from: 0, to: column + 1)
        case 2: erase(row: row, from: 0, to: columns)
        default: erase(row: row, from: column, to: columns)
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 1:
            for r in 0..<row { erase(row: r, from: 0, to: columns) }
            erase(row: row, from: 0, to: column + 1)
        case 2, 3:
            clearAll()
        default:
            erase(row: row, from: column, to: columns)
            if row + 1 < rows { for r in (row + 1)..<rows { erase(row: r, from: 0, to: columns) } }
        }
    }

    private mutating func deleteCharacters(_ count: Int) {
        let count = min(count, columns - column)
        grid[row].removeSubrange(column..<(column + count))
        grid[row].append(contentsOf: Array(repeating: " ", count: count))
    }

    private mutating func insertCharacters(_ count: Int) {
        let count = min(count, columns - column)
        grid[row].removeSubrange((columns - count)..<columns)
        grid[row].insert(contentsOf: Array(repeating: " ", count: count), at: column)
    }

    private mutating func switchScreen(toAlternate: Bool) {
        guard toAlternate != onAlternate else { return }
        if toAlternate {
            saved = (row, column)
            onAlternate = true
            clearAll()
            row = 0
            column = 0
        } else {
            onAlternate = false
            (row, column) = saved
        }
    }
}
