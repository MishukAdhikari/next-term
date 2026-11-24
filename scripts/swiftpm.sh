# Sourced by the build scripts: the build system SwiftPM uses, named. Swift 6.4 defaults to swiftbuild, which compiles
# SwiftTerm's Metal shader (it needs Xcode's Metal Toolchain, which the Command Line Tools lack) and writes its products
# to .build/out/Products. These scripts read .build/debug and .build/<triple>/release, the layout of the native build
# system, which CI's Swift 6.1 uses by default. Next Term never uses SwiftTerm's Metal renderer, and SwiftTerm compiles
# that shader from source at run time when no metallib is there, so nothing is lost.
SWIFTPM_FLAGS=(--build-system native)
