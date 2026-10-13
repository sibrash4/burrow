import Foundation

public enum ANSI {
    /// Removes ANSI/VT escape sequences and resolves line editing the way a terminal would:
    /// `\r\n` becomes `\n`, a bare `\r` overwrites from the start of the line, and `ESC[K` / `ESC[2K` erase.
    /// Cursor jumps to the top of the screen (`ESC[H`, `ESC[2J`) start a new line if one is in progress.
    public static func strip(_ text: String) -> String {
        var stripper = ANSIStripper()
        _ = stripper.feed(text.unicodeScalars)
        return stripper.text
    }
}

enum VTEvent: Equatable {
    case print(Unicode.Scalar)
    case control(UInt8)
    case csi(params: String, final: Unicode.Scalar)
    case escape(Unicode.Scalar)
}

/// Splits a character stream into printable text, control characters and escape sequences.
struct VTParser {
    private enum State { case ground, escape, csi, string, stringEscape, charset }
    private var state = State.ground
    private var params = ""

    mutating func feed(_ scalar: Unicode.Scalar, _ emit: (VTEvent) -> Void) {
        let value = scalar.value
        switch state {
        case .ground:
            if value == 0x1B { state = .escape }
            else if value < 0x20 || value == 0x7F { emit(.control(UInt8(truncatingIfNeeded: value))) }
            else if value >= 0x80 && value < 0xA0 { return }
            else { emit(.print(scalar)) }
        case .escape:
            switch scalar {
            case "[": state = .csi; params = ""
            case "]", "P", "X", "^", "_": state = .string
            case "(", ")", "*", "+", "#", "%": state = .charset
            case "\u{1B}": break
            default:
                if value < 0x20 { emit(.control(UInt8(value))) } else { state = .ground; emit(.escape(scalar)) }
            }
        case .csi:
            if value >= 0x20 && value <= 0x3F { params.unicodeScalars.append(scalar) }
            else if value >= 0x40 && value <= 0x7E { state = .ground; emit(.csi(params: params, final: scalar)) }
            else if value == 0x1B { state = .escape }
            else if value < 0x20 { emit(.control(UInt8(value))) }
            else { state = .ground }
        case .string:
            if value == 0x07 || value == 0x9C { state = .ground }
            else if value == 0x1B { state = .stringEscape }
        case .stringEscape:
            if scalar == "\\" { state = .ground }
            else { state = .escape; feed(scalar, emit) }
        case .charset:
            state = .ground
        }
    }
}

/// Streaming ANSI stripper that produces plain text lines.
struct ANSIStripper {
    private var parser = VTParser()
    private var line: [Unicode.Scalar] = []
    private var column = 0
    private var done = ""

    /// All completed lines (each ending in `\n`) followed by the line in progress.
    var text: String { done + currentLine }
    var currentLine: String { String(String.UnicodeScalarView(line)) }

    /// Feeds characters and returns the lines completed by them.
    mutating func feed<S: Sequence>(_ scalars: S) -> [String] where S.Element == Unicode.Scalar {
        var completed: [String] = []
        for scalar in scalars {
            var events: [VTEvent] = []
            parser.feed(scalar) { events.append($0) }
            for event in events { handle(event, completed: &completed) }
        }
        return completed
    }

    /// Ends the line in progress, if any, and returns it.
    mutating func flush() -> String? {
        guard !line.isEmpty else { return nil }
        var completed: [String] = []
        finishLine(&completed)
        return completed.first
    }

    private mutating func handle(_ event: VTEvent, completed: inout [String]) {
        switch event {
        case .print(let scalar):
            put(scalar)
        case .control(let byte):
            switch byte {
            case 0x0A, 0x0B, 0x0C: finishLine(&completed)
            case 0x0D: column = 0
            case 0x08: column = max(0, column - 1)
            case 0x09: put("\t")
            default: break
            }
        case .csi(let params, let final):
            switch final {
            case "K": eraseInLine(Int(params) ?? 0)
            case "H", "f": if !line.isEmpty { finishLine(&completed) }
            case "J": if params == "2" || params == "3", !line.isEmpty { finishLine(&completed) }
            default: break
            }
        case .escape:
            break
        }
    }

    private mutating func put(_ scalar: Unicode.Scalar) {
        while line.count < column { line.append(" ") }
        if column < line.count { line[column] = scalar } else { line.append(scalar) }
        column += 1
    }

    private mutating func eraseInLine(_ mode: Int) {
        switch mode {
        case 1:
            for i in 0..<min(column + 1, line.count) { line[i] = " " }
        case 2:
            line.removeAll()
        default:
            if column < line.count { line.removeSubrange(column...) }
        }
    }

    private mutating func finishLine(_ completed: inout [String]) {
        let text = currentLine
        done += text + "\n"
        completed.append(text)
        line.removeAll()
        column = 0
    }
}
