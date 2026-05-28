import CoreFoundation
import Foundation

/// Sends messages to a Hammerspoon `hs.ipc.localPort(name, ...)` over a CFMessagePort.
final class HSMessagePort: @unchecked Sendable {
  private enum LogEvent {
    case none
    case reconnected
    case firstFailure(Int32)
  }

  private let portName: String
  private let lock = NSLock()
  private var remote: CFMessagePort?
  private var lastFailureLogged = false

  init(name: String) {
    self.portName = name
  }

  /// Lazily (re)create the remote port. `CFMessagePortCreateRemote` returns nil when
  /// no process has registered the port; a non-nil result is valid.
  private func ensureRemote() -> CFMessagePort? {
    if let port = remote, CFMessagePortIsValid(port) {
      return port
    }
    let port = CFMessagePortCreateRemote(nil, portName as CFString)
    remote = port
    return port
  }

  /// Forward a datagram's bytes to Hammerspoon.
  func forward(_ data: Data) {
    let event: LogEvent = {
      lock.lock()
      defer { lock.unlock() }

      let status: Int32
      if let port = ensureRemote() {
        status = CFMessagePortSendRequest(
          port,
          0,  // msgid (unused on the Hammerspoon side)
          data as CFData,
          0.25,  // send timeout (s)
          0.0,  // receive timeout (s) -- fire-and-forget, no reply awaited
          nil,  // reply mode: nil => do not wait for a reply
          nil  // return data: nil => discard any reply
        )
      } else {
        status = Int32(kCFMessagePortIsInvalid)
      }

      if status == Int32(kCFMessagePortSuccess) {
        if lastFailureLogged {
          lastFailureLogged = false
          return .reconnected
        }
        return .none
      } else {
        remote = nil  // force recreation on the next send
        if !lastFailureLogged {
          lastFailureLogged = true
          return .firstFailure(status)
        }
        return .none
      }
    }()

    switch event {
    case .none:
      break
    case .reconnected:
      FileHandle.standardError.write(
        Data("hs.ipc port \"\(portName)\" reconnected\n".utf8))
    case .firstFailure(let status):
      FileHandle.standardError.write(
        Data("hs.ipc port \"\(portName)\" send failed (status=\(status))\n".utf8))
    }
  }
}
