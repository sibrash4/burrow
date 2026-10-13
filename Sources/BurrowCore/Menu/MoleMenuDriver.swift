import Foundation

/// One row as seen with the cursor on it.
public struct MenuEntry: Equatable, Sendable {
    public var key: String
    public var row: MenuRow
}

public struct MenuSelectionReport: Equatable, Sendable {
    public var selectedKeys: [String]
    public var totalRows: Int
}

/// Drives Mole's interactive checklist (`mo installer`, `mo purge`) one key at a time.
///
/// Rows are identified by `MenuFrame.cursorKey`, read with the cursor on the row:
/// "name | location" for installers, the full path for purge.
public struct MoleMenuDriver: Sendable {
    public var firstFrameTimeout: TimeInterval
    public var frameTimeout: TimeInterval

    public init(firstFrameTimeout: TimeInterval = 180, frameTimeout: TimeInterval = 8) {
        self.firstFrameTimeout = firstFrameTimeout
        self.frameTimeout = frameTimeout
    }

    /// Makes exactly `wanted` selected, checks it twice, then presses Enter.
    /// On any doubt it sends `q` and throws; Enter is never sent unless the check passes.
    @discardableResult
    public func select(exactly wanted: [String], in session: InteractiveSession) async throws -> MenuSelectionReport {
        let wantedSet = Set(wanted)
        guard !wanted.isEmpty else {
            quit(session)
            throw BurrowError.cancelled
        }
        guard wantedSet.count == wanted.count else {
            quit(session)
            throw BurrowError.selectionMismatch(expected: describe(wanted), actual: "the same row requested twice")
        }
        do {
            let report = try await toggleThenVerify(wanted: wantedSet, in: session)
            try session.send(TerminalKey.enter)
            return report
        } catch {
            quit(session)
            throw error
        }
    }

    /// Walks the whole list top to bottom without changing anything. The cursor ends on the last row.
    public func readAllRows(in session: InteractiveSession) async throws -> [MenuEntry] {
        var frame = try await goToTop(session)
        var entries: [MenuEntry] = []
        let total = frame.totalRows
        for index in 0..<total {
            entries.append(try entry(of: frame))
            if index < total - 1 { frame = try await move(.down, to: index + 1, in: session) }
        }
        return entries
    }

    public func quit(_ session: InteractiveSession) {
        try? session.send(TerminalKey.quit)
    }

    // MARK: - Selection

    private func toggleThenVerify(wanted: Set<String>, in session: InteractiveSession) async throws -> MenuSelectionReport {
        var frame = try await goToTop(session)
        let total = frame.totalRows
        var seen = Set<String>()

        for index in 0..<total {
            let e = try entry(of: frame)
            if !seen.insert(e.key).inserted, wanted.contains(e.key) {
                throw BurrowError.selectionMismatch(expected: describe(wanted), actual: "more than one row named \(e.key)")
            }
            let want = wanted.contains(e.key)
            if e.row.isSelected != want {
                frame = try await toggle(at: index, want: want, from: frame, in: session)
            }
            if index < total - 1 { frame = try await move(.down, to: index + 1, in: session) }
        }

        // Second pass, bottom to top: read every row again and compare with what was asked.
        var selected: [String] = []
        var finalCount = frame.header.selectedCount
        for index in stride(from: total - 1, through: 0, by: -1) {
            let e = try entry(of: frame)
            if e.row.isSelected { selected.append(e.key) }
            finalCount = frame.header.selectedCount
            if index > 0 { frame = try await move(.up, to: index - 1, in: session) }
        }

        guard Set(selected) == wanted, selected.count == wanted.count, finalCount == wanted.count else {
            throw BurrowError.selectionMismatch(
                expected: "\(wanted.count): \(describe(wanted))",
                actual: "\(finalCount) counted, \(selected.count) ticked: \(describe(selected))")
        }
        return MenuSelectionReport(selectedKeys: selected.reversed(), totalRows: total)
    }

    private func toggle(at index: Int, want: Bool, from frame: MenuFrame, in session: InteractiveSession) async throws -> MenuFrame {
        let expectedCount = frame.header.selectedCount + (want ? 1 : -1)
        try session.send(TerminalKey.space)
        do {
            return try await waitMenu(session, timeout: frameTimeout) {
                $0.cursorIndex == index && $0.header.selectedCount == expectedCount && $0.cursorRow?.isSelected == want
            }
        } catch BurrowError.timeout {
            throw BurrowError.selectionMismatch(expected: "row \(index + 1) \(want ? "ticked" : "unticked")",
                                                actual: "Mole did not change it")
        }
    }

    // MARK: - Navigation

    private enum Direction { case up, down }

    private func move(_ direction: Direction, to index: Int, in session: InteractiveSession) async throws -> MenuFrame {
        try session.send(direction == .down ? TerminalKey.down : TerminalKey.up)
        return try await waitMenu(session, timeout: frameTimeout) { $0.cursorIndex == index }
    }

    private func goToTop(_ session: InteractiveSession) async throws -> MenuFrame {
        var frame = try await waitMenu(session, timeout: firstFrameTimeout) { _ in true }
        guard var index = frame.cursorIndex else { throw BurrowError.parseFailed("menu cursor") }
        while index > 0 {
            frame = try await move(.up, to: index - 1, in: session)
            index -= 1
        }
        return frame
    }

    private func entry(of frame: MenuFrame) throws -> MenuEntry {
        guard let row = frame.cursorRow, let key = frame.cursorKey else { throw BurrowError.parseFailed("menu row") }
        return MenuEntry(key: key, row: row)
    }

    private func waitMenu(_ session: InteractiveSession, timeout: TimeInterval,
                          where extra: @escaping @Sendable (MenuFrame) -> Bool) async throws -> MenuFrame {
        let text = try await session.waitForFrame(timeout: timeout) { text in
            guard let frame = MenuFrame.parse(text), frame.isComplete else { return false }
            return extra(frame)
        }
        guard let frame = MenuFrame.parse(text) else { throw BurrowError.parseFailed("menu frame") }
        return frame
    }

    private func describe(_ keys: some Collection<String>) -> String {
        keys.sorted().joined(separator: "; ")
    }
}
