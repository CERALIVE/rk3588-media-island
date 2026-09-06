// SPDX-License-Identifier: GPL-2.0-only
#include <kunit/test.h>
#include "../mpp/media_map.h"
#include "../mpp/mpp_iommu.h"

struct media_mapping_fixture {
	struct iosys_map exported;
	struct iosys_map returned;
	unsigned int unmaps;
};

static struct sg_table *media_mapping_attach(struct dma_buf_attachment *attach,
					    enum dma_data_direction direction)
{
	return ERR_PTR(-EOPNOTSUPP);
}

static void media_mapping_detach(struct dma_buf_attachment *attach,
				 struct sg_table *table, enum dma_data_direction direction)
{
}

static int media_mapping_vmap(struct dma_buf *buffer, struct iosys_map *map)
{
	struct media_mapping_fixture *fixture = buffer->priv;

	*map = fixture->exported;
	return 0;
}

static void media_mapping_vunmap(struct dma_buf *buffer, struct iosys_map *map)
{
	struct media_mapping_fixture *fixture = buffer->priv;

	fixture->returned = *map;
	fixture->unmaps++;
}

static void media_mapping_release(struct dma_buf *buffer)
{
}

static const struct dma_buf_ops media_mapping_ops = {
	.map_dma_buf = media_mapping_attach,
	.unmap_dma_buf = media_mapping_detach,
	.vmap = media_mapping_vmap,
	.vunmap = media_mapping_vunmap,
	.release = media_mapping_release,
};

static void media_mapping_preserves_exporter_map_test(struct kunit *test)
{
	DEFINE_DMA_BUF_EXPORT_INFO(info);
	struct media_mapping_fixture fixture = {};
	struct mpp_dma_buffer mapped = {};
	struct dma_buf *buffer;
	int ret;

	iosys_map_set_vaddr_iomem(&fixture.exported, (void __iomem *)0x1000UL);
	info.ops = &media_mapping_ops;
	info.size = PAGE_SIZE;
	info.priv = &fixture;
	buffer = dma_buf_export(&info);
	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, buffer);
	ret = dma_buf_vmap_unlocked(buffer, &mapped.map);
	KUNIT_EXPECT_EQ(test, ret, 0);
	if (!ret) {
		KUNIT_EXPECT_TRUE(test, mapped.map.is_iomem);
		media_dma_vunmap(buffer, &mapped.map);
		KUNIT_EXPECT_TRUE(test, iosys_map_is_equal(&fixture.exported, &fixture.returned));
		KUNIT_EXPECT_TRUE(test, iosys_map_is_null(&mapped.map));
		KUNIT_EXPECT_EQ(test, fixture.unmaps, 1u);
	}
	dma_buf_put(buffer);
}

static struct kunit_case media_mapping_cases[] = {
	KUNIT_CASE(media_mapping_preserves_exporter_map_test),
	{}
};

static struct kunit_suite media_mapping_suite = {
	.name = "rockchip-media-mapping",
	.test_cases = media_mapping_cases,
};
kunit_test_suite(media_mapping_suite);

MODULE_LICENSE("GPL");
MODULE_IMPORT_NS("DMA_BUF");
