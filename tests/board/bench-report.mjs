// SPDX-License-Identifier: GPL-2.0-only
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import assert from 'node:assert/strict';

function metrics(text) {
  return [...text.matchAll(/^METRIC (.+)$/gm)].map(match => Object.fromEntries(
    match[1].split(' ').map(pair => {
      const [key, value] = pair.split('=');
      return [key, Number(value)];
    })
  ));
}

function score(source, cell, result, streams, rate) {
  const s = metrics(source), m = metrics(cell);
  if (result !== 'source_rc=0 cell_rc=0' || !/^RESULT ok=1 /m.test(source) ||
      !/^RESULT ok=1 /m.test(cell) || s.length !== streams || m.length !== streams)
    return 'FAIL';
  if (m.some((row, index) => row.branch !== index || !Number.isFinite(row.fps) ||
      row.fps <= 0 || row.output !== row.sent || row.seconds <= 0 ||
      s[index]?.branch !== index || s[index].output !== s[index].sent ||
      !Number.isFinite(s[index]?.fps) || s[index].fps <= 0)) return 'FAIL';
  if (m.some((row, index) => s[index].fps < 1.2 * Math.max(rate, row.fps)))
    return 'SOURCE-LIMITED';
  if (rate && m.some(row => row.fps < rate * 0.99)) return 'RATE-MISS';
  return rate ? 'RATE-HELD' : 'MEASURED-THROUGHPUT';
}

function telemetry(before, after) {
  const counters = text => Object.fromEntries([...text.matchAll(/^(\/sys\/kernel\/debug\/rockchip-(?:mpp|rga)\/cores\/\d+\/(?:busy_ns|tasks|errors|resets))=(\d+)$/gm)].map(r => [r[1], Number(r[2])]));
  const a = counters(before), b = counters(after);
  const seconds = Number(after.match(/^UPTIME (\S+)/m)?.[1]) - Number(before.match(/^UPTIME (\S+)/m)?.[1]);
  const deltas = Object.fromEntries(Object.keys(a).map(key => [key, key in b ? b[key] - a[key] : null]));
  const cores = [...new Set(Object.keys(a).map(key => key.slice(0, key.lastIndexOf('/'))))];
  const complete = Number.isFinite(seconds) && seconds > 0 &&
    cores.filter(key => key.includes('rockchip-mpp')).length >= 2 &&
    cores.filter(key => key.includes('rockchip-rga')).length === 3 &&
    cores.every(core => ['busy_ns', 'tasks', 'errors', 'resets'].every(name =>
      Number.isSafeInteger(deltas[`${core}/${name}`]) && deltas[`${core}/${name}`] >= 0));
  return { seconds, deltas, complete };
}

function faultVerdict(deltas, journal) {
  if (Object.entries(deltas).some(([key, value]) => key.endsWith('/errors') && value > 0)) return 'COUNTER-ERROR';
  if (/Failed to map attachment|swiotlb buffer is full|BUG:|Oops:|Kernel panic|Call trace:|WARNING:|SError/.test(journal)) return 'JOURNAL-ERROR';
  return null;
}

function windowJournal(journal, before, after) {
  const start = Number(before.match(/^UPTIME (\S+)/m)?.[1]);
  const end = Number(after.match(/^UPTIME (\S+)/m)?.[1]);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) throw new Error('invalid journal window');
  return journal.split('\n').filter(line => {
    if (!line.trim() || line === '-- No entries --') return false;
    const timestamp = line.match(/^\[\s*(\d+\.\d+)\]/);
    if (!timestamp) throw new Error('unparseable journal timestamp');
    const time = Number(timestamp[1]);
    return time >= start && time <= end + 0.01;
  }).join('\n');
}

function improvement(baseline, island, lowerIsBetter, explanation) {
  if (baseline === null) return null;
  if (!Number.isFinite(baseline) || baseline <= 0 || !Number.isFinite(island) || island < 0)
    throw new Error('invalid comparison denominator or measurement');
  const delta = (island / baseline - 1) * (lowerIsBetter ? -100 : 100);
  if (delta < -3 && (!explanation || explanation.trim().split(/\s+/).length < 8))
    throw new Error('unexplained regression');
  return delta;
}

function quantile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.ceil(sorted.length * fraction) - 1];
}

function jitter(text, branch) {
  const times = [...text.matchAll(/^AU,(\d+),(\d+),\d+$/gm)]
    .filter(row => Number(row[1]) === branch).map(row => Number(row[2]));
  if (times.length < 3) throw new Error('missing AU interval samples');
  const intervals = times.slice(1).map((time, i) => (time - times[i]) / 1000);
  if (intervals.some(value => value < 0)) throw new Error('non-monotonic AU times');
  return quantile(intervals, 0.99) - quantile(intervals, 0.5);
}

function selfTest() {
  const log = fps => `METRIC branch=0 seconds=10 fps=${fps} sent=601 output=601\nRESULT ok=1 cpu_pct=10\n`;
  assert.equal(score(log(200), log(60), 'source_rc=0 cell_rc=0', 1, 60), 'RATE-HELD');
  assert.equal(score(log(60), log(59.9), 'source_rc=0 cell_rc=0', 1, 60), 'SOURCE-LIMITED');
  assert.equal(score(log(59.94), log(59.94), 'source_rc=0 cell_rc=0', 1, 60), 'SOURCE-LIMITED');
  assert.equal(score(log(59.94), log(29.97), 'source_rc=0 cell_rc=0', 1, 30), 'RATE-HELD');
  assert.equal(score(log(200), log(14.9), 'source_rc=0 cell_rc=0', 1, 60), 'RATE-MISS');
  assert.equal(score(log(200), log(60).replace('output=601', 'output=600'), 'source_rc=0 cell_rc=0', 1, 60), 'FAIL');
  assert.equal(score(log(200), log(60), 'source_rc=0 cell_rc=124', 1, 60), 'FAIL');
  assert.equal(score(log(200), '', 'source_rc=0 cell_rc=0', 1, 60), 'FAIL');
  assert.equal(score(log(200), log(60), 'source_rc=0 cell_rc=0', 2, 60), 'FAIL');
  assert.throws(() => improvement(100, 96, false, ''), /unexplained/);
  assert.throws(() => improvement(100, 104, true, ''), /unexplained/);
  assert.equal(improvement(null, 60, false, ''), null);
  assert.throws(() => improvement(0, 60, false, ''), /denominator/);
  assert.ok(improvement(100, 96, false, 'Accepted because the independently measured workload adds a required conversion stage.') < -3);
  assert.equal(jitter('AU,0,1000,0\nAU,0,2000,1\nAU,0,3000,2\nAU,0,7000,3\n', 0), 3);
  assert.throws(() => jitter('', 0), /missing/);
  const snapshot = (time, value) => `UPTIME ${time} 0\n` + ['mpp/cores/0', 'mpp/cores/1', 'rga/cores/0', 'rga/cores/1', 'rga/cores/2'].flatMap(core =>
    ['busy_ns', 'tasks', 'errors', 'resets'].map(name => `/sys/kernel/debug/rockchip-${core}/${name}=${value}\n`)).join('');
  assert.equal(telemetry(snapshot(1, 1), snapshot(2, 2)).complete, true);
  assert.equal(telemetry('', '').complete, false);
  assert.equal(telemetry(snapshot(1, 1), snapshot(1, 2)).complete, false);
  assert.equal(telemetry(snapshot(1, 2), snapshot(2, 1)).complete, false);
  assert.equal(telemetry(snapshot(1, 1), snapshot(2, 2).replace(/.+rockchip-rga\/cores\/2.+/g, '')).complete, false);
  assert.equal(faultVerdict({'/rga/cores/2/resets': 100}, '-- No entries --'), null);
  assert.equal(faultVerdict({'/rga/cores/2/errors': 1}, '-- No entries --'), 'COUNTER-ERROR');
  assert.equal(faultVerdict({}, 'rga: Failed to map attachment, ret[-5]'), 'JOURNAL-ERROR');
  assert.equal(windowJournal('[99.99] previous fault\n[100.50] current fault\n', 'UPTIME 100.00 0', 'UPTIME 101.00 0'), '[100.50] current fault');
  assert.throws(() => windowJournal('unknown clock', 'UPTIME 100 0', 'UPTIME 101 0'), /unparseable/);
  console.log('bench-report: scoring and complete/missing/reset telemetry assertions passed');
}

function report(directory) {
  const identity = readFileSync(join(directory, 'identity'), 'utf8');
  if (!/^[a-f0-9]{64}  .+\/bench-cell$/m.test(identity)) throw new Error('missing probe identity');
  const yaml = readFileSync(new URL('./bench-matrix.yaml', import.meta.url), 'utf8');
  const rows = [...yaml.matchAll(/^  - '([^']+)'$/gm)].map(row => row[1].split('|'));
  const results = [];
  for (const [id, mode, , , , , , rate, streams] of rows) {
    const path = join(directory, id);
    let result;
    try { result = readFileSync(join(path, 'result'), 'utf8').trim(); }
    catch { results.push({ id, verdict: 'NOT-RUN', baseline: null, delta: null }); continue; }
    if (mode === 'hdmi' && result === 'NO-SOURCE' && identity.includes('board=--run-rock')) {
      results.push({ id, verdict: 'NO-SOURCE', baseline: null, delta: null });
      continue;
    }
    if (mode === 'latency') {
      const verdict = result === 'NO-SOURCE' && identity.includes('board=--run-rock') ? 'NO-SOURCE' : 'PREREQUISITE-FAIL';
      results.push({ id, verdict, baseline: null, delta: null });
      continue;
    }
    if (mode === 'NO-SOURCE' || mode === 'EXCLUDED') {
      results.push({ id, verdict: result === mode ? mode : 'FAIL', baseline: null, delta: null });
      continue;
    }
    if (result === 'CANCELLED' || result.startsWith('FATAL-JOURNAL')) {
      results.push({ id, verdict: 'FAIL', reason: result, baseline: null, delta: null });
      continue;
    }
    let artifacts;
    try {
      artifacts = Object.fromEntries(['source.log', 'cell.log', 'before', 'after', 'samples', 'journal'].map(name => [name, readFileSync(join(path, name), 'utf8')]));
    } catch (error) {
      if (!['ENOENT', 'EACCES', 'EISDIR'].includes(error.code)) throw error;
      results.push({ id, verdict: 'FAIL', reason: 'missing-or-unreadable-artifact', baseline: null, delta: null });
      continue;
    }
    const source = artifacts['source.log'], cell = artifacts['cell.log'];
    const m = metrics(cell);
    const throughput_verdict = score(source, cell, result, Number(streams), Number(rate));
    const { seconds, deltas, complete } = telemetry(artifacts.before, artifacts.after);
    const sensor = artifacts.samples;
    const temps = [...sensor.matchAll(/^\/sys\/class\/thermal\/thermal_zone\d+\/temp=(\d+)$/gm)].map(r => Number(r[1]) / 1000);
    const intervals = m.map(row => { try { return jitter(cell, row.branch); } catch { return null; } });
    const cpu = Number(cell.match(/^RESULT ok=\d cpu_pct=(\S+)/m)?.[1]);
    const activeTasks = Object.entries(deltas).filter(([key]) => key.endsWith('/tasks') && key.includes(`rockchip-${mode === 'rga' ? 'rga' : 'mpp'}`)).reduce((sum, [, value]) => sum + (value ?? 0), 0);
    let journalWindow;
    try { journalWindow = windowJournal(artifacts.journal, artifacts.before, artifacts.after); }
    catch { journalWindow = null; }
    const fault = faultVerdict(deltas, journalWindow ?? '');
    const completeMetrics = complete && journalWindow !== null && temps.length > 0 && Number.isFinite(cpu) && cpu >= 0 && intervals.length === Number(streams) && intervals.every(value => value !== null);
    const verdict = throughput_verdict === 'FAIL' ? 'FAIL' : !completeMetrics ? 'TELEMETRY-GAP' : fault ?? (activeTasks === 0 ? 'NO-HARDWARE-TASKS' : throughput_verdict);
    results.push({ id, verdict, throughput_verdict, baseline: null, delta: improvement(null, m[0]?.fps, false, ''),
      source_fps: metrics(source).map(row => row.fps), fps: m.filter(row => row.seconds > 0 && row.output > 0).map(row => row.fps),
      jitter_ms: intervals,
      cpu_pct: cpu,
      peak_c: temps.length ? Math.max(...temps) : null, telemetry_seconds: seconds,
      core_deltas: deltas, complete_telemetry: completeMetrics,
      kernel_messages: artifacts.journal.trim(),
      workload_kernel_messages: journalWindow,
      files: readdirSync(path) });
  }
  console.log(JSON.stringify(results, null, 2));
  if (results.some(row => !['RATE-HELD', 'MEASURED-THROUGHPUT', 'NO-SOURCE', 'EXCLUDED'].includes(row.verdict))) process.exitCode = 1;
}

if (process.argv[2] === '--self-test') selfTest();
else if (process.argv.length === 3) report(process.argv[2]);
else { console.error('usage: bench-report.mjs --self-test | RESULT_DIRECTORY'); process.exitCode = 2; }
