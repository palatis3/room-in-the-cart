// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RecordArchive", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "RecordArchive", targets: ["RecordArchive"])], dependencies: [.package(path: "../CoreDomain")], targets: [.target(name: "RecordArchive", dependencies: ["CoreDomain"]), .testTarget(name: "RecordArchiveTests", dependencies: ["RecordArchive"], resources: [.copy("Fixtures")])])
