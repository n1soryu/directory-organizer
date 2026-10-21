// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileOrganizer",
    // macOS 27: the on-device model accepts images from this version on (Milestone 3).
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "organize", targets: ["organize"]),
        .executable(name: "make-testdata", targets: ["make-testdata"]),
        .executable(name: "DirectoryOrganizer", targets: ["DirectoryOrganizer"]),
    ],
    dependencies: [
        // On-device models (docs/mlx-plan.md). Pinned exactly: MLX's API moves fast.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.13.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        // Pure logic: reading facts, safety checks, rules and planning.
        // Proposes actions only; nothing in here moves or deletes files.
        .target(name: "OrganizerCore"),

        // The MLX engine: downloads, loads and runs the on-device models.
        // Kept out of OrganizerCore so `swift test` never needs the GPU (it has no Metal shaders);
        // only the app and the CLI link it, and they must be built with xcodebuild.
        .target(
            name: "OrganizerMLX",
            dependencies: [
                "OrganizerCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),

        // Builds realistic fake downloads (PDFs, scans, Office files, images...)
        // for the sandbox and for tests, so we never touch the real ~/Downloads.
        .target(name: "TestDataKit", dependencies: ["OrganizerCore"]),

        // Milestone 1 command-line tool: `organize plan <folder>`.
        .executableTarget(name: "organize", dependencies: ["OrganizerCore", "OrganizerMLX"]),

        .executableTarget(name: "make-testdata", dependencies: ["TestDataKit"]),

        // Milestone 4: the menu-bar app with its dashboard window.
        .executableTarget(name: "DirectoryOrganizer", dependencies: ["OrganizerCore", "OrganizerMLX"]),

        .testTarget(
            name: "OrganizerCoreTests",
            dependencies: ["OrganizerCore", "TestDataKit"]
        ),
    ]
)
