// swift-tools-version: 6.0
import PackageDescription

let vendorLib = Context.packageDirectory + "/Vendor/libimagequant/lib"

let package = Package(
    name: "Snap",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .systemLibrary(name: "CImageQuant", path: "Sources/CImageQuant"),
        .executableTarget(
            name: "Snap",
            dependencies: ["CZlib", "CImageQuant"],
            linkerSettings: [
                .unsafeFlags(["-L", vendorLib, "-Xlinker", "-dead_strip"]),
                .linkedLibrary("iconv"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
