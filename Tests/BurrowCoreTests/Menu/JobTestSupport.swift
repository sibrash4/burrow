import XCTest
@testable import BurrowCore

func collect(_ stream: AsyncThrowingStream<JobEvent, Error>) async throws -> (lines: [String], result: RunResult?) {
    var lines: [String] = []
    var result: RunResult?
    for try await event in stream {
        switch event {
        case .line(let l): lines.append(l)
        case .finished(let r): result = r
        case .status: break
        }
    }
    return (lines, result)
}
