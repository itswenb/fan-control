// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fan-probe", targets: ["FanProbe"]),
        .executable(name: "FanControlHelper", targets: ["FanControlHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/kennss/SiliconScope.git", exact: "4.4.0")
    ],
    targets: [
        .target(name: "FanCore", path: "macs-fan-control/Core"),
        .target(name: "FanHardware", dependencies: ["FanCore", .product(name: "SiliconScopeCore", package: "SiliconScope")], path: "macs-fan-control/Hardware"),
        .executableTarget(name: "FanProbe", dependencies: ["FanCore", "FanHardware"], path: "Tools/FanProbe", linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]),
        .executableTarget(name: "FanControlHelper", dependencies: ["FanCore", "FanHardware"], path: "Helper", linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore", "FanHardware", .product(name: "SiliconScopeCore", package: "SiliconScope")], path: "Tests/FanCoreTests", linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])])
    ]
)
