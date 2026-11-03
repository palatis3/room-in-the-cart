// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalStore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LocalStore", targets: ["LocalStore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "LocalStore", dependencies: ["CSQLite"]),
        .testTarget(name: "LocalStoreTests", dependencies: ["LocalStore", "CSQLite"])
    ]
)
