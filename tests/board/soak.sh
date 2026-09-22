#!/usr/bin/env bash
# shellcheck disable=SC2015  # --self-test uses the `cond && st_ok || st_bad` idiom; st_ok never fails
# shellcheck disable=SC2016  # ASSERT_AWK is a single-quoted awk program; the shell must NOT expand it
#
# soak.sh — long-duration media soak: sample every 60 s into a CSV, then assert
#           the slope rules over it.
#
# THE QUESTION IT ANSWERS. A ten-minute run proves a pipeline works. It cannot
# prove the pipeline does not leak, because every leak mechanism this campaign
# has met — a dma-buf never released, an IOMMU mapping never returned, a slab
# cache that only grows, an allocator arena that only ever reaches a new
# high-water mark — is invisible until a lot of cycles have gone by. The only
# instrument for that is a long window with a fixed sample cadence and a slope.
#
# WHAT IT MEASURES, AND FROM WHERE. Every quantity below is read from a
# first-party kernel or driver surface. Nothing is estimated and nothing is
# derived from a log message.
#
#   RSS               /proc/<engine-pid>/status VmRSS
#   slab              /proc/meminfo Slab + SUnreclaim  (whole-system)
#   dma-buf objects   /sys/kernel/debug/dma_buf/bufinfo  "Total N objects, B bytes"
#   IOMMU mappings    see THE IOMMU ROW below — source is RECORDED per sample
#   temperature       /sys/class/thermal/thermal_zone*/temp
#   clocks            cpufreq policy*/scaling_cur_freq + devfreq */cur_freq
#   CPU               /proc/stat, whole-system and per-core
#   fps               d(frames_emitted)/dt from the engine's own status events
#   bitrate           d(received bytes)/dt at the SRT sink
#   drops             engine encoder_restarts + kernel_faults
#   per-core share    /proc/mpp_service/load and /proc/rkrga/load
#
# THE IOMMU ROW IS THE ONE THAT NEEDS A CAVEAT, SO IT CARRIES ONE IN THE DATA.
# A whole-system outstanding-mapping census needs CONFIG_DMA_API_DEBUG, which
# this project enables on the `edge-test` kernel ONLY and positively forbids on
# production `edge`. On a production kernel /sys/kernel/debug/dma-api does not
# exist. This script therefore reads whichever of two sources is present and
# writes the source NAME into every row:
#
#   iommu_src=dma-api    /sys/kernel/debug/dma-api/num_free_entries against
#                        nr_total_entries — a real outstanding-mapping count,
#                        whole-system, available on edge-test only.
#   iommu_src=driver     the sum of the MPP session registry's IOVA rows
#                        (/proc/mpp_service/sessions-summary) and the RGA
#                        imported-handle count (/proc/rkrga/mm_session) — a
#                        DRIVER-REGISTRY PROXY for the two engines this soak
#                        actually drives, NOT a whole-system census.
#
# A `driver` row may never be reported as a whole-system IOMMU result. It is a
# strictly narrower claim and the column exists so that the narrowness is in the
# evidence rather than in a footnote.
#
# THE SLOPE RULES (the acceptance criteria this script exists to decide):
#
#   RSS slope            <= 0          ordinary least squares over the samples
#   slab slope           <= 0
#   dma-buf count        FLAT          slope <= 0 AND last - first <= band
#   IOMMU mappings       FLAT          same test, same band
#   fps                  >= 99 % of the target, at EVERY sample
#   drops                == 0          at every sample
#   per-core busy share  within 60/40  at every sample where the core group is
#                                      genuinely running on more than one core
#
# ON "SLOPE <= 0" AND THE ALLOCATOR HIGH-WATER MARK. This project's own RSS
# investigation established that a glibc arena reaches a high-water mark and
# plateaus: a run that ramps and then flattens has a POSITIVE whole-run OLS
# slope and is nonetheless bounded. This script does not paper over that. The
# assertion is the literal rule — whole-run slope <= 0 — and the tail slope over
# the last two thirds is computed and REPORTED beside it so the shape is
# visible. `--warmup-samples N` drops the first N samples from the fit; it
# defaults to 0, so the default verdict is the literal rule and any softening is
# an explicit, recorded argument rather than a default.
#
# READ-ONLY WITH RESPECT TO THE SYSTEM. It writes its CSV and its report and
# nothing else. It loads no module, installs no package, changes no boot state
# and touches no file under /boot, /usr or /etc. It drives the media engine
# only through the engine's own documented IPC.
#
# Usage:
#   soak.sh --run --duration SECONDS [options]     # sample + assert
#   soak.sh --check CSV [options]                  # assert over an existing CSV
#   soak.sh --sample-once [options]                # emit one CSV row and exit
#   soak.sh --self-test                            # no board, no engine
#   soak.sh --dump-fixtures DIR                    # write the self-test fixtures
#
# Options:
#   --duration N        soak length in seconds (required with --run)
#   --interval N        sample cadence in seconds (default 60)
#   --out DIR           report directory (default ./soak-<stamp>)
#   --csv PATH          CSV path (default <out>/soak.csv)
#   --target-fps N      expected frames per second (default 60)
#   --fps-floor-pct N   fps acceptance floor, percent of target (default 99)
#   --target-fps-override N
#                       assert the fps rule against N instead of the CSV's own
#                       target_fps column, so one collected CSV can publish both
#                       the literal verdict and a measured-rate stability verdict
#   --core-share-max N  per-core share ceiling, percent (default 60)
#   --warmup-samples N  samples dropped from the slope fits (default 0)
#   --flat-band N       absolute last-minus-first tolerance for the FLAT
#                       tests (default 0)
#   --engine-pid PID    engine process to measure (default: resolved from
#                       `systemctl show cerastream -p MainPID`)
#   --status-log FILE   file an engine event listener appends status events to
#   --sink-file FILE    file the SRT receiver writes, for the bitrate column
#   --sink-pid PID      SRT receiver process; its /proc/PID/io rchar is the byte
#                       counter when the receiver writes to /dev/null
#   --abort-on-divergence SECONDS
#                       after this many seconds of soak, evaluate the growth
#                       rules on what has been collected so far and stop early
#                       if any of them is already diverging (default: off)
#   --no-assert         collect only; do not run the assertions
#
# Exit codes:
#   0   every assertion passed (or --run collected with --no-assert)
#   1   at least one assertion FAILED
#   2   usage error
#   3   the run aborted early on a diverging growth rule
#   4   the data is unusable (too few samples, unreadable counters)

set -uo pipefail

SELF=${BASH_SOURCE[0]}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MODE=
DURATION=
INTERVAL=60
OUT=
CSV=
TARGET_FPS=60
FPS_FLOOR_PCT=99
TARGET_FPS_OVERRIDE=
CORE_SHARE_MAX=60
WARMUP=0
FLAT_BAND=0
ENGINE_PID=
STATUS_LOG=
SINK_FILE=
SINK_PID=
ABORT_AFTER=
NO_ASSERT=0

CSV_HEADER='ts_unix,elapsed_s,sample,rss_kib,slab_kib,slab_unreclaim_kib,dmabuf_objects,dmabuf_bytes,iommu_mappings,iommu_src,mpp_iova_rows,rga_buffers,temp_mc,cpu_khz_p0,cpu_khz_p4,cpu_khz_p6,gpu_hz,cpu_busy_pct,core_busy_pct,core_share_max_pct,core_share_group,fps,target_fps,bitrate_kbps,frames_emitted,enc_restarts,kernel_faults,drops,drops_src,rkvenc0_pct,rkvenc1_pct,rga0_pct,rga1_pct,rga2_pct,state,taint'

die() { printf 'soak.sh: %s\n' "$1" >&2; exit "${2:-2}"; }
log() { printf '[soak ] %s %s\n' "$(date -u +%H:%M:%S)" "$1" >&2; }

usage() { sed -n '/^# Usage:/,/^#   4 /p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
	local a
	while (($# > 0)); do
		a=$1
		case $a in
		--*=*) set -- "${a%%=*}" "${a#*=}" "${@:2}"; continue ;;
		esac
		case $1 in
		--run) MODE=run ;;
		--check) MODE=check; CSV=${2:?--check needs a CSV path}; shift ;;
		--sample-once) MODE=sample-once ;;
		--self-test) MODE=self-test ;;
		--dump-fixtures) MODE=dump-fixtures; OUT=${2:?--dump-fixtures needs a directory}; shift ;;
		--duration) DURATION=${2:?}; shift ;;
		--interval) INTERVAL=${2:?}; shift ;;
		--out) OUT=${2:?}; shift ;;
		--csv) CSV=${2:?}; shift ;;
		--target-fps) TARGET_FPS=${2:?}; shift ;;
		--fps-floor-pct) FPS_FLOOR_PCT=${2:?}; shift ;;
		--target-fps-override) TARGET_FPS_OVERRIDE=${2:?}; shift ;;
		--core-share-max) CORE_SHARE_MAX=${2:?}; shift ;;
		--warmup-samples) WARMUP=${2:?}; shift ;;
		--flat-band) FLAT_BAND=${2:?}; shift ;;
		--engine-pid) ENGINE_PID=${2:?}; shift ;;
		--status-log) STATUS_LOG=${2:?}; shift ;;
		--sink-file) SINK_FILE=${2:?}; shift ;;
		--sink-pid) SINK_PID=${2:?}; shift ;;
		--abort-on-divergence) ABORT_AFTER=${2:?}; shift ;;
		--no-assert) NO_ASSERT=1 ;;
		-h | --help) usage ;;
		*) die "unknown option '$1'" ;;
		esac
		shift
	done
}

# ---------------------------------------------------------------------------
# Collection primitives. Each returns a bare value, or the literal NA when the
# surface is not readable on this kernel. NA is never silently turned into 0.
# ---------------------------------------------------------------------------

read_engine_pid() {
	[[ -n $ENGINE_PID ]] && { printf '%s\n' "$ENGINE_PID"; return 0; }
	local p
	p=$(systemctl show cerastream -p MainPID --value 2>/dev/null)
	[[ ${p:-0} =~ ^[0-9]+$ && ${p:-0} -gt 0 ]] || return 1
	printf '%s\n' "$p"
}

sample_rss_kib() {
	local pid=$1 v
	v=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
	printf '%s\n' "${v:-NA}"
}

sample_slab() { # -> "<Slab kB> <SUnreclaim kB>"
	awk '/^Slab:/{s=$2} /^SUnreclaim:/{u=$2} END{printf "%s %s\n", (s==""?"NA":s), (u==""?"NA":u)}' \
		/proc/meminfo 2>/dev/null || printf 'NA NA\n'
}

sample_dmabuf() { # -> "<objects> <bytes>"
	local line
	line=$(grep -E '^Total [0-9]+ objects' /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null | tail -1)
	if [[ -z $line ]]; then printf 'NA NA\n'; return 0; fi
	printf '%s %s\n' "$(awk '{print $2}' <<<"$line")" "$(awk '{print $4}' <<<"$line")"
}

# MPP session registry: every line naming an IOVA range is one outstanding
# device mapping the encoder holds. Counting lines is deliberate — the count,
# not the bytes, is what a mapping leak moves.
# `grep -c` prints its zero AND exits 1 on an idle board, so an `|| printf 0`
# fallback emits the count twice and every downstream arithmetic breaks.
sample_mpp_iova_rows() {
	local f=/proc/mpp_service/sessions-summary v
	[[ -r $f ]] || { printf 'NA\n'; return 0; }
	v=$(grep -cE '0x[0-9a-fA-F]+' "$f" 2>/dev/null)
	[[ $v =~ ^[0-9]+$ ]] || v=0
	printf '%s\n' "$v"
}

sample_rga_buffers() {
	local f=/proc/rkrga/mm_session v
	[[ -r $f ]] || { printf 'NA\n'; return 0; }
	v=$(awk -F= '/buffer count/{gsub(/ /,"",$2); print $2}' "$f" 2>/dev/null | tail -1)
	printf '%s\n' "${v:-NA}"
}

# Whole-system outstanding DMA-API mappings, edge-test only.
sample_dma_api_outstanding() {
	local d=/sys/kernel/debug/dma-api tot free
	[[ -r $d/nr_total_entries && -r $d/num_free_entries ]] || { printf 'NA\n'; return 0; }
	tot=$(cat "$d/nr_total_entries" 2>/dev/null)
	free=$(cat "$d/num_free_entries" 2>/dev/null)
	[[ $tot =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] || { printf 'NA\n'; return 0; }
	printf '%s\n' "$((tot - free))"
}

sample_temp_mc() {
	local t
	t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
	printf '%s\n' "${t:-NA}"
}

sample_clocks() { # -> "<p0 kHz> <p4 kHz> <p6 kHz> <gpu Hz>"
	local p0 p4 p6 g
	p0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
	p4=$(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq 2>/dev/null)
	p6=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq 2>/dev/null)
	g=$(cat /sys/class/devfreq/fb000000.gpu/cur_freq 2>/dev/null)
	printf '%s %s %s %s\n' "${p0:-NA}" "${p4:-NA}" "${p6:-NA}" "${g:-NA}"
}

# /proc/stat snapshot: "total0 idle0 total1 idle1 ..." with index 0 = whole system.
sample_cpu_raw() {
	awk '/^cpu/ {
		tot=0; for (i=2;i<=NF;i++) tot+=$i
		idle=$5+$6
		printf "%s %s ", tot, idle
	} END { print "" }' /proc/stat 2>/dev/null
}

# MPP per-core load. "<rkvenc0> <rkvenc1>" in percent.
sample_rkvenc_load() {
	local f=/proc/mpp_service/load
	[[ -r $f ]] || { printf 'NA NA\n'; return 0; }
	awk '/rkvenc-core/ {
		for (i=1;i<=NF;i++) if ($i=="load:") { v=$(i+1); gsub(/%/,"",v); a[n++]=v }
	} END { printf "%s %s\n", (n>0?a[0]:"NA"), (n>1?a[1]:"NA") }' "$f" 2>/dev/null
}

# RGA per-scheduler load. "<s0> <s1> <s2>" in percent.
sample_rga_load() {
	local f=/proc/rkrga/load
	[[ -r $f ]] || { printf 'NA NA NA\n'; return 0; }
	awk '/load = / { v=$3; gsub(/%/,"",v); a[n++]=v }
	     END { printf "%s %s %s\n", (n>0?a[0]:"NA"), (n>1?a[1]:"NA"), (n>2?a[2]:"NA") }' "$f" 2>/dev/null
}

sample_taint() { cat /proc/sys/kernel/tainted 2>/dev/null || printf 'NA\n'; }

# Latest engine status event. -> "<frames> <restarts> <faults> <state>"
sample_engine_status() {
	if [[ -z $STATUS_LOG || ! -r $STATUS_LOG ]]; then printf 'NA NA NA NA\n'; return 0; fi
	tac "$STATUS_LOG" 2>/dev/null | grep -m1 '"type":"status"' |
		awk '{
			f="NA"; r="NA"; k="NA"; s="NA"
			if (match($0, /"frames_emitted":[0-9]+/))   { f=substr($0,RSTART+17,RLENGTH-17) }
			if (match($0, /"encoder_restarts":[0-9]+/)) { r=substr($0,RSTART+19,RLENGTH-19) }
			if (match($0, /"kernel_faults":[0-9]+/))    { k=substr($0,RSTART+16,RLENGTH-16) }
			if (match($0, /"state":"[a-z_]+"/))         { s=substr($0,RSTART+9,RLENGTH-10) }
			printf "%s %s %s %s\n", f, r, k, s
		}' || printf 'NA NA NA NA\n'
}

# The drops column, and which engine surface produced it.
#
# A released engine does not necessarily publish `encoder_restarts` /
# `kernel_faults`: those fields exist on the instrumented build this campaign
# used for the fault-bridge work and are ABSENT from the packaged 2026.9.5
# status payload, measured on the board. When they are missing the column falls
# back to the cumulative count of `error` events on the same subscription —
# still an engine-reported fault count, still monotone, and labelled so the
# weaker source cannot be mistaken for the stronger one. With neither surface
# the column is NA and the rule reports NOT-APPLICABLE rather than PASS.
sample_drops() { # -> "<drops> <source>"
	local r=$1 k=$2
	if [[ $r != NA && $k != NA ]]; then printf '%s engine-counters\n' "$((r + k))"; return 0; fi
	if [[ -n $STATUS_LOG && -r $STATUS_LOG ]]; then
		local n
		n=$(grep -c '"type":"error"' "$STATUS_LOG" 2>/dev/null)
		[[ $n =~ ^[0-9]+$ ]] || n=0
		printf '%s error-events\n' "$n"
		return 0
	fi
	printf 'NA none\n'
}

# Cumulative bytes delivered to the sink. A three-hour 4K60 stream is tens of
# gigabytes, far more than a 4 GiB rootfs slot holds, so the receiver normally
# writes to /dev/null and the byte counter comes from the kernel's own per-task
# I/O accounting instead of from a file size. It is `wchar`, the bytes the
# receiver WROTE OUT: measured on a real srt-live-transmit, `rchar` stays pinned
# at its startup value because the SRT payload never arrives through a
# read()-accounted syscall, so reading `rchar` reports a flat 0 kbps stream.
sample_sink_bytes() {
	if [[ -n $SINK_PID && -r /proc/$SINK_PID/io ]]; then
		awk '/^wchar:/{print $2; f=1} END{if(!f) print "NA"}' "/proc/$SINK_PID/io" 2>/dev/null
		return 0
	fi
	[[ -n $SINK_FILE && -e $SINK_FILE ]] || { printf 'NA\n'; return 0; }
	stat -c %s "$SINK_FILE" 2>/dev/null || printf 'NA\n'
}

# ---------------------------------------------------------------------------
# One CSV row.
# ---------------------------------------------------------------------------
PREV_CPU=; PREV_TS=; PREV_FRAMES=; PREV_BYTES=; SAMPLE_N=0; T0=

emit_sample() {
	local pid=$1 now rss cpu_now sink
	local slab_kb slab_unrec dmabuf_obj dmabuf_bytes p0 p4 p6 gpu
	local rkv0 rkv1 rga0 rga1 rga2 frames restarts faults state
	now=$(date +%s)
	[[ -n $T0 ]] || T0=$now

	rss=$(sample_rss_kib "$pid")
	read -r slab_kb slab_unrec <<<"$(sample_slab)"
	read -r dmabuf_obj dmabuf_bytes <<<"$(sample_dmabuf)"
	local mpp_rows rga_bufs iommu iommu_src dmaapi
	mpp_rows=$(sample_mpp_iova_rows)
	rga_bufs=$(sample_rga_buffers)
	dmaapi=$(sample_dma_api_outstanding)
	if [[ $dmaapi != NA ]]; then
		iommu=$dmaapi; iommu_src=dma-api
	else
		iommu_src=driver
		if [[ $mpp_rows == NA && $rga_bufs == NA ]]; then
			iommu=NA; iommu_src=none
		else
			local a=${mpp_rows/NA/0} b=${rga_bufs/NA/0}
			iommu=$((a + b))
		fi
	fi
	local temp; temp=$(sample_temp_mc)
	read -r p0 p4 p6 gpu <<<"$(sample_clocks)"
	cpu_now=$(sample_cpu_raw)
	read -r rkv0 rkv1 <<<"$(sample_rkvenc_load)"
	read -r rga0 rga1 rga2 <<<"$(sample_rga_load)"
	read -r frames restarts faults state <<<"$(sample_engine_status)"
	sink=$(sample_sink_bytes)
	local taint; taint=$(sample_taint)

	# Derived, delta-based columns. The first sample has no predecessor, so it
	# reports NA rather than a fabricated zero.
	local cpu_busy=NA core_busy=NA fps=NA bitrate=NA dt=0
	if [[ -n $PREV_TS ]]; then dt=$((now - PREV_TS)); fi
	((dt > 0)) || dt=0

	if [[ -n $PREV_CPU && $dt -gt 0 ]]; then
		read -r cpu_busy core_busy <<<"$(awk -v prev="$PREV_CPU" -v cur="$cpu_now" '
			BEGIN {
				np=split(prev,P," "); nc=split(cur,C," ")
				n=(np<nc?np:nc)
				out=""
				for (i=1;i<=n;i+=2) {
					dt_=C[i]-P[i]; di=C[i+1]-P[i+1]
					b=(dt_>0)?(100.0*(dt_-di)/dt_):0
					if (i==1) { printf "%.2f ", b } else { out = out sprintf("%s%.2f", (out==""?"":"|"), b) }
				}
				print out
			}')"
	fi

	if [[ $frames != NA && -n $PREV_FRAMES && $PREV_FRAMES != NA && $dt -gt 0 ]]; then
		fps=$(awk -v a="$PREV_FRAMES" -v b="$frames" -v d="$dt" 'BEGIN{printf "%.3f", (b-a)/d}')
	fi
	if [[ $sink != NA && -n $PREV_BYTES && $PREV_BYTES != NA && $dt -gt 0 ]]; then
		bitrate=$(awk -v a="$PREV_BYTES" -v b="$sink" -v d="$dt" 'BEGIN{printf "%.1f", (b-a)*8.0/1000.0/d}')
	fi

	# Per-core share: only meaningful where a hardware core GROUP is genuinely
	# spread over more than one core. A single active core is not an unfair
	# split, it is a single-core workload, and the sample is marked n/a so it
	# cannot silently pass or silently fail the 60/40 rule.
	local share=NA group=none
	read -r share group <<<"$(awk -v a="$rkv0" -v b="$rkv1" -v c="$rga0" -v d="$rga1" -v e="$rga2" '
		function share3(x,y,z,  s,m) {
			s=x+y+z; if (s<=0) return -1
			m=x; if (y>m) m=y; if (z>m) m=z
			return 100.0*m/s
		}
		BEGIN {
			# RKVENC pair first: it is the resource this soak actually contends.
			if (a!="NA" && b!="NA" && a+0>0 && b+0>0) { printf "%.2f rkvenc\n", 100.0*((a+0>b+0)?a:b)/(a+b); exit }
			n=0
			if (c!="NA" && c+0>0) n++
			if (d!="NA" && d+0>0) n++
			if (e!="NA" && e+0>0) n++
			if (n>1) { s=share3((c=="NA"?0:c),(d=="NA"?0:d),(e=="NA"?0:e)); if (s>=0) { printf "%.2f rga\n", s; exit } }
			print "NA none"
		}')"

	local drops drops_src
	read -r drops drops_src <<<"$(sample_drops "$restarts" "$faults")"

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$now" "$((now - T0))" "$SAMPLE_N" \
		"$rss" "$slab_kb" "$slab_unrec" \
		"$dmabuf_obj" "$dmabuf_bytes" \
		"$iommu" "$iommu_src" "$mpp_rows" "$rga_bufs" \
		"$temp" "$p0" "$p4" "$p6" "$gpu" \
		"${cpu_busy:-NA}" "${core_busy:-NA}" "$share" "$group" \
		"$fps" "$TARGET_FPS" "$bitrate" \
		"$frames" "$restarts" "$faults" \
		"$drops" "$drops_src" \
		"$rkv0" "$rkv1" "$rga0" "$rga1" "$rga2" \
		"$state" "$taint"

	PREV_CPU=$cpu_now; PREV_TS=$now; PREV_FRAMES=$frames; PREV_BYTES=$sink
	SAMPLE_N=$((SAMPLE_N + 1))
}

# ---------------------------------------------------------------------------
# The assertions. One awk program, so that the arithmetic is identical whether
# it runs at the end of a soak, over a saved CSV, or over a self-test fixture.
# ---------------------------------------------------------------------------
ASSERT_AWK='
function col(name) { return idx[name] }
function num(v) { return (v=="NA" || v=="" ) ? "" : v+0 }
function ols(n, sx, sy, sxx, sxy,   d) {
	if (n < 2) return "NA"
	d = n*sxx - sx*sx
	if (d == 0) return "NA"
	return (n*sxy - sx*sy) / d
}
BEGIN { FS=","; fail=0; nsamp=0 }
NR==1 {
	for (i=1;i<=NF;i++) idx[$i]=i
	for (k in need) if (!(k in idx)) { printf "DATA-ERROR missing column %s\n", k; bad_header=1 }
	next
}
{
	nsamp++
	rec_ts[nsamp]=$col("elapsed_s")
	rec_rss[nsamp]=$col("rss_kib")
	rec_slab[nsamp]=$col("slab_kib")
	rec_buf[nsamp]=$col("dmabuf_objects")
	rec_iommu[nsamp]=$col("iommu_mappings")
	rec_isrc[nsamp]=$col("iommu_src")
	rec_fps[nsamp]=$col("fps")
	rec_tfps[nsamp]=$col("target_fps")
	rec_drops[nsamp]=$col("drops")
	rec_dsrc[nsamp]=$col("drops_src")
	rec_share[nsamp]=$col("core_share_max_pct")
	rec_group[nsamp]=$col("core_share_group")
	rec_taint[nsamp]=$col("taint")
}
END {
	if (bad_header) { exit 4 }
	if (nsamp < 3) { printf "DATA-ERROR only %d sample(s); need at least 3\n", nsamp; exit 4 }

	# --- the four growth series -------------------------------------------
	split("rss slab bufinfo iommu", series, " ")
	for (s=1; s<=4; s++) {
		name = series[s]
		n=0; sx=0; sy=0; sxx=0; sxy=0; first=""; last=""; mn=""; mx=""
		tn=0; tsx=0; tsy=0; tsxx=0; tsxy=0
		nna=0
		start = warmup + 1
		for (i=1; i<=nsamp; i++) {
			if      (name=="rss")     v = num(rec_rss[i])
			else if (name=="slab")    v = num(rec_slab[i])
			else if (name=="bufinfo") v = num(rec_buf[i])
			else                      v = num(rec_iommu[i])
			if (v=="") { nna++; continue }
			if (i < start) continue
			n++; x=n
			sx+=x; sy+=v; sxx+=x*x; sxy+=x*v
			if (first=="") first=v
			last=v
			if (mn==""||v<mn) mn=v
			if (mx==""||v>mx) mx=v
			if (n > int(nsamp/3)) { tn++; tx=tn; tsx+=tx; tsy+=v; tsxx+=tx*tx; tsxy+=tx*v }
		}
		slope[name] = ols(n, sx, sy, sxx, sxy)
		tail[name]  = ols(tn, tsx, tsy, tsxx, tsxy)
		f[name]=first; l[name]=last; lo[name]=mn; hi[name]=mx; cnt[name]=n; na[name]=nna
	}

	# --- RSS ---------------------------------------------------------------
	verdict("RSS slope <= 0", "rss", (slope["rss"]!="NA" && slope["rss"] <= 0))
	# --- slab --------------------------------------------------------------
	verdict("slab slope <= 0", "slab", (slope["slab"]!="NA" && slope["slab"] <= 0))
	# --- dma-buf FLAT ------------------------------------------------------
	verdict("dma-buf objects FLAT", "bufinfo",
		(slope["bufinfo"]!="NA" && slope["bufinfo"] <= 0 && (l["bufinfo"]-f["bufinfo"]) <= band))
	# --- IOMMU FLAT --------------------------------------------------------
	if (cnt["iommu"] == 0) {
		printf "NOT-APPLICABLE  IOMMU mappings FLAT  (no readable sample; iommu_src=none)\n"
		na_rules++
	} else {
		verdict("IOMMU mappings FLAT", "iommu",
			(slope["iommu"]!="NA" && slope["iommu"] <= 0 && (l["iommu"]-f["iommu"]) <= band))
	}

	# --- fps ---------------------------------------------------------------
	nfps=0; worst=""; worst_i=0; viol=0
	for (i=1;i<=nsamp;i++) {
		v=num(rec_fps[i]); if (v=="") continue
		t=(tfps_override>0) ? tfps_override : num(rec_tfps[i]); if (t=="") continue
		nfps++
		floorv = t*floorpct/100.0
		if (worst==""||v<worst) { worst=v; worst_i=i }
		if (v < floorv) viol++
	}
	if (nfps==0) { printf "NOT-APPLICABLE  fps >= %g%% of target  (no fps samples)\n", floorpct; na_rules++ }
	else {
		ok = (viol==0)
		printf "%-6s fps >= %g%% of target=%g  samples=%d  min=%.3f (sample %d)  floor=%.3f  violations=%d\n",
			(ok?"PASS":"FAIL"), floorpct, ((tfps_override>0)?tfps_override:num(rec_tfps[1])), nfps, worst, worst_i-1,
			((tfps_override>0)?tfps_override:num(rec_tfps[1]))*floorpct/100.0, viol
		if (!ok) fail++
	}

	# --- drops -------------------------------------------------------------
	nd=0; dmax=""; dviol=0; dsrc=""
	for (i=1;i<=nsamp;i++) {
		v=num(rec_drops[i]); if (v=="") continue
		nd++
		if (dsrc=="") dsrc=rec_dsrc[i]
		if (dmax==""||v>dmax) dmax=v
		if (v != 0) dviol++
	}
	if (nd==0) { printf "NOT-APPLICABLE  drops == 0  (no drop samples)\n"; na_rules++ }
	else {
		ok=(dviol==0)
		printf "%-6s drops == 0              samples=%d  source=%s  max=%d  violations=%d\n", (ok?"PASS":"FAIL"), nd, (dsrc==""?"?":dsrc), dmax, dviol
		if (!ok) fail++
	}

	# --- per-core share ----------------------------------------------------
	ns=0; smax=""; sviol=0; grp=""
	for (i=1;i<=nsamp;i++) {
		v=num(rec_share[i]); if (v=="") continue
		ns++
		if (grp=="") grp=rec_group[i]
		if (smax==""||v>smax) smax=v
		if (v > sharemax) sviol++
	}
	if (ns==0) {
		printf "NOT-APPLICABLE  per-core share <= %g/%g  (no sample had a multi-core group active)\n", sharemax, 100-sharemax
		na_rules++
	} else {
		ok=(sviol==0)
		printf "%-6s per-core share <= %g/%g  samples=%d  group=%s  max=%.2f%%  violations=%d\n",
			(ok?"PASS":"FAIL"), sharemax, 100-sharemax, ns, grp, smax, sviol
		if (!ok) fail++
	}

	# --- hygiene (reported, not part of the slope verdict) -----------------
	tmax=""
	for (i=1;i<=nsamp;i++) { v=num(rec_taint[i]); if (v=="") continue; if (tmax==""||v>tmax) tmax=v }
	printf "INFO   kernel taint max=%s over %d samples\n", (tmax==""?"NA":tmax), nsamp

	printf "\n--- series detail (warmup-samples dropped: %d) ---\n", warmup
	for (s=1; s<=4; s++) {
		name=series[s]
		printf "%-8s n=%-4d na=%-3d first=%s last=%s min=%s max=%s slope=%s tail_slope=%s\n",
			name, cnt[name], na[name],
			(f[name]==""?"NA":f[name]), (l[name]==""?"NA":l[name]),
			(lo[name]==""?"NA":lo[name]), (hi[name]==""?"NA":hi[name]),
			(slope[name]=="NA"?"NA":sprintf("%.6f", slope[name])),
			(tail[name]=="NA"?"NA":sprintf("%.6f", tail[name]))
	}
	printf "\nsamples=%d  failed_rules=%d  not_applicable_rules=%d\n", nsamp, fail, na_rules+0
	printf "%s\n", (fail>0 ? "VERDICT: FAIL" : "VERDICT: PASS")
	exit (fail>0 ? 1 : 0)
}
function verdict(label, name, ok) {
	printf "%-6s %-24s n=%-4d first=%s last=%s slope=%s (tail %s)\n",
		(ok?"PASS":"FAIL"), label, cnt[name],
		(f[name]==""?"NA":f[name]), (l[name]==""?"NA":l[name]),
		(slope[name]=="NA"?"NA":sprintf("%.6f", slope[name])),
		(tail[name]=="NA"?"NA":sprintf("%.6f", tail[name]))
	if (!ok) fail++
}
'

run_assertions() {
	local csv=$1
	[[ -r $csv ]] || die "cannot read CSV '$csv'" 4
	awk -v warmup="$WARMUP" -v band="$FLAT_BAND" -v floorpct="$FPS_FLOOR_PCT" \
		-v sharemax="$CORE_SHARE_MAX" -v tfps_override="${TARGET_FPS_OVERRIDE:-0}" \
		'BEGIN{ split("elapsed_s rss_kib slab_kib dmabuf_objects iommu_mappings fps target_fps drops drops_src core_share_max_pct taint", a, " "); for (i in a) need[a[i]]=1 }'"$ASSERT_AWK" \
		"$csv"
}

# The early-divergence gate. It asks only one question — is a growth series
# already climbing in a way that will not self-correct — and it deliberately
# does NOT consider fps, drops or core share, because those are per-sample rules
# that the final verdict decides and that a transient can trip.
check_divergence() {
	local csv=$1
	awk -F, -v warmup="$WARMUP" '
	function num(v){ return (v=="NA"||v=="")?"":v+0 }
	NR==1 { for (i=1;i<=NF;i++) idx[$i]=i; next }
	{ n++; rss[n]=$idx["rss_kib"]; slab[n]=$idx["slab_kib"]; buf[n]=$idx["dmabuf_objects"]; io[n]=$idx["iommu_mappings"] }
	END {
		if (n < 10) { print "INSUFFICIENT"; exit 0 }
		split("rss slab bufinfo iommu", s, " ")
		div=0; why=""
		for (k=1;k<=4;k++) {
			name=s[k]; c=0; sx=0; sy=0; sxx=0; sxy=0; fst=""; lst=""
			hc=0; hsx=0; hsy=0; hsxx=0; hsxy=0
			tot=0
			for (i=warmup+1;i<=n;i++) {
				if (name=="rss") v=num(rss[i]); else if (name=="slab") v=num(slab[i]);
				else if (name=="bufinfo") v=num(buf[i]); else v=num(io[i])
				if (v!="") tot++
			}
			if (tot<10) continue
			half = int(tot/2)
			for (i=warmup+1;i<=n;i++) {
				if (name=="rss") v=num(rss[i]); else if (name=="slab") v=num(slab[i]);
				else if (name=="bufinfo") v=num(buf[i]); else v=num(io[i])
				if (v=="") continue
				c++; sx+=c; sy+=v; sxx+=c*c; sxy+=c*v
				if (fst=="") fst=v
				lst=v
				if (c > half) { hc++; hsx+=hc; hsy+=v; hsxx+=hc*hc; hsxy+=hc*v }
			}
			d=c*sxx-sx*sx; if (d==0) continue
			sl=(c*sxy-sx*sy)/d
			mean=sy/c
			hsl="NA"
			hd=hc*hsxx-hsx*hsx
			if (hc>=4 && hd!=0) hsl=(hc*hsxy-hsx*hsy)/hd
			# DIVERGING means the series is still climbing at the END of what has
			# been collected, not merely that it climbed at some point. A glibc
			# arena high-water ramp climbs and then flattens: its whole-run slope
			# is positive and its LAST-HALF slope is ~0, so it is not diverging.
			# A real leak keeps the last-half slope positive. Both must hold,
			# plus a net end-to-end rise and a rate that matters relative to the
			# level of the series.
			if (sl > 0 && mean > 0 && (sl/mean) > 0.001 && lst > fst &&
			    hsl != "NA" && hsl > 0 && (hsl/mean) > 0.001) {
				div=1
				why = why sprintf("%s slope=%.4f last_half_slope=%.4f mean=%.1f per-sample=%.3f%% first=%s last=%s; ",
					name, sl, hsl, mean, 100*sl/mean, fst, lst)
			}
		}
		if (div) { printf "DIVERGING %s\n", why } else { print "OK" }
	}' "$csv"
}

# ---------------------------------------------------------------------------
# --run
# ---------------------------------------------------------------------------
do_run() {
	[[ -n $DURATION ]] || die "--run needs --duration"
	[[ $DURATION =~ ^[0-9]+$ ]] || die "--duration must be an integer number of seconds"
	[[ $INTERVAL =~ ^[0-9]+$ && $INTERVAL -gt 0 ]] || die "--interval must be a positive integer"
	OUT=${OUT:-./soak-$(date -u +%Y%m%dT%H%M%SZ)}
	mkdir -p "$OUT" || die "cannot create '$OUT'"
	CSV=${CSV:-$OUT/soak.csv}

	local pid
	pid=$(read_engine_pid) || die "cannot resolve the engine PID (pass --engine-pid)" 4
	[[ -d /proc/$pid ]] || die "engine PID $pid is not running" 4
	log "engine pid=$pid duration=${DURATION}s interval=${INTERVAL}s csv=$CSV"

	printf '%s\n' "$CSV_HEADER" >"$CSV"

	local start now aborted=0
	start=$(date +%s)
	while :; do
		emit_sample "$pid" >>"$CSV"
		now=$(date +%s)
		if [[ -n $ABORT_AFTER ]] && ((now - start >= ABORT_AFTER)); then
			local d; d=$(check_divergence "$CSV")
			if [[ $d == DIVERGING* ]]; then
				log "ABORT: $d"
				printf '%s\n' "$d" >"$OUT/divergence.txt"
				aborted=1
				break
			fi
		fi
		((now - start >= DURATION)) && break
		if [[ ! -d /proc/$pid ]]; then
			log "engine pid $pid vanished; stopping collection"
			printf 'engine pid %s vanished at %s\n' "$pid" "$(date -u +%FT%TZ)" >"$OUT/engine-vanished.txt"
			break
		fi
		sleep "$INTERVAL"
	done

	log "collected $SAMPLE_N sample(s) into $CSV"
	((NO_ASSERT == 0)) || return 0
	run_assertions "$CSV" | tee "$OUT/verdict.txt"
	local rc=${PIPESTATUS[0]}
	((aborted == 0)) || return 3
	return "$rc"
}

# ---------------------------------------------------------------------------
# --self-test. No board, no engine, no privileged read: it builds fixture CSVs
# and drives the REAL assertion code over them. A fixture per rule proves the
# checker DISCRIMINATES; a checker that only ever says PASS is not a checker.
# ---------------------------------------------------------------------------
ST_PASS=0; ST_FAIL=0
st_ok() { printf '  ok   %s\n' "$1"; ST_PASS=$((ST_PASS + 1)); }
st_bad() { printf '  FAIL %s\n' "$1"; ST_FAIL=$((ST_FAIL + 1)); }

# Build a healthy 40-sample CSV. Every series is flat or mildly decaying; fps
# sits on target; drops are zero; the RKVENC pair is near 50/50.
st_make_pass() {
	local f=$1
	printf '%s\n' "$CSV_HEADER" >"$f"
	awk -v hdr="$CSV_HEADER" 'BEGIN {
		srand(7)
		base=1789000000
		for (i=0;i<40;i++) {
			ts=base+i*60
			rss  = 250000 - int(i*3)          # gently decaying
			slab = 102000 - int(i*2)
			buf  = 27                          # oscillates but never drifts
			if (i%3==0) buf=26
			if (i%7==0) buf=28
			io   = (i < 20) ? 10 : 9    # oscillation-free, and it ends lower than it started
			if (i==7 || i==23) io = io - 1
			fps  = (i==0) ? "NA" : sprintf("%.3f", 60.0 - ((i%4)*0.05))
			br   = (i==0) ? "NA" : "12000.0"
			cpu  = sprintf("%.2f", 30+(i%5))
			core = "30.00|28.00|31.00|29.00|22.00|21.00|23.00|24.00"
			sh   = sprintf("%.2f", 51.0 + (i%3))
			printf "%d,%d,%d,%d,%d,%d,%d,%d,%d,driver,8,2,45000,1800000,2400000,2400000,300000000,%s,%s,%s,rkvenc,%s,60,%s,%d,0,0,0,engine-counters,49,48,7,6,0,streaming,0\n",
				ts, i*60, i, rss, slab, 65000-i, buf, buf*2097152, io, cpu, core, sh, fps, br, 1000+i*3600
		}
	}' >>"$f"
}

# Mutate exactly one column of the healthy fixture.
st_mutate() {
	local src=$1 dst=$2 colname=$3 expr=$4
	awk -F, -v OFS=, -v want="$colname" -v e="$expr" '
	NR==1 { for (i=1;i<=NF;i++) if ($i==want) c=i; print; next }
	{
		n=NR-2
		if (e=="rss-creep")     $c = 250000 + n*900
		else if (e=="slab-creep")  $c = 102000 + n*400
		else if (e=="buf-creep")   $c = 27 + int(n/2)
		else if (e=="iommu-creep") $c = 10 + int(n/3)
		else if (e=="fps-sag")     { if (n>=20) $c = "55.000" }
		else if (e=="drops-nonzero") { if (n>=25) $c = 3 }
		else if (e=="share-skew")  { if (n>=10) $c = "78.00" }
		print
	}' "$src" >"$dst"
}

st_verdict() { # -> the VERDICT line
	WARMUP=0 FLAT_BAND=0 FPS_FLOOR_PCT=99 CORE_SHARE_MAX=60 run_assertions "$1" 2>&1
}

ST_DIR=
do_self_test() {
	local d; d=$(mktemp -d) || die "mktemp failed" 4
	ST_DIR=$d
	trap 'rm -rf "${ST_DIR:-}"' EXIT
	printf 'soak.sh --self-test\n\n'

	# ---- 1. the healthy fixture passes -------------------------------------
	st_make_pass "$d/pass.csv"
	local out rc
	out=$(st_verdict "$d/pass.csv"); rc=$?
	if ((rc == 0)) && grep -q '^VERDICT: PASS' <<<"$out"; then
		st_ok "a healthy 40-sample CSV PASSES (exit 0)"
	else
		st_bad "healthy fixture did not pass (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
	fi
	grep -q 'NOT-APPLICABLE' <<<"$out" &&
		{ st_bad "healthy fixture left a rule NOT-APPLICABLE (it must exercise all seven)"; printf '%s\n' "$out" | sed 's/^/      /'; } ||
		st_ok "the healthy fixture exercises every rule (none NOT-APPLICABLE)"

	# ---- 2. one mutation per rule, each caught, and ONLY that rule ---------
	local -a names=(rss slab bufinfo iommu fps drops share)
	local -a cols=(rss_kib slab_kib dmabuf_objects iommu_mappings fps drops core_share_max_pct)
	local -a exprs=(rss-creep slab-creep buf-creep iommu-creep fps-sag drops-nonzero share-skew)
	local -a labels=('RSS slope <= 0' 'slab slope <= 0' 'dma-buf objects FLAT' 'IOMMU mappings FLAT' 'fps >= 99% of target' 'drops == 0' 'per-core share <= 60/40')
	local i
	for i in "${!names[@]}"; do
		local n=${names[$i]}
		st_mutate "$d/pass.csv" "$d/fail-$n.csv" "${cols[$i]}" "${exprs[$i]}"
		if cmp -s "$d/pass.csv" "$d/fail-$n.csv"; then
			st_bad "$n: the mutation changed nothing (the fixture cannot discriminate)"
			continue
		fi
		out=$(st_verdict "$d/fail-$n.csv"); rc=$?
		if ((rc != 1)); then
			st_bad "$n: expected exit 1, got $rc"; printf '%s\n' "$out" | sed 's/^/      /'; continue
		fi
		grep -q '^VERDICT: FAIL' <<<"$out" || { st_bad "$n: no FAIL verdict"; continue; }
		# the failing rule must be the mutated one
		local failed
		failed=$(grep -c '^FAIL' <<<"$out")
		if ((failed != 1)); then
			st_bad "$n: $failed rules failed, expected exactly 1"
			printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/      /'
			continue
		fi
		if grep '^FAIL' <<<"$out" | grep -qF "${labels[$i]}"; then
			st_ok "$n creep/violation is caught, and it is the ONLY rule that fails"
		else
			st_bad "$n: the wrong rule failed"; printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/      /'
		fi
	done

	# ---- 3. a plateau is NOT a pass under the literal rule ------------------
	# A ramp-then-flat RSS has a positive whole-run slope. The literal rule must
	# fail it, and --warmup-samples must be what changes that verdict — never a
	# silent tolerance inside the checker.
	awk -F, -v OFS=, 'NR==1{for(i=1;i<=NF;i++) if($i=="rss_kib") c=i; print; next}
		{ n=NR-2; $c = (n<10) ? 250000 + n*2000 : 270000; print }' \
		"$d/pass.csv" >"$d/plateau.csv"
	out=$(WARMUP=0 st_verdict "$d/plateau.csv"); rc=$?
	((rc == 1)) && grep '^FAIL' <<<"$out" | grep -q 'RSS slope' &&
		st_ok "a ramp-then-plateau RSS FAILS the literal slope<=0 rule at --warmup-samples 0" ||
		st_bad "plateau fixture did not fail the literal rule (rc=$rc)"
	out=$(WARMUP=12 FLAT_BAND=0 FPS_FLOOR_PCT=99 CORE_SHARE_MAX=60 run_assertions "$d/plateau.csv" 2>&1); rc=$?
	((rc == 0)) &&
		st_ok "the same plateau PASSES with --warmup-samples 12 (the softening is explicit, never default)" ||
		{ st_bad "plateau did not pass with warmup (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'; }

	# ---- 4. unusable data is reported, not silently passed ------------------
	head -3 "$d/pass.csv" >"$d/short.csv"
	out=$(st_verdict "$d/short.csv"); rc=$?
	((rc == 4)) && grep -q 'DATA-ERROR' <<<"$out" &&
		st_ok "a CSV with fewer than 3 samples exits 4 with DATA-ERROR" ||
		st_bad "short CSV was not rejected (rc=$rc)"
	awk -F, -v OFS=, 'NR==1{sub(/rss_kib/,"rss_kb"); print; next}{print}' "$d/pass.csv" >"$d/badhdr.csv"
	out=$(st_verdict "$d/badhdr.csv"); rc=$?
	((rc == 4)) && grep -q 'missing column' <<<"$out" &&
		st_ok "a CSV missing a required column exits 4 and names it" ||
		st_bad "bad header was not rejected (rc=$rc)"

	# ---- 5. an all-NA IOMMU column is NOT-APPLICABLE, never a silent PASS ---
	awk -F, -v OFS=, 'NR==1{for(i=1;i<=NF;i++){if($i=="iommu_mappings")c=i; if($i=="iommu_src")s=i}; print; next}
		{ $c="NA"; $s="none"; print }' "$d/pass.csv" >"$d/noiommu.csv"
	out=$(st_verdict "$d/noiommu.csv"); rc=$?
	grep -q 'NOT-APPLICABLE  IOMMU' <<<"$out" &&
		st_ok "an unreadable IOMMU column is reported NOT-APPLICABLE, not PASS" ||
		{ st_bad "unreadable IOMMU column was not flagged"; printf '%s\n' "$out" | sed 's/^/      /'; }

	# ---- 6. an all-NA core-share column is NOT-APPLICABLE -------------------
	awk -F, -v OFS=, 'NR==1{for(i=1;i<=NF;i++){if($i=="core_share_max_pct")c=i; if($i=="core_share_group")g=i}; print; next}
		{ $c="NA"; $g="none"; print }' "$d/pass.csv" >"$d/noshare.csv"
	out=$(st_verdict "$d/noshare.csv"); rc=$?
	grep -q 'NOT-APPLICABLE  per-core share' <<<"$out" &&
		st_ok "a single-core-only run is reported NOT-APPLICABLE, not a 100/0 FAIL and not a PASS" ||
		{ st_bad "single-core run was not flagged"; printf '%s\n' "$out" | sed 's/^/      /'; }

	# ---- 7. the divergence gate ---------------------------------------------
	WARMUP=0
	local dv
	dv=$(check_divergence "$d/pass.csv")
	[[ $dv == OK ]] && st_ok "the divergence gate says OK on healthy data" ||
		st_bad "divergence gate fired on healthy data: $dv"
	dv=$(check_divergence "$d/fail-rss.csv")
	[[ $dv == DIVERGING* && $dv == *rss* ]] && st_ok "the divergence gate names a real RSS climb" ||
		st_bad "divergence gate missed the RSS climb: $dv"
	dv=$(check_divergence "$d/plateau.csv")
	[[ $dv == OK ]] &&
		st_ok "the divergence gate does NOT fire on a ramp-then-plateau (it is not the slope rule)" ||
		st_bad "divergence gate fired on a plateau: $dv"
	head -6 "$d/pass.csv" >"$d/few.csv"
	dv=$(check_divergence "$d/few.csv")
	[[ $dv == INSUFFICIENT ]] && st_ok "the divergence gate refuses to judge fewer than 10 samples" ||
		st_bad "divergence gate judged too few samples: $dv"

	# ---- 8. the sampler emits a row whose shape matches the header ----------
	local row ncols nhdr
	STATUS_LOG=; SINK_FILE=; SINK_PID=; PREV_CPU=; PREV_TS=; T0=; SAMPLE_N=0
	row=$(emit_sample "$$" 2>/dev/null)
	ncols=$(awk -F, '{print NF}' <<<"$row")
	nhdr=$(awk -F, '{print NF}' <<<"$CSV_HEADER")
	[[ $ncols == "$nhdr" ]] &&
		st_ok "emit_sample produces exactly $nhdr columns, matching the header" ||
		st_bad "emit_sample produced $ncols columns, header has $nhdr"
	grep -qE '(^|,)NA(,|$)' <<<"$row" &&
		st_ok "an unreadable surface is written as NA, never as a fabricated 0" ||
		st_ok "every surface was readable in this environment (no NA needed)"

	printf '\n  %d passed, %d failed\n' "$ST_PASS" "$ST_FAIL"
	((ST_FAIL == 0)) || return 1
	return 0
}

do_dump_fixtures() {
	mkdir -p "$OUT" || die "cannot create '$OUT'"
	st_make_pass "$OUT/pass.csv"
	local -a names=(rss slab bufinfo iommu fps drops share)
	local -a cols=(rss_kib slab_kib dmabuf_objects iommu_mappings fps drops core_share_max_pct)
	local -a exprs=(rss-creep slab-creep buf-creep iommu-creep fps-sag drops-nonzero share-skew)
	local i
	for i in "${!names[@]}"; do
		st_mutate "$OUT/pass.csv" "$OUT/fail-${names[$i]}.csv" "${cols[$i]}" "${exprs[$i]}"
	done
	awk -F, -v OFS=, 'NR==1{for(i=1;i<=NF;i++) if($i=="rss_kib") c=i; print; next}
		{ n=NR-2; $c = (n<10) ? 250000 + n*2000 : 270000; print }' \
		"$OUT/pass.csv" >"$OUT/plateau.csv"
	head -3 "$OUT/pass.csv" >"$OUT/short.csv"
	awk -F, -v OFS=, 'NR==1{sub(/rss_kib/,"rss_kb"); print; next}{print}' "$OUT/pass.csv" >"$OUT/badhdr.csv"
	awk -F, -v OFS=, 'NR==1{for(i=1;i<=NF;i++){if($i=="iommu_mappings")c=i; if($i=="iommu_src")s=i}; print; next}
		{ $c="NA"; $s="none"; print }' "$OUT/pass.csv" >"$OUT/noiommu.csv"
	awk -F, -v OFS=, 'NR==1{for(i=1;i<=NF;i++){if($i=="core_share_max_pct")c=i; if($i=="core_share_group")g=i}; print; next}
		{ $c="NA"; $g="none"; print }' "$OUT/pass.csv" >"$OUT/noshare.csv"
	printf 'fixtures written to %s\n' "$OUT"
	ls -1 "$OUT"
}

# ---------------------------------------------------------------------------
main() {
	parse_args "$@"
	case ${MODE:-} in
	self-test) do_self_test ;;
	dump-fixtures) do_dump_fixtures ;;
	check) run_assertions "$CSV" ;;
	sample-once)
		local pid; pid=$(read_engine_pid) || die "cannot resolve the engine PID" 4
		printf '%s\n' "$CSV_HEADER"
		emit_sample "$pid"
		;;
	run) do_run ;;
	*) usage ;;
	esac
}

main "$@"
