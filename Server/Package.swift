// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FSDrive",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FSDriveCore", targets: ["FSDriveCore"]),
        .library(name: "FSDriveClientKit", targets: ["FSDriveClientKit"]),
        .executable(name: "fsdrived", targets: ["fsdrived"]),
        .executable(name: "fsdrive", targets: ["fsdrive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        // The server's self-signed TLS certificate, made on first start.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
    ],
    targets: [
        // Linux has neither CryptoKit nor a guaranteed system SQLite (the static musl
        // build for QNAP has none), so it uses swift-crypto and a vendored SQLite.
        .target(
            name: "CSQLite",
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
            ]
        ),
        // Per-thread file-system identity (Linux), which Swift cannot reach on its own.
        .target(name: "CUserAccess"),
        .target(
            name: "FSDriveCore",
            dependencies: [
                "CUserAccess",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            linkerSettings: [.linkedLibrary("sqlite3", .when(platforms: [.macOS]))]
        ),
        .executableTarget(
            name: "fsdrived",
            dependencies: [
                "FSDriveCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .target(name: "FSDriveClientKit", dependencies: ["FSDriveCore"]),
        .executableTarget(name: "fsdrive", dependencies: ["FSDriveCore", "FSDriveClientKit"]),
        .testTarget(name: "FSDriveCoreTests", dependencies: ["FSDriveCore"]),
    ],
    swiftLanguageModes: [.v5]
)
