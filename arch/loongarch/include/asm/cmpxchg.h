/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Copyright (C) 2020-2022 Loongson Technology Corporation Limited
 */
#ifndef __ASM_CMPXCHG_H
#define __ASM_CMPXCHG_H

#include <linux/bits.h>
#include <linux/build_bug.h>
#include <asm/barrier.h>
#include <asm/cpu-features.h>

#define arch_xchg(ptr, x) __atomic_exchange_n(ptr, x, __ATOMIC_SEQ_CST)

#define arch_cmpxchg_local(ptr, old, new)				\
({									\
       __typeof__(*(ptr)) __res = old;					\
       int mo = __ATOMIC_RELAXED;					\
									\
       __atomic_compare_exchange_n(ptr, &__res, new, 0, mo, mo);	\
									\
       __res;								\
})

#define arch_cmpxchg(ptr, old, new)					\
({									\
       __typeof__(*(ptr)) __res = old;					\
       int mos = __ATOMIC_SEQ_CST;					\
       int mof = __ATOMIC_RELAXED;					\
									\
       __atomic_compare_exchange_n(ptr, &__res, new, 0, mos, mof);	\
									\
       __res;								\
})

#ifdef CONFIG_64BIT
#define arch_cmpxchg64_local(ptr, o, n)					\
  ({									\
	BUILD_BUG_ON(sizeof(*(ptr)) != 8);				\
	arch_cmpxchg_local((ptr), (o), (n));				\
  })

#define arch_cmpxchg64(ptr, o, n)					\
  ({									\
	BUILD_BUG_ON(sizeof(*(ptr)) != 8);				\
	arch_cmpxchg((ptr), (o), (n));					\
  })

#ifdef CONFIG_AS_HAS_SCQ_EXTENSION

union __u128_halves {
	u128 full;
	struct {
		u64 low;
		u64 high;
	};
};

#define system_has_cmpxchg128()	cpu_opt(LOONGARCH_CPU_SCQ)

#define __arch_cmpxchg128(ptr, old, new, llsc_mb)			\
({									\
	union __u128_halves __old, __new, __ret;			\
	volatile u64 *__ptr = (volatile u64 *)(ptr);			\
									\
	__old.full = (old);                                             \
	__new.full = (new);						\
									\
	__asm__ __volatile__(						\
	"1:   ll.d    %0, %3		# 128-bit cmpxchg low	\n"	\
	llsc_mb								\
	"     ld.d    %1, %4		# 128-bit cmpxchg high	\n"	\
	"     move    $t0, %0					\n"	\
	"     move    $t1, %1					\n"	\
	"     bne     %0, %z5, 2f				\n"	\
	"     bne     %1, %z6, 2f				\n"	\
	"     move    $t0, %z7					\n"	\
	"     move    $t1, %z8					\n"	\
	"2:   sc.q    $t0, $t1, %2				\n"	\
	"     beqz    $t0, 1b					\n"	\
	llsc_mb								\
	: "=&r" (__ret.low), "=&r" (__ret.high)				\
	: "r" (__ptr),							\
	  "ZC" (__ptr[0]), "m" (__ptr[1]),				\
	  "Jr" (__old.low), "Jr" (__old.high),				\
	  "Jr" (__new.low), "Jr" (__new.high)				\
	: "t0", "t1", "memory");					\
									\
	__ret.full;							\
})

#define arch_cmpxchg128(ptr, o, n)					\
({									\
	BUILD_BUG_ON(sizeof(*(ptr)) != 16);				\
	__arch_cmpxchg128(ptr, o, n, __WEAK_LLSC_MB);			\
})

#define arch_cmpxchg128_local(ptr, o, n)				\
({									\
	BUILD_BUG_ON(sizeof(*(ptr)) != 16);				\
	__arch_cmpxchg128(ptr, o, n, "");				\
})

#endif /* CONFIG_AS_HAS_SCQ_EXTENSION */

#else
#include <asm-generic/cmpxchg-local.h>
#define arch_cmpxchg64_local(ptr, o, n) __generic_cmpxchg64_local((ptr), (o), (n))
#define arch_cmpxchg64(ptr, o, n) arch_cmpxchg64_local((ptr), (o), (n))
#endif

#endif /* __ASM_CMPXCHG_H */
