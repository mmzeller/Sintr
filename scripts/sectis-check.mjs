// Checks Sintr's Sectis format against Sectis's own code (copied from its sync module,
// source/src/js/11-sync.js): join codes, the space, the PBKDF2 key and AES-GCM records.
//
//   node scripts/sectis-check.mjs make   <fixture.json>              (Sectis encrypts → Sintr reads)
//   node scripts/sectis-check.mjs verify <fixture.json> <sintr.json> (Sintr encrypts → Sectis reads)
//   node scripts/sectis-check.mjs listen <fixture.json> <sintr.json> (inside the Firestore emulator:
//        reads what Sintr wrote with the Firebase SDK and the same query Sectis's sync uses)
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

// ---- From Sectis (unchanged) ----
const utf8 = (s) => new TextEncoder().encode(s);
function b64(bytes) { let s = ''; const a = new Uint8Array(bytes); for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode.apply(null, a.subarray(i, i + 0x8000)); return btoa(s); }
function unb64(str) { const s = atob(str); const a = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; }
async function sha256hex(s) { const h = await crypto.subtle.digest('SHA-256', utf8(s)); return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, '0')).join(''); }
function newSyncKey() {
  const bytes = crypto.getRandomValues(new Uint8Array(26)), A = 'abcdefghijkmnpqrstuvwxyz23456789';
  return Array.from(bytes, (b) => A[b % 32]).join('');
}
function makeJoinCode(cfg, key) {
  const json = JSON.stringify({ c: cfg, k: key });
  return 'SECTIS-' + btoa(unescape(encodeURIComponent(json))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function deriveSpaceAndKey(key) {
  const space = (await sha256hex('sectis-space|' + key)).slice(0, 40);
  const material = await crypto.subtle.importKey('raw', utf8(key), 'PBKDF2', false, ['deriveKey']);
  const aes = await crypto.subtle.deriveKey({ name: 'PBKDF2', salt: utf8('sectis-sync-v1|' + space), iterations: 150000, hash: 'SHA-256' }, material, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  return { space, aes };
}
async function encryptRec(aes, rec) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, aes, utf8(JSON.stringify(rec)));
  return { c: b64(ct), iv: b64(iv) };
}
async function decryptRec(aes, doc) {
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(doc.iv) }, aes, unb64(doc.c));
  return JSON.parse(new TextDecoder().decode(pt));
}
function newTodoShape() {
  return { id: '', type: 'todo', title: '', notes: '', status: 'open', start: 'inbox', when: null, evening: false, deadline: null, reminder: null,
    projectId: null, areaId: null, headingId: null, tags: [], checklist: [], order: 0, todayOrder: 0, createdAt: 0, modifiedAt: 0,
    completedAt: null, logged: false, trashed: false, isTemplate: false, repeat: null, next: null, templateId: null, sample: false, linkId: null };
}
function isInbox(t) { return t.start === 'inbox' && !t.projectId && !t.areaId; }
function isWaiting(t) { return !!(t && t.type === 'todo' && t.waitFor && t.status === 'open' && !t.trashed && !t.isTemplate); }
// (from Sectis's notes formatting: what makes a link in a to-do's notes)
const MD_LINK = /\[([^\]\n]+)\]\(([^)\s]+)\)/g;
// ---- end of Sectis code ----

function fail(message) { console.error('✗ ' + message); process.exit(1); }
function check(condition, message) { if (!condition) fail(message); console.log('✓ ' + message); }

const [mode, fixturePath, sintrPath] = process.argv.slice(2);

if (mode === 'make') {
  // '~~~' and '???' in the config come out as '+' and '/' in Base64, so the code uses both
  // URL-safe characters ('-' and '_') and Sintr has to map them back.
  const cfg = { apiKey: 'AIzaSyDtestKey0123456789abcdefghijklm', projectId: 'demo-sectis', appId: '1:2:web:~~~???', authDomain: 'budget-ledger-test.firebaseapp.com' };
  const key = newSyncKey();
  const joinCode = makeJoinCode(cfg, key);
  if (!/[-]/.test(joinCode.slice(7)) || !/_/.test(joinCode.slice(7))) fail('test join code should contain - and _');
  const { space, aes } = await deriveSpaceAndKey(key);
  const tag = { id: 'tag123', title: 'Meeting Ü ✓', parentId: null, order: 3 };
  const sealed = await encryptRec(aes, tag);
  // Users paste codes with line breaks; Sintr should cope.
  const wrapped = joinCode.slice(0, 30) + '\n  ' + joinCode.slice(30);
  writeFileSync(fixturePath, JSON.stringify({ joinCode: wrapped, apiKey: cfg.apiKey, projectId: cfg.projectId, key, space, tag, tagC: sealed.c, tagIv: sealed.iv }, null, 2));
  console.log('Made a Sectis fixture: space ' + space);
} else if (mode === 'verify') {
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
  const sintr = JSON.parse(readFileSync(sintrPath, 'utf8'));
  const { space, aes } = await deriveSpaceAndKey(fixture.key);
  check(sintr.space === space, 'Sintr finds the same space as Sectis');
  let rec;
  try { rec = await decryptRec(aes, { c: sintr.c, iv: sintr.iv }); } catch (e) { fail('Sectis could not decrypt the to-do Sintr encrypted: ' + e); }
  check(true, 'Sectis decrypts the to-do Sintr encrypted');
  const expected = sintr.expected;
  check(rec.title === expected.title, `title survives: ${rec.title}`);
  check(rec.notes === expected.notes, 'notes survive (with line breaks and quotes)');
  check(rec.id === expected.id && /^sn[0-9a-f]{12}$/.test(rec.id), 'id is the stable Sintr id');
  check(rec.deadline === expected.deadline, 'deadline is a YYYY-MM-DD string');
  check(Array.isArray(rec.tags) && rec.tags[0] === 'tag123', 'tag id is kept');
  check(rec.start === 'inbox' && rec.status === 'open' && rec.type === 'todo' && isInbox(rec), 'it is an open Inbox to-do');
  const shapeKeys = Object.keys(newTodoShape()).sort().join(',');
  check(Object.keys(rec).sort().join(',') === shapeKeys, 'it has exactly the fields of a Sectis to-do');
  for (const k of ['when', 'reminder', 'projectId', 'areaId', 'headingId', 'completedAt', 'repeat', 'next', 'templateId']) {
    if (rec[k] !== null) fail(`${k} should be null`);
  }
  for (const k of ['evening', 'logged', 'trashed', 'isTemplate', 'sample']) if (rec[k] !== false) fail(`${k} should be false`);
  check(typeof rec.order === 'number' && typeof rec.createdAt === 'number' && Number.isInteger(rec.createdAt), 'numbers are numbers');
  check(Array.isArray(rec.checklist) && rec.checklist.length === 0, 'checklist is an empty list');
  // Sectis's rules: only these keys, and c must be a string under 500,000 characters.
  check(typeof sintr.c === 'string' && sintr.c.length < 500000, 'fits the Firestore rule size limit');

  // Someone else's item: waiting on Dana, in a project, with a checklist and a link back.
  let w;
  try { w = await decryptRec(aes, sintr.waiting); } catch (e) { fail('Sectis could not decrypt the waiting to-do: ' + e); }
  check(w.id === sintr.waiting.id, 'the waiting to-do has its stable id');
  check(isWaiting(w) && w.waitFor === 'Dana' && w.waitSince === '2026-10-22', 'Sectis files it under Waiting For: waiting on Dana since Oct 22');
  check(w.when === '2026-10-30' && w.start === 'anytime' && w.deadline === null, 'its follow-up date is its When date (back in Today then), with no deadline of yours');
  check(w.projectId === 'proj123' && w.areaId === null && w.headingId === null && !isInbox(w), 'it is in the project, not the Inbox');
  check(w.tags.join() === 'tag123,ptag', 'it has the Meeting tag and the project\'s tags');
  check(Array.isArray(w.checklist) && w.checklist.length === 2 && w.checklist.every((c) => typeof c.id === 'string' && c.id && c.done === false)
    && w.checklist.map((c) => c.title).join('|') === 'With the new rates|Copy finance', 'its sub-points are a checklist Sectis can tick');
  check(new Set(w.checklist.map((c) => c.id)).size === 2, 'checklist items have their own ids');
  const links = [...w.notes.matchAll(MD_LINK)].map((m) => m[2]);
  check(links.length === 1 && links[0] === 'sintr://note/B1A2C3D4-0000-4000-8000-000000000001', 'its notes link back to the Sintr note in a way Sectis shows as a link');
  const waitKeys = Object.keys(newTodoShape()).concat(['waitFor', 'waitSince']).sort().join(',');
  check(Object.keys(w).sort().join(',') === waitKeys, 'it has exactly the fields of a Sectis to-do, plus waitFor and waitSince');

  let a;
  try { a = await decryptRec(aes, sintr.area); } catch (e) { fail('Sectis could not decrypt the area to-do: ' + e); }
  check(a.areaId === 'area9' && a.projectId === null && a.start === 'anytime' && !isInbox(a) && !isWaiting(a), 'a to-do for an area is in that area');
  check(Object.keys(a).sort().join(',') === shapeKeys, '…with exactly the fields of a Sectis to-do');
} else if (mode === 'listen') {
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
  const cloud = JSON.parse(readFileSync(sintrPath, 'utf8')).cloud;
  if (!cloud) fail('the Swift self-test wrote nothing to the emulator');
  // The same Firebase library and version Sectis loads (compat build, 10.14.1).
  const require = createRequire(join(process.env.SECTIS_NODE_MODULES, 'noop.js'));
  const firebase = require('firebase/compat/app').default;
  require('firebase/compat/firestore');
  const app = firebase.initializeApp({ apiKey: fixture.apiKey, projectId: fixture.projectId }, 'sectis');
  const db = app.firestore();
  const [host, port] = process.env.FIRESTORE_EMULATOR_HOST.split(':');
  db.useEmulator(host, Number(port));
  const { space, aes } = await deriveSpaceAndKey(fixture.key);
  const col = db.collection('sectis').doc(space).collection('items');

  // Sectis's syncListen(): everything after its cursor, in server-time order.
  const since = new firebase.firestore.Timestamp(0, 0);
  const docs = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Sectis\'s query saw nothing within 30 s')), 30000);
    const unsub = col.where('t', '>', since).orderBy('t').onSnapshot((snap) => {
      const list = snap.docChanges().filter((c) => c.type !== 'removed' && !c.doc.metadata.hasPendingWrites).map((c) => Object.assign({ id: c.doc.id }, c.doc.data()));
      if (!list.length) return;
      clearTimeout(timer); unsub(); resolve(list);
    }, (err) => { clearTimeout(timer); reject(err); });
  }).catch((e) => fail(String(e)));

  check(docs.length === 1 + cloud.ids.length + 3, `Sectis's sync query sees the tag, ${cloud.ids.length} to-dos, a project, an area and a waiting to-do`);
  const SYNC_KINDS = { todo: 'todos', project: 'projects', heading: 'headings', area: 'areas', tag: 'tags' };
  for (const d of docs) {
    if (!(d.t && typeof d.t.seconds === 'number')) fail(`${d.id}: t should be a server timestamp`);
    if (typeof d.m !== 'number') fail(`${d.id}: m should be a number`);
    if (!SYNC_KINDS[d.k] || d.d !== false) fail(`${d.id}: k/d not as Sectis expects`);
    if (Object.keys(d).filter((k) => k !== 'id').sort().join(',') !== 'c,d,iv,k,m,t') fail(`${d.id}: unexpected fields`);
  }
  check(true, 'every document has t (server time), a numeric m, and only the fields Sectis\'s rules allow');
  const records = {};
  for (const d of docs) records[d.id] = { k: d.k, rec: await decryptRec(aes, d) };
  check(records[cloud.tagID]?.k === 'tag' && records[cloud.tagID].rec.title === 'Meeting', 'Sectis decrypts the Meeting tag');
  cloud.ids.forEach((id, i) => {
    const r = records[id];
    check(r && r.k === 'todo' && r.rec.title === cloud.titles[i] && r.rec.id === id, `Sectis decrypts “${cloud.titles[i]}”`);
    check(r.rec.tags.length === 1 && r.rec.tags[0] === cloud.tagID, '…tagged Meeting');
    check(r.rec.start === 'inbox' && r.rec.status === 'open', '…as an open Inbox to-do');
  });
  check(records[cloud.ids[0]].rec.deadline === '2026-10-23', 'deadline arrives');
  const waiting = records[cloud.waitingID];
  check(waiting && waiting.k === 'todo' && isWaiting(waiting.rec) && waiting.rec.waitFor === 'Dana', 'Sectis decrypts the to-do waiting on Dana');
  check(waiting.rec.projectId === cloud.projectID && records[cloud.projectID]?.k === 'project', '…in the project Sintr read from Sectis');
  check(waiting.rec.tags.includes(cloud.tagID) && waiting.rec.tags.includes('ptag') && waiting.rec.tags.includes('atag'), '…with the Meeting tag and the project\'s and area\'s tags');
  check(waiting.rec.checklist.length === 1 && waiting.rec.checklist[0].title === 'With the new rates', '…and its checklist');
  await app.delete();
  process.exit(0);
} else {
  fail('usage: sectis-check.mjs make|verify|listen …');
}
