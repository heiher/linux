/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Atomic operations.
 *
 * Copyright (C) 2020-2022 Loongson Technology Corporation Limited
 */
#ifndef _ASM_ATOMIC_H
#define _ASM_ATOMIC_H

#include <linux/types.h>
#include <asm/barrier.h>
#include <asm/cmpxchg.h>

#ifdef CONFIG_GENERIC_ATOMIC64
#include <asm-generic/atomic64.h>
#endif

#define ATOMIC_INIT(i)	  { (i) }

#define arch_atomic_read(v)	READ_ONCE((v)->counter)
#define arch_atomic_set(v, i)	WRITE_ONCE((v)->counter, (i))

#define ATOMIC_OP(O, B, T)						\
static inline void arch_atomic##B##_##O(T i, atomic##B##_t *v)		\
{									\
	__atomic_fetch_##O(&v->counter, i, __ATOMIC_RELAXED);		\
}

#define ATOMIC_OP_RETURN(O, B, T, M, S)					\
static inline T arch_atomic##B##_##O##_return##S(T i, atomic##B##_t *v)	\
{									\
	return __atomic_##O##_fetch(&v->counter, i, M);			\
}

#define ATOMIC_FETCH_OP(O, B, T, M, S)					\
static inline T arch_atomic##B##_fetch_##O##S(T i, atomic##B##_t *v)	\
{									\
	return __atomic_fetch_##O(&v->counter, i, M);			\
}

/*
 * __ATOMIC_SEQ_CST does not have semantics equivalent to LKMM full
 * ordering. However, LoongArch atomic RMW instructions have ISA-defined
 * ordering semantics that provide the ordering required by LKMM full
 * ordering, so no additional SC barrier is required.
 */
#define ATOMIC_OPS_FETCH(O, B, T)					\
	ATOMIC_OP(O, B, T)						\
	ATOMIC_FETCH_OP(O, B, T, __ATOMIC_SEQ_CST,         )		\
	ATOMIC_FETCH_OP(O, B, T, __ATOMIC_ACQUIRE, _acquire)		\
	ATOMIC_FETCH_OP(O, B, T, __ATOMIC_RELEASE, _release)		\
	ATOMIC_FETCH_OP(O, B, T, __ATOMIC_RELAXED, _relaxed)

#define ATOMIC_OPS_RETURN_FETCH(O, B, T)				\
	ATOMIC_OP(O, B, T)						\
	ATOMIC_OP_RETURN(O, B, T, __ATOMIC_SEQ_CST,         )		\
	ATOMIC_OP_RETURN(O, B, T, __ATOMIC_ACQUIRE, _acquire)		\
	ATOMIC_OP_RETURN(O, B, T, __ATOMIC_RELEASE, _release)		\
	ATOMIC_OP_RETURN(O, B, T, __ATOMIC_RELAXED, _relaxed)		\
	ATOMIC_FETCH_OP(O, B, T, __ATOMIC_SEQ_CST,         )		\
	ATOMIC_FETCH_OP(O, B, T, __ATOMIC_ACQUIRE, _acquire)		\
	ATOMIC_FETCH_OP(O, B, T, __ATOMIC_RELEASE, _release)		\
	ATOMIC_FETCH_OP(O, B, T, __ATOMIC_RELAXED, _relaxed)

ATOMIC_OPS_RETURN_FETCH(add, , int)
ATOMIC_OPS_RETURN_FETCH(sub, , int)

#define arch_atomic_add_return		arch_atomic_add_return
#define arch_atomic_add_return_acquire	arch_atomic_add_return_acquire
#define arch_atomic_add_return_release	arch_atomic_add_return_release
#define arch_atomic_add_return_relaxed	arch_atomic_add_return_relaxed
#define arch_atomic_sub_return		arch_atomic_sub_return
#define arch_atomic_sub_return_acquire	arch_atomic_sub_return_acquire
#define arch_atomic_sub_return_release	arch_atomic_sub_return_release
#define arch_atomic_sub_return_relaxed	arch_atomic_sub_return_relaxed
#define arch_atomic_fetch_add		arch_atomic_fetch_add
#define arch_atomic_fetch_add_acquire	arch_atomic_fetch_add_acquire
#define arch_atomic_fetch_add_release	arch_atomic_fetch_add_release
#define arch_atomic_fetch_add_relaxed	arch_atomic_fetch_add_relaxed
#define arch_atomic_fetch_sub		arch_atomic_fetch_sub
#define arch_atomic_fetch_sub_acquire	arch_atomic_fetch_sub_acquire
#define arch_atomic_fetch_sub_release	arch_atomic_fetch_sub_release
#define arch_atomic_fetch_sub_relaxed	arch_atomic_fetch_sub_relaxed

ATOMIC_OPS_FETCH(and, , int)
ATOMIC_OPS_FETCH(or, , int)
ATOMIC_OPS_FETCH(xor, , int)

#define arch_atomic_fetch_and		arch_atomic_fetch_and
#define arch_atomic_fetch_and_acquire	arch_atomic_fetch_and_acquire
#define arch_atomic_fetch_and_release	arch_atomic_fetch_and_release
#define arch_atomic_fetch_and_relaxed	arch_atomic_fetch_and_relaxed
#define arch_atomic_fetch_or		arch_atomic_fetch_or
#define arch_atomic_fetch_or_acquire	arch_atomic_fetch_or_acquire
#define arch_atomic_fetch_or_release	arch_atomic_fetch_or_release
#define arch_atomic_fetch_or_relaxed	arch_atomic_fetch_or_relaxed
#define arch_atomic_fetch_xor		arch_atomic_fetch_xor
#define arch_atomic_fetch_xor_acquire	arch_atomic_fetch_xor_acquire
#define arch_atomic_fetch_xor_release	arch_atomic_fetch_xor_release
#define arch_atomic_fetch_xor_relaxed	arch_atomic_fetch_xor_relaxed

static inline int arch_atomic_fetch_add_unless(atomic_t *v, int a, int u)
{
       int prev, rc;

	__asm__ __volatile__ (
		"0:	ll.w	%[p],  %[c]\n"
		"	beq	%[p],  %[u], 1f\n"
		"	add.w	%[rc], %[p], %[a]\n"
		"	sc.w	%[rc], %[c]\n"
		"	beqz	%[rc], 0b\n"
		"	b	2f\n"
		"1:\n"
		__WEAK_LLSC_MB
		"2:\n"
		: [p]"=&r" (prev), [rc]"=&r" (rc),
		  [c]"=ZB" (v->counter)
		: [a]"r" (a), [u]"r" (u)
		: "memory");

	return prev;
}
#define arch_atomic_fetch_add_unless arch_atomic_fetch_add_unless

static inline int arch_atomic_sub_if_positive(int i, atomic_t *v)
{
	int result;
	int temp;

	if (__builtin_constant_p(i)) {
		__asm__ __volatile__(
		"1:	ll.w	%1, %2		# atomic_sub_if_positive\n"
		"	addi.w	%0, %1, %3				\n"
		"	move	%1, %0					\n"
		"	bltz	%0, 2f					\n"
		"	sc.w	%1, %2					\n"
		"	beqz	%1, 1b					\n"
		"2:							\n"
		__WEAK_LLSC_MB
		: "=&r" (result), "=&r" (temp), "+ZC" (v->counter)
		: "I" (-i));
	} else {
		__asm__ __volatile__(
		"1:	ll.w	%1, %2		# atomic_sub_if_positive\n"
		"	sub.w	%0, %1, %3				\n"
		"	move	%1, %0					\n"
		"	bltz	%0, 2f					\n"
		"	sc.w	%1, %2					\n"
		"	beqz	%1, 1b					\n"
		"2:							\n"
		__WEAK_LLSC_MB
		: "=&r" (result), "=&r" (temp), "+ZC" (v->counter)
		: "r" (i));
	}

	return result;
}

#define arch_atomic_dec_if_positive(v)	arch_atomic_sub_if_positive(1, v)

#ifdef CONFIG_64BIT

#define ATOMIC64_INIT(i)    { (i) }

#define arch_atomic64_read(v)	READ_ONCE((v)->counter)
#define arch_atomic64_set(v, i)	WRITE_ONCE((v)->counter, (i))

ATOMIC_OPS_RETURN_FETCH(add, 64, long)
ATOMIC_OPS_RETURN_FETCH(sub, 64, long)

#define arch_atomic64_add_return		arch_atomic64_add_return
#define arch_atomic64_add_return_acquire	arch_atomic64_add_return_acquire
#define arch_atomic64_add_return_release	arch_atomic64_add_return_release
#define arch_atomic64_add_return_relaxed	arch_atomic64_add_return_relaxed
#define arch_atomic64_sub_return		arch_atomic64_sub_return
#define arch_atomic64_sub_return_acquire	arch_atomic64_sub_return_acquire
#define arch_atomic64_sub_return_release	arch_atomic64_sub_return_release
#define arch_atomic64_sub_return_relaxed	arch_atomic64_sub_return_relaxed
#define arch_atomic64_fetch_add			arch_atomic64_fetch_add
#define arch_atomic64_fetch_add_acquire		arch_atomic64_fetch_add_acquire
#define arch_atomic64_fetch_add_release		arch_atomic64_fetch_add_release
#define arch_atomic64_fetch_add_relaxed		arch_atomic64_fetch_add_relaxed
#define arch_atomic64_fetch_sub			arch_atomic64_fetch_sub
#define arch_atomic64_fetch_sub_acquire		arch_atomic64_fetch_sub_acquire
#define arch_atomic64_fetch_sub_release		arch_atomic64_fetch_sub_release
#define arch_atomic64_fetch_sub_relaxed		arch_atomic64_fetch_sub_relaxed

ATOMIC_OPS_FETCH(and, 64, long)
ATOMIC_OPS_FETCH(or, 64, long)
ATOMIC_OPS_FETCH(xor, 64, long)

#define arch_atomic64_fetch_and		arch_atomic64_fetch_and
#define arch_atomic64_fetch_and_acquire	arch_atomic64_fetch_and_acquire
#define arch_atomic64_fetch_and_release	arch_atomic64_fetch_and_release
#define arch_atomic64_fetch_and_relaxed	arch_atomic64_fetch_and_relaxed
#define arch_atomic64_fetch_or		arch_atomic64_fetch_or
#define arch_atomic64_fetch_or_acquire	arch_atomic64_fetch_or_acquire
#define arch_atomic64_fetch_or_release	arch_atomic64_fetch_or_release
#define arch_atomic64_fetch_or_relaxed	arch_atomic64_fetch_or_relaxed
#define arch_atomic64_fetch_xor		arch_atomic64_fetch_xor
#define arch_atomic64_fetch_xor_acquire	arch_atomic64_fetch_xor_acquire
#define arch_atomic64_fetch_xor_release	arch_atomic64_fetch_xor_release
#define arch_atomic64_fetch_xor_relaxed	arch_atomic64_fetch_xor_relaxed

static inline long arch_atomic64_fetch_add_unless(atomic64_t *v, long a, long u)
{
       long prev, rc;

	__asm__ __volatile__ (
		"0:	ll.d	%[p],  %[c]\n"
		"	beq	%[p],  %[u], 1f\n"
		"	add.d	%[rc], %[p], %[a]\n"
		"	sc.d	%[rc], %[c]\n"
		"	beqz	%[rc], 0b\n"
		"	b	2f\n"
		"1:\n"
		__WEAK_LLSC_MB
		"2:\n"
		: [p]"=&r" (prev), [rc]"=&r" (rc),
		  [c] "=ZB" (v->counter)
		: [a]"r" (a), [u]"r" (u)
		: "memory");

	return prev;
}
#define arch_atomic64_fetch_add_unless arch_atomic64_fetch_add_unless

static inline long arch_atomic64_sub_if_positive(long i, atomic64_t *v)
{
	long result;
	long temp;

	if (__builtin_constant_p(i)) {
		__asm__ __volatile__(
		"1:	ll.d	%1, %2	# atomic64_sub_if_positive	\n"
		"	addi.d	%0, %1, %3				\n"
		"	move	%1, %0					\n"
		"	bltz	%0, 2f					\n"
		"	sc.d	%1, %2					\n"
		"	beqz	%1, 1b					\n"
		"2:							\n"
		__WEAK_LLSC_MB
		: "=&r" (result), "=&r" (temp), "+ZC" (v->counter)
		: "I" (-i));
	} else {
		__asm__ __volatile__(
		"1:	ll.d	%1, %2	# atomic64_sub_if_positive	\n"
		"	sub.d	%0, %1, %3				\n"
		"	move	%1, %0					\n"
		"	bltz	%0, 2f					\n"
		"	sc.d	%1, %2					\n"
		"	beqz	%1, 1b					\n"
		"2:							\n"
		__WEAK_LLSC_MB
		: "=&r" (result), "=&r" (temp), "+ZC" (v->counter)
		: "r" (i));
	}

	return result;
}

#define arch_atomic64_dec_if_positive(v)	arch_atomic64_sub_if_positive(1, v)

#endif /* CONFIG_64BIT */

#undef ATOMIC_OPS_FETCH
#undef ATOMIC_OPS_RETURN_FETCH
#undef ATOMIC_FETCH_OP
#undef ATOMIC_OP_RETURN
#undef ATOMIC_OP

#endif /* _ASM_ATOMIC_H */
