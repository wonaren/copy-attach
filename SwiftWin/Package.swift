// swift-tools-version:5.9
// CopyAttach Windows frontend — Swift on Windows (Win32 via the toolchain's
// WinSDK module), calling the Rust backend cdylib through the shared C ABI.
import PackageDescription

let package = Package(
    name: "CopyAttachWin",
    targets: [
        // C FFI declarations for the Rust copy_attach library (shared with macOS).
        .systemLibrary(name: "CCopyAttach"),
        .executableTarget(
            name: "CopyAttachWin",
            dependencies: ["CCopyAttach"],
            linkerSettings: [
                .linkedLibrary("copy_attach"),
                .linkedLibrary("user32"),
                .linkedLibrary("gdi32"),
                .linkedLibrary("shell32"),
                .linkedLibrary("comctl32"),
                .linkedLibrary("advapi32"),
            ]
        )
    ]
)
