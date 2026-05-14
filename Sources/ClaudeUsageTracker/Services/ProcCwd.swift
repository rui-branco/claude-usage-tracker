import Foundation
import Darwin

/// Read a process's current working directory via libproc instead of shelling
/// out to `lsof -p <pid> -Fn`. lsof on macOS opens every file descriptor and
/// resolves vnode paths — it's notoriously heavy and was being spawned per
/// scanned PID on every 5s tick across three services.
///
/// `PROC_PIDVNODEPATHINFO` returns both the executable's vnode and the cwd
/// vnode in a single syscall; we read the cwd field.
enum ProcCwd {
    static func of(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let written = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        // proc_pidinfo returns the number of bytes it filled — anything less
        // than the full struct means we'd be reading uninitialized fields.
        guard written == size else { return nil }

        // Copy the C path tuple out of the parent struct before reading it —
        // taking the address of a nested field while the parent is still in
        // scope trips Swift's exclusive-access checker.
        var pathTuple = info.pvi_cdir.vip_path
        let capacity = MemoryLayout.size(ofValue: pathTuple)
        var path = withUnsafePointer(to: &pathTuple) { tuplePtr -> String in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        // Strip trailing NULs just in case
        while path.last == "\0" { path.removeLast() }
        return path.isEmpty ? nil : path
    }
}
