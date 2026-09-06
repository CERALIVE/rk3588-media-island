/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ISLAND_IOCTL_TEST_MEMORY_H
#define ISLAND_IOCTL_TEST_MEMORY_H

#include <kunit/test.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>

/* Each translation unit has one sequential KUnit fixture, never production state. */
static struct {
	struct kunit *test;
	struct {
		unsigned long address;
		void *buffer;
		size_t readable;
		size_t writable;
	} regions[4];
	unsigned int faults;
	unsigned int copies;
	int allocations;
} ioctl_memory;

static void ioctl_region(unsigned int slot, void *buffer, size_t size)
{
	ioctl_memory.regions[slot].address = 0x10000UL * (slot + 1);
	ioctl_memory.regions[slot].buffer = buffer;
	ioctl_memory.regions[slot].readable = size;
	ioctl_memory.regions[slot].writable = size;
}

static unsigned long ioctl_copy(void *kernel, unsigned long address,
				size_t size, bool write)
{
	unsigned int i;

	ioctl_memory.copies++;
	for (i = 0; i < ARRAY_SIZE(ioctl_memory.regions); i++) {
		size_t limit = write ? ioctl_memory.regions[i].writable :
				      ioctl_memory.regions[i].readable;
		unsigned long start = ioctl_memory.regions[i].address;
		size_t offset;

		if (!start || address < start)
			continue;
		offset = address - start;
		if (offset > limit || size > limit - offset)
			continue;
		if (write)
			memcpy((u8 *)ioctl_memory.regions[i].buffer + offset, kernel, size);
		else
			memcpy(kernel, (u8 *)ioctl_memory.regions[i].buffer + offset, size);
		return 0;
	}
	ioctl_memory.faults++;
	if (!write)
		memset(kernel, 0, size);
	return size;
}

static void *ioctl_alloc(size_t size, gfp_t flags)
{
	void *ptr = kvzalloc(size, flags);

	if (!ZERO_OR_NULL_PTR(ptr))
		ioctl_memory.allocations++;
	return ptr;
}

static void ioctl_memory_contract_test(struct kunit *test)
{
	u8 storage[6] = { 0xa5, 1, 2, 3, 4, 0x5a };
	u8 copy[4] = {};

	ioctl_region(3, &storage[1], 4);
	KUNIT_EXPECT_EQ(test, ioctl_copy(copy, 0x40000, 4, false), 0UL);
	KUNIT_EXPECT_MEMEQ(test, copy, &storage[1], 4);
	KUNIT_EXPECT_EQ(test, ioctl_copy(copy, 0x40001, 4, false), 4UL);
	KUNIT_EXPECT_MEMEQ(test, copy, ((u8[4]) {}), 4);
	KUNIT_EXPECT_EQ(test, ioctl_copy(copy, ULONG_MAX, 4, true), 4UL);
	KUNIT_EXPECT_EQ(test, ioctl_copy(copy, 0x40001, 4, true), 4UL);
	KUNIT_EXPECT_EQ(test, storage[0], 0xa5);
	KUNIT_EXPECT_EQ(test, storage[5], 0x5a);
	KUNIT_EXPECT_EQ(test, ioctl_copy(copy, 0x40000, 4, true), 0UL);
	KUNIT_EXPECT_MEMEQ(test, &storage[1], copy, 4);
}

static void ioctl_free(const void *ptr)
{
	if (!ZERO_OR_NULL_PTR(ptr))
		ioctl_memory.allocations--;
	kvfree(ptr);
}

/* Redefinitions apply only to the verbatim source included by this test TU. */
#undef copy_from_user
#undef copy_to_user
#undef get_user
#undef put_user
#define copy_from_user(dst, src, n) ioctl_copy(dst, (unsigned long)(src), n, false)
#define copy_to_user(dst, src, n) ioctl_copy((void *)(src), (unsigned long)(dst), n, true)
#define get_user(value, ptr) ({ \
	typeof(*(ptr)) _value; \
	int _ret = ioctl_copy(&_value, (unsigned long)(ptr), sizeof(_value), false); \
	(value) = _value; \
	_ret ? -EFAULT : 0; \
})
#define put_user(value, ptr) ({ \
	typeof(*(ptr)) _value = (value); \
	ioctl_copy(&_value, (unsigned long)(ptr), sizeof(_value), true) ? -EFAULT : 0; \
})
#undef kzalloc
#undef kvzalloc
#define kzalloc(size, flags) ioctl_alloc(size, flags)
#define kvzalloc(size, flags) ioctl_alloc(size, flags)
#define kfree(ptr) ioctl_free(ptr)
#define kvfree(ptr) ioctl_free(ptr)

#endif
