// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import Darwin

/// A TCP port a process of this user listens on ("who blocks port 3000?").
public struct ListeningPort: Hashable, Sendable {
    public let port: UInt16
    public let identity: ProcessIdentity
    public let processName: String
    /// Reachable only from this Mac (bound to 127.0.0.1 or ::1).
    public let isLoopbackOnly: Bool
}

/// Lists listening TCP sockets with libproc, like `lsof -iTCP -sTCP:LISTEN`
/// but without a subprocess. macOS shows only the user's own processes
/// without administrator rights, which is also all MacHorus may quit.
public enum ListeningPorts {
    public static func read() -> [ListeningPort] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var ports: [ListeningPort] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let sockets = listeningSockets(of: pid)
            guard !sockets.isEmpty, let identity = ProcessInspector.identity(of: pid) else { continue }
            let name = ProcessInspector.name(of: pid)
            // IPv4 and IPv6 sockets on the same port are one entry.
            for (port, loopback) in merge(sockets) {
                ports.append(
                    ListeningPort(port: port, identity: identity, processName: name, isLoopbackOnly: loopback))
            }
        }
        return ports.sorted { ($0.port, $0.identity.pid) < ($1.port, $1.identity.pid) }
    }

    /// One entry per port; loopback-only when every socket on it is.
    static func merge(_ sockets: [(port: UInt16, loopback: Bool)]) -> [(UInt16, Bool)] {
        var byPort: [UInt16: Bool] = [:]
        for socket in sockets { byPort[socket.port] = (byPort[socket.port] ?? true) && socket.loopback }
        return byPort.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private static func listeningSockets(of pid: pid_t) -> [(port: UInt16, loopback: Bool)] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        var result: [(UInt16, Bool)] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            let socket = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_lport))
            result.append((port, isLoopback(socket, family: info.psi.soi_family)))
        }
        return result
    }

    private static func isLoopback(_ socket: in_sockinfo, family: Int32) -> Bool {
        if family == AF_INET {
            return UInt32(bigEndian: socket.insi_laddr.ina_46.i46a_addr4.s_addr) >> 24 == 127
        }
        var address = socket.insi_laddr.ina_6
        var loopback = in6addr_loopback
        return memcmp(&address, &loopback, MemoryLayout<in6_addr>.size) == 0
    }
}
