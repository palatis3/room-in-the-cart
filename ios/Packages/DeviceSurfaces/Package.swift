// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DeviceSurfaces", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "DeviceSurfaces", targets: ["DeviceSurfaces"])], targets: [
    .systemLibrary(name: "CDeviceSQLite"),
    .target(name: "DeviceSurfaces", dependencies: ["CDeviceSQLite"]),
    .testTarget(name: "DeviceSurfacesTests", dependencies: ["DeviceSurfaces"])
])
