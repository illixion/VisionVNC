// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Opus",

    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1)
    ],

    products: [
        .library(
            name: "Opus",
            type: .static,
            targets: ["Opus"]
        )
    ],

    targets: [
        .target(
            name: "Opus",
            path: ".",
            exclude: [
                // x86-only optimizations
                "celt/x86",
                "silk/x86",
                "silk/fixed",
                "silk/float/x86",

                // ARM assembly, template, and script files
                "celt/arm/celt_pitch_xcorr_arm.s",
                "celt/arm/armopts.s.in",
                "celt/arm/arm2gnu.pl",

                // NE10-dependent ARM files (we don't ship NE10)
                "celt/arm/celt_fft_ne10.c",
                "celt/arm/celt_mdct_ne10.c",

                // DNN/DRED/OSCE (not needed for basic decode)
                "dnn",

                // CELT dump modes tool
                "celt/dump_modes",

                // Files with main() — demos and test programs
                "src/opus_demo.c",
                "src/opus_compare.c",
                "src/repacketizer_demo.c",
                "src/qext_compare.c",
                "celt/opus_custom_demo.c",

                // Build system files
                "CMakeLists.txt",
                "Makefile.am",
                "Makefile.unix",
                "configure.ac",
                "autogen.sh",
                "autogen.bat",
                "meson.build",
                "meson_options.txt",
                "meson",
                "cmake",
                "m4",
                "doc",
                "tests",
                "scripts",
                "training",

                // Metadata
                "README",
                "README.draft",
                "COPYING",
                "AUTHORS",
                "ChangeLog",
                "NEWS",
                "LICENSE_PLEASE_READ.txt",
                "releases.sha2",
                "tar_list.txt",
                "opus.m4",
                "opus.pc.in",
                "opus-uninstalled.pc.in",
                "create_opus_data.sh",
                "update_version",

                // Source list make files
                "celt_sources.mk",
                "celt_headers.mk",
                "silk_sources.mk",
                "silk_headers.mk",
                "opus_sources.mk",
                "opus_headers.mk",
                "lpcnet_sources.mk",
                "lpcnet_headers.mk",

                // Meson build files in subdirectories
                "src/meson.build",
                "include/meson.build",
                "celt/meson.build",
                "celt/arm/meson.build",
                "silk/meson.build",

                // Test directories inside source trees
                "celt/tests",
                "silk/tests",

                // SPM config directory (contains config.h, not C sources)
                "spm-config",
            ],
            sources: ["src", "celt", "silk"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("silk/fixed"),
                .headerSearchPath("spm-config"),
                .define("HAVE_CONFIG_H"),
                .define("OPUS_BUILD"),
            ]
        )
    ]
)
