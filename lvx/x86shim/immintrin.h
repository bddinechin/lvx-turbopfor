// Part of the LVX port of TurboPFor. This repository is GPL-2.0 (see LICENSE);
// so is this file.
//
// TurboPFor reaches its SIMD paths through <immintrin.h>, which does not exist
// for lvx-mbr. SIMDe provides the operations but under its own header names
// (simde/x86/...), so this shim stands in for the x86 header and forwards.
// Put this directory FIRST on the include path and the library's own
// `#include <immintrin.h>' resolves here.
//
// avx2.h transitively pulls sse, sse2, sse3, ssse3 and sse4.1, so one include
// covers every path the library selects. SIMDE_ENABLE_NATIVE_ALIASES, passed
// by the harness, is what makes the plain _mm_ and _mm256_ spellings
// available -- exactly as lvx-ssw does for SSW's SSE2.
//
// The point of the shim is to let ONE source tree be measured through three
// different translation layers -- scalar C that GCC auto-vectorizes, SIMDe's
// 128-bit SSE lowering, and SIMDe's 256-bit AVX2 lowering onto a 128-bit
// machine -- so the layers can be compared rather than assumed.
//
// Line comments deliberately: a block comment here cannot mention the
// intrinsic prefixes without an embedded */ ending it early, which is how the
// first version of this file failed to compile.
#if !defined(LVX_TPF_IMMINTRIN_SHIM)
#define LVX_TPF_IMMINTRIN_SHIM
#include <simde/x86/avx2.h>
#endif
