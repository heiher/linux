// SPDX-License-Identifier: GPL-2.0
/*
 * Map contiguous PTE blocks with large TLB entries.
 *
 * A LoongArch TLB entry maps an even/odd pair of pages of size PS. The STLB
 * only holds entries of the base page size (CSR.STLBPS), while the MTLB is
 * fully associative and holds entries of any supported page size, TLBFILL
 * selects the MTLB when PS != STLBPS. A naturally aligned block of 2^order
 * PTEs that map physically contiguous (and equally aligned) pages with the
 * same attributes can therefore be covered by a single MTLB entry with
 * PS = PAGE_SHIFT + order - 1, instead of 2^(order - 1) STLB entries.
 *
 * There is no hardware "contiguous" bit, so set_ptes() marks such blocks:
 *
 *  - _PAGE_CONT: a PPN bit below the page size, so the hardware ignores it,
 *    but LDPTE keeps it in TLBRELO0, the TLB refill handler tests it with a
 *    single CSR read and takes a slow path only for marked PTEs;
 *  - _PAGE_CONT_ORDER: the block order, read from memory by the slow path.
 *
 * The marking is only a hint, nothing relies on it being kept up to date.
 * Before a large entry is created (by the refill slow path in tlbex.S or by
 * contpte_update_tlb() after a page fault) the whole block is verified:
 * every PTE must be present and valid, have the same hardware attributes
 * (including D) and map the next PFN, the first PFN must be aligned to the
 * block size. Otherwise the normal base-page entry is used. Overlapping
 * entries of the block are invalidated first, since multiple TLB hits are
 * not allowed.
 *
 * A large entry is never more permissive than any PTE of the block when it
 * is created. Making a PTE less permissive is always followed by a TLB flush
 * of that address, and INVTLB compares the address using the page size of
 * each entry, so the whole large entry is dropped. Making a PTE more
 * permissive without a flush (setting V/D in the TLB exception handlers)
 * replaces the matching large entry with a base-page entry via TLBSRCH and
 * TLBWR, so those keep working unchanged.
 */
#include <linux/debugfs.h>
#include <linux/init.h>
#include <linux/kstrtox.h>
#include <linux/mm.h>
#include <linux/seq_file.h>

#include <asm/cpu-features.h>
#include <asm/loongarch.h>
#include <asm/mmu_context.h>
#include <asm/pgtable.h>
#include <asm/tlb.h>

static_assert(CONTPTE_MAX_ORDER < (1 << _PAGE_CONT_ORDER_WIDTH));

/*
 * PTE bits that may differ inside a block: the software bits 7 ~ PFN_PTE_SHIFT-1
 * (_PAGE_PRESENT, _PAGE_WRITE, _PAGE_MODIFIED, _PAGE_PROTNONE, _PAGE_SPECIAL,
 * _PAGE_CONT), _PAGE_VALID is required instead of _PAGE_PRESENT. All other
 * bits, including _PAGE_CONT_ORDER, must be equal, the PFN must be the next
 * one. Keep in sync with handle_tlb_refill.
 */
#define CONTPTE_IGNORE		GENMASK(PFN_PTE_SHIFT - 1, 7)

/* Bitmap of block orders that set_ptes() may mark, 0 disables marking */
unsigned long contpte_orders __read_mostly;
EXPORT_SYMBOL(contpte_orders);

/* Bitmap of block orders that the MTLB can map */
static unsigned long contpte_orders_supported __read_mostly;

/* Requested orders from the command line, -1 means the default orders */
static long contpte_orders_param __initdata = -1;

static int __init contpte_param(char *str)
{
	unsigned long val;

	if (!str)
		return -EINVAL;
	if (!strcmp(str, "off"))
		val = 0;
	else if (kstrtoul(str, 0, &val))
		return -EINVAL;
	contpte_orders_param = val;

	return 0;
}
early_param("contpte_orders", contpte_param);

void contpte_set_ptes(struct mm_struct *mm, unsigned long addr,
		      pte_t *ptep, pte_t pte, unsigned int nr)
{
	unsigned long orders = READ_ONCE(contpte_orders);
	unsigned long val = pte_val(pte) & ~_PAGE_CONT_MASK;
	unsigned long pfn = pte_pfn(pte);

	if (mm == &init_mm || !(val & _PAGE_PRESENT) || (val & _PAGE_GLOBAL))
		orders = 0;

	while (nr) {
		unsigned long hint = 0, i, n;
		unsigned int order = 0;

		if (orders) {
			unsigned long align = (addr >> PAGE_SHIFT) | pfn;
			unsigned int max = ilog2(nr);
			unsigned long mask;

			if (align)
				max = min(max, __ffs(align));
			mask = orders & GENMASK(max, 0);
			if (mask) {
				order = __fls(mask);
				hint = _PAGE_CONT | ((unsigned long)order << _PAGE_CONT_ORDER_SHIFT);
			}
		}

		n = 1UL << order;
		for (i = 0; i < n; i++) {
			set_pte(ptep++, __pte(val | hint));
			val += 1UL << PFN_PTE_SHIFT;
		}
		addr += n << PAGE_SHIFT;
		pfn += n;
		nr -= n;
	}
}
EXPORT_SYMBOL(contpte_set_ptes);

/* Verify a block of 2^order PTEs, return the TLBELO0 value on success */
static bool contpte_check_block(pte_t *ptep, unsigned int order, unsigned long *lo)
{
	unsigned long first = pte_val(ptep_get(ptep));
	unsigned long i, n = 1UL << order;

	/* Expect the order of the faulting PTE, like handle_tlb_refill */
	first &= ~_PAGE_CONT_ORDER;
	first |= (unsigned long)order << _PAGE_CONT_ORDER_SHIFT;

	if (!(first & _PAGE_VALID))
		return false;
	if (pte_pfn(__pte(first)) & (n - 1))
		return false;

	for (i = 1; i < n; i++) {
		unsigned long val = pte_val(ptep_get(ptep + i));

		if ((val ^ (first + (i << PFN_PTE_SHIFT))) & ~CONTPTE_IGNORE)
			return false;
	}

	*lo = first & ~_PAGE_CONT_ORDER;

	return true;
}

/*
 * Called by update_mmu_cache_range() with the PTL held, for a marked PTE.
 * Install a large entry for the block containing @address. Return the
 * number of PTEs from @ptep to the end of the block, or 0 if a large
 * entry can't be used and the caller should fall back to __update_tlb().
 */
unsigned int contpte_update_tlb(struct vm_area_struct *vma,
				unsigned long address, pte_t *ptep)
{
	unsigned long val = pte_val(ptep_get(ptep));
	unsigned int order = (val & _PAGE_CONT_ORDER) >> _PAGE_CONT_ORDER_SHIFT;
	unsigned long flags, start, size, lo, va, idx;
	int asid;

	if (cpu_has_ptw || !(contpte_orders_supported & BIT(order)))
		return 0;

	/* Handle debugger faulting in for debugee */
	if (current->active_mm != vma->vm_mm)
		return 0;

	address &= PAGE_MASK;
	size = PAGE_SIZE << order;
	start = address & ~(size - 1);
	idx = (address - start) >> PAGE_SHIFT;

	if (!contpte_check_block(ptep - idx, order, &lo))
		return 0;

	local_irq_save(flags);

	asid = cpu_asid(smp_processor_id(), vma->vm_mm);
	for (va = start; va < start + size; va += PAGE_SIZE << 1)
		invtlb(INVTLB_ADDR_GFALSE_AND_ASID, asid, va);

	write_csr_entryhi(start);
	write_csr_pagesize(PAGE_SHIFT + order - 1);
	write_csr_entrylo0(lo);
	write_csr_entrylo1(lo + ((size >> 1) >> PAGE_SHIFT << PFN_PTE_SHIFT));
	tlb_write_random();
	write_csr_pagesize(PS_DEFAULT_SIZE);

	local_irq_restore(flags);

	return (1UL << order) - idx;
}

static int __init contpte_init(void)
{
	unsigned long prcfg2 = read_csr_prcfg2();
	unsigned int ksnum = read_csr_prcfg1() & CSR_CONF1_KSNUM;
	unsigned int order;

	/*
	 * The refill slow path needs REFILL_KS0/1, a hardware page table
	 * walker never looks at the hint. Some emulators don't report
	 * PRCFG1/PRCFG2 (zero), assume the architectural defaults then.
	 */
	if (cpu_has_ptw || (ksnum && ksnum < 8) || !current_cpu_data.tlbsizemtlb) {
		pr_info("contpte: not supported\n");
		return 0;
	}
	if (!prcfg2)
		prcfg2 = CSR_CONF2_PGMASK_SUPP;

	for (order = CONTPTE_MIN_ORDER; order <= CONTPTE_MAX_ORDER; order++) {
		if (prcfg2 & BIT(PAGE_SHIFT + order - 1))
			contpte_orders_supported |= BIT(order);
	}

	/*
	 * All large entries live in the MTLB, which is much smaller than the
	 * STLB. Only blocks for which the MTLB reaches more memory than the
	 * whole STLB does with base pages reduce TLB misses, smaller blocks
	 * just thrash the MTLB. Use those by default, the others can still
	 * be enabled from the command line or debugfs.
	 */
	if (contpte_orders_param == -1) {
		unsigned long stlb = current_cpu_data.tlbsize - current_cpu_data.tlbsizemtlb;

		stlb = 2 * stlb / current_cpu_data.tlbsizemtlb;
		order = stlb ? ilog2(stlb) + 1 : CONTPTE_MIN_ORDER;
		contpte_orders = contpte_orders_supported & ~GENMASK(order - 1, 0);
	} else {
		contpte_orders = contpte_orders_supported & contpte_orders_param;
	}
	pr_info("contpte: supported orders 0x%lx, enabled orders 0x%lx\n",
		contpte_orders_supported, contpte_orders);

	return 0;
}
early_initcall(contpte_init);

#ifdef CONFIG_DEBUG_FS
static int contpte_orders_get(void *data, u64 *val)
{
	*val = READ_ONCE(contpte_orders);
	return 0;
}

static int contpte_orders_set(void *data, u64 val)
{
	if (val & ~contpte_orders_supported)
		return -EINVAL;
	WRITE_ONCE(contpte_orders, val);
	return 0;
}
DEFINE_DEBUGFS_ATTRIBUTE(contpte_orders_fops, contpte_orders_get,
			 contpte_orders_set, "0x%llx\n");

/* Dump the valid MTLB entries of the current CPU */
static int mtlb_show(struct seq_file *m, void *v)
{
	int i, stlb = current_cpu_data.tlbsizestlbsets * current_cpu_data.tlbsizestlbways;
	unsigned long flags, ehi, lo0, lo1, asid, idx;
	unsigned long old_ehi, old_asid;

	preempt_disable();
	seq_printf(m, "cpu %d asid %lx\n", smp_processor_id(),
		   (unsigned long)(read_csr_asid() & CSR_ASID_ASID));

	for (i = stlb; i < current_cpu_data.tlbsize; i++) {
		local_irq_save(flags);
		old_ehi = read_csr_entryhi();
		old_asid = read_csr_asid();
		write_csr_tlbidx((read_csr_tlbidx() & ~CSR_TLBIDX_IDXM) | i);
		tlb_read();
		idx = read_csr_tlbidx();
		ehi = read_csr_entryhi();
		lo0 = read_csr_entrylo0();
		lo1 = read_csr_entrylo1();
		asid = read_csr_asid() & CSR_ASID_ASID;
		write_csr_entryhi(old_ehi);
		write_csr_asid(old_asid);
		write_csr_pagesize(PS_DEFAULT_SIZE);
		local_irq_restore(flags);

		if (idx & CSR_TLBIDX_EHINV)
			continue;
		seq_printf(m, "%4d ps %2lu va %016lx asid %3lx lo0 %016lx lo1 %016lx\n",
			   i, (idx & CSR_TLBIDX_SIZEM) >> CSR_TLBIDX_SIZE,
			   ehi, asid, lo0, lo1);
	}
	preempt_enable();

	return 0;
}
DEFINE_SHOW_ATTRIBUTE(mtlb);

static int __init contpte_debugfs_init(void)
{
	debugfs_create_file("contpte_orders", 0644, arch_debugfs_dir, NULL,
			    &contpte_orders_fops);
	debugfs_create_file("mtlb", 0444, arch_debugfs_dir, NULL, &mtlb_fops);

	return 0;
}
late_initcall(contpte_debugfs_init);
#endif
