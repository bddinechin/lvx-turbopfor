// Part of the LVX port of TurboPFor. This repository is GPL-2.0 (see LICENSE);
// so is this file. Written for this repository rather than shared with
// lvx-ssw's equivalent: that one is Apache-2.0 WITH LLVM-exception, whose
// patent and indemnification terms are additional restrictions under GPLv2, so
// it cannot be combined in here.
//
// The freestanding link has no libc -- crt.S supplies _start, write and exit
// and nothing else -- but GCC still emits calls to memcpy and memset for the
// codecs' block moves and buffer clears. These two are all that is missing;
// every buffer in tpf-bench.c is static, so no allocator is needed.
//
// THESE ARE ON THE TIMED PATH, which is why they are not byte loops.
// bitunpack.c calls memcpy inside the unpack routines this benchmark times, so
// a pessimal implementation would be measured as if it were the codec. Copying
// a word at a time when both pointers share alignment is enough to keep the
// shim off the critical path; it is not meant to beat a tuned libc, only to
// avoid being the bottleneck. If one ever shows up in a profile of this
// benchmark, that is the signal to replace it rather than to reinterpret the
// numbers.
#include <stddef.h>
#include <stdint.h>

void *memcpy (void *d, const void *s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;

	/* Word-at-a-time only when both sides agree on alignment; a misaligned
	   pair would need read-modify-shift and is rare enough here not to be
	   worth the code. */
	if (n >= sizeof (uint64_t)
	    && (((uintptr_t) dp ^ (uintptr_t) sp) & (sizeof (uint64_t) - 1)) == 0) {
		while ((uintptr_t) dp & (sizeof (uint64_t) - 1)) {
			if (!n--) return d;
			*dp++ = *sp++;
		}
		while (n >= sizeof (uint64_t)) {
			*(uint64_t *) dp = *(const uint64_t *) sp;
			dp += sizeof (uint64_t); sp += sizeof (uint64_t);
			n -= sizeof (uint64_t);
		}
	}
	while (n--) *dp++ = *sp++;
	return d;
}

void *memset (void *d, int c, size_t n)
{
	unsigned char *dp = d;
	uint64_t w = (unsigned char) c;
	w |= w << 8; w |= w << 16; w |= w << 32;

	if (n >= sizeof (uint64_t)) {
		while ((uintptr_t) dp & (sizeof (uint64_t) - 1)) {
			if (!n--) return d;
			*dp++ = (unsigned char) c;
		}
		while (n >= sizeof (uint64_t)) {
			*(uint64_t *) dp = w;
			dp += sizeof (uint64_t);
			n -= sizeof (uint64_t);
		}
	}
	while (n--) *dp++ = (unsigned char) c;
	return d;
}

/* GCC can emit memmove for an overlapping copy; the codecs do not overlap, but
   providing it costs three lines and an undefined symbol at link time would
   cost a build. */
void *memmove (void *d, const void *s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;
	if (dp == sp || !n) return d;
	if (dp < sp) return memcpy (d, s, n);
	dp += n; sp += n;
	while (n--) *--dp = *--sp;
	return d;
}

/* bitutil.c's FP "razor" helpers (_fprazor32 and friends) call these. This
   benchmark never invokes them -- it packs integers -- but they must resolve
   for the link, and libm would drag in a hosted startup that collides with
   crt.S's _start.
   
   Deliberately TRAPS rather than approximating. A plausible-looking wrong
   round() would make a future FP-codec row quietly incorrect, which on this
   target is the failure mode that reads as a speed-up. Trapping means anyone
   who extends this benchmark to the FP codecs finds out immediately. */
double round (double x)
{
	(void) x;
	__builtin_trap ();
	return 0;
}

float roundf (float x)
{
	(void) x;
	__builtin_trap ();
	return 0;
}
