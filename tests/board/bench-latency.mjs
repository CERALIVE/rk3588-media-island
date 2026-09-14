// SPDX-License-Identifier: GPL-2.0-only
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, readdirSync, mkdtempSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

export function scoreLatency(log, types, overlays) {
  const rows = kind => log.split('\n').filter(line => line.startsWith(`${kind},`)).map(line => {
    const match = line.match(new RegExp(`^${kind},(\\d+),(\\d+)$`));
    assert.ok(match, `malformed ${kind} observation`);
    const us = Number(match[1]), pts = BigInt(match[2]);
    assert.ok(Number.isSafeInteger(us) && us >= 0 && pts < 18446744073709551615n, 'invalid clock or PTS');
    return { us, pts };
  });
  const capture = rows('CAPTURE'), aus = rows('AU');
  assert.equal(capture.length, 180, 'expected all 180 capture buffers');
  assert.equal(aus.length, capture.length, 'AU conservation');
  assert.deepEqual(aus.map(row => row.pts), capture.map(row => row.pts), 'AU PTS order');
  assert.equal(new Set(capture.map(row => row.pts)).size, capture.length, 'unique PTS');
  assert.equal(log.split('\n').filter(line => line.startsWith('RESULT ')).join(''), 'RESULT rc=0', 'successful EOS');
  assert.equal(types.length, capture.length, 'decoded frame conservation');
  assert.ok(types.every(type => /^[IP],?$/.test(type)), 'no reordered B frames');
  assert.equal(overlays.length, capture.length, 'all decoded overlays required');
  for (const [index, text] of overlays.entries()) {
    const match = text.trim().match(/^(\d+):([0-5]\d):([0-5]\d)\.(\d{3})$/);
    assert.ok(match, `timestamp missing or ambiguous in frame ${index + 1}`);
    const [, h, m, s, ms] = match;
    const displayed = ((BigInt(h) * 60n + BigInt(m)) * 60n + BigInt(s)) * 1000n + BigInt(ms);
    assert.equal(displayed, capture[index].pts / 1000000n, `overlay mismatch frame ${index + 1}`);
  }
  const samples = capture.map((row, index) => {
    assert.ok(index === 0 || (row.us >= capture[index - 1].us && aus[index].us >= aus[index - 1].us), 'non-monotonic observations');
    const latency_ms = (aus[index].us - row.us) / 1000;
    assert.ok(latency_ms >= 0, 'negative latency');
    return { us: row.us, pts: row.pts.toString(), latency_ms };
  });
  const summarize = rows => {
    if (!rows.length) return null;
    const values = rows.map(row => row.latency_ms).sort((a, b) => a - b);
    const percentile = p => values[Math.ceil(p * values.length) - 1];
    return { count: values.length, min_ms: values[0], p50_ms: percentile(.5), p99_ms: percentile(.99),
      max_ms: values.at(-1), mean_ms: values.reduce((a, b) => a + b, 0) / values.length };
  };
  return { method: 'capture-source-pad delivery to parsed AU, including overlay overhead; same-board monotonic; host decode verifies pixels only; not sensor-to-display latency',
    overlay_matches: overlays.length, whole_run: summarize(samples),
    after_two_seconds: summarize(samples.filter(row => row.us >= samples[0].us + 2000000)),
    capture_elapsed_s: (samples.at(-1).us - samples[0].us) / 1000000, samples };
}

export function measureLatency(directory) {
  const path = resolve(directory);
  const work = mkdtempSync(join(path, 'host-decode-'));
  function command(program, args, timeout = 120000) {
    const result = spawnSync(program, args, { encoding: 'utf8', timeout, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, OMP_THREAD_LIMIT: '1' } });
    writeFileSync(join(work, `${program}.log`), `${result.stderr ?? ''}\n${result.error?.message ?? ''}\nstatus=${result.status}\n`, { flag: 'a' });
    if (result.error?.code === 'ENOENT') throw new Error(`missing host prerequisite: ${program}`);
    assert.ifError(result.error);
    assert.equal(result.status, 0, `${program} failed; see ${work}`);
    return result.stdout;
  }
  for (const program of ['ffmpeg', 'ffprobe', 'tesseract']) {
    writeFileSync(join(work, `${program}-version.txt`), command(program, [program === 'tesseract' ? '--version' : '-version']));
  }
  const recording = join(path, 'capture.h264');
  const typeText = command('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pict_type', '-of', 'csv=p=0', recording]);
  writeFileSync(join(work, 'frame-types.txt'), typeText);
  command('ffmpeg', ['-v', 'error', '-xerror', '-hwaccel', 'none', '-threads', '2', '-i', recording,
    '-vf', 'crop=330:60:10:20', '-fps_mode', 'passthrough', join(work, 'roi-%03d.png')]);
  const frames = readdirSync(work).filter(name => /^roi-\d+\.png$/.test(name)).sort();
  assert.equal(frames.length, 180, 'host decode must conserve all 180 frames');
  const overlays = [];
  for (const [index, frame] of frames.entries()) {
    overlays.push(command('tesseract', [join(work, frame), 'stdout', '--psm', '7'], 10000).trim());
    writeFileSync(join(work, 'ocr.tsv'), overlays.map((text, i) => `${i + 1}\t${text}`).join('\n') + '\n');
    if ((index + 1) % 30 === 0) console.error(`latency host decode: ${index + 1}/180 timestamps read`);
  }
  const latency = scoreLatency(readFileSync(join(path, 'cell.log'), 'utf8'), typeText.trim().split('\n'), overlays);
  writeFileSync(join(work, 'latency.json'), JSON.stringify(latency, null, 2));
  return { ...latency, evidence_directory: work };
}
