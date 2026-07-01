// Opus configuration for Apple platforms (visionOS/iOS/macOS ARM64)
// Generated for SPM build

#ifndef OPUS_CONFIG_H
#define OPUS_CONFIG_H

// Use floating-point math (ARM64 has excellent FPU)
#define FLOATING_POINT 1
#define OPUS_ENABLE_FLOAT_API 1

// Stack allocation mode — use C99 variable-length arrays
#define VAR_ARRAYS 1

// Standard C library features
#define HAVE_LRINTF 1
#define HAVE_LRINT 1
#define HAVE_STDINT_H 1
#define HAVE_DLFCN_H 1
#define HAVE_MEMORY_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_INTTYPES_H 1
#define STDC_HEADERS 1

// ARM64 NEON optimizations
#if defined(__aarch64__) || defined(__arm64__)
#define OPUS_ARM_PRESUME_AARCH64_NEON_INTR 1
#define OPUS_ARM_PRESUME_NEON_INTR 1
#define OPUS_ARM_PRESUME_NEON 1
#define OPUS_HAVE_RTCD 1
#define OPUS_ARM_MAY_HAVE_NEON_INTR 1
#endif

// x86_64 (Intel Mac): plain portable C, no RTCD. The vendored SSE/AVX
// sources (celt/x86, silk/x86) are excluded from this SPM target's source
// list (see Package.swift), so RTCD must stay off here — otherwise
// cpu_support.h pulls in x86/x86cpu.h expecting opus_select_arch() from
// x86cpu.c, which isn't compiled in, and the link fails.

// Disable features we don't need
// No DRED, no OSCE, no custom modes
// #undef OPUS_ENABLE_DRED
// #undef OPUS_ENABLE_OSCE

// Package version
#define PACKAGE_VERSION "1.5.2"

#endif
