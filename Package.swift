// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "karabiner-hammerspoon-bridge",
  platforms: [
    .macOS(.v15)
  ],
  targets: [
    .executableTarget(
      name: "karabiner-hammerspoon-bridge"
    )
  ]
)
