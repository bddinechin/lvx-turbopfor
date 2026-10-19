// Part of the LVX port of TurboPFor. GPL-2.0, as the repository is.
// Shim: see immintrin.h beside it. Every x86 intrinsic header the library
// reaches for forwards to the same SIMDe entry point, because SIMDe's avx2.h
// transitively provides sse through sse4.1 and selecting a narrower header
// here would only risk a missing symbol later.
#if !defined(LVX_TPF_XMMINTRIN_SHIM)
#define LVX_TPF_XMMINTRIN_SHIM
#include <simde/x86/avx2.h>
#endif
