# karabiner-hammerspoon-bridge

Forwards Karabiner-Elements `send_user_command` datagrams to Hammerspoon over a CFMessagePort.

```
Karabiner send_user_command --(Unix dgram)--> bridge --(CFMessagePort "karabiner")--> hs.ipc.localPort
```

- Receive half (`KarabinerReceiver.swift`) binds Karabiner's user-command Unix datagram socket directly and forwards each datagram's payload (trailing CRLF stripped).
  This **takes over** the socket: the bridge unlinks any existing socket file on startup before binding its own. If `karabiner_session_monitor` is running, don't run it alongside the bridge.
  This is an inline reimplementation of [`pqrs-org/Karabiner-Elements-user-command-receiver`](https://github.com/pqrs-org/Karabiner-Elements-user-command-receiver) (`KEUserCommandReceiver`); the bridge avoids the SwiftPM dependency and keeps the receiver as a single file.
- Send half is a tiny CFMessagePort client (`HSMessagePort.swift`). Sends are fire-and-forget:
  if Hammerspoon is not running or restarts at runtime, transient sends are dropped and the remote port is recreated on the next send.
  The first send failure after a state change (and the first recovery after that) is logged to stderr.

## Hammerspoon side

```lua
require 'hs.ipc'

if Karabiner then
  Karabiner:delete()
end
Karabiner = hs.ipc.localPort('karabiner', function(_, _, data)
  ...
end)
```

## Build & install

```sh
make install # build -c release, copy binary to ~/.local/bin
```

## Test

With Hammerspoon running and the localPort registered:

```sh
make send-command # sends {"action":"launcher"} to the Karabiner socket
```
