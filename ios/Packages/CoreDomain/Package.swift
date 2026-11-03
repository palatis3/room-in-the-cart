// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoreDomain",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "CoreDomain", targets: ["CoreDomain"])],
    targets: [
        .target(name: "CoreDomain"),
        .testTarget(name: "CoreDomainTests", dependencies: ["CoreDomain"])
    ]
)
