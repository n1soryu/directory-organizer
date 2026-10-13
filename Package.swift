// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileOrganizer",
    // macOS 27: the on-device model accepts images from this version on (Milestone 3).
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "organize", targets: ["organize"]),
        .executable(name: "make-testdata", targets: ["make-testdata"]),
    ],
    targets: [
        // Pure logic: reading facts, safety checks, rules and planning.
        // Proposes actions only; nothing in here moves or deletes files.
        .target(name: "OrganizerCore"),

        // Builds realistic fake downloads (PDFs, scans, Office files, images...)
        // for the sandbox and for tests, so we never touch the real ~/Downloads.
        .target(name: "TestDataKit", dependencies: ["OrganizerCore"]),

        // Milestone 1 command-line tool: `organize plan <folder>`.
        .executableTarget(name: "organize", dependencies: ["OrganizerCore"]),

        .executableTarget(name: "make-testdata", dependencies: ["TestDataKit"]),

        .testTarget(
            name: "OrganizerCoreTests",
            dependencies: ["OrganizerCore", "TestDataKit"]
        ),
    ]
)
