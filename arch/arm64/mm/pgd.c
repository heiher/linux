// SPDX-License-Identifier: GPL-2.0-only
/*
 * PGD allocation/freeing
 *
 * Copyright (C) 2012 ARM Ltd.
 * Author: Catalin Marinas <catalin.marinas@arm.com>
 */

#include <linux/mm.h>
#include <linux/gfp.h>
#include <linux/highmem.h>
#include <linux/slab.h>

#include <asm/pgalloc.h>
#include <asm/page.h>
#include <asm/tlbflush.h>

static struct kmem_cache *pgd_cache __ro_after_init;

static bool pgdir_is_page_size(void)
{
	if (PGD_SIZE == PAGE_SIZE)
		return true;
	if (CONFIG_PGTABLE_LEVELS == 4)
		return !pgtable_l4_enabled();
	if (CONFIG_PGTABLE_LEVELS == 5)
		return !pgtable_l5_enabled();
	return false;
}

pgd_t *pgd_alloc(struct mm_struct *mm)
{
	gfp_t gfp = GFP_PGTABLE_USER;

	if (pgdir_is_page_size())
		return __pgd_alloc(mm, 0);
	else
		return kmem_cache_alloc(pgd_cache, gfp);
}

void pgd_free(struct mm_struct *mm, pgd_t *pgd)
{
	if (pgdir_is_page_size())
		__pgd_free(mm, pgd);
	else
		kmem_cache_free(pgd_cache, pgd);
}

void __init pgtable_cache_init(void)
{
	if (pgdir_is_page_size())
		return;

#ifdef CONFIG_ARM64_PA_BITS_52
	/*
	 * With 52-bit physical addresses, the architecture requires the
	 * top-level table to be aligned to at least 64 bytes.
	 */
	BUILD_BUG_ON(PGD_SIZE < 64);
#endif

	/*
	 * Naturally aligned pgds required by the architecture.
	 */
	pgd_cache = kmem_cache_create("pgd_cache", PGD_SIZE, PGD_SIZE,
				      SLAB_PANIC, NULL);
}
