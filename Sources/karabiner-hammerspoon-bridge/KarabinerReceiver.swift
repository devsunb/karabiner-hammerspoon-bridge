import Darwin
import Foundation

enum KarabinerReceiverError: Error, CustomStringConvertible {
  case sys(String)
  case invalidPath(String)

  var description: String {
    switch self {
    case .sys(let s): return s
    case .invalidPath(let p): return "invalid socket path: \(p)"
    }
  }
}

/// Binds Karabiner-Elements' `user_command_receiver` Unix datagram socket and
/// invokes `onPayload` per-datagram with the raw bytes (trailing CRLF stripped).
final class KarabinerReceiver: @unchecked Sendable {
  static let maxDatagramBytes = 32 * 1024
  static let recvBufferBytes = 128 * 1024

  static func defaultSocketPath() -> String {
    "/Library/Application Support/org.pqrs/tmp/user/\(geteuid())/user_command_receiver.sock"
  }

  private let path: String
  private let onPayload: @Sendable (Data) -> Void
  private let onError: @Sendable (Error) -> Void
  private let stopLock = NSLock()
  private var fd: Int32 = -1
  private var stopRequested = false

  init(
    path: String,
    onPayload: @escaping @Sendable (Data) -> Void,
    onError: @escaping @Sendable (Error) -> Void
  ) {
    self.path = path
    self.onPayload = onPayload
    self.onError = onError
  }

  func start() throws {
    let fd = try bindUnixDatagramSocket(path: path)

    var bufsize = Self.recvBufferBytes
    _ = setsockopt(
      fd, SOL_SOCKET, SO_RCVBUF, &bufsize,
      socklen_t(MemoryLayout.size(ofValue: bufsize)))

    stopLock.lock()
    if stopRequested {
      stopLock.unlock()
      close(fd)
      _ = path.withCString { unlink($0) }
      throw KarabinerReceiverError.sys("stopped before start completed")
    }
    self.fd = fd
    stopLock.unlock()

    let onPayload = self.onPayload
    let onError = self.onError
    let path = self.path
    let isStopRequested: @Sendable () -> Bool = { [weak self] in
      self?.checkStopRequested() ?? true
    }
    DispatchQueue.global(qos: .userInitiated).async {
      receiveLoop(
        fd: fd, path: path, onPayload: onPayload, onError: onError,
        isStopRequested: isStopRequested)
    }
  }

  /// Close the socket and remove its filesystem entry. Idempotent.
  /// Closing the fd wakes the blocked `recvfrom` with `EBADF`, which ends the loop.
  func stop() {
    stopLock.lock()
    stopRequested = true
    let fd = self.fd
    self.fd = -1
    stopLock.unlock()
    if fd >= 0 { close(fd) }
    _ = path.withCString { unlink($0) }
  }

  private func checkStopRequested() -> Bool {
    stopLock.lock()
    defer { stopLock.unlock() }
    return stopRequested
  }
}

private func receiveLoop(
  fd: Int32,
  path: String,
  onPayload: @Sendable (Data) -> Void,
  onError: @Sendable (Error) -> Void,
  isStopRequested: @Sendable () -> Bool
) {
  var buf = [UInt8](repeating: 0, count: KarabinerReceiver.maxDatagramBytes)

  while true {
    // Use recvmsg so we can read msg_flags after the call: on Darwin, MSG_TRUNC
    // is an *output* flag (set in msg_flags when the datagram was larger than
    // the buffer), not a recv flag input. recvfrom() can't surface that.
    let (n, truncated): (ssize_t, Bool) = buf.withUnsafeMutableBufferPointer { bufPtr in
      var iov = iovec(iov_base: bufPtr.baseAddress, iov_len: bufPtr.count)
      return withUnsafeMutablePointer(to: &iov) { iovPtr in
        var msg = msghdr()
        msg.msg_iov = iovPtr
        msg.msg_iovlen = 1
        let n = recvmsg(fd, &msg, 0)
        return (n, (msg.msg_flags & MSG_TRUNC) != 0)
      }
    }
    if n < 0 {
      let e = errno
      if e == EINTR { continue }
      // Terminal: socket is gone or unusable.
      if e == EBADF || e == ENOTSOCK || e == EINVAL {
        if isStopRequested() { break }
        // Socket died without stop() being called. Surface and exit so the supervisor/user notices instead of leaving a deaf process running.
        onError(
          KarabinerReceiverError.sys(
            "receive loop terminated unexpectedly errno=\(e) (\(String(cString: strerror(e)))); exiting"
          ))
        _ = path.withCString { unlink($0) }
        exit(1)
      }
      // Treat anything else as transient and back off so a persistent error (e.g. ENOMEM) doesn't busy-spin stderr.
      onError(
        KarabinerReceiverError.sys("recvmsg failed errno=\(e) (\(String(cString: strerror(e))))"))
      usleep(50_000)
      continue
    }
    if n == 0 { continue }

    if truncated {
      onError(
        KarabinerReceiverError.sys(
          "datagram exceeded \(buf.count)-byte buffer (received \(n) bytes); dropping"))
      continue
    }

    var end = n
    if end > 0 && buf[end - 1] == 0x0A { end -= 1 }
    if end > 0 && buf[end - 1] == 0x0D { end -= 1 }
    if end == 0 { continue }

    onPayload(Data(buf[..<end]))
  }
}

private func bindUnixDatagramSocket(path: String) throws -> Int32 {
  guard !path.isEmpty else {
    throw KarabinerReceiverError.invalidPath(path)
  }

  let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
  if fd < 0 {
    let e = errno
    throw KarabinerReceiverError.sys(
      "socket(dgram) failed errno=\(e) (\(String(cString: strerror(e))))")
  }

  _ = path.withCString { unlink($0) }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
  guard path.utf8CString.count <= maxLen else {
    close(fd)
    throw KarabinerReceiverError.invalidPath(path)
  }
  path.withCString { cstr in
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
      p.withMemoryRebound(to: CChar.self, capacity: maxLen) { buf in
        strncpy(buf, cstr, maxLen - 1)
        buf[maxLen - 1] = 0
      }
    }
  }

  let bindRes: Int32 = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
      bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  if bindRes != 0 {
    let e = errno
    close(fd)
    // The existing socket file (if any) was unlinked above, so a bind failure
    // leaves Karabiner-Elements' session monitor with no socket to send to
    // until Karabiner is restarted. Surface that in the error.
    throw KarabinerReceiverError.sys(
      "bind(dgram) failed errno=\(e) (\(String(cString: strerror(e)))) path=\(path); "
        + "existing socket file was unlinked, so Karabiner-Elements may need "
        + "to be restarted to recreate it")
  }

  // Restrict to owner; don't rely on the process umask.
  _ = path.withCString { chmod($0, 0o600) }

  return fd
}
