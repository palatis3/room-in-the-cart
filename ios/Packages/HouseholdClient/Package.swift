// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "HouseholdClient", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "HouseholdClient", targets: ["HouseholdClient"])],
    targets: [.target(name: "HouseholdClient"), .testTarget(name: "HouseholdClientTests", dependencies: ["HouseholdClient"])])
