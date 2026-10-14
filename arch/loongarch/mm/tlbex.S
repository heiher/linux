/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Copyright (C) 2020-2022 Loongson Technology Corporation Limited
 */
#include <asm/asm.h>
#include <asm/loongarch.h>
#include <asm/page.h>
#include <asm/pgtable.h>
#include <asm/regdef.h>
#include <asm/stackframe.h>

#define INVTLB_ADDR_GFALSE_AND_ASID	5

#define PTRS_PER_PGD_BITS	(PAGE_SHIFT - PTRLOG)
#define PTRS_PER_PUD_BITS	(PAGE_SHIFT - PTRLOG)
#define PTRS_PER_PMD_BITS	(PAGE_SHIFT - PTRLOG)
#define PTRS_PER_PTE_BITS	(PAGE_SHIFT - PTRLOG)

#ifdef CONFIG_32BIT
#define PTE_LL	ll.w
#define PTE_SC	sc.w
#else
#define PTE_LL	ll.d
#define PTE_SC	sc.d
#endif

	.macro tlb_do_page_fault, write
	SYM_CODE_START(tlb_do_page_fault_\write)
	UNWIND_HINT_UNDEFINED
	SAVE_ALL
	csrrd		a2, LOONGARCH_CSR_BADV
	move		a0, sp
	REG_S		a2, sp, PT_BVADDR
	li.w		a1, \write
	bl		do_page_fault
	RESTORE_ALL_AND_RET
	SYM_CODE_END(tlb_do_page_fault_\write)
	.endm

	tlb_do_page_fault 0
	tlb_do_page_fault 1

SYM_CODE_START(handle_tlb_protect)
	UNWIND_HINT_UNDEFINED
	BACKUP_T0T1
	SAVE_ALL
	move		a0, sp
	move		a1, zero
	csrrd		a2, LOONGARCH_CSR_BADV
	REG_S		a2, sp, PT_BVADDR
	la_abs		t0, do_page_fault
	jirl		ra, t0, 0
	RESTORE_ALL_AND_RET
SYM_CODE_END(handle_tlb_protect)

SYM_CODE_START(handle_tlb_load)
	UNWIND_HINT_UNDEFINED
	csrwr		t0, EXCEPTION_KS0
	csrwr		t1, EXCEPTION_KS1
	csrwr		ra, EXCEPTION_KS2

	/*
	 * The vmalloc handling is not in the hotpath.
	 */
	csrrd		t0, LOONGARCH_CSR_BADV
	bltz		t0, vmalloc_load
	csrrd		t1, LOONGARCH_CSR_PGDL

vmalloc_done_load:
	/* Get PGD offset in bytes */
#ifdef CONFIG_32BIT
	PTR_BSTRPICK	ra, t0, 31, PGDIR_SHIFT
#else
	PTR_BSTRPICK	ra, t0, PTRS_PER_PGD_BITS + PGDIR_SHIFT - 1, PGDIR_SHIFT
#endif
	PTR_ALSL	t1, ra, t1, _PGD_T_LOG2

#if CONFIG_PGTABLE_LEVELS > 3
	PTR_L		t1, t1, 0
	PTR_BSTRPICK	ra, t0, PTRS_PER_PUD_BITS + PUD_SHIFT - 1, PUD_SHIFT
	PTR_ALSL	t1, ra, t1, _PMD_T_LOG2

#endif
#if CONFIG_PGTABLE_LEVELS > 2
	PTR_L		t1, t1, 0
	PTR_BSTRPICK	ra, t0, PTRS_PER_PMD_BITS + PMD_SHIFT - 1, PMD_SHIFT
	PTR_ALSL	t1, ra, t1, _PMD_T_LOG2

#endif
	PTR_L		ra, t1, 0

	/*
	 * For huge tlb entries, pmde doesn't contain an address but
	 * instead contains the tlb pte. Check the PAGE_HUGE bit and
	 * see if we need to jump to huge tlb processing.
	 */
	PTR_ROTRI	ra, ra, _PAGE_HUGE_SHIFT + 1
	bltz		ra, tlb_huge_update_load

	PTR_ROTRI	ra, ra, BITS_PER_LONG - (_PAGE_HUGE_SHIFT + 1)
	PTR_BSTRPICK	t0, t0, PTRS_PER_PTE_BITS + PAGE_SHIFT - 1, PAGE_SHIFT
	PTR_ALSL	t1, t0, ra, _PTE_T_LOG2

#ifdef CONFIG_SMP
smp_pgtable_change_load:
	PTE_LL		t0, t1, 0
#else
	PTR_L		t0, t1, 0
#endif
	andi		ra, t0, _PAGE_PRESENT
	beqz		ra, nopage_tlb_load

	ori		t0, t0, _PAGE_VALID

#ifdef CONFIG_SMP
	PTE_SC		t0, t1, 0
	beqz		t0, smp_pgtable_change_load
#else
	PTR_S		t0, t1, 0
#endif

	tlbsrch
	PTR_BSTRINS	t1, zero, _PTE_T_LOG2, _PTE_T_LOG2
	PTR_L		t0, t1, 0
	PTR_L		t1, t1, _PTE_T_SIZE
	csrwr		t0, LOONGARCH_CSR_TLBELO0
	csrwr		t1, LOONGARCH_CSR_TLBELO1
	tlbwr

	csrrd		t0, EXCEPTION_KS0
	csrrd		t1, EXCEPTION_KS1
	csrrd		ra, EXCEPTION_KS2
	ertn

vmalloc_load:
	la_abs		t1, swapper_pg_dir
	b		vmalloc_done_load

	/* This is the entry point of a huge page. */
tlb_huge_update_load:
#ifdef CONFIG_SMP
	PTE_LL		ra, t1, 0
#else
	PTR_ROTRI	ra, ra, BITS_PER_LONG - (_PAGE_HUGE_SHIFT + 1)
#endif
	andi		t0, ra, _PAGE_PRESENT
	beqz		t0, nopage_tlb_load

#ifdef CONFIG_SMP
	ori		t0, ra, _PAGE_VALID
	PTE_SC		t0, t1, 0
	beqz		t0, tlb_huge_update_load
	ori		t0, ra, _PAGE_VALID
#else
	ori		t0, ra, _PAGE_VALID
	PTR_S		t0, t1, 0
#endif
	csrrd		ra, LOONGARCH_CSR_ASID
	csrrd		t1, LOONGARCH_CSR_BADV
	andi		ra, ra, CSR_ASID_ASID
	invtlb		INVTLB_ADDR_GFALSE_AND_ASID, ra, t1

	/*
	 * A huge PTE describes an area the size of the
	 * configured huge page size. This is twice the
	 * of the large TLB entry size we intend to use.
	 * A TLB entry half the size of the configured
	 * huge page size is configured into entrylo0
	 * and entrylo1 to cover the contiguous huge PTE
	 * address space.
	 */
	/* Huge page: Move Global bit */
	xori		t0, t0, _PAGE_HUGE
	lu12i.w		t1, _PAGE_HGLOBAL >> 12
	and		t1, t0, t1
	PTR_SRLI	t1, t1, (_PAGE_HGLOBAL_SHIFT - _PAGE_GLOBAL_SHIFT)
	or		t0, t0, t1

	move		ra, t0
	csrwr		ra, LOONGARCH_CSR_TLBELO0

	/* Convert to entrylo1 */
	PTR_ADDI	t1, zero, 1
	PTR_SLLI	t1, t1, (HPAGE_SHIFT - 1)
	PTR_ADD		t0, t0, t1
	csrwr		t0, LOONGARCH_CSR_TLBELO1

	/* Set huge page tlb entry size */
	PTR_LI		t0, (CSR_TLBIDX_PS >> 16) << 16
	PTR_LI		t1, (PS_HUGE_SIZE << (CSR_TLBIDX_PS_SHIFT))
	csrxchg		t1, t0, LOONGARCH_CSR_TLBIDX

	tlbfill

	PTR_LI		t0, (CSR_TLBIDX_PS >> 16) << 16
	PTR_LI		t1, (PS_DEFAULT_SIZE << (CSR_TLBIDX_PS_SHIFT))
	csrxchg		t1, t0, LOONGARCH_CSR_TLBIDX

	csrrd		t0, EXCEPTION_KS0
	csrrd		t1, EXCEPTION_KS1
	csrrd		ra, EXCEPTION_KS2
	ertn

nopage_tlb_load:
	dbar		0x700
	csrrd		ra, EXCEPTION_KS2
	la_abs		t0, tlb_do_page_fault_0
	jr		t0
SYM_CODE_END(handle_tlb_load)

SYM_CODE_START(handle_tlb_load_ptw)
	UNWIND_HINT_UNDEFINED
	csrwr		t0, LOONGARCH_CSR_KS0
	csrwr		t1, LOONGARCH_CSR_KS1
	la_abs		t0, tlb_do_page_fault_0
	jr		t0
SYM_CODE_END(handle_tlb_load_ptw)

SYM_CODE_START(handle_tlb_store)
	UNWIND_HINT_UNDEFINED
	csrwr		t0, EXCEPTION_KS0
	csrwr		t1, EXCEPTION_KS1
	csrwr		ra, EXCEPTION_KS2

	/*
	 * The vmalloc handling is not in the hotpath.
	 */
	csrrd		t0, LOONGARCH_CSR_BADV
	bltz		t0, vmalloc_store
	csrrd		t1, LOONGARCH_CSR_PGDL

vmalloc_done_store:
	/* Get PGD offset in bytes */
#ifdef CONFIG_32BIT
	PTR_BSTRPICK	ra, t0, 31, PGDIR_SHIFT
#else
	PTR_BSTRPICK	ra, t0, PTRS_PER_PGD_BITS + PGDIR_SHIFT - 1, PGDIR_SHIFT
#endif
	PTR_ALSL	t1, ra, t1, _PGD_T_LOG2

#if CONFIG_PGTABLE_LEVELS > 3
	PTR_L		t1, t1, 0
	PTR_BSTRPICK	ra, t0, PTRS_PER_PUD_BITS + PUD_SHIFT - 1, PUD_SHIFT
	PTR_ALSL	t1, ra, t1, _PMD_T_LOG2
#endif
#if CONFIG_PGTABLE_LEVELS > 2
	PTR_L		t1, t1, 0
	PTR_BSTRPICK	ra, t0, PTRS_PER_PMD_BITS + PMD_SHIFT - 1, PMD_SHIFT
	PTR_ALSL	t1, ra, t1, _PMD_T_LOG2
#endif
	PTR_L		ra, t1, 0

	/*
	 * For huge tlb entries, pmde doesn't contain an address but
	 * instead contains the tlb pte. Check the PAGE_HUGE bit and
	 * see if we need to jump to huge tlb processing.
	 */
	PTR_ROTRI	ra, ra, _PAGE_HUGE_SHIFT + 1
	bltz		ra, tlb_huge_update_store

	PTR_ROTRI	ra, ra, BITS_PER_LONG - (_PAGE_HUGE_SHIFT + 1)
	PTR_BSTRPICK	t0, t0, PTRS_PER_PTE_BITS + PAGE_SHIFT - 1, PAGE_SHIFT
	PTR_ALSL	t1, t0, ra, _PTE_T_LOG2

#ifdef CONFIG_SMP
smp_pgtable_change_store:
	PTE_LL		t0, t1, 0
#else
	PTR_L		t0, t1, 0
#endif

#ifdef CONFIG_64BIT
	andi		ra, t0, _PAGE_PRESENT | _PAGE_WRITE
	xori		ra, ra, _PAGE_PRESENT | _PAGE_WRITE
#else
	PTR_LI		ra, _PAGE_PRESENT | _PAGE_WRITE
	and		ra, ra, t0
	nor		ra, ra, zero
#endif
	bnez		ra, nopage_tlb_store

#ifdef CONFIG_64BIT
	ori		t0, t0, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
#else
	PTR_LI		ra, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
	or		t0, ra, t0
#endif

#ifdef CONFIG_SMP
	PTE_SC		t0, t1, 0
	beqz		t0, smp_pgtable_change_store
#else
	PTR_S		t0, t1, 0
#endif
	tlbsrch
	PTR_BSTRINS	t1, zero, _PTE_T_LOG2, _PTE_T_LOG2
	PTR_L		t0, t1, 0
	PTR_L		t1, t1, _PTE_T_SIZE
	csrwr		t0, LOONGARCH_CSR_TLBELO0
	csrwr		t1, LOONGARCH_CSR_TLBELO1
	tlbwr

	csrrd		t0, EXCEPTION_KS0
	csrrd		t1, EXCEPTION_KS1
	csrrd		ra, EXCEPTION_KS2
	ertn

vmalloc_store:
	la_abs		t1, swapper_pg_dir
	b		vmalloc_done_store

	/* This is the entry point of a huge page. */
tlb_huge_update_store:
#ifdef CONFIG_SMP
	PTE_LL		ra, t1, 0
#else
	PTR_ROTRI	ra, ra, BITS_PER_LONG - (_PAGE_HUGE_SHIFT + 1)
#endif

#ifdef CONFIG_64BIT
	andi		t0, ra, _PAGE_PRESENT | _PAGE_WRITE
	xori		t0, t0, _PAGE_PRESENT | _PAGE_WRITE
#else
	PTR_LI		t0, _PAGE_PRESENT | _PAGE_WRITE
	and		t0, t0, ra
	nor		t0, t0, zero
#endif

	bnez		t0, nopage_tlb_store

#ifdef CONFIG_SMP
	ori		t0, ra, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
	PTE_SC		t0, t1, 0
	beqz		t0, tlb_huge_update_store
	ori		t0, ra, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
#else
#ifdef CONFIG_64BIT
	ori		t0, ra, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
#else
	PTR_LI		t0, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
	or		t0, ra, t0
#endif
	PTR_S		t0, t1, 0
#endif
	csrrd		ra, LOONGARCH_CSR_ASID
	csrrd		t1, LOONGARCH_CSR_BADV
	andi		ra, ra, CSR_ASID_ASID
	invtlb		INVTLB_ADDR_GFALSE_AND_ASID, ra, t1

	/*
	 * A huge PTE describes an area the size of the
	 * configured huge page size. This is twice the
	 * of the large TLB entry size we intend to use.
	 * A TLB entry half the size of the configured
	 * huge page size is configured into entrylo0
	 * and entrylo1 to cover the contiguous huge PTE
	 * address space.
	 */
	/* Huge page: Move Global bit */
	xori		t0, t0, _PAGE_HUGE
	lu12i.w		t1, _PAGE_HGLOBAL >> 12
	and		t1, t0, t1
	PTR_SRLI	t1, t1, (_PAGE_HGLOBAL_SHIFT - _PAGE_GLOBAL_SHIFT)
	or		t0, t0, t1

	move		ra, t0
	csrwr		ra, LOONGARCH_CSR_TLBELO0

	/* Convert to entrylo1 */
	PTR_ADDI	t1, zero, 1
	PTR_SLLI	t1, t1, (HPAGE_SHIFT - 1)
	PTR_ADD		t0, t0, t1
	csrwr		t0, LOONGARCH_CSR_TLBELO1

	/* Set huge page tlb entry size */
	PTR_LI		t0, (CSR_TLBIDX_PS >> 16) << 16
	PTR_LI		t1, (PS_HUGE_SIZE << (CSR_TLBIDX_PS_SHIFT))
	csrxchg		t1, t0, LOONGARCH_CSR_TLBIDX

	tlbfill

	/* Reset default page size */
	PTR_LI		t0, (CSR_TLBIDX_PS >> 16) << 16
	PTR_LI		t1, (PS_DEFAULT_SIZE << (CSR_TLBIDX_PS_SHIFT))
	csrxchg		t1, t0, LOONGARCH_CSR_TLBIDX

	csrrd		t0, EXCEPTION_KS0
	csrrd		t1, EXCEPTION_KS1
	csrrd		ra, EXCEPTION_KS2
	ertn

nopage_tlb_store:
	dbar		0x700
	csrrd		ra, EXCEPTION_KS2
	la_abs		t0, tlb_do_page_fault_1
	jr		t0
SYM_CODE_END(handle_tlb_store)

SYM_CODE_START(handle_tlb_store_ptw)
	UNWIND_HINT_UNDEFINED
	csrwr		t0, LOONGARCH_CSR_KS0
	csrwr		t1, LOONGARCH_CSR_KS1
	la_abs		t0, tlb_do_page_fault_1
	jr		t0
SYM_CODE_END(handle_tlb_store_ptw)

SYM_CODE_START(handle_tlb_modify)
	UNWIND_HINT_UNDEFINED
	csrwr		t0, EXCEPTION_KS0
	csrwr		t1, EXCEPTION_KS1
	csrwr		ra, EXCEPTION_KS2

	/*
	 * The vmalloc handling is not in the hotpath.
	 */
	csrrd		t0, LOONGARCH_CSR_BADV
	bltz		t0, vmalloc_modify
	csrrd		t1, LOONGARCH_CSR_PGDL

vmalloc_done_modify:
	/* Get PGD offset in bytes */
#ifdef CONFIG_32BIT
	PTR_BSTRPICK	ra, t0, 31, PGDIR_SHIFT
#else
	PTR_BSTRPICK	ra, t0, PTRS_PER_PGD_BITS + PGDIR_SHIFT - 1, PGDIR_SHIFT
#endif
	PTR_ALSL	t1, ra, t1, _PGD_T_LOG2

#if CONFIG_PGTABLE_LEVELS > 3
	PTR_L		t1, t1, 0
	PTR_BSTRPICK	ra, t0, PTRS_PER_PUD_BITS + PUD_SHIFT - 1, PUD_SHIFT
	PTR_ALSL	t1, ra, t1, _PMD_T_LOG2
#endif
#if CONFIG_PGTABLE_LEVELS > 2
	PTR_L		t1, t1, 0
	PTR_BSTRPICK	ra, t0, PTRS_PER_PMD_BITS + PMD_SHIFT - 1, PMD_SHIFT
	PTR_ALSL	t1, ra, t1, _PMD_T_LOG2
#endif
	PTR_L		ra, t1, 0

	/*
	 * For huge tlb entries, pmde doesn't contain an address but
	 * instead contains the tlb pte. Check the PAGE_HUGE bit and
	 * see if we need to jump to huge tlb processing.
	 */
	PTR_ROTRI	ra, ra, _PAGE_HUGE_SHIFT + 1
	bltz		ra, tlb_huge_update_modify

	PTR_ROTRI	ra, ra, BITS_PER_LONG - (_PAGE_HUGE_SHIFT + 1)
	PTR_BSTRPICK	t0, t0, PTRS_PER_PTE_BITS + PAGE_SHIFT - 1, PAGE_SHIFT
	PTR_ALSL	t1, t0, ra, _PTE_T_LOG2

#ifdef CONFIG_SMP
smp_pgtable_change_modify:
	PTE_LL		t0, t1, 0
#else
	PTR_L		t0, t1, 0
#endif
#ifdef CONFIG_64BIT
	andi		ra, t0, _PAGE_WRITE
#else
	PTR_LI		ra, _PAGE_WRITE
	and 		ra, t0, ra
#endif

	beqz		ra, nopage_tlb_modify

#ifdef CONFIG_64BIT
	ori		t0, t0, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
#else
	PTR_LI		ra, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
	or		t0, ra, t0
#endif

#ifdef CONFIG_SMP
	PTE_SC		t0, t1, 0
	beqz		t0, smp_pgtable_change_modify
#else
	PTR_S		t0, t1, 0
#endif
	tlbsrch
	PTR_BSTRINS	t1, zero, _PTE_T_LOG2, _PTE_T_LOG2
	PTR_L		t0, t1, 0
	PTR_L		t1, t1, _PTE_T_SIZE
	csrwr		t0, LOONGARCH_CSR_TLBELO0
	csrwr		t1, LOONGARCH_CSR_TLBELO1
	tlbwr

	csrrd		t0, EXCEPTION_KS0
	csrrd		t1, EXCEPTION_KS1
	csrrd		ra, EXCEPTION_KS2
	ertn

vmalloc_modify:
	la_abs		t1, swapper_pg_dir
	b		vmalloc_done_modify

	/* This is the entry point of a huge page. */
tlb_huge_update_modify:
#ifdef CONFIG_SMP
	PTE_LL		ra, t1, 0
#else
	PTR_ROTRI	ra, ra, BITS_PER_LONG - (_PAGE_HUGE_SHIFT + 1)
#endif

#ifdef CONFIG_64BIT
	andi		t0, ra, _PAGE_WRITE
#else
	PTR_LI		t0, _PAGE_WRITE
	and 		t0, ra, t0
#endif

	beqz		t0, nopage_tlb_modify

#ifdef CONFIG_SMP
	ori		t0, ra, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
	PTE_SC		t0, t1, 0
	beqz		t0, tlb_huge_update_modify
	ori		t0, ra, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
#else
#ifdef CONFIG_64BIT
	ori		t0, ra, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
#else
	PTR_LI		t0, (_PAGE_VALID | _PAGE_DIRTY | _PAGE_MODIFIED)
	or		t0, ra, t0
#endif
	PTR_S		t0, t1, 0
#endif
	csrrd		ra, LOONGARCH_CSR_ASID
	csrrd		t1, LOONGARCH_CSR_BADV
	andi		ra, ra, CSR_ASID_ASID
	invtlb		INVTLB_ADDR_GFALSE_AND_ASID, ra, t1

	/*
	 * A huge PTE describes an area the size of the
	 * configured huge page size. This is twice the
	 * of the large TLB entry size we intend to use.
	 * A TLB entry half the size of the configured
	 * huge page size is configured into entrylo0
	 * and entrylo1 to cover the contiguous huge PTE
	 * address space.
	 */
	/* Huge page: Move Global bit */
	xori		t0, t0, _PAGE_HUGE
	lu12i.w		t1, _PAGE_HGLOBAL >> 12
	and		t1, t0, t1
	PTR_SRLI	t1, t1, (_PAGE_HGLOBAL_SHIFT - _PAGE_GLOBAL_SHIFT)
	or		t0, t0, t1

	move		ra, t0
	csrwr		ra, LOONGARCH_CSR_TLBELO0

	/* Convert to entrylo1 */
	PTR_ADDI	t1, zero, 1
	PTR_SLLI	t1, t1, (HPAGE_SHIFT - 1)
	PTR_ADD		t0, t0, t1
	csrwr		t0, LOONGARCH_CSR_TLBELO1

	/* Set huge page tlb entry size */
	PTR_LI		t0, (CSR_TLBIDX_PS >> 16) << 16
	PTR_LI		t1, (PS_HUGE_SIZE << (CSR_TLBIDX_PS_SHIFT))
	csrxchg		t1, t0, LOONGARCH_CSR_TLBIDX

	tlbfill

	/* Reset default page size */
	PTR_LI		t0, (CSR_TLBIDX_PS >> 16) << 16
	PTR_LI		t1, (PS_DEFAULT_SIZE << (CSR_TLBIDX_PS_SHIFT))
	csrxchg		t1, t0, LOONGARCH_CSR_TLBIDX

	csrrd		t0, EXCEPTION_KS0
	csrrd		t1, EXCEPTION_KS1
	csrrd		ra, EXCEPTION_KS2
	ertn

nopage_tlb_modify:
	dbar		0x700
	csrrd		ra, EXCEPTION_KS2
	la_abs		t0, tlb_do_page_fault_1
	jr		t0
SYM_CODE_END(handle_tlb_modify)

SYM_CODE_START(handle_tlb_modify_ptw)
	UNWIND_HINT_UNDEFINED
	csrwr		t0, LOONGARCH_CSR_KS0
	csrwr		t1, LOONGARCH_CSR_KS1
	la_abs		t0, tlb_do_page_fault_1
	jr		t0
SYM_CODE_END(handle_tlb_modify_ptw)

#ifdef CONFIG_32BIT
SYM_CODE_START(handle_tlb_refill)
	UNWIND_HINT_UNDEFINED
	csrwr		t0, EXCEPTION_KS0
	csrwr		t1, EXCEPTION_KS1
	csrwr		ra, EXCEPTION_KS2
	li.w		ra, 0x1fffffff

	csrrd		t0, LOONGARCH_CSR_PGD
	csrrd		t1, LOONGARCH_CSR_TLBRBADV
	srli.w		t1, t1, PGDIR_SHIFT
	slli.w		t1, t1, 0x2
	add.w		t0, t0, t1
	and		t0, t0, ra

	ld.w		t0, t0, 0
	csrrd		t1, LOONGARCH_CSR_TLBRBADV
	slli.w		t1, t1, (32 - PGDIR_SHIFT)
	srli.w		t1, t1, (32 - PGDIR_SHIFT + PAGE_SHIFT + 1)
	slli.w		t1, t1, (0x2 + 1)
	add.w		t0, t0, t1
	and		t0, t0, ra

	ld.w		t1, t0, 0x0
	csrwr		t1, LOONGARCH_CSR_TLBRELO0

	ld.w		t1, t0, 0x4
	csrwr		t1, LOONGARCH_CSR_TLBRELO1

	tlbfill
	csrrd		t0, EXCEPTION_KS0
	csrrd		t1, EXCEPTION_KS1
	csrrd		ra, EXCEPTION_KS2
	ertn
SYM_CODE_END(handle_tlb_refill)
#endif

#ifdef CONFIG_64BIT
SYM_CODE_START(handle_tlb_refill)
	UNWIND_HINT_UNDEFINED
	csrwr		t0, LOONGARCH_CSR_TLBRSAVE
	csrrd		t0, LOONGARCH_CSR_PGD
	lddir		t0, t0, 3
#if CONFIG_PGTABLE_LEVELS > 3
	lddir		t0, t0, 2
#endif
#if CONFIG_PGTABLE_LEVELS > 2
	lddir		t0, t0, 1
#endif
	ldpte		t0, 0
	ldpte		t0, 1
#ifdef CONFIG_LOONGARCH_CONT_PTE
	csrrd		t0, LOONGARCH_CSR_TLBRELO0
	bstrpick.d	t0, t0, _PAGE_CONT_SHIFT, _PAGE_CONT_SHIFT
	bnez		t0, tlb_refill_cont
#endif
	tlbfill
	csrrd		t0, LOONGARCH_CSR_TLBRSAVE
	ertn

#ifdef CONFIG_LOONGARCH_CONT_PTE
#if PFN_PTE_SHIFT != PAGE_SHIFT
#error "PFN_PTE_SHIFT != PAGE_SHIFT"
#endif
	/*
	 * The even PTE is marked as part of a contiguous block, try to map
	 * the whole block with one large MTLB entry, see mm/contpte.c.
	 * TLBRELO0/1 and TLBREHI still hold the base page entry for the
	 * fallback. This runs in DA mode, the code is copied to the refill
	 * vector, so all branches must stay inside handle_tlb_refill.
	 */
tlb_refill_cont:
	csrwr		t1, REFILL_KS0
	csrwr		t2, REFILL_KS1

	/* Walk again, t0 = PTE table */
	csrrd		t0, LOONGARCH_CSR_PGD
	lddir		t0, t0, 3
#if CONFIG_PGTABLE_LEVELS > 3
	lddir		t0, t0, 2
#endif
#if CONFIG_PGTABLE_LEVELS > 2
	lddir		t0, t0, 1
#endif
	andi		t1, t0, _PAGE_HUGE
	bnez		t1, tlb_refill_cont_fail

	/* t0 = PTE pointer, t1 = PTE of the bad address */
	csrrd		t1, LOONGARCH_CSR_TLBRBADV
	bstrpick.d	t1, t1, PTRS_PER_PTE_BITS + PAGE_SHIFT - 1, PAGE_SHIFT
	alsl.d		t0, t1, t0, _PTE_T_LOG2
	ld.d		t1, t0, 0

	/* t2 = block order, must be in [CONTPTE_MIN_ORDER, CONTPTE_MAX_ORDER] */
	bstrpick.d	t2, t1, _PAGE_CONT_SHIFT, _PAGE_CONT_SHIFT
	beqz		t2, tlb_refill_cont_fail
	bstrpick.d	t2, t1, _PAGE_CONT_ORDER_SHIFT + _PAGE_CONT_ORDER_WIDTH - 1, _PAGE_CONT_ORDER_SHIFT
	addi.d		t1, t2, -CONTPTE_MIN_ORDER
	sltui		t1, t1, CONTPTE_MAX_ORDER - CONTPTE_MIN_ORDER + 1
	beqz		t1, tlb_refill_cont_fail

	/* t0 = first PTE pointer of the block */
	addi.d		t2, t2, _PTE_T_LOG2
	srl.d		t0, t0, t2
	sll.d		t0, t0, t2
	addi.d		t2, t2, -_PTE_T_LOG2

	/*
	 * t1 = expected PTE, the first one with the block order of the bad
	 * address, it must be present and valid.
	 */
	ld.d		t1, t0, 0
	bstrins.d	t1, t2, _PAGE_CONT_ORDER_SHIFT + _PAGE_CONT_ORDER_WIDTH - 1, _PAGE_CONT_ORDER_SHIFT
	andi		t2, t1, _PAGE_PRESENT | _PAGE_VALID
	xori		t2, t2, _PAGE_PRESENT | _PAGE_VALID
	bnez		t2, tlb_refill_cont_fail

	/*
	 * Every PTE must equal the expected one, except the software bits
	 * 8 ~ PFN_PTE_SHIFT-1 and the bits 48 ~ 60 (CONTPTE_IGNORE).
	 */
1:	ld.d		t2, t0, 0
	xor		t2, t2, t1
	bstrins.d	t2, zero, 60, 48
	bstrins.d	t2, zero, PFN_PTE_SHIFT - 1, 8
	bnez		t2, tlb_refill_cont_fail
	lu12i.w		t2, (1 << PFN_PTE_SHIFT) >> 12
	add.d		t1, t1, t2
	addi.d		t0, t0, _PTE_T_SIZE
	/* Loop until t0 is aligned to (_PTE_T_SIZE << order) */
	bstrpick.d	t2, t1, _PAGE_CONT_ORDER_SHIFT + _PAGE_CONT_ORDER_WIDTH - 1, _PAGE_CONT_ORDER_SHIFT
	sub.d		t2, zero, t2
	addi.d		t2, t2, 64 - _PTE_T_LOG2
	sll.d		t2, t0, t2
	bnez		t2, 1b

	/* t1 = first PTE + block size now, the PFN must be aligned to it */
	bstrpick.d	t0, t1, _PAGE_CONT_ORDER_SHIFT + _PAGE_CONT_ORDER_WIDTH - 1, _PAGE_CONT_ORDER_SHIFT
	bstrpick.d	t2, t1, _PAGE_PFN_END_SHIFT - 1, PFN_PTE_SHIFT
	sub.d		t0, zero, t0
	addi.d		t0, t0, 64
	sll.d		t2, t2, t0
	bnez		t2, tlb_refill_cont_fail

	/*
	 * t0 = PS = PAGE_SHIFT + order - 1, t2 = 1 << PS = half block
	 * in PTE units (PFN_PTE_SHIFT == PAGE_SHIFT), TLBRELO0 = first
	 * PTE = t1 - 2 * t2, TLBRELO1 = TLBRELO0 + t2.
	 */
	bstrpick.d	t0, t1, _PAGE_CONT_ORDER_SHIFT + _PAGE_CONT_ORDER_WIDTH - 1, _PAGE_CONT_ORDER_SHIFT
	addi.d		t0, t0, PAGE_SHIFT - 1
	ori		t2, zero, 1
	sll.d		t2, t2, t0
	bstrins.d	t1, zero, 60, 48
	sub.d		t1, t1, t2
	sub.d		t1, t1, t2
	add.d		t2, t1, t2
	csrwr		t1, LOONGARCH_CSR_TLBRELO0
	csrwr		t2, LOONGARCH_CSR_TLBRELO1

	/* TLBREHI = block address | PS */
	csrrd		t1, LOONGARCH_CSR_TLBRBADV
	addi.d		t2, t0, 1
	srl.d		t1, t1, t2
	sll.d		t1, t1, t2
	or		t2, t1, t0
	csrwr		t2, LOONGARCH_CSR_TLBREHI

	/* No other entry may overlap the block, invalidate them */
	csrrd		t0, LOONGARCH_CSR_ASID
	andi		t0, t0, CSR_ASID_ASID
2:	invtlb		INVTLB_ADDR_GFALSE_AND_ASID, t0, t1
	lu12i.w		t2, (PAGE_SIZE << 1) >> 12
	add.d		t1, t1, t2
	csrrd		t2, LOONGARCH_CSR_TLBREHI
	andi		t2, t2, CSR_TLBREHI_PS
	sub.d		t2, zero, t2
	addi.d		t2, t2, 63
	sll.d		t2, t1, t2
	bnez		t2, 2b

	tlbfill

	/* Restore the default page size for the next refill */
	csrrd		t0, LOONGARCH_CSR_TLBREHI
	ori		t1, zero, PS_DEFAULT_SIZE
	bstrins.d	t0, t1, CSR_TLBREHI_PS_SHIFT + 5, CSR_TLBREHI_PS_SHIFT
	csrwr		t0, LOONGARCH_CSR_TLBREHI

	csrrd		t1, REFILL_KS0
	csrrd		t2, REFILL_KS1
	csrrd		t0, LOONGARCH_CSR_TLBRSAVE
	ertn

tlb_refill_cont_fail:
	csrrd		t1, REFILL_KS0
	csrrd		t2, REFILL_KS1
	tlbfill
	csrrd		t0, LOONGARCH_CSR_TLBRSAVE
	ertn
#endif
SYM_INNER_LABEL(handle_tlb_refill_end, SYM_L_GLOBAL)
SYM_CODE_END(handle_tlb_refill)
#endif
