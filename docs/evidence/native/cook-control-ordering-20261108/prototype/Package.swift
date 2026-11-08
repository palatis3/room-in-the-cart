// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SpeechControlPrototype",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SpeechControlPrototype", targets: ["SpeechControlPrototype"])],
    targets: [
        .target(name: "SpeechControlPrototype"),
        .testTarget(name: "SpeechControlPrototypeTests", dependencies: ["SpeechControlPrototype"])
    ]
)
