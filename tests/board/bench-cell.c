// SPDX-License-Identifier: GPL-2.0-only
/* Immutable pixels: timed work shares DMA-BUF references, never renders frames. */
#define _GNU_SOURCE
#include <gst/allocators/gstdmabuf.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

#define BRANCHES 8
#define RING 8
struct counter {
	_Atomic unsigned count;
	GArray *intervals;
	gint64 previous;
};
static struct counter counters[BRANCHES];
static gboolean source_only;
static gint64 origin;
static _Atomic gint64 measurement_end;
static _Atomic unsigned capture_sent;

static GstPadProbeReturn observe_input(GstPad *pad, GstPadProbeInfo *info, gpointer data)
{
	(void)pad; (void)data;
	if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER)
		atomic_fetch_add(&capture_sent, 1);
	return GST_PAD_PROBE_OK;
}

static gchar *capture_graph(const char *codec, unsigned width, unsigned height,
			   unsigned rate, gboolean control)
{
	gchar *tail = control ? g_strdup("identity name=input ! fakesink name=sink sync=false async=false") :
		g_strdup_printf("%srgaconvert name=convert ! video/x-raw,format=NV12,width=%u,height=%u,colorimetry=bt709 ! "
			"identity name=input ! mpp%senc name=encode rc-mode=cbr bitrate=20000000 gop=60 ! "
			"%sparse ! video/x-%s,alignment=au ! fakesink name=sink sync=false async=false",
			rate == 30 ? "videorate drop-only=true ! video/x-raw,framerate=30000/1001 ! " : "",
			width, height, codec, codec, codec);
	gchar *graph = g_strdup_printf(
		"v4l2src name=source device=/dev/video0 io-mode=dmabuf ! "
		"video/x-raw,format=NV16,width=3840,height=2160,framerate=60000/1001,colorimetry=bt709 ! "
		"%s", tail);
	g_free(tail);
	return graph;
}

static GstPadProbeReturn observe(GstPad *pad, GstPadProbeInfo *info, gpointer data)
{
	unsigned branch = GPOINTER_TO_UINT(data);
	struct counter *c = &counters[branch];
	gint64 now = g_get_monotonic_time();
	(void)pad;
	if (!(GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER))
		return GST_PAD_PROBE_OK;
	/* Warmup is excluded from timing distributions, but not conservation counts. */
	gint64 end = atomic_load(&measurement_end);
	if (!source_only && now > origin + 2000000 && (!end || now < end)) {
		if (c->previous) {
			double ms = (now - c->previous) / 1000.0;
			g_array_append_val(c->intervals, ms);
		}
		c->previous = now;
		g_print("AU,%u,%" G_GINT64_FORMAT ",%" G_GUINT64_FORMAT "\n",
			branch, now, GST_BUFFER_PTS(GST_PAD_PROBE_INFO_BUFFER(info)));
	}
	atomic_fetch_add(&c->count, 1);
	return GST_PAD_PROBE_OK;
}

static GstBuffer *frame(GstVideoInfo *info, unsigned phase)
{
	int heap = open("/dev/dma_heap/system", O_RDWR | O_CLOEXEC);
	struct dma_heap_allocation_data allocation = {
		.len = info->size, .fd_flags = O_RDWR | O_CLOEXEC
	};
	if (heap < 0 || ioctl(heap, DMA_HEAP_IOCTL_ALLOC, &allocation))
		g_error("DMA heap allocation failed");
	close(heap);
	void *map = mmap(NULL, info->size, PROT_READ | PROT_WRITE,
			MAP_SHARED, allocation.fd, 0);
	struct dma_buf_sync sync = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE};
	if (map == MAP_FAILED || ioctl(allocation.fd, DMA_BUF_IOCTL_SYNC, &sync))
		g_error("DMA map/sync failed");
	memset(map, 128, info->size);
	for (int y = 0; y < info->height; y++)
		for (int x = 0; x < info->width; x++)
			((unsigned char *)map)[y * info->stride[0] + x] =
				16 + ((x / 32 + y / 32 + phase * 13) % 220);
	sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
	if (ioctl(allocation.fd, DMA_BUF_IOCTL_SYNC, &sync))
		g_error("DMA sync end failed");
	munmap(map, info->size);
	GstAllocator *allocator = gst_dmabuf_allocator_new();
	GstBuffer *buffer = gst_buffer_new();
	GstMemory *memory = gst_dmabuf_allocator_alloc(allocator, allocation.fd, info->size);
	if (!memory)
		g_error("DMA memory wrap failed");
	gst_buffer_append_memory(buffer, memory);
	gst_object_unref(allocator);
	if (!gst_buffer_add_video_meta_full(buffer, GST_VIDEO_FRAME_FLAG_NONE,
		GST_VIDEO_INFO_FORMAT(info), info->width, info->height,
		GST_VIDEO_INFO_N_PLANES(info), info->offset, info->stride))
		g_error("video meta failed");
	return buffer;
}

static gboolean error_pending(GstElement *pipeline)
{
	GstBus *bus = gst_element_get_bus(pipeline);
	GstMessage *message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
	gst_object_unref(bus);
	if (!message)
		return FALSE;
	GError *error = NULL;
	gchar *debug = NULL;
	gst_message_parse_error(message, &error, &debug);
	g_printerr("PIPELINE_ERROR %s: %s\n", error->message, debug ? debug : "");
	g_clear_error(&error);
	g_free(debug);
	gst_message_unref(message);
	return TRUE;
}

static int compare(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static unsigned number(const char *text, unsigned max)
{
	char *end;
	unsigned long value = strtoul(text, &end, 10);
	if (!*text || *end || value > max) {
		fprintf(stderr, "invalid number\n");
		exit(2);
	}
	return value;
}

static const gchar *output_media_type(gboolean isolated_rga)
{
	return isolated_rga ? "video/x-raw(memory:DMABuf)" : "video/x-raw";
}

int main(int argc, char **argv)
{
	if (argc != 12) {
		fprintf(stderr, "usage: bench-cell mode codec in out width height rate streams seconds core operation\n");
		return 2;
	}
	gboolean capture = !strcmp(argv[1], "hdmi") || !strcmp(argv[1], "hdmi-source");
	source_only = !strcmp(argv[1], "source") || !strcmp(argv[1], "hdmi-source");
	gboolean rga = !strcmp(argv[1], "rga");
	gboolean encode = !strcmp(argv[1], "encode") || !strcmp(argv[1], "hdmi");
	if ((!source_only && !rga && !encode) ||
		(strcmp(argv[2], "h264") && strcmp(argv[2], "h265")) ||
		(strcmp(argv[3], "NV12") && strcmp(argv[3], "NV16") && strcmp(argv[3], "RGB")) ||
		(strcmp(argv[4], "NV12") && strcmp(argv[4], "RGB")))
		return 2;
	unsigned width = number(argv[5], 3840), height = number(argv[6], 2160);
	unsigned rate = number(argv[7], 240), streams = number(argv[8], BRANCHES);
	if (capture && (streams != 1 || (rate != 30 && rate != 60) ||
		strcmp(argv[3], "NV16") || strcmp(argv[4], "NV12"))) return 2;
	unsigned seconds = number(argv[9], 120), core = number(argv[10], 4);
	const char *operation = argv[11];
	if (!width || !height || (width % 2) || (height % 2) || !streams || !seconds ||
		(core != 0 && core != 1 && core != 2 && core != 4) ||
		(strcmp(operation, "copy") && strcmp(operation, "crop") &&
		 strcmp(operation, "scale") && strcmp(operation, "rotate") &&
		 strcmp(operation, "csc") && strcmp(operation, "combined")))
		return 2;
	if (!getenv("CERALIVE_BOARD_TEST") || strcmp(getenv("CERALIVE_BOARD_TEST"), "1"))
		return 77;
	alarm(seconds + 45);
	setvbuf(stdout, NULL, _IOLBF, 0);
	gst_init(NULL, NULL);
	GstVideoInfo info;
	if (!gst_video_info_set_format(&info, gst_video_format_from_string(argv[3]), width, height))
		return 2;
	GstBuffer *ring[RING];
	for (unsigned i = 0; !capture && i < RING; i++)
		ring[i] = frame(&info, i);
	if (capture) g_print("SOURCE live-hdmi=1 format=NV16 framerate=60000/1001\n");
	else g_print("SOURCE ring=%u immutable=1 bytes=%zu\n", RING, RING * info.size);
	GstElement *pipes[BRANCHES] = {0}, *sources[BRANCHES] = {0};
	unsigned sent[BRANCHES] = {0}, baseline[BRANCHES] = {0}, at_stop[BRANCHES] = {0};
	unsigned pressure[BRANCHES] = {0};
	gboolean ok = TRUE;
	unsigned out_width = width, out_height = height;
	gboolean crop = !strcmp(operation, "crop") || !strcmp(operation, "combined");
	gboolean scale = !strcmp(operation, "scale") || !strcmp(operation, "combined");
	gboolean rotate = !strcmp(operation, "rotate") || !strcmp(operation, "combined");
	if (crop || scale) { out_width /= 2; out_height /= 2; }
	if (rotate) { unsigned swap = out_width; out_width = out_height; out_height = swap; }
	for (unsigned i = 0; i < streams; i++) {
		gchar *conversion = g_strdup_printf(
			"rgaconvert name=convert core-mask=%u rotation=%u crop-x=%u crop-y=%u crop-w=%u crop-h=%u ! "
			"%s,format=%s,width=%u,height=%u,colorimetry=%s ! ",
			core, rotate ? 90 : 0, crop ? 16 : 0, crop ? 16 : 0,
			crop ? width / 2 : 0, crop ? height / 2 : 0,
			output_media_type(rga), argv[4], out_width, out_height, !strcmp(argv[4], "RGB") ? "sRGB" : "bt601");
		gchar *encoding = g_strdup_printf("mpp%senc name=encode rc-mode=cbr bitrate=20000000 gop=60 ! "
			"%sparse ! video/x-%s,alignment=au ! ", argv[2], argv[2], argv[2]);
		gchar *graph = g_strdup_printf(
			"appsrc name=source is-live=true format=time block=false max-buffers=8 max-bytes=0 "
			"caps=\"video/x-raw,format=%s,width=%u,height=%u,framerate=%u/1,interlace-mode=progressive,colorimetry=%s\" ! "
			"%s%s fakesink name=sink sync=false async=false",
			argv[3], width, height, rate ? rate : 120,
			!strcmp(argv[3], "RGB") ? "sRGB" : "bt601",
			!source_only && (rga || !strcmp(argv[3], "NV16")) ? conversion : "",
			encode ? encoding : "");
		if (capture) {
			g_free(graph);
			graph = capture_graph(argv[2], width, height, rate, source_only);
		}
		g_print("GRAPH branch=%u %s\n", i, graph);
		GError *error = NULL;
		pipes[i] = gst_parse_launch(graph, &error);
		g_free(conversion); g_free(encoding); g_free(graph);
		if (error || !pipes[i])
			g_error("graph parse: %s", error ? error->message : "null");
		sources[i] = gst_bin_get_by_name(GST_BIN(pipes[i]), "source");
		if (capture) {
			GstElement *input = gst_bin_get_by_name(GST_BIN(pipes[i]), "input");
			GstPad *input_pad = gst_element_get_static_pad(input, "src");
			gst_pad_add_probe(input_pad, GST_PAD_PROBE_TYPE_BUFFER, observe_input, NULL, NULL);
			gst_object_unref(input_pad); gst_object_unref(input);
		}
		GstElement *sink = gst_bin_get_by_name(GST_BIN(pipes[i]), "sink");
		GstPad *pad = gst_element_get_static_pad(sink, "sink");
		counters[i].intervals = g_array_new(FALSE, FALSE, sizeof(double));
		gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, observe, GUINT_TO_POINTER(i), NULL);
		gst_object_unref(pad); gst_object_unref(sink);
	}
	origin = g_get_monotonic_time();
	for (unsigned i = 0; i < streams; i++)
		if (gst_element_set_state(pipes[i], GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
			ok = FALSE;
	gint64 start = 0, stop = 0, next_progress = origin;
	struct rusage cpu_start, cpu_stop;
	memset(&cpu_start, 0, sizeof(cpu_start));
	while (ok) {
		gint64 now = g_get_monotonic_time();
		if (!start && now - origin >= 2000000) {
			start = now;
			getrusage(RUSAGE_SELF, &cpu_start);
			for (unsigned i = 0; i < streams; i++) baseline[i] = atomic_load(&counters[i].count);
		}
		if (start && now - start >= seconds * G_GINT64_CONSTANT(1000000)) break;
		gboolean pushed = FALSE;
		for (unsigned i = 0; i < streams; i++) {
			if (error_pending(pipes[i])) { ok = FALSE; break; }
			if (capture) continue;
			if (rate && now - origin < (gint64)sent[i] * 1000000 / rate) continue;
			guint64 queued = 0;
			g_object_get(sources[i], "current-level-buffers", &queued, NULL);
			if (queued >= RING) { pressure[i]++; continue; }
			GstBuffer *buffer = gst_buffer_copy(ring[sent[i] % RING]);
			GST_BUFFER_PTS(buffer) = (guint64)sent[i] * GST_SECOND / (rate ? rate : 120);
			GST_BUFFER_DURATION(buffer) = GST_SECOND / (rate ? rate : 120);
			if (gst_app_src_push_buffer(GST_APP_SRC(sources[i]), buffer) != GST_FLOW_OK) {
				ok = FALSE; break;
			}
			sent[i]++; pushed = TRUE;
		}
		if (now >= next_progress) {
			g_print("PROGRESS elapsed=%.3f output0=%u\n", (now-origin)/1e6, atomic_load(&counters[0].count));
			next_progress = now + 2000000;
		}
		if (rate || !pushed) g_usleep(100);
	}
	stop = g_get_monotonic_time();
	atomic_store(&measurement_end, stop);
	getrusage(RUSAGE_SELF, &cpu_stop);
	for (unsigned i = 0; i < streams; i++) {
		at_stop[i] = atomic_load(&counters[i].count);
		if (capture) gst_element_send_event(pipes[i], gst_event_new_eos());
		else gst_app_src_end_of_stream(GST_APP_SRC(sources[i]));
	}
	for (unsigned i = 0; i < streams; i++) {
		GstBus *bus = gst_element_get_bus(pipes[i]);
		GstMessage *message = gst_bus_timed_pop_filtered(bus, 5 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
		if (!message || GST_MESSAGE_TYPE(message) != GST_MESSAGE_EOS) ok = FALSE;
		if (message) gst_message_unref(message);
		gst_object_unref(bus);
		unsigned output = atomic_load(&counters[i].count);
		if (capture) sent[i] = atomic_load(&capture_sent);
		if (output != sent[i] || !output || !start) ok = FALSE;
		const char *names[] = {"convert", "encode"};
		for (unsigned j = 0; j < G_N_ELEMENTS(names); j++) {
			GstElement *element = gst_bin_get_by_name(GST_BIN(pipes[i]), names[j]);
			if (!element) continue;
			guint64 fallback = 0, dropped = 0, rejected = 0;
			g_object_get(element, "conversion-fallback-frames", &fallback,
				"conversion-dropped-frames", &dropped, "layout-rejections", &rejected, NULL);
			g_print("COUNTERS branch=%u element=%s fallback=%" G_GUINT64_FORMAT " dropped=%" G_GUINT64_FORMAT " rejected=%" G_GUINT64_FORMAT "\n",
				i, names[j], fallback, dropped, rejected);
			if (fallback || dropped || rejected) ok = FALSE;
			gst_object_unref(element);
		}
		gst_element_set_state(pipes[i], GST_STATE_NULL);
		gst_object_unref(sources[i]); gst_object_unref(pipes[i]);
		GArray *intervals = counters[i].intervals;
		g_array_sort(intervals, compare);
		double p50 = -1, p99 = -1;
		if (intervals->len) {
			p50 = g_array_index(intervals, double, (intervals->len-1) / 2);
			p99 = g_array_index(intervals, double, ((guint64)intervals->len * 99 + 99) / 100 - 1);
		}
		g_print("METRIC branch=%u seconds=%.6f fps=%.6f sent=%u output=%u pressure=%u p50_ms=%.6f p99_ms=%.6f jitter_ms=%.6f\n",
			i, start ? (stop-start)/1e6 : 0, start ? (at_stop[i]-baseline[i])*1e6/(stop-start) : 0,
			sent[i], output, pressure[i], p50, p99, p99-p50);
		g_array_unref(intervals);
	}
	for (unsigned i = 0; !capture && i < RING; i++) gst_buffer_unref(ring[i]);
	double cpu = (cpu_stop.ru_utime.tv_sec - cpu_start.ru_utime.tv_sec) +
		(cpu_stop.ru_stime.tv_sec - cpu_start.ru_stime.tv_sec) +
		(cpu_stop.ru_utime.tv_usec - cpu_start.ru_utime.tv_usec +
		 cpu_stop.ru_stime.tv_usec - cpu_start.ru_stime.tv_usec) / 1e6;
	g_print("RESULT ok=%d cpu_pct=%.6f\n", ok, start ? cpu*1e8/(stop-start) : -1);
	return ok ? 0 : 1;
}
