# build-windows.ps1 — CopyAttach Windows build.
#
# Produces build\windows\CopyAttach\ with:
#   CopyAttachWin.exe   Swift-on-Windows frontend (Win32)
#   copy_attach.dll     Rust backend (cdylib, the same code as the macOS dylib)
#
# Prerequisites (Windows x64):
#   1. Rust toolchain, target x86_64-pc-windows-msvc
#        rustup target add x86_64-pc-windows-msvc
#   2. Visual Studio 2022 Build Tools (C++ workload, link.exe on PATH
#      via the "x64 Native Tools" shell or vcvars64)
#   3. Swift 6.x toolchain from swift.org (installs WinSDK module)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File build-windows.ps1
param()
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# ── 1) Rust backend (cdylib → copy_attach.dll + MSVC import lib) ──
cargo build --release --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { exit 1 }
$rustOut = Join-Path $root "target\x86_64-pc-windows-msvc\release"
if (-not (Test-Path "$rustOut\copy_attach.dll")) {
    Write-Error "copy_attach.dll not found at $rustOut"
}

# ── 2) Swift frontend (Win32, statically linked Swift stdlib) ──
Push-Location (Join-Path $root "SwiftWin")
swift build -c release -Xswiftc -static-stdlib -Xlinker "/LIBPATH:$rustOut"
if ($LASTEXITCODE -ne 0) { Pop-Location; exit 1 }
Pop-Location
$swiftBin = Join-Path $root "SwiftWin\.build\release"

# ── 3) Stage the app directory ──
$appDir = Join-Path $root "build\windows\CopyAttach"
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
Copy-Item "$rustOut\copy_attach.dll" $appDir -Force
Copy-Item "$swiftBin\CopyAttachWin.exe" $appDir -Force

# Some toolchains keep a few Foundation/dispatch runtime DLLs dynamic even
# with -static-stdlib; pull them from the toolchain if they are missing.
$swiftExe = (Get-Command swift -ErrorAction SilentlyContinue).Source
if ($swiftExe) {
    $runtimeDir = Join-Path (Split-Path -Parent $swiftExe) "lib\swift\windows"
    foreach ($dll in @("dispatch.dll", "Foundation.dll", "FoundationEssentials.dll", "CFRuntime.dll")) {
        $src = Join-Path $runtimeDir $dll
        if ((-not (Test-Path (Join-Path $appDir $dll))) -and (Test-Path $src)) {
            Copy-Item $src $appDir -Force
        }
    }
}

Write-Host ""
Write-Host "Build complete: $appDir"
Write-Host "Run CopyAttachWin.exe — tray icon appears; Alt+X toggles the history popup."
