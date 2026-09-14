// SPDX-License-Identifier: GPL-2.0-only
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { scoreLatency } from './bench-latency.mjs';

const scratch = new URL('./build-host/', import.meta.url).pathname;
mkdirSync(scratch, { recursive: true });

// Execute the real dispatch loop with command doubles, never board admission or I/O.
const harness = readFileSync(new URL('./bench-matrix.sh', import.meta.url), 'utf8');
const definitions = harness.slice(harness.indexOf('parse_cells()'), harness.indexOf('if [[ ${1:-} == --self-test'));
const loop = harness.slice(harness.indexOf("while IFS='|' read -r id mode"));
assert.ok(definitions.includes('prepare_cell()') && loop.includes('MATRIX_FINISHED'));
const id = 'hdmi-capture-au-latency-timeoverlay-host-decode';
function run(inspectRc, probeRc = 0, journalRc = 0, board = '--run-opi') {
  const out = mkdtempSync(join(scratch, 'bench-latency-test-'));
  try {
    const script = `set -uo pipefail
${definitions}
out=$1; inspect_rc=$2; probe_rc=$3; journal_rc=$4; board=$5
set -- "$board"
id=${id}; rows="$id|latency"; probe=mock-probe; failed=0; pid=
gst-inspect-1.0() { printf 'inspected:%s registry:%s\\n' "$*" "\${GST_REGISTRY_UPDATE:-unset}" >> "$out/calls"; return "$inspect_rc"; }
v4l2-ctl() { return 0; }
snapshot() { printf 'UPTIME 1 0\\n'; }
journalctl() { if [[ $* == *--show-cursor* ]]; then printf '%s\\n' '-- cursor: fixture'; else return "$journal_rc"; fi; }
timeout() { printf 'probe:%s\\n' "$*" >> "$out/calls"; return "$probe_rc"; }
${loop}`;
    const child = spawnSync('bash', ['-c', script, 'fixture', out, String(inspectRc), String(probeRc), String(journalRc), board], { encoding: 'utf8', timeout: 10000 });
    assert.ifError(child.error);
    return { status: child.status, result: readFileSync(join(out, id, 'result'), 'utf8').trim(),
      calls: board === '--run-rock' ? '' : readFileSync(join(out, 'calls'), 'utf8'), stdout: child.stdout };
  } finally { rmSync(out, { recursive: true, force: true }); }
}

const present = run(0);
assert.notEqual(present.result, 'PREREQUISITE-FAIL', 'registered timeoverlay must reach the latency collector, not PREREQUISITE-FAIL');
assert.equal(present.result, 'CAPTURED-PENDING-HOST-DECODE');
assert.equal(present.status, 0);
assert.match(present.calls, /inspected:timeoverlay/);
assert.match(present.calls, /registry:yes/);
assert.match(present.calls, /probe:.*mock-probe latency/);
const absent = run(255);
assert.match(absent.result, /^PREREQUISITE-FAIL reason=timeoverlay-unavailable inspect_rc=255$/);
assert.doesNotMatch(absent.calls, /probe:/);
assert.equal(absent.status, 1);
assert.match(run(127).result, /reason=gst-inspect-unavailable/);
assert.match(run(0, 124).result, /^FAIL reason=latency-capture cell_rc=124$/);
assert.match(run(0, 0, 1).result, /^FATAL-JOURNAL/);
assert.equal(run(0, 0, 0, '--run-rock').result, 'NO-SOURCE');
console.log('latency dispatch: present, absent, missing inspector, timeout, journal failure, Rock no-source passed');

const capture = Array.from({ length: 180 }, (_, i) => `CAPTURE,${1000000 + i * 20000},${BigInt(i) * 20000000n}`);
const aus = capture.map(line => line.replace('CAPTURE', 'AU').replace(/,(\d+),/, (_, us) => `,${Number(us) + 23000},`));
const log = [...capture, ...aus, 'RESULT rc=0'].join('\n');
const types = Array(180).fill('P');
const overlays = capture.map((_, i) => `0:00:${String(Math.floor(i / 50)).padStart(2, '0')}.${String(i % 50 * 20).padStart(3, '0')}`);
const good = scoreLatency(log, types, overlays);
assert.equal(good.whole_run.p50_ms, 23);
assert.equal(good.whole_run.p99_ms, 23);
assert.equal(good.after_two_seconds.count, 80);
assert.equal(good.overlay_matches, 180);
assert.match(good.method, /not sensor-to-display/);
assert.throws(() => scoreLatency(log.replace(`${capture[0]}\n`, ''), types, overlays), /180 capture/);
assert.throws(() => scoreLatency(log.replace(`${aus[0]}\n`, ''), types, overlays), /AU conservation/);
assert.throws(() => scoreLatency(`${capture[0]}\n${log}`, types, overlays), /180 capture/);
assert.throws(() => scoreLatency(log, [...types, 'P'], overlays), /frame conservation/);
assert.throws(() => scoreLatency(log.replace(capture[0], capture[1]).replace(aus[0], aus[1]), types, overlays), /unique PTS/);
assert.throws(() => scoreLatency(log.replace(aus[0], aus[1]), types, overlays), /PTS order/);
assert.throws(() => scoreLatency(log.replace('RESULT rc=0', 'RESULT rc=1'), types, overlays), /EOS/);
assert.throws(() => scoreLatency(log, types.slice(1), overlays), /frame conservation/);
assert.throws(() => scoreLatency(log, ['B', ...types.slice(1)], overlays), /B frames/);
assert.throws(() => scoreLatency(log, types, overlays.slice(1)), /all decoded overlays/);
assert.throws(() => scoreLatency(log, types, ['0:00:00.001', ...overlays.slice(1)]), /overlay mismatch/);
assert.throws(() => scoreLatency(log.replace(aus[0], 'AU,999999,0'), types, overlays), /negative latency/);
assert.throws(() => scoreLatency(log.replace(capture[0], 'CAPTURE,invalid,0'), types, overlays), /malformed/);

const reportDir = mkdtempSync(join(scratch, 'bench-latency-report-'));
try {
  writeFileSync(join(reportDir, 'identity'), `${'a'.repeat(64)}  /fixture/bench-cell\nboard=--run-opi\n`);
  mkdirSync(join(reportDir, id));
  for (const result of ['CAPTURED-PENDING-HOST-DECODE', 'FAIL reason=latency-capture cell_rc=124', 'CANCELLED', 'FATAL-JOURNAL']) {
    writeFileSync(join(reportDir, id, 'result'), result);
    const child = spawnSync('bun', [new URL('./bench-report.mjs', import.meta.url).pathname, reportDir], { encoding: 'utf8', timeout: 10000 });
    assert.ifError(child.error);
    const row = JSON.parse(child.stdout).find(row => row.id === id);
    assert.equal(row.verdict, 'FAIL', `host reporter must not turn ${result} into a prerequisite failure`);
  }
} finally { rmSync(reportDir, { recursive: true, force: true }); }
console.log('latency scoring: exact conservation, PTS, OCR, monotonic clocks, and host verdict mutations passed');

if (process.argv[2] === '--software-decode') {
  const directory = mkdtempSync(join(scratch, 'bench-latency-software-'));
  try {
    const cell = join(directory, id);
    mkdirSync(cell);
    const child = spawnSync(new URL('./build-host/test-bench-cell', import.meta.url).pathname,
      ['--latency-fixture', join(cell, 'capture.h264')], { encoding: 'utf8', timeout: 40000 });
    assert.ifError(child.error);
    assert.equal(child.status, 0, child.stderr);
    writeFileSync(join(cell, 'cell.log'), child.stdout);
    writeFileSync(join(cell, 'result'), 'CAPTURED-PENDING-HOST-DECODE\n');
    writeFileSync(join(cell, 'journal'), '-- No entries --\n');
    writeFileSync(join(directory, 'identity'), `${'a'.repeat(64)}  /fixture/bench-cell\nboard=--run-opi\n`);
    const snapshot = time => `UPTIME ${time} 0\n` + ['mpp/cores/0', 'mpp/cores/1', 'rga/cores/0', 'rga/cores/1', 'rga/cores/2'].flatMap(core =>
      ['busy_ns', 'tasks', 'errors', 'resets'].map(name => `/sys/kernel/debug/rockchip-${core}/${name}=0\n`)).join('');
    writeFileSync(join(cell, 'before'), snapshot(1));
    writeFileSync(join(cell, 'after'), snapshot(2));
    const report = spawnSync('bun', [new URL('./bench-report.mjs', import.meta.url).pathname, directory], { encoding: 'utf8', timeout: 120000 });
    assert.ifError(report.error);
    process.stderr.write(report.stderr);
    const result = JSON.parse(report.stdout).find(row => row.id === id);
    assert.equal(result.verdict, 'MEASURED-LATENCY', result.reason);
    assert.equal(result.latency.overlay_matches, 180);
    console.log('latency software pipeline: all 180 host-decoded burned-in timestamps verified (not hardware evidence)');
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
