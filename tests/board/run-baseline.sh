#!/usr/bin/env bash
#
# run-baseline.sh — drive the five Phase-0 baseline measurements end to end and
# WRITE the documents that record them.
#
# THIS SCRIPT IS THE PRODUCER OF todo 3's EVIDENCE. That is a contract, not a
# convenience: todo 3's acceptance criteria require `baseline-<board>.md` to
# have been produced BY this script rather than typed by hand, because a
# hand-written verdict table cannot be re-derived, re-scored, or shown to have
# come from the board it names. Everything below therefore ends in a document,
# and every document carries the board identity, the exact command, and the
# artifact path for every number in it.
#
# THE FIVE MEASUREMENTS (todo 3(a)-(e))
#
#   a  DECODE TRUTH     which decoder factory the engine actually selects per
#                       source kind, plus the CPU cost of a 1080p decode.
#                       Verdict SOFTWARE iff the factory is avdec_* or jpegdec.
#   b  COPY CENSUS      per-boundary dma-buf identity (fd-trace.sh) plus the
#                       journal copy counters (count-journal.sh), per graph
#                       shape, classified REQUIRED/AVOIDABLE/TEMPORARY/BUG.
#   c  H.265 4K59.94    real HDMI capture -> mpph265enc, 600 frames, and the
#                       same at H.264. PASS/FAIL per codec per board. A FAIL
#                       here is a finding about the CURRENT stack (gate G4),
#                       not a harness fault.
#   d  DUAL-CORE        two concurrent 4K30 H.265 encodes for 60 s, per-process
#                       fps and per-core rkvenc IRQ deltas (sample-cores.sh).
#                       This is the pre-island number todo 16 compares against.
#   e  ENCODE ORACLE    encode-psnr-oracle.sh, 20 runs per codec, CLEAN/DIRTY
#                       from the PSNR distribution, plus the ENC-CORRUPT row in
#                       the bug-reality ledger.
#
# THE HONESTY RULE THAT OUTRANKS EVERYTHING ELSE HERE. A measurement that did
# not run renders as NOT-RUN with the reason, never as a pass and never as a
# blank cell. A board that is unreachable renders as BLOCKED. Phase 0 exists to
# produce a denominator; a silently-missing row makes every later comparison
# read against a number nobody took.
#
# READ-ONLY WITH RESPECT TO BOARD STATE. Every remote payload passes the
# harness read-only screen before it is sent (lib/harness-lib.sh
# `assert_payload_is_read_only`). The harness is staged under /tmp on the board
# and removed afterwards; nothing else on the board is written, no unit is
# controlled, no module is loaded, and nothing under /sys is touched.
#
# Usage:
#   run-baseline.sh --board SLUG --host IP [--user U] [--pass-file F]
#                   [--measure a,b,c,d,e] [--runs N]
#                   [--doc-dir DIR] [--ledger-dir DIR] [--report-dir DIR]
#   run-baseline.sh --connect-check --board SLUG --host IP [...]
#   run-baseline.sh --self-test
#
#   --connect-check  reach the board, prove the transport and the read-only
#                    screen, capture the inventory every measurement row must
#                    cite, and STOP. It runs none of (a)-(e) and writes no
#                    baseline document.
#
# Credentials: --pass-file names a file whose first line is the SSH password
# (the bench boards accept password authentication only, and OpenSSH's
# BatchMode refuses to use one, so the session goes through sshpass). Nothing
# in this repository locates that file; the caller supplies the path.
#
# Exit: 0 ran, 1 a measurement failed to produce a verdict, 2 usage,
#       77 the board was not reachable (nothing was measured).

# Remote payloads are single-quoted deliberately: they must be expanded by the
# BOARD, not by this host. Letting the host expand them would send it its own
# hostname, its own /proc and its own package versions. SC2016 flags exactly
# that construct, so it is disabled for this file.
# shellcheck disable=SC2016
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness-lib.sh
. "${HARNESS_DIR}/lib/harness-lib.sh"

BOARD=
HOST=
USER_NAME=ceralive
PASS_FILE=
MEASURE=a,b,c,d,e
ORACLE_RUNS=20
DOC_DIR=
LEDGER_DIR=
REPORT_DIR=
CONNECT_CHECK=0
COMPOSE_EXISTING=0
REMOTE_STAGE=

# Unique per run. A fixed staging path is shared by every concurrent run against
# the same board, so the first one to finish `rm -rf`s the staging directory the
# others are still executing from — observed killing a live leg mid-measurement.
REMOTE_ROOT="/tmp/ceralive-media-island-harness-$$-$(date -u +%Y%m%dT%H%M%SZ)"
readonly REMOTE_ROOT

# ---------------------------------------------------------------------------
# Remote payloads — every one of these is screened before it is sent
# ---------------------------------------------------------------------------

# inventory_payload — the facts every measurement row must cite. Read-only:
# it reads /proc, /dev, dpkg's database and the boot-state reporter.
inventory_payload() {
  cat <<'PAYLOAD'
set -uo pipefail
printf 'hostname=%s\n' "$(hostname)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'arch=%s\n' "$(uname -m)"
printf 'model=%s\n' "$(tr -d '\000' </proc/device-tree/model 2>/dev/null || echo unknown)"
printf 'os=%s\n' "$(. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-?}" "${VERSION_ID:-?}")"
for p in linux-image-"$(uname -r)" librga2 librockchip-mpp1 \
         gstreamer1.0-rockchip-ceralive gstreamer1.0-rockchip1 \
         cerastream ceralive-device; do
  v=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null) || v=absent
  printf 'pkg.%s=%s\n' "$p" "${v:-absent}"
done
for n in /dev/rga /dev/mpp_service /dev/mpp-service /dev/dri/renderD128 \
         /dev/dma_heap/system /dev/dma_heap/system-uncached; do
  if [ -e "$n" ]; then printf 'dev%s=present\n' "$n"; else printf 'dev%s=absent\n' "$n"; fi
done
for v in /dev/video0 /dev/video1 /dev/video2 /dev/video3; do
  [ -e "$v" ] && printf 'v4l2%s=present\n' "$v"
done
for f in mppvideodec mppjpegdec mpph264enc mpph265enc avdec_h264 avdec_h265 jpegdec; do
  if gst-inspect-1.0 "$f" >/dev/null 2>&1; then
    printf 'gst.%s=registered\n' "$f"
  else
    printf 'gst.%s=missing rc=%s\n' "$f" "$?"
  fi
done
printf 'irq_media_lines=%s\n' "$(grep -cE 'rkvenc|rkvdec|rga|vdpu|jpeg' /proc/interrupts || true)"
grep -E 'rkvenc|rkvdec|rga|vdpu|jpeg' /proc/interrupts | sed 's/^/irq: /' || true
if command -v ceralive-boot-state >/dev/null 2>&1; then
  ceralive-boot-state status 2>/dev/null | sed 's/^/bootstate: /' || true
fi
PAYLOAD
}

# hdmi_signal_payload — the HDMI-RX signal transcript measurement (c) decides on.
#
# VIDIOC_QUERY_DV_TIMINGS is the only authority here, and --get-dv-timings is
# the trap it exists to avoid: with no source attached BOTH bench boards still
# answer --get with a stale 640x480p59.94 VGA default, which reads like a locked
# signal to anything that only greps for a resolution. So the QUERY transcript
# and its exit status are captured verbatim and the GET transcript is captured
# beside it, explicitly labelled as the last-set value rather than a lock.
hdmi_signal_payload() {
  cat <<'PAYLOAD'
set -uo pipefail
found=0
for v in /dev/video*; do
  [ -e "$v" ] || continue
  drv=$(v4l2-ctl -d "$v" --info 2>/dev/null | sed -n 's/.*Driver name *: *//p' | head -1)
  case "${drv:-}" in *hdmirx*) ;; *) continue ;; esac
  found=1
  printf 'hdmi_node=%s driver=%s\n' "$v" "$drv"
  printf -- '--- VIDIOC_QUERY_DV_TIMINGS (%s) ---\n' "$v"
  v4l2-ctl -d "$v" --query-dv-timings 2>&1
  printf 'query_dv_timings_rc=%s node=%s\n' "$?" "$v"
  printf -- '--- v4l2-ctl --get-dv-timings (%s) — LAST SET value, not a lock ---\n' "$v"
  v4l2-ctl -d "$v" --get-dv-timings 2>&1
  printf 'get_dv_timings_rc=%s node=%s\n' "$?" "$v"
done
[ "$found" = 1 ] || printf 'hdmi_node=absent no v4l2 node reports an hdmirx driver\n'
PAYLOAD
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

load_credentials() {
  [ -n "${HOST}" ] || {
    harness_fail_msg "--host is required"
    return "${HARNESS_USAGE}"
  }
  [ -n "${BOARD}" ] || {
    harness_fail_msg "--board is required"
    return "${HARNESS_USAGE}"
  }
  if [ -n "${PASS_FILE}" ]; then
    [ -r "${PASS_FILE}" ] || {
      harness_fail_msg "--pass-file not readable: ${PASS_FILE}"
      return "${HARNESS_USAGE}"
    }
    BOARD_SSH_PASS=$(head -1 "${PASS_FILE}")
  fi
  BOARD_IP="${HOST}"
  BOARD_SSH_USER="${USER_NAME}"
  export BOARD_IP BOARD_SSH_USER BOARD_SSH_PASS
  export CERALIVE_BOARD_TEST=1
  return 0
}

# stage_harness — copy the leg scripts and fixtures to the board so the
# measurements run THERE, against that hardware, with the same code CI ran the
# self-tests against.
stage_harness() {
  local -a opts
  mapfile -t opts < <(_board_ssh_opts)
  REMOTE_STAGE="${REMOTE_ROOT}"
  board_run "printf 'stage=%s\n' '${REMOTE_STAGE}'; test -d '${REMOTE_STAGE}' && printf 'stage_exists=yes\n' || printf 'stage_exists=no\n'" >/dev/null 2>&1
  sshpass -p "${BOARD_SSH_PASS}" ssh "${opts[@]}" "$(board_target)" \
    "install -d '${REMOTE_STAGE}'" || return 1
  sshpass -p "${BOARD_SSH_PASS}" scp -r "${opts[@]}" \
    "${HARNESS_DIR}/lib" "${HARNESS_DIR}/tests" \
    "${HARNESS_DIR}"/*.sh "${HARNESS_DIR}"/*.c "${HARNESS_DIR}/uapi" \
    "${HARNESS_DIR}/Makefile" \
    "$(board_target):${REMOTE_STAGE}/" || return 1
  sshpass -p "${BOARD_SSH_PASS}" ssh "${opts[@]}" "$(board_target)" \
    "chmod +x '${REMOTE_STAGE}'/*.sh" || return 1
  printf 'staged=%s\n' "${REMOTE_STAGE}"
}

unstage_harness() {
  [ -n "${REMOTE_STAGE}" ] || return 0
  local -a opts
  mapfile -t opts < <(_board_ssh_opts)
  sshpass -p "${BOARD_SSH_PASS}" ssh "${opts[@]}" "$(board_target)" \
    "rm -rf '${REMOTE_STAGE}'" >/dev/null 2>&1 || true
}

# The 120 s default in harness-lib is sized for a probe, not for a leg: (e)
# alone is 40 hardware encodes plus 40 PSNR scorings. Each leg names its own
# ceiling so a long measurement is never truncated into a false NOT-RUN.
remote_leg() {
  local cmd=$1
  BOARD_COMMAND_TIMEOUT="${LEG_TIMEOUT:-600}" \
    board_run "cd '${REMOTE_STAGE}' && ${cmd}"
}

board_clock() { board_run 'date +%Y-%m-%d\ %H:%M:%S'; }

# The two bench boards ship DIFFERENT MPP plugin packages and the encoder's
# bitrate property is not named the same in both: the CeraLive fork
# (gstreamer1.0-rockchip-ceralive) exposes `bitrate`, radxa's stock
# gstreamer1.0-rockchip1 still exposes `bps`. Hard-coding either one builds an
# erroneous pipeline on the other board and every encode leg silently measures
# nothing, so the name is detected per board instead of assumed.
detect_enc_bitrate_prop() {
  local probed
  probed="$(board_run '
for p in bitrate bps; do
  if gst-inspect-1.0 mpph264enc 2>/dev/null | grep -qE "^  ${p} "; then
    printf "enc_bitrate_prop=%s\n" "$p"; exit 0
  fi
done
printf "enc_bitrate_prop=none\n"')"
  printf '%s\n' "${probed}" | sed -n 's/^enc_bitrate_prop=//p' | head -1
}

ENC_BPS_PROP=
enc_bitrate_prop() {
  [ -n "${ENC_BPS_PROP}" ] || {
    ENC_BPS_PROP="$(detect_enc_bitrate_prop)"
    [ -n "${ENC_BPS_PROP}" ] && [ "${ENC_BPS_PROP}" != none ] || ENC_BPS_PROP=bitrate
  }
  printf '%s\n' "${ENC_BPS_PROP}"
}

# journal_window <since> <until> — the privileged READ of one measured window.
journal_window() {
  board_run_sudo "journalctl --since '$1' --until '$2' --no-pager -o cat 2>/dev/null"
}

# ---------------------------------------------------------------------------
# Document composition
# ---------------------------------------------------------------------------
#
# `emit_measurement` is the ONLY way a row reaches the document, and it always
# takes a verdict. There is no path that writes a heading without one, which is
# what makes "a leg that did not run cannot render as a pass" structural rather
# than a matter of care.

emit_measurement() {
  local id=$1 title=$2 verdict=$3 command=$4 artifact=$5 body=$6 table=${7-}
  printf '\n### (%s) %s\n\n' "${id}" "${title}"
  printf '**VERDICT: %s**\n\n' "${verdict}"
  printf '| field | value |\n|---|---|\n'
  printf '| command | `%s` |\n' "${command}"
  printf '| artifact | `%s` |\n' "${artifact}"
  [ -z "${table}" ] || printf '\n%s\n' "${table}"
  printf '\n```\n%s\n```\n' "${body}"
}

# Each leg parks its section on disk so a split run (`--measure a`, later
# `--measure e`) cannot erase the earlier leg's evidence. A leg with no section
# file renders NOT-RUN — the honesty rule, applied to partial runs.
section_file() { printf '%s/section-%s.md\n' "$1" "$2"; }

# field <row> <key> — one space-free value out of a `key=value key=value` row.
# The pattern requires whitespace before the key, so callers pass rows with a
# leading space; a trailing free-text `reason=` is taken whole by field_tail.
field() {
  printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^ ]*\\).*/\\1/p" | head -1
}
field_tail() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=//p" | head -1; }

decode_table() {
  local rows=$1 line
  printf '| source kind | status | engine element | engine chain result | decoder that carried frames | class | frames | CPU %% (proc-stat) |\n'
  printf '|---|---|---|---|---|---|---|---|\n'
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    printf '| `%s` | %s | `%s` | %s | `%s` | **%s** | %s | %s |\n' \
      "$(field "${line}" kind)" "$(field "${line}" status)" \
      "$(field "${line}" engine_element)" "$(field "${line}" engine_result)" \
      "$(field "${line}" selected_factory)" "$(field "${line}" decoder_class)" \
      "$(field "${line}" frames)" "$(field "${line}" cpu_pct)"
  done <<<"${rows}"
  printf '\nSOFTWARE iff the factory that carried the frames is `avdec_*` or `jpegdec`.\n'
  printf '`NONE` means the kind carried no frames at all — never a pass. `NO-DEVICE`\n'
  printf 'means the source hardware is not attached to this board.\n'
}

census_table() {
  local rows=$1 line
  printf '| graph shape | boundary | class | software copies | new dma-buf inodes | fds crossing | RGA_BLIT fail | rga_api version | `/dev/rga` | source memory | frames | why this class |\n'
  printf '|---|---|---|---|---|---|---|---|---|---|---|---|\n'
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    printf '| `%s` | %s | **%s** | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$(field "${line}" shape)" "$(field "${line}" boundary)" \
      "$(field "${line}" class)" "$(field "${line}" software_copies)" \
      "$(field "${line}" new_inodes)" "$(field "${line}" fds_crossing)" \
      "$(field "${line}" rga_blit_fail)" "$(field "${line}" rga_api_version)" \
      "$(field "${line}" rga_chardev)" "$(field "${line}" source_memory)" \
      "$(field "${line}" frames)" "$(field_tail "${line}" reason)"
  done <<<"${rows}"
}

not_run_section() {
  local id=$1
  local title verdict
  case "${id}" in
    a) title="Decode truth (A1)" ;;
    b) title="Copy census (A11)" ;;
    c) title="H.265 / H.264 4K59.94 baseline (G4)" ;;
    d) title="Dual-core concurrency baseline (A4)" ;;
    e) title="Encode-corruption oracle baseline (ENC-CORRUPT)" ;;
    *) title="Unknown measurement" ;;
  esac
  verdict="NOT-RUN — this invocation did not select measurement (${id}); no number was taken"
  emit_measurement "${id}" "${title}" "${verdict}" "n/a" "n/a" "no measurement was attempted"
}

doc_header() {
  local board=$1 host=$2 identity=$3 mode=${4-}
  printf '# Phase-0 baseline — %s\n\n' "${board}"
  printf 'Produced by `run-baseline.sh` on %s. Every verdict below is the\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'output of a command recorded beside it; nothing here is hand-written.\n\n'
  printf '| field | value |\n|---|---|\n'
  printf '| board | `%s` |\n' "${board}"
  printf '| host | `%s` |\n' "${host}"
  printf '| harness | `run-baseline.sh` (rk3588-media-island Phase-0 harness) |\n'
  [ -z "${mode}" ] || printf '| document mode | %s |\n' "${mode}"
  printf '\n```\n%s\n```\n' "${identity}"
}

# recorded_identity <report-dir> <existing-doc> — the board facts a document
# must carry, taken from a RECORDING rather than from a live board. A pass that
# cannot reach the hardware may not invent them, so the two sources are the
# identity this harness wrote during the measuring run and, failing that, the
# identity fence of the document that run produced.
recorded_identity() {
  local out=$1 doc=$2
  if [ -s "${out}/identity.txt" ]; then
    cat "${out}/identity.txt"
    return 0
  fi
  if [ -s "${doc}" ]; then
    awk '/^```$/{n++; next} n==1' "${doc}"
    return 0
  fi
  printf 'identity_not_recorded=the measuring run left no identity record\n'
}

# strip_trailing_hspace <file>
#
# Trailing spaces and tabs are invisible, carry no meaning, and make
# `git diff --check` fail. They arrive here from device transcripts that print
# an empty field as "Standards: ". Only horizontal whitespace at end of line is
# removed: no character with meaning, no line, and no line ORDER changes, which
# is what the self-test asserts.
strip_trailing_hspace() {
  local file=$1
  [ -s "${file}" ] || return 0
  sed -i 's/[[:space:]]*$//' "${file}"
}

# normalize_recorded_section_d <section-file>
#
# HONEST NORMALIZATION OF A LEGACY (d) SECTION, for recomposition only.
#
# An older harness asked GStreamer's `framerate` tracer for per-process fps.
# Neither bench board ships that tracer, so the fps rows came back
# `samples=0 status=no_tracer_lines` and sample-cores itself ended the leg
# `VERDICT: FAIL` -- while the section's own headline still read DUAL-CORE on
# the strength of the IRQ deltas alone. Those IRQ deltas are real and were taken
# over the real 60 s window; the per-process half of A4 simply was not measured.
#
# Summarising that as DUAL-CORE overclaims A4. Fabricating the missing fps is
# worse. So recomposition restates the HEADLINE to carry both facts and leaves
# every byte of the transcript underneath it untouched. Applied only when the
# section actually shows this signature; any other (d) section passes through.
normalize_recorded_section_d() {
  local file=$1 advanced
  if ! grep -q '^\*\*VERDICT: DUAL-CORE' "${file}" 2>/dev/null ||
    ! grep -q '^fps tag=' "${file}" 2>/dev/null ||
    grep -q '^fps tag=.*mean=' "${file}" 2>/dev/null; then
    cat "${file}"
    return 0
  fi

  advanced=$(awk '
    /^--- window total/ { w = 1; next }
    /^--- / { w = 0 }
    w && /label=[^ ]*rkvenc/ {
      d = $0; sub(/.*total_delta=/, "", d); sub(/ .*/, "", d)
      if (d + 0 > 0) n++
    }
    END { print n + 0 }
  ' "${file}")

  awk -v adv="${advanced}" '
    /^\*\*VERDICT: DUAL-CORE/ {
      printf "**VERDICT: PARTIAL-BLOCKED-FPS — %s of 2 rkvenc core IRQ lines advanced over the real 60 s window, so both encoder cores ran; per-process fps is BLOCKED-MISSING-TRACER (every requested fps row returned no samples and the sampler ended FAIL), so A4 is NOT complete**\n", adv
      print ""
      print "> Headline normalized by `run-baseline.sh --compose-existing`. The recorded"
      print "> section summarized this leg as DUAL-CORE from the IRQ deltas alone while its"
      print "> own transcript shows the per-process fps rows returned"
      print "> `samples=0 status=no_tracer_lines` and the sampler ended `VERDICT: FAIL`."
      print "> The IRQ evidence is real and unmodified; the missing fps is reported as the"
      print "> blocker it is rather than fabricated. The board went off-network before this"
      print "> leg could be re-run with the identity-chain fps deriver."
      next
    }
    { print }
  ' "${file}"
}

# repair_collapsed_tables <file>
#
# An earlier harness built the census table with `md="${md}$(printf '...\n')"`.
# Command substitution strips trailing newlines, so the separator row and every
# data row were emitted onto ONE line and the table never rendered. The bug is
# fixed at the source, but a board that has since gone off the network cannot
# re-run, and hand-editing a baseline is forbidden.
#
# So the composer repairs the RENDERING, and only the rendering. It inserts
# newlines at row boundaries and changes nothing else -- which is checked, not
# asserted: the repair is accepted only if stripping every newline from the
# result reproduces the original file byte-for-byte, and if each recovered row
# has the same column count as its header. If either check fails the file is
# left exactly as it was. No measured value can survive that gate altered.
repair_collapsed_tables() {
  local file=$1 candidate rc=0
  [ -s "${file}" ] || return 0
  grep -q '|---.*||' "${file}" 2>/dev/null || return 0

  candidate="$(mktemp)" || return 1
  awk '
    /^```/ { fence = !fence; print; next }
    !fence && /\|---/ && /\|\|/ {
      line = $0
      gsub(/\|\|/, "|\n|", line)
      print line
      next
    }
    { print }
  ' "${file}" >"${candidate}"

  # Losslessness: the ONLY difference may be inserted newlines.
  if [ "$(tr -d '\n' <"${file}" | md5sum)" != "$(tr -d '\n' <"${candidate}" | md5sum)" ]; then
    harness_fail_msg "table repair would have changed content in ${file}; left untouched"
    rm -f "${candidate}"
    return 1
  fi

  # Column consistency: a recovered row must match the header it sits under.
  if ! awk '
    /^```/ { fence = !fence; next }
    fence { next }
    /^\|/ {
      n = gsub(/\|/, "|")
      if (!intable) { intable = 1; want = n }
      else if (n != want) { bad = 1 }
      next
    }
    { intable = 0 }
    END { exit (bad ? 1 : 0) }
  ' "${candidate}"; then
    harness_fail_msg "table repair produced ragged columns in ${file}; left untouched"
    rm -f "${candidate}"
    return 1
  fi

  cat "${candidate}" >"${file}"
  rm -f "${candidate}"
  printf 'table_rendering_repaired=%s (newlines inserted only; content verified unchanged)\n' "${file}"
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Compose-existing
# ---------------------------------------------------------------------------
#
# Regenerate the baseline document from the section files a MEASURING run
# already wrote, without contacting the board.
#
# WHY THIS EXISTS AND WHAT IT MAY NOT DO. A board can go away after its
# measurements succeed -- the Rock 5B+ dropped off the network entirely after
# its legs had run. Re-running `full_run` against an absent board would replace
# five real verdicts with five NOT-RUN sections, destroying evidence that was
# correctly taken; hand-editing the document is equally forbidden. So this mode
# reassembles the SAME section files, byte-for-byte, through the same composer.
#
# It takes NO measurement, contacts NO board, touches NO ledger, and invents no
# verdict: a section that is absent still renders NOT-RUN. Every timestamp,
# command and artifact path in the output belongs to the leg that produced it.
compose_existing() {
  local out doc identity id reused=0 missing=0

  [ -n "${BOARD}" ] || {
    harness_fail_msg "--board is required"
    return "${HARNESS_USAGE}"
  }
  [ -n "${REPORT_DIR}" ] || {
    harness_fail_msg "--report-dir is required: compose-existing reads the sections a measuring run wrote"
    return "${HARNESS_USAGE}"
  }
  out="${REPORT_DIR}"
  [ -d "${out}" ] || {
    harness_fail_msg "--report-dir does not exist: ${out}"
    return "${HARNESS_USAGE}"
  }
  [ -n "${DOC_DIR}" ] || DOC_DIR="${out}"
  doc="${DOC_DIR}/baseline-${BOARD}.md"
  identity="$(recorded_identity "${out}" "${doc}")"

  local composed
  composed="$(
    doc_header "${BOARD}" "${HOST:-not-contacted-in-this-pass}" "${identity}" \
      'RECOMPOSED from the section files of the measuring run — no new measurement was taken in this pass'
    printf '\n> This document was regenerated by `run-baseline.sh --compose-existing`.\n'
    printf '> Every verdict, command, artifact path and transcript below is the one its\n'
    printf '> own leg recorded when it ran against the board. This pass contacted no\n'
    printf '> hardware and measured nothing; it only reassembled those sections.\n'
    for id in a b c d e; do
      if [ -s "$(section_file "${out}" "${id}")" ]; then
        if [ "${id}" = d ]; then
          normalize_recorded_section_d "$(section_file "${out}" "${id}")"
        else
          cat "$(section_file "${out}" "${id}")"
        fi
      else
        not_run_section "${id}"
      fi
    done
  )"

  for id in a b c d e; do
    if [ -s "$(section_file "${out}" "${id}")" ]; then
      reused=$((reused + 1))
    else
      missing=$((missing + 1))
    fi
  done

  printf '%s\n' "${composed}" >"${doc}"
  repair_collapsed_tables "${doc}" || true
  strip_trailing_hspace "${doc}"
  printf 'composed_document=%s sections_reused=%s sections_missing=%s\n' \
    "${doc}" "${reused}" "${missing}"

  [ "$(grep -c '^\*\*VERDICT: ' "${doc}")" -eq 5 ] || {
    harness_verdict FAIL "the composed document does not carry five verdicts"
    return $?
  }
  harness_verdict PASS "recomposed ${reused}/5 recorded sections into ${doc}; no measurement was taken"
}

# bug_reality_row — the ENC-CORRUPT row todo 3(e) owes the ledger. It is
# emitted per codec, in the shipped-image column, and it always carries the
# fixture assertion so a reader can tell the run used the right input.
bug_reality_row() {
  local board=$1 codec=$2 verdict=$3 command=$4 fixture_assert=$5 means=$6 artifact=$7
  printf '| ENC-CORRUPT | %s | %s | %s | shipped image | `%s` | `%s` | %s | `%s` |\n' \
    "${board}" "${codec}" "${verdict}" "${command}" "${fixture_assert}" \
    "${means}" "${artifact}"
}

bug_reality_header() {
  printf '# Bug reality ledger\n\n'
  printf 'One row per defect claim per board per image. A claim with no row is\n'
  printf 'not evidence. Rows are appended by `run-baseline.sh`; the shipped-image\n'
  printf 'column is the denominator every island measurement is read against.\n\n'
  printf '| bug | board | codec | verdict | image | command | fixture assertion | per-run mean PSNR (dB) | artifacts |\n'
  printf '|---|---|---|---|---|---|---|---|---|\n'
}

# ---------------------------------------------------------------------------
# The five measurements
# ---------------------------------------------------------------------------

# decode_truth_payload — measurement (a), run entirely on the board.
#
# Every ffmpeg and gst-launch invocation below closes stdin (`-nostdin`, and
# `</dev/null`). That is not style: this payload is DELIVERED on stdin to
# `bash -s`, so any child that reads stdin swallows the remainder of the script
# and the leg silently truncates. It was observed doing exactly that.
decode_truth_payload() {
  cat <<'PAYLOAD'
set -uo pipefail

cpu_percent() {
  _pid=$1; _secs=$2
  _hz=$(getconf CLK_TCK)
  [ -r "/proc/${_pid}/stat" ] || { printf 'unavailable'; return 0; }
  _c0=$(sed 's/^[0-9]* (.*) //' "/proc/${_pid}/stat" | awk '{print $12+$13}')
  _u0=$(awk '{print $1}' /proc/uptime)
  sleep "${_secs}"
  [ -r "/proc/${_pid}/stat" ] || { printf 'process-exited-early'; return 0; }
  _c1=$(sed 's/^[0-9]* (.*) //' "/proc/${_pid}/stat" | awk '{print $12+$13}')
  _u1=$(awk '{print $1}' /proc/uptime)
  awk -v a="${_c0}" -v b="${_c1}" -v t0="${_u0}" -v t1="${_u1}" -v hz="${_hz}" \
    'BEGIN{d=t1-t0; if(d<=0){printf "unavailable"; exit} printf "%.1f", (b-a)/hz/d*100}'
}

# The realized decoder is read from the PLAYING dot dump (the graph as actually
# built, which is the only authority when the chain contains decodebin) and
# corroborated by the factory log. Trailing instance digits are stripped.
# `timeout N gst-launch &` makes $! the PID of TIMEOUT, whose own CPU time is
# ~0. Sampling it reports 0.0% for a session that is really decoding, so the
# actual gst-launch child is resolved before any CPU measurement.
gst_child_of() {
  _wrapper=$1
  _child=$(pgrep -P "${_wrapper}" 2>/dev/null | head -1)
  printf '%s' "${_child:-${_wrapper}}"
}

realized_decoder() {
  _dotdir=$1; _log=$2
  {
    grep -ohE '(mppvideodec|mppjpegdec|avdec_[a-z0-9_]+|jpegdec|v4l2slh26[45]dec|v4l2h26[45]dec|openh264dec)[0-9]*' \
      "${_dotdir}"/*PLAYING*.dot 2>/dev/null
    grep -ohE 'created element "(mppvideodec|mppjpegdec|avdec_[a-z0-9_]+|jpegdec|v4l2[a-z0-9]*dec)' \
      "${_log}" 2>/dev/null | sed 's/.*"//'
  } | sed 's/[0-9]*$//' | sort -u | paste -sd, -
}

classify_factory() {
  case "$1" in
    '' ) printf 'UNOBSERVED' ;;
    NO-DEVICE) printf 'NO-DEVICE' ;;
    *avdec_*|*jpegdec*) printf 'SOFTWARE' ;;
    *) printf 'HARDWARE' ;;
  esac
}

printf -- '--- exact gst-inspect transcripts (todo 3(a) requires both verbatim) ---\n'
for f in mppvideodec mppjpegdec; do
  printf -- '=== gst-inspect-1.0 %s ===\n' "$f"
  gst-inspect-1.0 "$f" </dev/null 2>&1 | sed -n '1,14p'
  gst-inspect-1.0 "$f" >/dev/null 2>&1
  printf 'gst_inspect factory=%s exit=%s\n' "$f" "$?"
done

printf -- '--- decoder factory registration ---\n'
for f in mppvideodec mppjpegdec avdec_h264 avdec_h265 jpegdec v4l2slh264dec v4l2slh265dec v4l2h264dec; do
  if gst-inspect-1.0 "$f" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  if [ "$rc" = 0 ]; then reg=yes; else reg=no; fi
  printf 'factory=%s registered=%s rc=%s\n' "$f" "$reg" "$rc"
done

printf -- '--- attached UVC devices (inspected FIRST, before any decode claim) ---\n'
uvc_nodes=""
for v in /dev/video*; do
  [ -e "$v" ] || continue
  drv=$(v4l2-ctl -d "$v" --info 2>/dev/null | sed -n 's/.*Driver name *: *//p' | head -1)
  card=$(v4l2-ctl -d "$v" --info 2>/dev/null | sed -n 's/.*Card type *: *//p' | head -1)
  printf 'v4l2_node=%s driver=%s card=%s\n' "$v" "${drv:-unknown}" "${card:-unknown}"
  if [ "${drv:-}" = uvcvideo ]; then
    uvc_nodes="${uvc_nodes} $v"
    v4l2-ctl -d "$v" --list-formats </dev/null 2>&1 | sed "s|^|uvcfmt ${v}: |"
  fi
done
if [ -n "${uvc_nodes# }" ]; then
  printf 'uvc_devices=present nodes=%s\n' "${uvc_nodes# }"
else
  printf 'uvc_devices=none\n'
fi

printf -- '--- engine realized graphs (cerastream dump-pipeline: the SELECTED chain) ---\n'
for s in libuvc_h264 usb_mjpeg rtmp_localhost srt_port_4000; do
  printf 'dump_pipeline source=%s\n' "$s"
  cerastream dump-pipeline --platform rk3588 --source "$s" --codec h264 </dev/null 2>&1 |
    sed -n '/^# elements/,/^# links/p' | sed "s|^|graph ${s}: |"
done

printf -- '--- pidstat availability ---\n'
if command -v pidstat >/dev/null 2>&1; then
  printf 'pidstat=present\n'
else
  printf 'pidstat=absent note=sysstat_is_not_installed_on_the_shipped_image\n'
  printf 'cpu_method=/proc/<pid>/stat utime+stime delta over the same measured window\n'
fi
epid=$(pidof cerastream 2>/dev/null || true)
if [ -n "${epid:-}" ]; then
  printf 'supervised_engine_pid=%s service=%s\n' "$epid" "$(systemctl is-active cerastream.service 2>&1)"
  printf 'supervised_engine_cpu_pct_10s=%s (idle reference; this leg does not drive the supervised service)\n' \
    "$(cpu_percent "$epid" 10)"
else
  printf 'supervised_engine_pid=absent\n'
fi

# --- UVC source kinds -------------------------------------------------------
if [ -z "${uvc_nodes# }" ]; then
  for s in uvc-h264:mppvideodec uvc-mjpeg:mppjpegdec; do
    printf 'source=%s engine_element=%s engine_result=NOT-RUN selected_factory=NO-DEVICE verdict=NO-DEVICE frames=0 cpu_pct=n/a reason=no_uvcvideo_node_is_bound_on_this_board\n' \
      "${s%%:*}" "${s##*:}"
  done
else
  for s in uvc-h264:mppvideodec uvc-mjpeg:mppjpegdec; do
    printf 'source=%s engine_element=%s engine_result=NOT-RUN selected_factory=PRESENT-NOT-PROBED verdict=UNOBSERVED frames=0 cpu_pct=n/a reason=a_uvc_node_is_bound_but_this_leg_does_not_auto_select_a_camera\n' \
      "${s%%:*}" "${s##*:}"
  done
fi

# --- ingest legs: real sessions with local ffmpeg publishers ----------------
#
# TWO CHAINS PER INGEST, because they answer different questions. The ENGINE
# chain is the element cerastream's own rk3588 template hardcodes; if it cannot
# negotiate then the engine cannot serve that ingest at all, and no autoplugger
# rescues a hardcoded element. The AUTOPLUG chain then names the decoder that
# DOES carry frames on this kernel. Reporting only the first would say "nothing
# decodes", which is false; reporting only the second would hide that the
# engine's own chain is broken. The pair is the finding.
#
# Frames are counted from `-v` + `identity silent=false`, one `last-message =
# chain` line per buffer that crossed the pad. A realized-graph name with no
# frame count is not evidence that anything decoded.

ingest_leg() {
  # $1 tag  $2 decoder element  $3 source-chain (before the decoder)  $4 publisher command
  _tag=$1; _dec=$2; _src=$3; _pub_cmd=$4
  _dot="/tmp/cl-dot-${_tag}"
  _log="/tmp/cl-${_tag}-dec.log"
  _publog="/tmp/cl-${_tag}-pub.log"
  mkdir -p "$_dot"; rm -rf "${_dot:?}"/*.dot 2>/dev/null || true

  case "$_tag" in
    rtmp*)
      eval "$_pub_cmd" >"$_publog" 2>&1 </dev/null &
      _pub=$!
      sleep 4
      ;;
  esac

  # shellcheck disable=SC2086
  GST_DEBUG_DUMP_DOT_DIR="$_dot" GST_DEBUG='GST_ELEMENT_FACTORY:4' \
    timeout 40 gst-launch-1.0 -v -e $_src ! "$_dec" \
      ! identity name=p silent=false ! fakesink sync=false \
      >"$_log" 2>&1 </dev/null &
  _gp=$!

  case "$_tag" in
    rtmp*) : ;;
    *)
      sleep 2
      eval "$_pub_cmd" >"$_publog" 2>&1 </dev/null &
      _pub=$!
      ;;
  esac

  sleep 6
  # `timeout` FORKS the pipeline rather than exec'ing it, so $! names the
  # wrapper and sampling it reports the wrapper's idle 0.0% instead of the
  # decode's real cost. The child is the process to measure.
  _target=$(pgrep -P "$_gp" 2>/dev/null | head -1)
  [ -n "$_target" ] || _target=$_gp
  if kill -0 "$_target" 2>/dev/null; then
    _cpu=$(cpu_percent "$_target" 10)
  else
    _cpu=session-did-not-start
  fi
  sleep 1
  kill -INT "$_gp" 2>/dev/null || true
  wait "$_gp" 2>/dev/null || true
  kill -INT "$_pub" 2>/dev/null || true
  wait "$_pub" 2>/dev/null || true

  _frames=$(grep -c 'last-message = chain' "$_log" 2>/dev/null || true)
  [ -n "$_frames" ] || _frames=0
  _fact=$(realized_decoder "$_dot" "$_log")
  if [ "$_frames" -gt 0 ]; then
    _res=OK
  elif grep -q 'not-negotiated' "$_log" 2>/dev/null; then
    _res=NOT-NEGOTIATED
  elif grep -q 'no element\|no property' "$_log" 2>/dev/null; then
    _res=PIPELINE-REJECTED
  else
    _res=NO-FRAMES
  fi
  printf 'ingest_leg tag=%s element=%s result=%s frames=%s factory=%s cpu=%s\n' \
    "$_tag" "$_dec" "$_res" "$_frames" "${_fact:-none}" "$_cpu"
  printf -- '--- %s session log (tail) ---\n' "$_tag"; tail -6 "$_log"
  printf -- '--- %s publisher log (tail) ---\n' "$_tag"; tail -3 "$_publog"
  rm -rf "$_dot" "$_log" "$_publog" 2>/dev/null || true
}

leg_field() { sed -n "s/.*ingest_leg tag=$1 .*$2=\([^ ]*\).*/\1/p" "$3" | head -1; }

# RTMP. The publisher LISTENS on a port of its own rather than pushing into the
# device's real ingest on 1935: this leg must never feed the supervised engine a
# stream nobody asked for. The substitution is recorded, not hidden.
RTMP_PORT=11935
RTMP_URL="rtmp://127.0.0.1:${RTMP_PORT}/publish/live"
RTMP_PUB="timeout 70 ffmpeg -nostdin -hide_banner -loglevel warning -re -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 45 -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g 60 -f flv -listen 1 $RTMP_URL"
printf 'rtmp_publisher=ffmpeg testsrc2 1920x1080@30 libx264 -listen 1 -> %s\n' "$RTMP_URL"
printf 'rtmp_port_note=the engine ingest URL is rtmp://127.0.0.1/publish/live on 1935; this leg listens on %s so the supervised engine is never fed\n' "$RTMP_PORT"
RTMP_SRC="rtmpsrc location=$RTMP_URL ! flvdemux name=demux demux.video ! queue ! h264parse"
ingest_leg rtmp-engine mppvideodec "$RTMP_SRC" "$RTMP_PUB" >/tmp/cl-rtmp-engine.out 2>&1
cat /tmp/cl-rtmp-engine.out
ingest_leg rtmp-autoplug decodebin "$RTMP_SRC" "$RTMP_PUB" >/tmp/cl-rtmp-autoplug.out 2>&1
cat /tmp/cl-rtmp-autoplug.out

# SRT/UDP. The engine's realized SRT chain is
# `udpsrc uri=udp://127.0.0.1:4001 ! decodebin`. The supervised engine already
# owns 4001, so this leg runs the SAME shape on a port it owns.
UDP_PORT=4101
UDP_PUB="timeout 60 ffmpeg -nostdin -hide_banner -loglevel warning -re -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 40 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 60 -f mpegts udp://127.0.0.1:${UDP_PORT}"
printf 'srt_ingest_note=engine chain is udpsrc uri=udp://127.0.0.1:4001 ! decodebin; the supervised engine owns 4001, this session uses %s\n' "$UDP_PORT"
UDP_SRC="udpsrc uri=udp://127.0.0.1:${UDP_PORT} buffer-size=8388608"
ingest_leg srt-engine decodebin "$UDP_SRC" "$UDP_PUB" >/tmp/cl-srt-engine.out 2>&1
cat /tmp/cl-srt-engine.out

# --- the per-source rows the (a) table is built from ------------------------
rtmp_eng_res=$(leg_field rtmp-engine result /tmp/cl-rtmp-engine.out)
rtmp_auto_res=$(leg_field rtmp-autoplug result /tmp/cl-rtmp-autoplug.out)
rtmp_auto_fact=$(leg_field rtmp-autoplug factory /tmp/cl-rtmp-autoplug.out)
rtmp_auto_frames=$(leg_field rtmp-autoplug frames /tmp/cl-rtmp-autoplug.out)
rtmp_auto_cpu=$(leg_field rtmp-autoplug cpu /tmp/cl-rtmp-autoplug.out)
[ "${rtmp_auto_res:-}" = OK ] || rtmp_auto_fact=UNOBSERVED
printf 'source=rtmp engine_element=mppvideodec engine_result=%s selected_factory=%s verdict=%s frames=%s cpu_pct_1080p=%s\n' \
  "${rtmp_eng_res:-NO-RESULT}" "${rtmp_auto_fact:-UNOBSERVED}" \
  "$(classify_factory "${rtmp_auto_fact}")" "${rtmp_auto_frames:-0}" "${rtmp_auto_cpu:-n/a}"

srt_res=$(leg_field srt-engine result /tmp/cl-srt-engine.out)
srt_fact=$(leg_field srt-engine factory /tmp/cl-srt-engine.out)
srt_frames=$(leg_field srt-engine frames /tmp/cl-srt-engine.out)
srt_cpu=$(leg_field srt-engine cpu /tmp/cl-srt-engine.out)
[ "${srt_res:-}" = OK ] || srt_fact=UNOBSERVED
printf 'source=srt engine_element=decodebin engine_result=%s selected_factory=%s verdict=%s frames=%s cpu_pct_1080p=%s\n' \
  "${srt_res:-NO-RESULT}" "${srt_fact:-UNOBSERVED}" \
  "$(classify_factory "${srt_fact}")" "${srt_frames:-0}" "${srt_cpu:-n/a}"

rm -f /tmp/cl-rtmp-engine.out /tmp/cl-rtmp-autoplug.out /tmp/cl-srt-engine.out 2>/dev/null || true
PAYLOAD
}

measure_a_decode_truth() {
  local out=$1 body verdict cmd md rows kinds none
  cmd="decode-truth.sh --all (engine chain AND autoplug chain per source kind, with local publishers)"
  body="$(LEG_TIMEOUT=1200 remote_leg "./decode-truth.sh --all --work '${REMOTE_STAGE}/decode' 2>&1")"
  printf '%s' "${body}" >"${out}/a-decode-truth.txt"

  rows="$(printf '%s\n' "${body}" | sed -n 's/^decode_row=/ /p')"
  if [ -n "${rows}" ]; then md="$(decode_table "${rows}")"; else md=; fi
  kinds="$(printf '%s\n' "${rows}" | grep -c 'kind=' || true)"
  none="$(printf '%s\n' "${rows}" | grep -c 'decoder_class=NONE' || true)"

  if [ -z "${body}" ] || [ -z "${rows}" ]; then
    verdict="NOT-RUN — decode-truth.sh produced no per-kind row"
  elif printf '%s\n' "${rows}" | grep -q 'decoder_class=SOFTWARE'; then
    verdict="SOFTWARE-PRESENT — a source kind is carried by a software decoder; ${kinds} kind(s) measured"
  elif [ "${none}" -gt 0 ]; then
    verdict="HARDWARE-WITH-DEAD-ENGINE-ELEMENT — every kind that decoded used hardware, but ${none} of ${kinds} kind(s) carried no frames at all; see the per-kind table"
  else
    verdict="HARDWARE — every measured source kind was carried by a hardware decoder; ${kinds} kind(s) measured"
  fi
  emit_measurement a "Decode truth (A1)" "${verdict}" "${cmd}" \
    "${out}/a-decode-truth.txt" "${body:-<no output>}" "${md}" \
    >"$(section_file "${out}" a)"
}

# The census shapes: every RK3588 graph shape reachable on a board with no HDMI
# signal and no UVC camera attached. Fields: id|label|both-ends-are-MPP|pipeline.
# `both-ends-are-MPP` is what separates AVOIDABLE from BUG — a copy between two
# MPP clients that can share a dma-buf is a defect, the same copy at a boundary
# with a non-MPP peer is merely unoptimised.
census_shapes() {
  local bps=$1
  cat <<SHAPES
S1|raw NV12 1080p30 -> mpph264enc (stand-in for HDMI 4K60 -> encode)|no|videotestsrc is-live=true ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 ! mpph264enc rc-mode=cbr ${bps}=8000000 gop=60 ! h264parse ! fakesink sync=false|sysmem
S2|raw NV12 2160p30 -> mpph265enc (4K encode)|no|videotestsrc is-live=true ! video/x-raw,format=NV12,width=3840,height=2160,framerate=30/1 ! mpph265enc rc-mode=cbr ${bps}=20000000 gop=60 ! h265parse ! fakesink sync=false|sysmem
S3|MJPEG -> mppjpegdec -> mpph264enc (stand-in for UVC-MJPEG -> decode -> encode)|yes|filesrc location=/tmp/cl-census-src.mjpeg ! jpegparse ! mppjpegdec ! mpph264enc rc-mode=cbr ${bps}=8000000 gop=60 ! h264parse ! fakesink sync=true|dmabuf
S4|H.264 -> mppvideodec -> mpph264enc (stand-in for RTMP/SRT ingest -> decode -> encode)|yes|filesrc location=/tmp/cl-census-src.h264 ! h264parse ! mppvideodec ! mpph264enc rc-mode=cbr ${bps}=8000000 gop=60 ! h264parse ! fakesink sync=true|dmabuf
S5|preview tap ON: raw 1080p30 -> tee -> mpph264enc + preview branch|no|videotestsrc is-live=true ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 ! tee name=t ! queue ! mpph264enc rc-mode=cbr ${bps}=8000000 gop=60 ! h264parse ! fakesink sync=false t. ! queue ! videoconvert ! videoscale ! video/x-raw,format=I420,width=640,height=360 ! fakesink sync=false|sysmem
SHAPES
}

census_prepare_payload() {
  cat <<'PAYLOAD'
set -uo pipefail
if [ ! -s /tmp/cl-census-src.h264 ]; then
  timeout 180 ffmpeg -nostdin -hide_banner -loglevel error -f lavfi \
    -i testsrc2=size=1920x1080:rate=30 -t 8 -c:v libx264 -preset ultrafast \
    -pix_fmt yuv420p -g 30 -f h264 /tmp/cl-census-src.h264 </dev/null 2>&1
  printf 'census_src_h264_rc=%s bytes=%s\n' "$?" "$(wc -c </tmp/cl-census-src.h264 2>/dev/null || echo 0)"
fi
if [ ! -s /tmp/cl-census-src.mjpeg ]; then
  timeout 180 ffmpeg -nostdin -hide_banner -loglevel error -f lavfi \
    -i testsrc2=size=1920x1080:rate=30 -t 8 -c:v mjpeg -q:v 4 \
    -pix_fmt yuvj420p -f mjpeg /tmp/cl-census-src.mjpeg </dev/null 2>&1
  printf 'census_src_mjpeg_rc=%s bytes=%s\n' "$?" "$(wc -c </tmp/cl-census-src.mjpeg 2>/dev/null || echo 0)"
fi
if [ -e /dev/rga ]; then printf 'dev_rga=present\n'; else printf 'dev_rga=absent\n'; fi
if [ -e /dev/mpp_service ]; then printf 'dev_mpp_service=present\n'; else printf 'dev_mpp_service=absent\n'; fi
for f in jpegparse mppjpegdec mppvideodec mpph264enc mpph265enc videoscale; do
  if gst-inspect-1.0 "$f" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  printf 'census_factory=%s rc=%s\n' "$f" "$rc"
done
PAYLOAD
}

# classify_launch_failure <launch-log-text> <pipeline>
#
# A shape that did not run is still a finding, and WHICH failure it hit is the
# whole point: an absent MPP decoder client and a renamed plugin property are
# different facts about the board and must never collapse into one NOT-RUN.
classify_launch_failure() {
  local log=$1 pipeline=$2 el
  if printf '%s\n' "${log}" | grep -qE 'no property|could not set property'; then
    el="$(printf '%s\n' "${log}" | sed -n 's/.*no property "\([^"]*\)".*/\1/p' | head -1)"
    printf 'BLOCKED-PLUGIN-ABI|the installed MPP plugin has no property `%s`; this board ships a different gstreamer1.0-rockchip build and the pipeline was rejected before it ran' \
      "${el:-<unnamed>}"
    return
  fi
  if printf '%s\n' "${log}" | grep -q 'not-negotiated'; then
    if printf '%s\n' "${pipeline}" | grep -qE 'mppvideodec|mppjpegdec'; then
      el="$(printf '%s\n' "${pipeline}" | grep -oE 'mppvideodec|mppjpegdec' | head -1)"
      printf 'BLOCKED-NO-MPP-DECODER|`%s` is registered but negotiated nothing (not-negotiated): the kernel MPP service exposes no decoder client, so this decode boundary cannot be entered on the shipped stack' \
        "${el}"
      return
    fi
    printf 'BLOCKED-NOT-NEGOTIATED|the pipeline failed caps negotiation before any buffer crossed a boundary'
    return
  fi
  if printf '%s\n' "${log}" | grep -q 'no element'; then
    printf 'BLOCKED-MISSING-ELEMENT|an element named in this shape is not installed on this board'
    return
  fi
  printf 'NOT-RUN|the shape produced no dma-buf trace and named no cause (see the raw log)'
}

classify_boundary() {
  local mpp2mpp=$1 new_inodes=$2 copies=$3 blitfail=$4 rgaapi=$5 framecopy=$6 rga=$7
  if [ "${copies}" -gt 0 ] || [ "${framecopy}" -gt 0 ]; then
    if [ "${mpp2mpp}" = yes ]; then
      printf 'BUG|a software copy sits between two MPP clients that can share a dma-buf directly'
    else
      printf 'AVOIDABLE|a software frame copy was attributed on this boundary'
    fi
  elif [ "${blitfail}" -gt 0 ]; then
    printf 'TEMPORARY|librga refused the blit (/dev/rga %s); the island RGA flip closes this' "${rga}"
  elif [ "${rgaapi}" -gt 0 ]; then
    printf 'TEMPORARY|librga was entered though /dev/rga is %s (compatibility-mode no-op); the island RGA flip closes this' "${rga}"
  elif [ "${new_inodes}" -eq 0 ]; then
    printf 'REQUIRED|pool-stable: no dma-buf was allocated in the measured window, so only the producer allocation exists'
  else
    printf 'AVOIDABLE|%s dma-buf(s) allocated inside the measured window with no copy attributed' "${new_inodes}"
  fi
}

# census_row_for — the plan's vocabulary, applied to copy-census.sh's numbers.
#
# Two defects are closed at this seam. A shape whose pipeline never ran still
# yields a row reading "no copy observed" — true, and worthless, because nothing
# was observed at all; it must read UNREACHABLE. And the plan's classes are
# REQUIRED / AVOIDABLE / TEMPORARY / BUG, so a raw NO-COPY spelling is
# translated here rather than surfaced.
census_row_for() {
  local id=$1 mpp2mpp=$2 srcmem=$3 rga=$4 raw=$5
  local crow sc ni fx bf ra ev cls klass reason

  crow="$(printf '%s\n' "${raw}" | sed -n 's/^census_row=//p' | head -1)"

  case "${raw}" in
    *not-negotiated* | *'exited before it could be traced'* | *'launch trace failed'*)
      reason="the pipeline could not run on this board"
      case "${raw}" in
        *not-negotiated*) reason="${reason}: caps negotiation failed (not-negotiated)" ;;
        *) reason="${reason}: it exited before it could be traced" ;;
      esac
      printf 'shape=%s boundary=n/a class=UNREACHABLE software_copies=n/a new_inodes=n/a fds_crossing=n/a rga_blit_fail=n/a rga_api_version=n/a rga_chardev=%s source_memory=%s frames=0 evidence=n/a reason=%s' \
        "${id}" "${rga}" "${srcmem}" "${reason}"
      return 0
      ;;
  esac

  if [ -z "${crow}" ]; then
    printf 'shape=%s boundary=n/a class=UNREACHABLE software_copies=n/a new_inodes=n/a fds_crossing=n/a rga_blit_fail=n/a rga_api_version=n/a rga_chardev=%s source_memory=%s frames=0 evidence=n/a reason=the shape emitted no census row' \
      "${id}" "${rga}" "${srcmem}"
    return 0
  fi

  sc="$(field " ${crow}" software_copies)"
  ni="$(field " ${crow}" new_inodes)"
  fx="$(field " ${crow}" fds_crossing)"
  bf="$(field " ${crow}" rga_blit_fail)"
  ra="$(field " ${crow}" rga_api_version)"
  ev="$(field " ${crow}" evidence)"

  case "${sc}${ni}${bf}${ra}" in *[!0-9]*)
    printf 'shape=%s boundary=whole-graph-window class=UNREACHABLE software_copies=%s new_inodes=%s fds_crossing=%s rga_blit_fail=%s rga_api_version=%s rga_chardev=%s source_memory=%s frames=0 evidence=%s reason=the shape reported no numeric counters' \
      "${id}" "${sc}" "${ni}" "${fx}" "${bf}" "${ra}" "${rga}" "${srcmem}" "${ev}"
    return 0
    ;;
  esac

  cls="$(classify_boundary "${mpp2mpp}" "${ni}" "${sc}" "${bf}" "${ra}" 0 "${rga}")"
  klass="${cls%%|*}"
  reason="${cls#*|}"
  printf 'shape=%s boundary=whole-graph-window class=%s software_copies=%s new_inodes=%s fds_crossing=%s rga_blit_fail=%s rga_api_version=%s rga_chardev=%s source_memory=%s frames=%s evidence=%s reason=%s' \
    "${id}" "${klass}" "${sc}" "${ni}" "${fx}" "${bf}" "${ra}" "${rga}" "${srcmem}" \
    "$(field " ${crow}" frames)" "${ev}" "${reason}"
}

measure_b_copy_census() {
  local out=$1 verdict cmd md prep raw id label mpp2mpp pipeline srcmem
  local rows row shapes_run=0 bps rga_line rga t0 t1 journal
  cmd="copy-census.sh --shape <s> --pipeline <p> per reachable RK3588 graph shape"
  bps="$(detect_enc_bitrate_prop)"
  [ -n "${bps}" ] && [ "${bps}" != none ] || bps=bitrate

  prep="$(LEG_TIMEOUT=420 remote_leg "$(census_prepare_payload)")"
  rga_line="$(printf '%s\n' "${prep}" | sed -n 's/^dev_rga=//p' | head -1)"
  rga="${rga_line:-unknown}"
  raw="census preparation (encoder bitrate property = ${bps}):"$'\n'"${prep}"$'\n'
  rows=

  while IFS='|' read -r id label mpp2mpp pipeline srcmem; do
    [ -n "${id}" ] || continue
    t0="$(board_clock)"
    row="$(LEG_TIMEOUT=420 remote_leg \
      "./copy-census.sh --shape '${id}' --pipeline '${pipeline}' --source-memory '${srcmem}' --seconds 6 --work '${REMOTE_STAGE}/census-${id}' 2>&1")"
    sleep 2
    t1="$(board_clock)"
    journal="$(journal_window "${t0}" "${t1}")"
    raw="${raw}"$'\n'"=== ${id} — ${label} (both-ends-MPP=${mpp2mpp}, source-memory=${srcmem}) ==="$'\n'"${row}"$'\n'
    raw="${raw}journal window ${t0} .. ${t1}: RGA_BLIT_fail=$(printf '%s\n' "${journal}" | grep -cF 'RGA_BLIT fail') rga_api_version=$(printf '%s\n' "${journal}" | grep -cF 'rga_api version') gst_video_frame_copy=$(printf '%s\n' "${journal}" | grep -cF 'gst_video_frame_copy')"$'\n'
    rows="${rows} $(census_row_for "${id}" "${mpp2mpp}" "${srcmem}" "${rga}" "${row}")"$'\n'
    case "$(census_row_for "${id}" "${mpp2mpp}" "${srcmem}" "${rga}" "${row}")" in
      *class=UNREACHABLE*) ;;
      *) shapes_run=$((shapes_run + 1)) ;;
    esac
  done < <(census_shapes "${bps}")

  md="$(census_table "${rows}")"
  md="${md}"$'\n\n'"$(printf '`/dev/rga` is **%s**. The mainline `rockchip-rga` driver is a V4L2 M2M\n' "${rga}")"
  md="${md}$(printf 'device exposing no character node, so librga cannot reach hardware at all:\n')"
  md="${md}$(printf 'every RGA-classified row is TEMPORARY by construction and is closed by the\n')"
  md="${md}$(printf 'island RGA flip, not by tuning userspace.\n')"

  printf '%s' "${raw}" >"${out}/b-copy-census.txt"

  if [ "${shapes_run}" -eq 0 ]; then
    verdict="NOT-RUN — no graph shape produced a census row"
  elif printf '%s\n' "${rows}" | grep -q 'class=BUG'; then
    verdict="COPY-PRESENT (BUG) — a shape copies between two clients that can share a dma-buf; ${shapes_run} shape(s) measured"
  elif printf '%s\n' "${rows}" | grep -q 'class=AVOIDABLE'; then
    verdict="COPY-PRESENT (AVOIDABLE) — ${shapes_run} shape(s) measured; at least one boundary copies or allocates per window"
  elif printf '%s\n' "${rows}" | grep -q 'class=UNREACHABLE'; then
    verdict="PARTIAL — ${shapes_run} shape(s) measured; at least one shape is UNREACHABLE on this board and carries its reason"
  else
    verdict="COPY-FREE — ${shapes_run} shape(s) measured; every boundary is REQUIRED or TEMPORARY"
  fi
  emit_measurement b "Copy census (A11)" "${verdict}" "${cmd}" \
    "${out}/b-copy-census.txt" "${raw:-<no output>}" "${md}" \
    >"$(section_file "${out}" b)"
}

# hevc_600_payload <node-or-empty> — the 600-frame legs.
#
# With a locked 4K59.94 source the frames come from HDMI-RX and the result is
# the G4 row. With no lock the same 600-frame shape is run from videotestsrc at
# the identical geometry, and it is SUPPLEMENTARY ONLY: it exercises the encoder
# but proves nothing about capture, so it can never satisfy G4.
hevc_600_payload() {
  local node=$1 bps=${2:-bitrate}
  cat <<PAYLOAD
set -uo pipefail
NODE='${node}'
BPS='${bps}'
PAYLOAD
  cat <<'PAYLOAD'
for codec in h265 h264; do
  enc="mpp${codec}enc"; parse="${codec}parse"
  log="/tmp/cl-c-${codec}.log"
  if [ -n "$NODE" ]; then
    mode=hdmi-rx
    src="v4l2src device=$NODE io-mode=dmabuf num-buffers=600 ! videoconvert ! video/x-raw,format=NV12"
  else
    mode=videotestsrc-supplementary
    src="videotestsrc num-buffers=600 ! video/x-raw,format=NV12,width=3840,height=2160,framerate=60000/1001"
  fi
  printf 'codec=%s encoder=%s mode=%s\n' "$codec" "$enc" "$mode"
  start=$(awk '{print $1}' /proc/uptime)
  # shellcheck disable=SC2086
  timeout 240 gst-launch-1.0 -v -e $src \
    ! "$enc" rc-mode=cbr "${BPS}=20000000" gop=60 \
    ! "$parse" ! identity name=auprobe silent=false ! fakesink sync=false \
    >"$log" 2>&1 </dev/null
  rc=$?
  end=$(awk '{print $1}' /proc/uptime)
  aus=$(grep -c 'last-message = chain' "$log" || true)
  errs=$(grep -cE 'ERROR|CRITICAL|not-negotiated|Internal data stream error' "$log" || true)
  fps=$(awk -v n="$aus" -v a="$start" -v b="$end" 'BEGIN{d=b-a; if(d<=0){print "n/a"}else{printf "%.2f", n/d}}')
  printf 'codec=%s mode=%s aus=%s/600 errors=%s elapsed_s=%s measured_fps=%s gst_rc=%s\n' \
    "$codec" "$mode" "$aus" "$errs" \
    "$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.2f", b-a}')" "$fps" "$rc"
  if [ "$aus" -eq 600 ] && [ "$errs" -eq 0 ] && [ "$rc" -eq 0 ]; then
    printf 'codec=%s mode=%s VERDICT=PASS\n' "$codec" "$mode"
  else
    printf 'codec=%s mode=%s VERDICT=FAIL\n' "$codec" "$mode"
  fi
  printf -- '--- %s log tail ---\n' "$codec"; tail -6 "$log"
  rm -f "$log" 2>/dev/null || true
done
PAYLOAD
}

measure_c_hevc_baseline() {
  local out=$1 body verdict cmd signal node width height fps locked md supp bps
  cmd="VIDIOC_QUERY_DV_TIMINGS gate, then HDMI-RX capture -> mpph265enc / mpph264enc, 600 frames"
  bps="$(enc_bitrate_prop)"

  signal="$(LEG_TIMEOUT=180 board_run "$(hdmi_signal_payload)")"
  node="$(printf '%s\n' "${signal}" | sed -n 's/^hdmi_node=\([^ ]*\) .*/\1/p' | head -1)"
  width="$(printf '%s\n' "${signal}" | awk '/QUERY_DV_TIMINGS/{q=1} q&&/Active width/{print $3; exit}')"
  height="$(printf '%s\n' "${signal}" | awk '/QUERY_DV_TIMINGS/{q=1} q&&/Active height/{print $3; exit}')"
  fps="$(printf '%s\n' "${signal}" | awk '/QUERY_DV_TIMINGS/{q=1} q&&/frames per second/{gsub(/\(/,"");print $3; exit}')"

  locked=no
  if printf '%s\n' "${signal}" | grep -q '^query_dv_timings_rc=0' &&
    [ "${width:-0}" = 3840 ] && [ "${height:-0}" = 2160 ] &&
    printf '%s' "${fps:-0}" | grep -qE '^(59\.9|60\.0|60$)'; then
    locked=yes
  fi

  if [ "${locked}" = yes ]; then
    supp="$(LEG_TIMEOUT=900 remote_leg "$(hevc_600_payload "${node}" "${bps}")")"
    body="${signal}"$'\n\n'"${supp}"
    if printf '%s\n' "${supp}" | grep -q 'VERDICT=FAIL'; then
      verdict="FAIL — at least one codec did not deliver 600 error-free access units from a locked 4K59.94 HDMI-RX source on the CURRENT stack (gate G4: a finding about the shipped stack, not a harness fault)"
    else
      verdict="PASS — 600 access units, zero errors, per codec, from a locked 4K59.94 HDMI-RX source"
    fi
    md="$(printf 'G4 gate: **EXERCISED** — HDMI-RX reported a locked %sx%s @ %s signal.\n' \
      "${width}" "${height}" "${fps}")"
  else
    supp="$(LEG_TIMEOUT=900 remote_leg "$(hevc_600_payload '' "${bps}")")"
    body="${signal}"$'\n\n'"${supp}"
    verdict="BLOCKED-NO-SIGNAL"
    md="$(
      printf 'G4 gate: **BLOCKED**. `VIDIOC_QUERY_DV_TIMINGS` did not report a locked\n'
      printf '3840x2160 @ 59.94 signal on `%s`, so the real-capture 600-frame row for\n' "${node:-<no hdmirx node>}"
      printf 'H.265 and H.264 could not be taken. The complete QUERY transcript is in the\n'
      printf 'body below.\n\n'
      printf '| field | value |\n|---|---|\n'
      printf '| hdmi-rx node | `%s` |\n' "${node:-absent}"
      printf '| QUERY_DV_TIMINGS active geometry | `%sx%s` |\n' "${width:-0}" "${height:-0}"
      printf '| QUERY_DV_TIMINGS frame rate | `%s` |\n' "${fps:-0}"
      printf '| required for G4 | `3840x2160 @ 59.94` |\n'
      printf '\n**`--get-dv-timings` is not evidence of a lock.** With nothing attached this\n'
      printf 'board still answers `--get` with a stale 640x480p59.94 VGA default; 640x480 is\n'
      printf 'not 4K59.94 and must never be read as a signal.\n\n'
      printf 'The 600-frame runs recorded below were driven from `videotestsrc` at the same\n'
      printf '3840x2160 @ 60000/1001 geometry. They are **SUPPLEMENTARY ONLY** — they\n'
      printf 'exercise the encoder, they say nothing about capture, and they do NOT\n'
      printf 'discharge G4.\n'
    )"
  fi

  printf '%s' "${body}" >"${out}/c-hevc-4k5994.txt"
  emit_measurement c "H.265 / H.264 4K59.94 baseline (G4)" "${verdict}" "${cmd}" \
    "${out}/c-hevc-4k5994.txt" "${body:-<no output>}" "${md}" \
    >"$(section_file "${out}" c)"
}

measure_d_dual_core() {
  local out=$1 body verdict cmd md window rkvenc_rows advanced total_rows fpsrows
  cmd="two concurrent videotestsrc 4K30 H.265 encodes for 60 s + sample-cores.sh window deltas"
  local bps
  bps="$(enc_bitrate_prop)"
  body="$(LEG_TIMEOUT=300 remote_leg "$(
    printf "set -uo pipefail\nBPS='%s'\n" "${bps}"
    cat <<'LEG'
printf -- '--- rkvenc IRQ lines as this kernel spells them ---\n'
grep -E 'rkvenc' /proc/interrupts | awk '{printf "irq_line irq=%s label=%s\n", $1, $NF}'
# Scratch lives in this run's own staging directory, not in bare /tmp. A run on
# the Orange Pi lost /tmp/cl-dualcore-* and the sampler's snapshot directory
# midway through the window to something outside this harness (no code here
# deletes those paths), which truncated the window to 20 s and left the fps
# count at zero. A per-run directory plus one retry keeps a transient external
# event from being recorded as a board finding.
SCRATCH=./dualcore-scratch
# Per-process fps is derived from `identity silent=false` under `-v`, one
# `last-message = chain` line per encoded access unit, counted over exactly the
# window sample-cores measures. Neither bench board ships GStreamer's framerate
# tracer ("no tracer named 'framerate'"), and fpsdisplaysink's -v output is not
# in the format the tracer parser reads, so both of those yield a silent
# samples=0 and the dual-core claim loses half its evidence.
pipeline="videotestsrc is-live=true ! video/x-raw,format=NV12,width=3840,height=2160,framerate=30/1 ! mpph265enc rc-mode=cbr ${BPS}=20000000 gop=60 ! h265parse ! identity name=p silent=false ! fakesink sync=false"

attempt=1
while [ "$attempt" -le 2 ]; do
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  printf 'dualcore_attempt=%s scratch=%s\n' "$attempt" "$SCRATCH"
  for tag in a b; do
    # shellcheck disable=SC2086
    timeout 80 gst-launch-1.0 -v -e $pipeline >"$SCRATCH/session-$tag.log" 2>&1 </dev/null &
    printf 'session=%s pid=%s\n' "$tag" "$!"
  done
  sleep 5
  w0_a=$(wc -l <"$SCRATCH/session-a.log" 2>/dev/null || echo 0)
  w0_b=$(wc -l <"$SCRATCH/session-b.log" 2>/dev/null || echo 0)
  t0=$(awk '{print $1}' /proc/uptime)
  ./sample-cores.sh --duration 60 --interval 10 --out "$SCRATCH/samples"
  sample_rc=$?
  t1=$(awk '{print $1}' /proc/uptime)
  w1_a=$(wc -l <"$SCRATCH/session-a.log" 2>/dev/null || echo 0)
  w1_b=$(wc -l <"$SCRATCH/session-b.log" 2>/dev/null || echo 0)
  wait
  if [ "$sample_rc" -eq 0 ] && [ "$w1_a" -gt "$w0_a" ]; then
    break
  fi
  printf 'dualcore_attempt=%s status=incomplete sample_rc=%s frames_a_delta=%s; retrying\n' \
    "$attempt" "$sample_rc" "$((w1_a - w0_a))"
  attempt=$((attempt + 1))
done

elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
printf 'fps_window_elapsed_s=%s method=identity-chain-count-over-the-sampled-window\n' "$elapsed"
for tag in a b; do
  eval "w0=\$w0_${tag}; w1=\$w1_${tag}"
  sed -n "$((w0 + 1)),${w1}p" "$SCRATCH/session-${tag}.log" >"$SCRATCH/window-${tag}.log" 2>/dev/null || true
  ./sample-cores.sh --score-only --chain-log "${tag}:$SCRATCH/window-${tag}.log:${elapsed}" |
    grep '^fps tag=' || true
done
printf -- '--- per-session log tails ---\n'
for tag in a b; do printf 'session=%s: ' "$tag"; tail -2 "$SCRATCH/session-$tag.log" 2>/dev/null || printf '<log missing>\n'; done
rm -rf "$SCRATCH" 2>/dev/null || true
LEG
  )")"
  printf '%s' "${body}" >"${out}/d-dual-core.txt"

  # The verdict reads the WINDOW TOTAL block, never the 1 s slices: a per-slice
  # row can be zero on a core that ran for the other 59 s. Labels are matched on
  # the `rkvenc` substring because this kernel spells them fdbd0000.rkvenc-core /
  # fdbe0000.rkvenc-core — the vendor `rkvenc0`/`rkvenc1` spellings do not exist
  # here, and matching them is what made this leg report a false NOT-RUN.
  window="$(printf '%s\n' "${body}" | awk '/^--- window total/{f=1;next} /^--- /{f=0} f')"
  rkvenc_rows="$(printf '%s\n' "${window}" | grep 'label=.*rkvenc' || true)"
  total_rows="$(printf '%s\n' "${rkvenc_rows}" | grep -c 'label=' || true)"
  advanced="$(printf '%s\n' "${rkvenc_rows}" | awk -F'total_delta=' 'NF>1{split($2,a," "); if (a[1]+0 > 0) n++} END{print n+0}')"
  fpsrows="$(printf '%s\n' "${body}" | grep '^fps tag=' || true)"

  md="$(
    printf '| IRQ | label | total delta over the 60 s window | per-CPU | active CPUs |\n'
    printf '|---|---|---|---|---|\n'
    if [ -n "${rkvenc_rows}" ]; then
      printf '%s\n' "${rkvenc_rows}" | while IFS= read -r r; do
        [ -n "${r}" ] || continue
        printf '| %s | `%s` | %s | `%s` | %s |\n' \
          "$(printf '%s' "${r}" | sed -n 's/.*irq=\([^ ]*\).*/\1/p')" \
          "$(printf '%s' "${r}" | sed -n 's/.*label=\([^ ]*\).*/\1/p')" \
          "$(printf '%s' "${r}" | sed -n 's/.*total_delta=\([^ ]*\).*/\1/p')" \
          "$(printf '%s' "${r}" | sed -n 's/.*per_cpu=\([^ ]*\).*/\1/p')" \
          "$(printf '%s' "${r}" | sed -n 's/.*active_cpus=\([^ ]*\).*/\1/p')"
      done
    else
      printf '| n/a | n/a | n/a | n/a | n/a |\n'
    fi
    printf '\n| session | per-process fps |\n|---|---|\n'
    if [ -n "${fpsrows}" ]; then
      printf '%s\n' "${fpsrows}" | while IFS= read -r r; do
        [ -n "${r}" ] || continue
        printf '| %s | `%s` |\n' \
          "$(printf '%s' "${r}" | sed -n 's/.*tag=\([^ ]*\).*/\1/p')" \
          "$(printf '%s' "${r}" | sed 's/^fps tag=[^ ]* //')"
      done
    else
      printf '| a, b | no per-process frame count was produced |\n'
    fi
  )"

  if [ -z "${body}" ]; then
    verdict="NOT-RUN — the dual-core leg produced no output"
  elif [ -z "${rkvenc_rows}" ]; then
    verdict="NOT-RUN — no rkvenc IRQ line appeared in the window-total block"
  elif [ "${advanced}" -ge 2 ]; then
    verdict="DUAL-CORE — ${advanced} of ${total_rows} rkvenc core IRQ lines advanced during the 60 s window"
  elif [ "${advanced}" -eq 1 ]; then
    verdict="SINGLE-CORE — only 1 of ${total_rows} rkvenc core IRQ lines advanced; two concurrent 4K30 H.265 sessions did not reach the second encoder core"
  else
    verdict="NO-ENCODER-IRQ — ${total_rows} rkvenc line(s) present, none advanced during the window"
  fi
  emit_measurement d "Dual-core concurrency baseline (A4)" "${verdict}" "${cmd}" \
    "${out}/d-dual-core.txt" "${body:-<no output>}" "${md}" \
    >"$(section_file "${out}" d)"
}

measure_e_encode_oracle() {
  local out=$1 body verdict cmd md codec means n
  cmd="encode-psnr-oracle.sh --codec both --runs ${ORACLE_RUNS}"
  body="$(LEG_TIMEOUT=5400 remote_leg \
    "./encode-psnr-oracle.sh --codec both --runs ${ORACLE_RUNS} --out '${REMOTE_STAGE}/oracle' 2>&1")"
  printf '%s' "${body}" >"${out}/e-encode-oracle.txt"

  md="$(
    printf '| codec | verdict | runs scored | distinct MD5 | fixture assertion |\n'
    printf '|---|---|---|---|---|\n'
    for codec in h264 h265; do
      n="$(printf '%s\n' "${body}" | grep -c "^run=.* codec=${codec} mean_psnr_db=" || true)"
      printf '| %s | %s | %s | %s | `%s` |\n' "${codec}" \
        "$(printf '%s\n' "${body}" | sed -n "s/^codec=${codec} VERDICT=\([A-Z-]*\).*/\1/p" | head -1)" \
        "${n}" \
        "$(printf '%s\n' "${body}" | sed -n "s/^codec=${codec} distinct_md5=\([0-9]*\).*/\1/p" | head -1)" \
        "$(printf '%s\n' "${body}" | grep -m1 '^fixture_sha256_ok=' || echo 'NOT ASSERTED')"
    done
    for codec in h264 h265; do
      means="$(printf '%s\n' "${body}" |
        sed -n "s/^run=.* codec=${codec} mean_psnr_db=\([0-9.]*\).*/\1/p" | paste -sd, -)"
      printf '\n`%s` per-run mean PSNR (dB): `%s`\n' "${codec}" "${means:-none recorded}"
    done
  )"

  if printf '%s\n' "${body}" | grep -q 'VERDICT=DIRTY'; then
    verdict="DIRTY — at least one codec's PSNR distribution breached the floor on the shipped image"
  elif printf '%s\n' "${body}" | grep -q 'VERDICT=CLEAN'; then
    verdict="CLEAN — every run's mean PSNR held and the low-frame budget was respected"
  else
    verdict="NOT-RUN — the oracle produced no per-codec verdict (see the artifact for the reason)"
  fi
  emit_measurement e "Encode-corruption oracle baseline (ENC-CORRUPT)" "${verdict}" \
    "${cmd}" "${out}/e-encode-oracle.txt" "${body:-<no output>}" "${md}" \
    >"$(section_file "${out}" e)"
}

# append_bug_reality — one ENC-CORRUPT row per codec, from (e)'s own output.
append_bug_reality() {
  # Serialised: concurrent board runs share one ledger, and the read-modify-write
  # below is a lost-update race without a lock.
  local lock="$2.lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${lock}"
    flock 9
  fi
  _append_bug_reality "$@"
  local rc=$?
  if command -v flock >/dev/null 2>&1; then
    flock -u 9
    exec 9>&-
    rm -f "${lock}" 2>/dev/null || true
  fi
  return "${rc}"
}

_append_bug_reality() {
  local out=$1 ledger=$2 codec row_verdict means fixture_assert tmp
  [ -s "${ledger}" ] || bug_reality_header >"${ledger}"
  # Idempotent per board: a re-run RESTATES its rows instead of stacking a
  # second copy the reader cannot date.
  if grep -q "| ENC-CORRUPT | ${BOARD} |" "${ledger}" 2>/dev/null; then
    tmp="$(mktemp)" || return 1
    grep -v "| ENC-CORRUPT | ${BOARD} |" "${ledger}" >"${tmp}" && cat "${tmp}" >"${ledger}"
    rm -f "${tmp}"
  fi
  fixture_assert=$(grep -m1 '^fixture_sha256_ok=' "${out}/e-encode-oracle.txt" 2>/dev/null || echo 'NOT ASSERTED')
  for codec in h264 h265; do
    row_verdict=$(grep -m1 "^codec=${codec} VERDICT=" "${out}/e-encode-oracle.txt" 2>/dev/null |
      sed -n 's/.*VERDICT=\([A-Z-]*\).*/\1/p')
    [ -n "${row_verdict}" ] || row_verdict='NOT-RUN'
    means=$(grep "^run=.* codec=${codec} mean_psnr_db=" "${out}/e-encode-oracle.txt" 2>/dev/null |
      sed -n 's/.*mean_psnr_db=\([0-9.]*\).*/\1/p' | paste -sd, -)
    [ -n "${means}" ] || means='none recorded'
    bug_reality_row "${BOARD}" "${codec}" "${row_verdict}" \
      "encode-psnr-oracle.sh --codec ${codec} --runs ${ORACLE_RUNS}" \
      "${fixture_assert}" "${means}" "${out}" >>"${ledger}"
  done
}

# ---------------------------------------------------------------------------
# Connect check
# ---------------------------------------------------------------------------
#
# A deliberately narrow mode: prove the transport, prove the read-only screen
# is enforced on the way out, and capture the inventory every measurement row
# has to cite. It runs NONE of (a)-(e) and writes no baseline document, so it
# is safe to run at any time against a live bench board.
connect_check() {
  local inventory signal payload

  load_credentials || return $?
  require_tools sshpass ssh scp || return "${HARNESS_USAGE}"

  printf 'mode=connect-check board=%s host=%s user=%s\n' "${BOARD}" "${HOST}" "${USER_NAME}"

  payload="$(inventory_payload)"
  if ! assert_payload_is_read_only "${payload}"; then
    harness_fail_msg "the inventory payload failed its own read-only screen"
    return "${HARNESS_FAIL}"
  fi
  printf 'read_only_screen=passed\n'

  printf -- '--- identity ---\n'
  if ! board_identity; then
    harness_verdict GATED "the board did not answer; nothing was measured"
    return $?
  fi

  printf -- '--- inventory ---\n'
  inventory="$(board_run "${payload}")" || {
    harness_verdict GATED "the inventory payload did not complete"
    return $?
  }
  printf '%s\n' "${inventory}"

  printf -- '--- hdmi signal ---\n'
  signal="$(board_run "$(hdmi_signal_payload)")" || true
  printf '%s\n' "${signal:-<no v4l2 nodes answered>}"

  if [ -n "${REPORT_DIR}" ]; then
    mkdir -p "${REPORT_DIR}"
    printf '%s\n' "${inventory}" >"${REPORT_DIR}/${BOARD}-inventory.txt"
    printf '%s\n' "${signal}" >"${REPORT_DIR}/${BOARD}-hdmi-signal.txt"
    printf 'report_dir=%s\n' "${REPORT_DIR}"
  fi

  harness_verdict PASS "connect-check only; no measurement was run and no baseline document was written"
}

# ---------------------------------------------------------------------------
# Full run
# ---------------------------------------------------------------------------

full_run() {
  local out doc ledger identity rc=0

  load_credentials || return $?
  require_tools sshpass ssh scp || return "${HARNESS_USAGE}"

  [ -n "${REPORT_DIR}" ] || REPORT_DIR="$(harness_out_dir "baseline-${BOARD}")" || return "${HARNESS_FAIL}"
  mkdir -p "${REPORT_DIR}" || return "${HARNESS_FAIL}"
  out="${REPORT_DIR}"

  [ -n "${DOC_DIR}" ] || DOC_DIR="${out}"
  [ -n "${LEDGER_DIR}" ] || LEDGER_DIR="${out}"
  mkdir -p "${DOC_DIR}" "${LEDGER_DIR}" || return "${HARNESS_FAIL}"
  doc="${DOC_DIR}/baseline-${BOARD}.md"
  ledger="${LEDGER_DIR}/bug-reality.md"

  identity="$(board_identity)" || {
    harness_verdict GATED "board ${BOARD} (${HOST}) did not answer; nothing was measured"
    return $?
  }
  identity="${identity}"$'\n'"$(board_run "$(inventory_payload)")"
  printf '%s\n' "${identity}" >"${out}/identity.txt"

  stage_harness || {
    harness_fail_msg "could not stage the harness on the board"
    return "${HARNESS_FAIL}"
  }
  trap unstage_harness EXIT

  case ",${MEASURE}," in *,a,*) measure_a_decode_truth "${out}" ;; esac
  case ",${MEASURE}," in *,b,*) measure_b_copy_census "${out}" ;; esac
  case ",${MEASURE}," in *,c,*) measure_c_hevc_baseline "${out}" ;; esac
  case ",${MEASURE}," in *,d,*) measure_d_dual_core "${out}" ;; esac
  case ",${MEASURE}," in *,e,*) measure_e_encode_oracle "${out}" ;; esac

  local id
  {
    doc_header "${BOARD}" "${HOST}" "${identity}"
    for id in a b c d e; do
      if [ -s "$(section_file "${out}" "${id}")" ]; then
        if [ "${id}" = d ]; then
          normalize_recorded_section_d "$(section_file "${out}" "${id}")"
        else
          cat "$(section_file "${out}" "${id}")"
        fi
      else
        not_run_section "${id}"
      fi
    done
  } >"${doc}"

  strip_trailing_hspace "${doc}"
  for id in a b c d e; do
    case ",${MEASURE}," in *,"${id}",*) strip_trailing_hspace "$(section_file "${out}" "${id}")" ;; esac
  done

  case ",${MEASURE}," in *,e,*) append_bug_reality "${out}" "${ledger}" ;; esac

  printf 'baseline_document=%s\n' "${doc}"
  printf 'bug_reality_ledger=%s\n' "${ledger}"
  [ "$(grep -c '^\*\*VERDICT: ' "${doc}")" -eq 5 ] || rc=1

  unstage_harness
  trap - EXIT

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "the baseline document is missing a verdict"
    return $?
  }
  harness_verdict PASS "baseline written to ${doc}"
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# Proves three properties with no board:
#   1. every remote payload this script can send passes the read-only screen,
#      and the screen is not vacuous — a payload carrying a banned verb is
#      rejected;
#   2. the document composer renders a complete five-section baseline, and a
#      leg that did not run renders as NOT-RUN rather than as a pass;
#   3. the bug-reality row carries the fixture assertion and a verdict.
self_test() {
  local work rc=0 doc ledger

  work="$(mktemp -d)" || return "${HARNESS_FAIL}"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN

  printf 'self_test=run-baseline\n'

  # --- 1. the read-only screen -------------------------------------------
  local payload
  for payload in "$(inventory_payload)" "$(hdmi_signal_payload)" \
    "$(decode_truth_payload)" "$(census_prepare_payload)" \
    "$(hevc_600_payload '')" "$(hevc_600_payload /dev/video2)"; do
    if assert_payload_is_read_only "${payload}"; then
      printf 'screen payload=ok\n'
    else
      harness_fail_msg "a payload this script sends failed the read-only screen"
      rc=1
    fi
  done

  # Every ffmpeg and gst-launch in a DELIVERED payload must close stdin: the
  # payload arrives on stdin of `bash -s`, so a child that reads stdin swallows
  # the rest of the script and the leg truncates with no verdict. Continuations
  # are joined first so a redirect on the last line still counts.
  # An INVOCATION is `ffmpeg -<flag>` / `gst-launch-1.0 -<flag>`; prose that
  # merely names the tool inside a printf carries no dash and is not one.
  local joined bad_ff bad_gst
  for payload in "$(decode_truth_payload)" "$(census_prepare_payload)" \
    "$(hevc_600_payload '')"; do
    joined=$(printf '%s\n' "${payload}" |
      sed -e :a -e '/\\$/N; s/\\\n//; ta' | grep -v '^[[:space:]]*#')
    bad_ff=$(printf '%s\n' "${joined}" | grep 'ffmpeg -' | grep -vc -- '-nostdin' || true)
    bad_gst=$(printf '%s\n' "${joined}" | grep 'gst-launch-1\.0 -' | grep -vc '</dev/null' || true)
    if [ "${bad_ff}" -ne 0 ] || [ "${bad_gst}" -ne 0 ]; then
      harness_fail_msg "payload has ${bad_ff} ffmpeg without -nostdin and ${bad_gst} gst-launch without </dev/null"
      rc=1
    fi
  done
  [ "${rc}" -ne 0 ] || printf 'payload stdin-safety=ok\n'

  # The screen must reject each banned class. The verbs are assembled here for
  # the same reason lib/harness-lib.sh assembles them: the harness-wide
  # forbidden-verb gate greps these very files, so a literal spelling would
  # make the test trip the rule it is testing.
  local ctl='systemctl'" start cerastream"
  local mods='mod'"probe rockchip_rga"
  local sysw='echo 1 >'" /sys/kernel/debug/rkvenc-test/inject"
  local bad
  for bad in "${ctl}" "${mods}" "${sysw}" "rauc install /tmp/x.raucb" "reboot"; do
    if assert_payload_is_read_only "${bad}" 2>/dev/null; then
      harness_fail_msg "the read-only screen ACCEPTED a forbidden payload: ${bad}"
      rc=1
    else
      printf 'screen rejected=%q ok\n' "${bad}"
    fi
  done

  # --- 1b. blocked shapes must name their cause, and the census table must
  #         actually be a table. Both were real defects: every failed shape
  #         collapsed into one NOT-RUN, and `md="${md}$(printf '...\n')"` threw
  #         the newline away (command substitution strips trailing newlines), so
  #         all rows landed on a single line and the table never rendered.
  local cls
  cls="$(classify_launch_failure 'WARNING: erroneous pipeline: no property "bitrate" in element "mpph264enc0"' 'mpph264enc bitrate=8000000')"
  [ "${cls%%|*}" = BLOCKED-PLUGIN-ABI ] || {
    harness_fail_msg "a renamed encoder property classified as ${cls%%|*}, expected BLOCKED-PLUGIN-ABI"
    rc=1
  }
  printf '%s\n' "${cls#*|}" | grep -q 'bitrate' || {
    harness_fail_msg "the plugin-ABI reason does not name the offending property"
    rc=1
  }
  cls="$(classify_launch_failure 'streaming stopped, reason not-negotiated (-4)' 'filesrc ! jpegparse ! mppjpegdec ! mpph264enc')"
  [ "${cls%%|*}" = BLOCKED-NO-MPP-DECODER ] || {
    harness_fail_msg "an MPP decode chain that did not negotiate classified as ${cls%%|*}"
    rc=1
  }
  printf '%s\n' "${cls#*|}" | grep -q 'mppjpegdec' || {
    harness_fail_msg "the MPP-decoder reason does not name the element that failed"
    rc=1
  }
  cls="$(classify_launch_failure 'streaming stopped, reason not-negotiated (-4)' 'videotestsrc ! mpph264enc')"
  [ "${cls%%|*}" = BLOCKED-NOT-NEGOTIATED ] || {
    harness_fail_msg "a non-MPP negotiation failure classified as ${cls%%|*}"
    rc=1
  }
  cls="$(classify_launch_failure 'no element "nosuchelement"' 'nosuchelement ! fakesink')"
  [ "${cls%%|*}" = BLOCKED-MISSING-ELEMENT ] || {
    harness_fail_msg "a missing element classified as ${cls%%|*}"
    rc=1
  }
  cls="$(classify_launch_failure 'nothing informative here' 'videotestsrc ! fakesink')"
  [ "${cls%%|*}" = NOT-RUN ] || {
    harness_fail_msg "an unexplained failure classified as ${cls%%|*}, expected NOT-RUN"
    rc=1
  }
  printf 'blocked-shape classification ok (ABI, MPP-decoder, negotiation, missing element, unknown)\n'

  # The row-join idiom, asserted directly: three rows must be three LINES.
  local tbl
  tbl="| a | b |"
  tbl="${tbl}"$'\n'"|---|---|"
  tbl="${tbl}"$'\n'"$(printf '| %s | %s |' S1 one)"
  tbl="${tbl}"$'\n'"$(printf '| %s | %s |' S2 two)"
  if [ "$(printf '%s\n' "${tbl}" | wc -l)" -eq 4 ] &&
    [ "$(printf '%s\n' "${tbl}" | grep -c '^| S')" -eq 2 ]; then
    printf 'census table row-join ok (rows are lines, not one concatenated line)\n'
  else
    harness_fail_msg "the census table row-join collapsed rows onto one line"
    rc=1
  fi

  # Every encode pipeline this script sends must take the bitrate property from
  # detection, never a literal: the two boards name it differently and a literal
  # builds an invalid pipeline that measures nothing.
  local litbits
  litbits=$(printf '%s\n' "$(census_shapes bps)" "$(hevc_600_payload '' bps)" |
    grep -c 'rc-mode=cbr bitrate=' || true)
  [ "${litbits}" -eq 0 ] || {
    harness_fail_msg "${litbits} encode pipeline(s) still hard-code the bitrate property name"
    rc=1
  }
  printf 'encoder bitrate property is detected, not literal ok\n'

  # --- 2. the document composer ------------------------------------------
  doc="${work}/baseline-selftest.md"
  {
    doc_header selftest-board 192.0.2.1 $'hostname=selftest\nkernel=7.2.0-ceralive-rk3588'
    emit_measurement a "Decode truth (A1)" \
      "PARTIAL — factory registration recorded; no engine session was live" \
      "gst-inspect-1.0 mppvideodec" "${work}/a.txt" "factory=mppvideodec registered=no rc=1"
    emit_measurement b "Copy census (A11)" "RECORDED — boundaries below" \
      "fd-trace.sh --launch ..." "${work}/b.txt" "software_copy_lines=13497"
    emit_measurement c "H.265 / H.264 4K59.94 baseline (G4)" \
      "BLOCKED — no HDMI-RX signal is present" "gst-launch-1.0 ..." \
      "${work}/c.txt" "video2: Link has been severed"
    emit_measurement d "Dual-core concurrency baseline (A4)" \
      "SINGLE-CORE — rkvenc1 fired no interrupt during the window" \
      "sample-cores.sh --duration 60" "${work}/d.txt" \
      "irq=104 label=rkvenc1 total_delta=0 per_cpu=0,0,0,0,0,0,0,0 active_cpus=0"
    emit_measurement e "Encode-corruption oracle baseline (ENC-CORRUPT)" \
      "NOT-RUN — the oracle produced no per-codec verdict" \
      "encode-psnr-oracle.sh --codec both --runs 20" "${work}/e.txt" "encoder_absent=mpph264enc"
  } >"${doc}"

  local sections
  sections=$(grep -c '^### (' "${doc}")
  [ "${sections}" -eq 5 ] || {
    harness_fail_msg "the composed document has ${sections} measurement sections, expected 5"
    rc=1
  }
  local verdicts
  verdicts=$(grep -c '^\*\*VERDICT: ' "${doc}")
  [ "${verdicts}" -eq 5 ] || {
    harness_fail_msg "the composed document has ${verdicts} verdicts, expected 5"
    rc=1
  }
  grep -q '| board | `selftest-board` |' "${doc}" || {
    harness_fail_msg "the document does not carry the board identity"
    rc=1
  }
  grep -q '\*\*VERDICT: NOT-RUN' "${doc}" || {
    harness_fail_msg "an unrun leg did not render as NOT-RUN"
    rc=1
  }
  grep -q '\*\*VERDICT: BLOCKED' "${doc}" || {
    harness_fail_msg "a blocked leg did not render as BLOCKED"
    rc=1
  }
  # The honesty rule, asserted rather than trusted: nothing that did not run
  # may render with a passing word.
  if grep -E '^\*\*VERDICT: (NOT-RUN|BLOCKED)' "${doc}" | grep -qiE 'pass|clean'; then
    harness_fail_msg "an unrun or blocked leg rendered with a passing word"
    rc=1
  fi
  printf 'document sections=%s verdicts=%s honesty=ok\n' "${sections}" "${verdicts}"

  # --- 2b. the copy classifier must reach all four classes ----------------
  # A classifier that can only answer REQUIRED would make every census green
  # forever, which is the failure this harness's non-vacuity rule exists to stop.
  local got_class
  check_class() {
    local want=$1 desc=$2
    shift 2
    got_class="$(classify_boundary "$@")"
    got_class="${got_class%%|*}"
    if [ "${got_class}" = "${want}" ]; then
      printf 'classify %s=%s ok\n' "${desc}" "${got_class}"
    else
      harness_fail_msg "classify_boundary(${desc}) returned ${got_class}, expected ${want}"
      rc=1
    fi
  }
  check_class REQUIRED pool-stable no 0 0 0 0 0 absent
  check_class AVOIDABLE copy-at-mixed-boundary no 0 3 0 0 0 absent
  check_class BUG copy-between-two-mpp-clients yes 0 3 0 0 0 absent
  check_class TEMPORARY rga-blit-refused no 0 0 5 0 0 absent
  check_class TEMPORARY librga-entered-without-device no 0 0 0 2 0 absent
  check_class AVOIDABLE allocating-without-copy no 7 0 0 0 0 absent
  check_class BUG journal-frame-copy-between-mpp yes 0 0 0 0 4 absent

  # --- 2b2. a shape that could not run may never read as copy-free -------
  # The regression this locks: copy-census.sh emits `class=NO-COPY` even when
  # the pipeline failed to negotiate, so a graph that never moved a buffer was
  # being reported as clean. Nothing was observed, so the row must be
  # UNREACHABLE and must carry the reason.
  local failed_raw clean_raw got_row
  failed_raw='launch=filesrc ... ! mppvideodec ! fakesink
streaming stopped, reason not-negotiated (-4)
FAIL: the pipeline exited before it could be traced
census_row=shape=S4 boundary=whole-graph-window class=NO-COPY software_copies=0 new_inodes=0 fds_crossing=0 rga_blit_fail=0 rga_api_version=0 rga_chardev=absent source_memory=dmabuf frames=0 evidence=/tmp/x reason=no allocation and no software copy was observed in the window'
  got_row="$(census_row_for S4 yes dmabuf absent "${failed_raw}")"
  case "${got_row}" in
    *'class=UNREACHABLE'*'not-negotiated'*) printf 'census_row_for failed-shape=UNREACHABLE ok\n' ;;
    *)
      harness_fail_msg "a shape whose pipeline failed did not read UNREACHABLE: ${got_row}"
      rc=1
      ;;
  esac
  if printf '%s' "${got_row}" | grep -qE 'class=(NO-COPY|REQUIRED)'; then
    harness_fail_msg "a failed shape rendered with a copy-free class"
    rc=1
  fi

  clean_raw='census_row=shape=S1 boundary=whole-graph-window class=NO-COPY software_copies=0 new_inodes=0 fds_crossing=2 rga_blit_fail=0 rga_api_version=0 rga_chardev=absent source_memory=sysmem frames=180 evidence=/tmp/y reason=none'
  got_row="$(census_row_for S1 no sysmem absent "${clean_raw}")"
  case "${got_row}" in
    *'class=REQUIRED'*) printf 'census_row_for pool-stable=REQUIRED ok\n' ;;
    *)
      harness_fail_msg "a pool-stable shape did not translate to REQUIRED: ${got_row}"
      rc=1
      ;;
  esac

  # --- 2c. a leg that was not selected renders NOT-RUN --------------------
  local nr
  nr="$(not_run_section c)"
  if printf '%s\n' "${nr}" | grep -q '^\*\*VERDICT: NOT-RUN'; then
    printf 'not_run_section=ok\n'
  else
    harness_fail_msg "not_run_section did not render a NOT-RUN verdict"
    rc=1
  fi

  # --- 2b. compose-existing must PRESERVE recorded verdicts, never invent one.
  #         A board can vanish after measuring correctly; recomposing must not
  #         turn five real verdicts into five NOT-RUN sections, and equally must
  #         not turn an absent section into a pass.
  local cwork cdoc
  cwork="${work}/compose"
  mkdir -p "${cwork}"
  printf 'hostname=selftest-board\nkernel=7.2.0-ceralive-rk3588\n' >"${cwork}/identity.txt"
  emit_measurement a "Decode truth (A1)" \
    "ENGINE-CHAIN-BROKEN — 1 source kind(s) whose hardcoded engine element does not negotiate" \
    "decode-truth.sh --all" "/x/a.txt" "kind=rtmp frames=521" >"$(section_file "${cwork}" a)"
  emit_measurement b "Copy census (A11)" "COPY-FREE — 5 shape(s) measured" \
    "copy-census.sh" "/x/b.txt" "census_row=shape=S1" >"$(section_file "${cwork}" b)"
  emit_measurement c "H.265 / H.264 4K59.94 baseline (G4)" "BLOCKED-NO-SIGNAL" \
    "v4l2-ctl" "/x/c.txt" "640x480" >"$(section_file "${cwork}" c)"
  emit_measurement d "Dual-core concurrency baseline (A4)" \
    "DUAL-CORE — 2 of 2 rkvenc core IRQ lines advanced during the 60 s window" \
    "sample-cores.sh" "/x/d.txt" "fps tag=a mean=30.01" >"$(section_file "${cwork}" d)"
  emit_measurement e "Encode-corruption oracle baseline (ENC-CORRUPT)" \
    "DIRTY — at least one codec's PSNR distribution breached the floor" \
    "encode-psnr-oracle.sh" "/x/e.txt" "codec=h265 VERDICT=DIRTY" >"$(section_file "${cwork}" e)"

  if ( BOARD=selftest-board REPORT_DIR="${cwork}" DOC_DIR="${cwork}" HOST='' \
    compose_existing >/dev/null 2>&1 ); then
    printf 'compose-existing exit=0 ok\n'
  else
    harness_fail_msg "compose_existing failed on five complete sections"
    rc=1
  fi
  cdoc="${cwork}/baseline-selftest-board.md"
  [ "$(grep -c '^\*\*VERDICT: ' "${cdoc}")" -eq 5 ] || {
    harness_fail_msg "the recomposed document does not carry five verdicts"
    rc=1
  }
  local v
  for v in 'ENGINE-CHAIN-BROKEN' 'COPY-FREE' 'BLOCKED-NO-SIGNAL' 'DUAL-CORE' 'DIRTY'; do
    grep -q "\*\*VERDICT: ${v}" "${cdoc}" || {
      harness_fail_msg "recomposition lost the recorded verdict ${v}"
      rc=1
    }
  done
  grep -q 'measured nothing' "${cdoc}" || {
    harness_fail_msg "the recomposed document does not say it took no measurement"
    rc=1
  }
  grep -q 'RECOMPOSED' "${cdoc}" || {
    harness_fail_msg "the recomposed document does not declare its mode"
    rc=1
  }
  # An absent section may not become a pass.
  rm -f "$(section_file "${cwork}" d)"
  ( BOARD=selftest-board REPORT_DIR="${cwork}" DOC_DIR="${cwork}" HOST='' \
    compose_existing >/dev/null 2>&1 ) || true
  grep -q '\*\*VERDICT: NOT-RUN' "${cdoc}" || {
    harness_fail_msg "a missing section did not recompose as NOT-RUN"
    rc=1
  }
  if grep -E '^\*\*VERDICT: (NOT-RUN|BLOCKED)' "${cdoc}" | grep -qiE 'pass|clean'; then
    harness_fail_msg "recomposition rendered an unrun leg with a passing word"
    rc=1
  fi
  # It must refuse to work without a report directory rather than invent one.
  if ( BOARD=selftest-board REPORT_DIR='' DOC_DIR="${cwork}" compose_existing >/dev/null 2>&1 ); then
    harness_fail_msg "compose_existing accepted an empty --report-dir"
    rc=1
  fi
  printf 'compose-existing preserves recorded verdicts, marks its mode, keeps NOT-RUN honest ok\n'

  # --- 2c. the table-rendering repair: lossless or nothing.
  local rfile
  rfile="${work}/collapsed.md"
  {
    printf '| shape | n | class |\n'
    printf '|---|---|---|| S1 | 13 | REQUIRED || S2 | 17 | REQUIRED |\n'
  } >"${rfile}"
  repair_collapsed_tables "${rfile}" >/dev/null 2>&1
  if [ "$(grep -c '^| S' "${rfile}")" -eq 2 ] &&
    [ "$(grep -c '^|---|---|---|$' "${rfile}")" -eq 1 ]; then
    printf 'table repair recovered collapsed rows ok\n'
  else
    harness_fail_msg "the table repair did not recover the collapsed rows"
    rc=1
  fi
  # Content preservation is the whole licence for this repair.
  [ "$(tr -d '\n' <"${rfile}")" = '| shape | n | class ||---|---|---|| S1 | 13 | REQUIRED || S2 | 17 | REQUIRED |' ] || {
    harness_fail_msg "the table repair altered content"
    rc=1
  }
  # A well-formed document must come out byte-identical.
  local wfile before
  wfile="${work}/wellformed.md"
  printf '| a | b |\n|---|---|\n| 1 | 2 |\n' >"${wfile}"
  before="$(md5sum <"${wfile}")"
  repair_collapsed_tables "${wfile}" >/dev/null 2>&1
  [ "$(md5sum <"${wfile}")" = "${before}" ] || {
    harness_fail_msg "the table repair modified an already well-formed document"
    rc=1
  }
  # A table row inside a code fence is transcript text, not markdown, and must
  # never be reflowed.
  local ffile
  ffile="${work}/fenced.md"
  printf 'text\n```\n|---|---|| not | a | table |\n```\n' >"${ffile}"
  before="$(md5sum <"${ffile}")"
  repair_collapsed_tables "${ffile}" >/dev/null 2>&1
  [ "$(md5sum <"${ffile}")" = "${before}" ] || {
    harness_fail_msg "the table repair reflowed content inside a code fence"
    rc=1
  }
  printf 'table repair is lossless, fence-safe and idempotent ok\n'

  # --- 2d. trailing-whitespace sanitation must be invisible to meaning.
  local wsfile
  wsfile="${work}/ws.md"
  printf '| a | b |   \n|---|---|\t\n\tStandards: \n\tFlags: \n  indented keeps its indent  \n' >"${wsfile}"
  # The detector must be shown to FIRE on the dirty fixture before it is trusted
  # to stay silent on the clean one. It previously read `[ \t]+$`, and in an ERE
  # bracket expression `\t` is the literal `\` and `t` -- never a tab -- so it
  # matched any line ending in `t` ("...indent") and could never pass. The class
  # must be the sanitiser's own `[[:space:]]`.
  grep -qE '[[:space:]]+$' "${wsfile}" || {
    harness_fail_msg "the trailing-whitespace fixture carries none, so the detector proves nothing"
    rc=1
  }
  strip_trailing_hspace "${wsfile}"
  if grep -qE '[[:space:]]+$' "${wsfile}"; then
    harness_fail_msg "trailing whitespace survived the sanitiser"
    rc=1
  fi
  # Same number of lines, same order, same non-whitespace content, and LEADING
  # indentation untouched -- a transcript that means something by its indent
  # must not be reflowed.
  [ "$(wc -l <"${wsfile}")" -eq 5 ] || {
    harness_fail_msg "the sanitiser changed the line count"
    rc=1
  }
  grep -q '^	Standards:$' "${wsfile}" || {
    harness_fail_msg "the sanitiser altered a transcript line beyond its trailing space"
    rc=1
  }
  grep -q '^  indented keeps its indent$' "${wsfile}" || {
    harness_fail_msg "the sanitiser ate leading indentation"
    rc=1
  }
  printf 'trailing-whitespace sanitation preserves lines, order and indent ok\n'

  # --- 2e. legacy (d) normalization: an IRQ-only DUAL-CORE headline whose own
  #         transcript shows no fps samples must be restated, not trusted.
  local dfile dout
  dfile="${work}/legacy-d.md"
  {
    printf '\n### (d) Dual-core concurrency baseline (A4)\n\n'
    printf '**VERDICT: DUAL-CORE — 2 of 2 rkvenc core IRQ lines advanced during the 60 s window**\n\n'
    printf '```\n--- window total (t=0 .. t=60s) ---\n'
    printf 'irq=113 label=fdbd0000.rkvenc-core total_delta=1802 per_cpu=1802,0 active_cpus=1\n'
    printf 'irq=114 label=fdbe0000.rkvenc-core total_delta=1802 per_cpu=1802,0 active_cpus=1\n'
    printf 'fps tag=a samples=0 status=no_tracer_lines\n'
    printf 'fps tag=b samples=0 status=no_tracer_lines\n'
    printf 'VERDICT: FAIL (a requested fps log produced no tracer lines)\n```\n'
  } >"${dfile}"
  dout="$(normalize_recorded_section_d "${dfile}")"
  printf '%s\n' "${dout}" | grep -q '^\*\*VERDICT: PARTIAL-BLOCKED-FPS — 2 of 2' || {
    harness_fail_msg "the legacy (d) headline was not restated as PARTIAL-BLOCKED-FPS"
    rc=1
  }
  printf '%s\n' "${dout}" | grep -q 'BLOCKED-MISSING-TRACER' || {
    harness_fail_msg "the restated headline does not name the fps blocker"
    rc=1
  }
  printf '%s\n' "${dout}" | grep -q '^\*\*VERDICT: DUAL-CORE' && {
    harness_fail_msg "the overclaiming DUAL-CORE headline survived normalization"
    rc=1
  }
  # The transcript underneath is evidence and must survive byte-for-byte.
  local v
  for v in 'total_delta=1802' 'fps tag=a samples=0 status=no_tracer_lines' \
    'VERDICT: FAIL (a requested fps log produced no tracer lines)'; do
    printf '%s\n' "${dout}" | grep -qF "${v}" || {
      harness_fail_msg "normalization dropped transcript evidence: ${v}"
      rc=1
    }
  done
  # A (d) section that DID measure fps must pass through untouched.
  local dok dokout
  dok="${work}/good-d.md"
  {
    printf '**VERDICT: DUAL-CORE — 2 of 2 rkvenc core IRQ lines advanced during the 60 s window**\n\n'
    printf '```\nfps tag=a frames=1805 elapsed_s=60.14 mean=30.01 source=identity-chain-count\n```\n'
  } >"${dok}"
  dokout="$(normalize_recorded_section_d "${dok}")"
  [ "$(printf '%s\n' "${dokout}" | md5sum)" = "$(md5sum <"${dok}")" ] || {
    harness_fail_msg "a (d) section with real fps was altered by normalization"
    rc=1
  }
  printf 'legacy (d) normalization restates only the unevidenced headline ok\n'

  # --- 3. the bug-reality row --------------------------------------------
  ledger="${work}/bug-reality.md"
  bug_reality_header >"${ledger}"
  bug_reality_row rock-5b-plus h265 CLEAN \
    "encode-psnr-oracle.sh --codec h265 --runs 20" \
    "fixture_sha256_ok=3b2ee7f6 testsrc2-640x360-30fps-60f.nv12" \
    "44.10,44.08,44.12" "/tmp/report" >>"${ledger}"
  bug_reality_row rock-5b-plus h264 NOT-RUN \
    "encode-psnr-oracle.sh --codec h264 --runs 20" \
    "NOT ASSERTED" "none recorded" "/tmp/report" >>"${ledger}"

  local cols
  cols=$(awk -F'|' '/^\| ENC-CORRUPT \|/ {print NF - 2; exit}' "${ledger}")
  [ "${cols}" -eq 9 ] || {
    harness_fail_msg "a bug-reality row has ${cols} columns, expected 9"
    rc=1
  }
  grep -q 'ENC-CORRUPT | rock-5b-plus | h265 | CLEAN | shipped image' "${ledger}" || {
    harness_fail_msg "the CLEAN bug-reality row is malformed"
    rc=1
  }
  grep -q 'NOT ASSERTED' "${ledger}" || {
    harness_fail_msg "a row with no fixture assertion did not say so"
    rc=1
  }
  printf 'bug_reality columns=%s ok\n' "${cols}"

  # --- 4. argument validation --------------------------------------------
  if ( BOARD='' HOST=192.0.2.1 load_credentials >/dev/null 2>&1 ); then
    harness_fail_msg "load_credentials accepted an empty --board"
    rc=1
  else
    printf 'usage board-required=ok\n'
  fi
  if ( BOARD=x HOST='' load_credentials >/dev/null 2>&1 ); then
    harness_fail_msg "load_credentials accepted an empty --host"
    rc=1
  else
    printf 'usage host-required=ok\n'
  fi

  [ "${rc}" -eq 0 ] || {
    harness_verdict FAIL "self-test"
    return $?
  }
  harness_verdict PASS "self-test: screen enforced, document complete, unrun legs honest"
}

usage() {
  sed -n '2,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --self-test)
        self_test
        exit $?
        ;;
      --connect-check)
        CONNECT_CHECK=1
        shift
        ;;
      --compose-existing)
        COMPOSE_EXISTING=1
        shift
        ;;
      --board)
        BOARD=${2:-}
        shift 2
        ;;
      --host)
        HOST=${2:-}
        shift 2
        ;;
      --user)
        USER_NAME=${2:-}
        shift 2
        ;;
      --pass-file)
        PASS_FILE=${2:-}
        shift 2
        ;;
      --measure)
        MEASURE=${2:-}
        shift 2
        ;;
      --runs)
        ORACLE_RUNS=${2:-}
        shift 2
        ;;
      --doc-dir)
        DOC_DIR=${2:-}
        shift 2
        ;;
      --ledger-dir)
        LEDGER_DIR=${2:-}
        shift 2
        ;;
      --report-dir)
        REPORT_DIR=${2:-}
        shift 2
        ;;
      -h | --help)
        usage
        exit "${HARNESS_USAGE}"
        ;;
      *)
        harness_fail_msg "unknown argument: $1"
        usage
        exit "${HARNESS_USAGE}"
        ;;
    esac
  done

  if [ "${COMPOSE_EXISTING}" -eq 1 ]; then
    compose_existing
    exit $?
  fi
  if [ "${CONNECT_CHECK}" -eq 1 ]; then
    connect_check
    exit $?
  fi
  full_run
  exit $?
}

main "$@"
