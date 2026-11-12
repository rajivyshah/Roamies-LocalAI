// The diagnostics report: everything needed to work out a problem, nothing secret or personal. Run: npm test
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { activityLogs, buildReport, redact, reportName, scrubConfig, tail } from '../diagnostics.mjs';

const who = { home: '/Users/jane', user: 'jane' };
const r = (s) => redact(s, who);
assert.equal(r('key sk-ant-api03-AbCdEfGhIjKlMnOpQrSt here'), 'key <key> here');
assert.equal(r('sk-proj-abcdefghijklmnop1234'), '<key>');
assert.equal(r('xai-abcdefghijklmnopqrstu'), '<key>');
assert.equal(r('AIzaSyA1234567890abcdefghijklmnopqrs'), '<key>');
assert.equal(r('ghp_abcdefghijklmnopqrstuvwxyz'), '<key>');
assert.equal(r('Authorization: Bearer abc.def-ghi_jkl123'), 'Authorization: Bearer <token>');
assert.equal(r('eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4'), '<token>');
assert.equal(r('https://x.io/a?api_key=SECRET&b=1'), 'https://x.io/a?api_key=<redacted>&b=1');
assert.equal(r('{"accessToken":"abcdef123456"}'), '{"accessToken":"<redacted>"}');
assert.equal(r('mail jane.doe@example.com'), 'mail <email>');
assert.equal(r('/Users/jane/.gg/sidekick.log'), '~/.gg/sidekick.log', 'the home folder becomes ~');
assert.equal(r('user jane opened Janet'), 'user <user> opened Janet', 'the user name, not words that contain it');
assert.equal(r('no_input reason=busy'), 'no_input reason=busy', 'ordinary lines are left alone');
const win = { home: 'C:\\Users\\Jane', user: 'Jane' };
assert.equal(redact('C:\\Users\\Jane\\.gg and C:/Users/Jane/x and {"p":"C:\\\\Users\\\\Jane\\\\y"}', win), '~\\.gg and ~/x and {"p":"~\\\\y"}');
assert.equal(redact('c:\\users\\jane\\Downloads', win), '~\\Downloads', 'Windows paths in any case');

// Settings: secrets and names go, the rest (what's on, which model, the talk keys) stays.
const cfg = scrubConfig({ provider: 'anthropic', userName: 'Jane', fishKey: 'abc', keys: { talk: ['control', 'option'], summon: 'Control+Alt+KeyS' }, sound: true, fishKeySaved: true, email: '' });
assert.deepEqual(cfg, { provider: 'anthropic', userName: '<redacted>', fishKey: '<redacted>', keys: { talk: ['control', 'option'], summon: 'Control+Alt+KeyS' }, sound: true, fishKeySaved: true, email: '' });

// Long logs keep their newest lines, from a whole line.
const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'roamies-diag-'));
const big = path.join(dir, 'big.log');
await fs.writeFile(big, Array.from({ length: 2000 }, (_, i) => `line ${i}`).join('\n') + '\n');
const t = await tail(big, 1000);
assert.ok(t.startsWith('[… '), 'says older lines were left out');
assert.ok(t.trimEnd().endsWith('line 1999'));
assert.match(t.split('\n')[1], /^line \d+$/, 'starts on a whole line');
assert.ok(Buffer.byteLength(t) < 1100);
assert.equal(await tail(path.join(dir, 'missing.log'), 1000), '', 'a missing log is empty, not an error');
assert.equal(await tail(big, 1e9), await fs.readFile(big, 'utf8'), 'a short log comes whole');

// Activity logs: the newest days first get the space, shown oldest first; other files are skipped.
const logs = path.join(dir, 'logs');
await fs.mkdir(logs);
for (const d of ['2026-11-08', '2026-11-09', '2026-11-10']) await fs.writeFile(path.join(logs, `${d}.log`), `${d} event\n`.repeat(400));
await fs.writeFile(path.join(logs, 'notes.txt'), 'x');
const act = await activityLogs(logs, 12000);
assert.deepEqual(act.map(([title]) => title), ['Activity log 2026-11-09.log', 'Activity log 2026-11-10.log'], 'only what fits, newest kept');
assert.ok(act[1][1].startsWith('2026-11-10 event'), 'the newest day comes whole');

// The report: a header saying where to send it, each section, all of it scrubbed.
const report = buildReport({ now: new Date('2026-11-11T09:30:00Z'), version: '1.2.3', sections: [['System', { platform: 'win32' }], ['Voice helper log', '/Users/jane/x sk-ant-api03-AbCdEfGhIjKlMnOpQrSt'], ['Empty', '']] }, who);
assert.match(report, /^BitJarvis diagnostics\nMade 2026-11-11T09:30:00\.000Z by BitJarvis 1\.2\.3\./);
assert.match(report, /github\.com\/rajivyshah\/Roamies-LocalAI\/issues/);
assert.match(report, /-------- System -+\n\{\n {2}"platform": "win32"\n\}/);
assert.match(report, /-------- Voice helper log -+\n~\/x <key>\n/);
assert.match(report, /-------- Empty -+\n\(none\)/);
assert.ok(!report.includes('jane') && !report.includes('AbCdEf'));
assert.equal(reportName(new Date('2026-11-11T09:30:05Z')), 'roamies-diagnostics-2026-11-11-09-30-05.log');
await fs.rm(dir, { recursive: true, force: true });
console.log('diagnostics tests: passed');
