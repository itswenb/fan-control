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
        .package(url: "https://github.com/Shakshi3104/DeviceHardware.git", from: "3.7.1"),
        .package(url: "https://github.com/kennss/SiliconScope.git", exact: "4.4.0")
    ],
    targets: [
        .target(name: "FanCore", path: "macs-fan-control/Core"),
        .target(name: "FanHardware", dependencies: ["FanCore", .product(name: "SiliconScopeCore", package: "SiliconScope")], path: "macs-fan-control/Hardware"),
        .target(name: "FanAppModel", dependencies: ["FanCore", "FanHardware", .product(name: "DeviceHardware", package: "DeviceHardware")],
                path: "macs-fan-control",
                exclude: ["Core", "Hardware", "Assets.xcassets", "MyApp.swift", "ContentView.swift", "FanEditorView.swift", "PresetsView.swift", "SettingsView.swift", "GlassStyle.swift", "DebugPreview.swift"],
                sources: ["AppStore.swift", "HelperClient.swift"]),
        .executableTarget(name: "FanProbe", dependencies: ["FanCore", "FanHardware"], path: "Tools/FanProbe", linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]),
        .executableTarget(name: "FanControlHelper", dependencies: ["FanCore", "FanHardware"], path: "Helper", linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore", "FanHardware", .product(name: "SiliconScopeCore", package: "SiliconScope")], path: "Tests/FanCoreTests", linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]),
        .testTarget(name: "FanAppTests", dependencies: ["FanAppModel", "FanCore"], path: "Tests/FanAppTests",
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])])
    ]
)
