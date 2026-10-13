import Foundation

/// Descriptor helpers for code that spawns children. Every descriptor Burrow creates for itself is close-on-exec from
/// the moment it exists, so no child, however it is started, can inherit one. An inherited write end of a capture pipe
/// keeps that pipe open for as long as the child lives, and a reader waiting for end-of-file then waits for the child.
enum FileDescriptors {
    /// A pipe whose two ends both have FD_CLOEXEC. Children that need an end get it through an explicit dup2
    /// (posix_spawn file actions), which gives the copy a clear flag.
    ///
    /// macOS has no pipe2(), so the flag is set right after pipe(). All Burrow spawns use posix_spawn with
    /// POSIX_SPAWN_CLOEXEC_DEFAULT and Foundation.Process passes only 0...2 (both are covered by
    /// FileDescriptorInheritanceTests), so nothing can exec inside that gap.
    static func makeCloexecPipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        setCloexec(fds[0])
        setCloexec(fds[1])
        return (fds[0], fds[1])
    }

    /// Opens a path close-on-exec.
    static func open(_ path: String, _ flags: Int32) -> Int32 {
        Foundation.open(path, flags | O_CLOEXEC)
    }

    static func setCloexec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    static func isCloexec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }
}
