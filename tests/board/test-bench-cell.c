// SPDX-License-Identifier: GPL-2.0-only
#define main bench_main
#include "bench-cell.c"
#undef main

int main(void)
{
	gst_init(NULL, NULL);
	gchar *capture = capture_graph("h265", 1920, 1080, 30, FALSE);
	g_assert_nonnull(strstr(capture, "io-mode=dmabuf"));
	g_assert_nonnull(strstr(capture, "framerate=60000/1001,colorimetry=bt709"));
	g_assert_nonnull(strstr(capture, "videorate drop-only=true"));
	g_assert_nonnull(strstr(capture, "framerate=30000/1001"));
	g_assert_nonnull(strstr(capture, "format=NV12,width=1920,height=1080,colorimetry=bt709"));
	g_assert_nonnull(strstr(capture, "identity name=input ! mpph265enc"));
	g_free(capture);
	capture = capture_graph("h264", 3840, 2160, 60, TRUE);
	g_assert_null(strstr(capture, "rgaconvert"));
	g_assert_null(strstr(capture, "mpph264enc"));
	g_assert_nonnull(strstr(capture, "identity name=input ! fakesink"));
	g_free(capture);
	GstCaps *dma_caps = gst_caps_from_string(output_media_type(TRUE));
	GstCaps *plain_caps = gst_caps_from_string(output_media_type(FALSE));
	g_assert_true(gst_caps_features_contains(gst_caps_get_features(dma_caps, 0), GST_CAPS_FEATURE_MEMORY_DMABUF));
	g_assert_false(gst_caps_features_contains(gst_caps_get_features(plain_caps, 0), GST_CAPS_FEATURE_MEMORY_DMABUF));
	gst_caps_unref(dma_caps); gst_caps_unref(plain_caps);
	GstBuffer *original = gst_buffer_new_allocate(NULL, 128, NULL);
	GstBuffer *copy = gst_buffer_copy(original);
	g_assert_true(gst_buffer_peek_memory(copy, 0) == gst_buffer_peek_memory(original, 0));
	GST_BUFFER_PTS(copy) = 123;
	g_assert_cmpuint(GST_BUFFER_PTS(original), ==, GST_CLOCK_TIME_NONE);
	gst_buffer_unref(copy);
	gst_buffer_unref(original);
	GError *error = NULL;
	GstElement *pipe = gst_parse_launch("fakesrc num-buffers=300 ! fakesink name=sink sync=false", &error);
	g_assert_no_error(error);
	GstElement *sink = gst_bin_get_by_name(GST_BIN(pipe), "sink");
	GstPad *pad = gst_element_get_static_pad(sink, "sink");
	source_only = TRUE;
	counters[0].intervals = g_array_new(FALSE, FALSE, sizeof(double));
	gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, observe, GUINT_TO_POINTER(0), NULL);
	gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, observe_input, NULL, NULL);
	g_assert_cmpint(gst_element_set_state(pipe, GST_STATE_PLAYING), !=, GST_STATE_CHANGE_FAILURE);
	GstBus *bus = gst_element_get_bus(pipe);
	GstMessage *message = gst_bus_timed_pop_filtered(bus, 5 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
	g_assert_nonnull(message);
	g_assert_cmpint(GST_MESSAGE_TYPE(message), ==, GST_MESSAGE_EOS);
	g_assert_cmpuint(atomic_load(&counters[0].count), ==, 300);
	g_assert_cmpuint(atomic_load(&capture_sent), ==, 300);
	g_assert_cmpuint(counters[0].intervals->len, ==, 0);
	g_assert_false(error_pending(pipe));
	gst_element_set_state(pipe, GST_STATE_NULL);
	gst_message_unref(message);
	gst_object_unref(bus); gst_object_unref(pad); gst_object_unref(sink); gst_object_unref(pipe);
	g_array_unref(counters[0].intervals);
	g_print("bench-cell: immutable memory, independent PTS, 300 real pad callbacks, EOS conservation passed\n");
	return 0;
}
