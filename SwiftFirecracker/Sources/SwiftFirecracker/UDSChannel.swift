import Foundation
import NIOCore
import NIOPosix

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Opens NIO `Channel`s on Unix domain sockets, preserving this package's
/// `sun_path` overflow handling.
///
/// Every AF_UNIX connect in the package funnels through here. NIO's own
/// `SocketAddress(unixDomainSocketPath:)` throws `unixDomainSocketPathTooLong`
/// on the long paths a jailed VM produces (issue #425), and a bootstrap would
/// perform its connect at a moment we do not control — which the
/// `/proc/self/fd` alias cannot survive, because that alias is only valid while
/// its parent-directory fd is open.
///
/// So the connect stays here: synchronous, bounded by ``UnixSocketPath``, with
/// the directory fd held open across exactly the one `connect(2)` that needs
/// it. NIO is then handed an already-connected descriptor and owns it from that
/// point on — which is what removes raw file descriptors from the async paths
/// entirely.
extension TimeAmount {
    /// Saturating conversion from `Duration`.
    ///
    /// Saturates instead of trapping: an already-elapsed deadline yields a
    /// negative `Duration`, and a caller-supplied budget can exceed what
    /// `Int64` nanoseconds can hold. Neither should crash an agent supervising
    /// live VMs, which a plain `Int64(...)` conversion would do.
    static func clamping(_ duration: Duration) -> TimeAmount {
        let parts = duration.components
        guard parts.seconds > 0 || (parts.seconds == 0 && parts.attoseconds > 0) else {
            return .nanoseconds(0)
        }
        let maxWholeSeconds = Int64.max / 1_000_000_000
        guard parts.seconds < maxWholeSeconds else { return .nanoseconds(.max) }
        return .nanoseconds(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
    }

    /// Saturating conversion from a `TimeInterval` in seconds. NaN and negative
    /// values collapse to zero rather than trapping.
    static func clamping(seconds: TimeInterval) -> TimeAmount {
        guard seconds.isFinite, seconds > 0 else { return .nanoseconds(0) }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds < Double(Int64.max) else { return .nanoseconds(.max) }
        return .nanoseconds(Int64(nanoseconds))
    }
}

enum UDSChannel {
    /// The event loop group used when a caller does not supply one.
    ///
    /// NIO's process-wide singleton rather than a group of our own: a group per
    /// `FirecrackerClient` (let alone per VM) would multiply thread pools across
    /// a host running many microVMs.
    static var defaultGroup: EventLoopGroup { MultiThreadedEventLoopGroup.singleton }

    /// Connects to the Unix socket at `path` and wraps the resulting descriptor
    /// in a NIO channel configured by `pipeline`.
    static func connect(
        path: String,
        group: EventLoopGroup,
        pipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let fd = try openUnixStream(to: path)
        // NIO takes ownership of the descriptor it is handed as soon as it
        // constructs the `Channel`, and closes it itself on any later failure
        // (a throwing channel initializer, a failed option, a failed
        // registration). It does *not* close it if `SocketChannel.init` throws.
        // Those two cases are indistinguishable from out here, so closing `fd`
        // on error risks a double `close(2)` — which in a multithreaded process
        // can tear down a descriptor another thread has just been handed.
        //
        // Hand NIO its own duplicate instead: each side then closes only what
        // it owns. The worst case is leaking one descriptor if NIO fails before
        // taking ownership, which is both bounded and far safer than closing
        // someone else's socket.
        let nioFD = dup(fd)
        guard nioFD >= 0 else {
            let failure = errno
            _ = close(fd)
            throw FirecrackerError.connectionFailed(
                "Failed to duplicate Unix socket descriptor: \(failure)")
        }
        defer { _ = close(fd) }

        // Deliberately *not* enabling `allowRemoteHalfClosure`: with it on, a
        // peer that closes (Firecracker resetting a vsock connection the guest
        // is not listening on, or a VMM exiting mid-request) delivers
        // `ChannelEvent.inputClosed` as a user event instead of firing
        // `channelInactive` — and every handler waiting on a reply would hang
        // instead of failing. Neither protocol here needs half-closure.
        return try await ClientBootstrap(group: group)
            .channelInitializer(pipeline)
            .withConnectedSocket(nioFD)
            .get()
    }

    /// Opens a blocking AF_UNIX stream socket connected to `path`, routing
    /// overlong paths through the `/proc/self/fd` alias.
    static func openUnixStream(to path: String) throws -> Int32 {
        #if os(Linux)
        let sock = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard sock >= 0 else {
            throw FirecrackerError.connectionFailed("Failed to create Unix socket: \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)

        let connectable: UnixSocketPath.Connectable
        do {
            connectable = try UnixSocketPath.connectable(path: path, capacity: capacity)
        } catch {
            _ = close(sock)
            throw error
        }
        defer { connectable.closeDirFD() }

        connectable.path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                    // Bounded copy: strncpy never writes past `capacity - 1`,
                    // and `connectable` guarantees the source fits with a NUL.
                    strncpy(dest, ptr, capacity - 1)
                    dest[capacity - 1] = 0
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                #if os(Linux)
                Glibc.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard result == 0 else {
            // Capture errno before close(2), which is free to overwrite it.
            let failure = errno
            _ = close(sock)
            throw FirecrackerError.connectionFailed(
                "Failed to connect to Unix socket \(path): \(failure)")
        }

        // NIO drives the descriptor with a selector, so it must not block.
        let flags = fcntl(sock, F_GETFL)
        if flags >= 0 { _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK) }

        return sock
    }
}
