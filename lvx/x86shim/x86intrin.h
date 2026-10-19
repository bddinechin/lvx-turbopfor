/* Part of the LVX port of TurboPFor. This repository is GPL-2.0 (see LICENSE);
   so is this file.  See immintrin.h beside it for why the shim exists.

   conf.h pulls <x86intrin.h> under __AVX2__ for BMI2's _bzhi_u32 and
   _bextr_u32, so this adds SIMDe's bmi.h on top of the vector headers. */
#if !defined(LVX_TPF_X86INTRIN_SHIM)
#define LVX_TPF_X86INTRIN_SHIM
#include <simde/x86/avx2.h>
#include <simde/x86/bmi.h>
#endif
