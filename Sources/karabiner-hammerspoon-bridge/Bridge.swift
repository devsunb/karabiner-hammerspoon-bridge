import Dispatch
import Foundation

@main
struct Bridge {
  static let portName = "karabiner"

  static func main() {
    var mask = sigset_t()
    sigemptyset(&mask)
    sigaddset(&mask, SIGINT)
    sigaddset(&mask, SIGTERM)
    pthread_sigmask(SIG_BLOCK, &mask, nil)

    let sender = HSMessagePort(name: portName)
    let socketPath = KarabinerReceiver.defaultSocketPath()
    let receiver = KarabinerReceiver(
      path: socketPath,
      onPayload: { data in sender.forward(data) },
      onError: { error in
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      }
    )

    Thread.detachNewThread {
      var waitMask = sigset_t()
      sigemptyset(&waitMask)
      sigaddset(&waitMask, SIGINT)
      sigaddset(&waitMask, SIGTERM)
      var sig: Int32 = 0
      if sigwait(&waitMask, &sig) == 0 {
        receiver.stop()
        exit(0)
      }
      FileHandle.standardError.write(Data("fatal: sigwait failed errno=\(errno)\n".utf8))
      exit(1)
    }

    do {
      try receiver.start()
    } catch {
      FileHandle.standardError.write(Data("fatal: socket bind failed: \(error)\n".utf8))
      exit(1)
    }
    FileHandle.standardError.write(
      Data("listening: \(socketPath) -> hs.ipc port \"\(portName)\"\n".utf8))

    dispatchMain()
  }
}
