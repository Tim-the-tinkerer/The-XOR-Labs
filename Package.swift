// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TheXORLabs",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "XORLabs", targets: ["XORLabs"]),
        .library(name: "XORCore", targets: ["XORCore"])
    ],
    targets: [
        .executableTarget(name: "XORLabs", dependencies: ["Moire", "ParityPainter", "Crosstalk", "XORCipher"]),
        .target(name: "Moire"),
        .target(name: "ParityPainter"),
        .target(name: "Crosstalk"),
        .target(
            name: "CArgon2",
            path: "Sources/CArgon2",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("phc"),
                .headerSearchPath("phc/blake2"),
            ]
        ),
        .target(
            name: "XORPassCore",
            dependencies: ["CArgon2"],
            path: "Sources/XORPassCore"
        ),
        .target(
            name: "XORCore",
            path: "Sources/XORCore"
        ),
        .target(
            name: "XORCipher",
            dependencies: ["XORCore", "XORPassCore"],
            path: "Sources/XORCipher"
        ),
        .executableTarget(
            name: "XORCipherTestRunner",
            dependencies: ["XORCore"],
            path: "Tests/XORCipherTestRunner"
        ),
        .executableTarget(
            name: "XORPassTestRunner",
            dependencies: ["XORPassCore", "CArgon2"],
            path: "Tests/XORPassTestRunner"
        )
    ]
)
