// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeteorPaperCraftStudio",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MeteorPaperCraftStudio", targets: ["MeteorPaperCraftStudio"])],
    targets: [.executableTarget(name: "MeteorPaperCraftStudio")]
)
