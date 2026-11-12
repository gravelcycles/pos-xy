// Pos XY web viewer. Everything happens in this tab: files are decrypted here and kept in memory.
import { decodePoints, isLocked, FormatError } from './format.js';
import { ACTIVITY, ACTIVITY_ORDER, isDashed, clean, segments as segmentDay, totals, GAP_THRESHOLD } from './segmenter.js';

const $ = (id) => document.getElementById(id);
const ICON = { stationary: '📍', walking: '🚶', running: '🏃', cycling: '🚲', driving: '🚗', flying: '✈️', unknown: '❔' };

// ---------------------------------------------------------------- state
const state = {
  points: [],             // all loaded points, sorted, de-duplicated
  days: [],               // [{ key, date, count }] newest first
  dayCache: new Map(),
  loadedNames: new Set(),
  lastPassphrase: null,
  day: null,              // { key, points, segments }
  time: 0,                // unix seconds
  playing: false,
  speed: 300,
  follow: false,
};

// ---------------------------------------------------------------- formatting
const imperial = /-(US|LR|MM)\b/i.test(navigator.language);
function fmtDistance(m) {
  if (imperial) {
    const mi = m / 1609.344;
    return mi < 0.1 ? `${Math.round(m * 3.28084)} ft` : `${mi.toFixed(mi < 10 ? 1 : 0)} mi`;
  }
  return m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(m < 10000 ? 1 : 0)} km`;
}
function fmtDuration(s) {
  if (s < 60) return '<1 min';
  const h = Math.floor(s / 3600), m = Math.round((s % 3600) / 60);
  return h ? `${h} h ${m} min` : `${m} min`;
}
const fmtTime = (t, seconds = false) => new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', ...(seconds && { second: '2-digit' }) });
const dayKeyOf = (t) => { const d = new Date(t * 1000); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
const dateOfKey = (k) => { const [y, m, d] = k.split('-').map(Number); return new Date(y, m - 1, d); };
const fmtBytes = (n) => (n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : `${(n / 1048576).toFixed(1)} MB`);

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

// ---------------------------------------------------------------- map
const map = L.map('map', { preferCanvas: true, zoomControl: true, worldCopyJump: true }).setView([20, 0], 2);
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 19,
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
}).addTo(map);
map.attributionControl.setPrefix(false);
const trackLayer = L.layerGroup().addTo(map);
let marker = null;
let drawnCutoff = null;

function buildLegend() {
  const legend = $('legend');
  for (const t of ['walking', 'running', 'cycling', 'driving', 'flying', 'stationary']) {
    const s = el('span');
    const d = el('i', 'dot'); d.style.background = ACTIVITY[t].color;
    s.append(d, ACTIVITY[t].label);
    legend.append(s);
  }
}

function latlng(p) { return [p.lat, p.lon]; }

function drawTrack(cutoff) {
  if (!state.day || drawnCutoff === cutoff) return;
  drawnCutoff = cutoff;
  trackLayer.clearLayers();
  const { points: pts, segments: segs } = state.day;
  const line = (lo, hi, type, faded) => {
    if (hi <= lo) return;
    L.polyline(pts.slice(lo, hi + 1).map(latlng), {
      color: ACTIVITY[type].color, weight: faded ? 4 : 5, opacity: faded ? 0.45 : 0.95,
      dashArray: isDashed(type) ? '8 8' : null, lineCap: 'round', lineJoin: 'round', interactive: false,
    }).addTo(trackLayer);
  };
  if (!segs.length && pts.length > 1) line(0, pts.length - 1, 'unknown', false);
  for (const s of segs) {
    if (s.type === 'stationary') {
      const faded = s.first > cutoff;
      L.circle(latlng(pts[Math.floor((s.first + s.last) / 2)]), {
        radius: 35, color: ACTIVITY.stationary.color, weight: 2, opacity: faded ? 0.3 : 0.9,
        fillOpacity: faded ? 0.1 : 0.3, interactive: false,
      }).addTo(trackLayer);
      continue;
    }
    if (s.first < cutoff) line(s.first, Math.min(s.last, cutoff), s.type, false);
    if (s.last > cutoff) line(Math.max(s.first, cutoff), s.last, s.type, true);
  }
}

function fitTo(lo, hi) {
  const pts = state.day?.points;
  if (!pts?.length) return;
  const slice = pts.slice(lo ?? 0, (hi ?? pts.length - 1) + 1).map(latlng);
  const bounds = L.latLngBounds(slice);
  if (bounds.getNorthEast().distanceTo(bounds.getSouthWest()) < 600) map.setView(bounds.getCenter(), 16);
  else map.fitBounds(bounds, { padding: [50, 50] });
}

// ---------------------------------------------------------------- time helpers
function cutoffIndex() {
  const pts = state.day.points;
  let lo = 0, hi = pts.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (pts[mid].t <= state.time) lo = mid + 1; else hi = mid; }
  return Math.max(lo - 1, 0);
}
function currentSegment(c) {
  const segs = state.day.segments;
  return segs.find((s) => s.first <= c && c < s.last) ?? segs[segs.length - 1] ?? null;
}
function markerPosition(c) {
  const pts = state.day.points;
  const a = pts[c], b = pts[c + 1];
  if (!b) return latlng(a);
  const dt = b.t - a.t;
  if (dt <= 0 || dt > GAP_THRESHOLD) return latlng(a);
  const f = Math.min(Math.max((state.time - a.t) / dt, 0), 1);
  return [a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f];
}
const dayStart = () => state.day.points[0].t;
const dayEnd = () => state.day.points[state.day.points.length - 1].t;

// ---------------------------------------------------------------- render
let lastCurrentFirst = null;
function renderTime() {
  if (!state.day?.points.length) return;
  const c = cutoffIndex();
  drawTrack(c);
  const seg = currentSegment(c);
  const type = seg?.type ?? 'unknown';
  const pos = markerPosition(c);
  if (!marker) {
    marker = L.circleMarker(pos, { radius: 9, color: '#fff', weight: 3, fillOpacity: 1, fillColor: ACTIVITY[type].color, interactive: false }).addTo(map);
  } else {
    marker.setLatLng(pos);
    marker.setStyle({ fillColor: ACTIVITY[type].color });
  }
  marker.bringToFront();
  if (state.follow) map.panTo(pos, { animate: false });

  const span = Math.max(dayEnd() - dayStart(), 1);
  $('slider').value = String(Math.round(((state.time - dayStart()) / span) * 10000));
  $('clock').textContent = fmtTime(state.time, true);
  drawStrip();

  const first = seg?.first ?? null;
  if (first !== lastCurrentFirst) {
    lastCurrentFirst = first;
    for (const li of $('segments').children) li.classList.toggle('current', Number(li.dataset.first) === first);
    $('segments').querySelector('.current')?.scrollIntoView({ block: 'nearest' });
  }
}

function drawStrip() {
  const canvas = $('strip');
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  if (!state.day?.points.length) return;
  const style = getComputedStyle(document.documentElement);
  const start = dayStart(), span = Math.max(dayEnd() - start, 1), barH = h - 14;
  const x = (t) => ((t - start) / span) * w;

  ctx.fillStyle = style.getPropertyValue('--line');
  ctx.beginPath(); ctx.roundRect(0, 0, w, barH, 4); ctx.fill();
  for (const s of state.day.segments) {
    ctx.globalAlpha = s.type === 'stationary' ? 0.5 : 0.95;
    ctx.fillStyle = ACTIVITY[s.type].color;
    ctx.fillRect(x(s.start), 0, Math.max(x(s.end) - x(s.start), 1), barH);
  }
  ctx.globalAlpha = 1;

  // Hour ticks.
  const every = span > 10 * 3600 ? 3 : span > 4 * 3600 ? 2 : 1;
  const d = new Date(start * 1000); d.setMinutes(0, 0, 0); d.setHours(d.getHours() + 1);
  ctx.fillStyle = style.getPropertyValue('--muted');
  ctx.font = '10px system-ui, sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'top';
  for (let t = d.getTime() / 1000; t < start + span; t += 3600) {
    const tx = x(t);
    ctx.fillRect(tx, barH - 5, 1, 5);
    const hour = new Date(t * 1000).getHours();
    if (hour % every === 0) ctx.fillText(new Date(t * 1000).toLocaleTimeString([], { hour: 'numeric' }), tx, barH + 2);
  }
  // Playhead.
  ctx.fillStyle = style.getPropertyValue('--text');
  ctx.fillRect(x(state.time) - 1.5, 0, 3, barH);
}

function renderDayList() {
  const list = $('dayList');
  list.replaceChildren();
  let month = '';
  for (const d of state.days) {
    const m = d.date.toLocaleDateString([], { month: 'long', year: 'numeric' });
    if (m !== month) { month = m; list.append(el('div', 'month', m)); }
    const b = el('button');
    b.append(d.date.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' }), el('span', 'count', String(d.count)));
    b.classList.toggle('selected', state.day?.key === d.key);
    b.addEventListener('click', () => selectDay(d.key));
    list.append(b);
  }
}

function renderPanel() {
  const totalsEl = $('totals'), segEl = $('segments');
  totalsEl.replaceChildren(); segEl.replaceChildren();
  lastCurrentFirst = null;
  if (!state.day) return;
  for (const t of totals(state.day.segments)) {
    if (t.type === 'unknown') continue;
    const li = el('li');
    const label = el('span'); const dot = el('i', 'dot'); dot.style.background = ACTIVITY[t.type].color;
    label.append(dot, ` ${ACTIVITY[t.type].label}`);
    li.append(label, el('span', 'tval', t.type === 'stationary' ? fmtDuration(t.duration) : `${fmtDistance(t.distance)} · ${fmtDuration(t.duration)}`));
    totalsEl.append(li);
  }
  const pointsLi = el('li'); pointsLi.append(el('span', null, 'Points'), el('span', 'tval', String(state.day.points.length)));
  totalsEl.append(pointsLi);

  for (const s of state.day.segments) {
    const li = el('li'); li.dataset.first = String(s.first);
    const icon = el('div', 'seg-icon', ICON[s.type]); icon.style.background = ACTIVITY[s.type].color;
    const main = el('div', 'seg-main');
    main.append(el('div', 'seg-title', ACTIVITY[s.type].label), el('div', 'seg-time', `${fmtTime(s.start)} – ${fmtTime(s.end)}`));
    const right = el('div', 'seg-right');
    if (s.type !== 'stationary') right.append(el('div', null, fmtDistance(s.distance)));
    right.append(el('div', 'seg-dur', fmtDuration(s.end - s.start)));
    li.append(icon, main, right);
    li.addEventListener('click', () => { setPlaying(false); state.time = s.start; fitTo(s.first, s.last); renderTime(); });
    segEl.append(li);
  }
}

// ---------------------------------------------------------------- data
function rebuildDays() {
  const counts = new Map();
  for (const p of state.points) { const k = dayKeyOf(p.t); counts.set(k, (counts.get(k) ?? 0) + 1); }
  state.days = [...counts].map(([key, count]) => ({ key, count, date: dateOfKey(key) })).sort((a, b) => (a.key < b.key ? 1 : -1));
  state.dayCache.clear();
}

function merge(newPoints, name) {
  const seen = new Set();
  const all = [];
  for (const p of [...state.points, ...newPoints].sort((a, b) => a.t - b.t)) {
    const k = Math.round(p.t * 1000);
    if (!seen.has(k)) { seen.add(k); all.push(p); }
  }
  state.points = all;
  state.loadedNames.add(name);
  rebuildDays();
  renderDayList();
  markLoadedFiles();
  if (!state.day || !state.days.some((d) => d.key === state.day.key)) selectDay(state.days[0]?.key);
  else selectDay(state.day.key, { keepView: true });
}

function dayData(key) {
  if (state.dayCache.has(key)) return state.dayCache.get(key);
  const pts = clean(state.points.filter((p) => dayKeyOf(p.t) === key));
  const data = { key, points: pts, segments: segmentDay(pts) };
  state.dayCache.set(key, data);
  return data;
}

function selectDay(key, { keepView = false } = {}) {
  setPlaying(false);
  $('empty').hidden = Boolean(key);
  if (!key) {
    state.day = null; trackLayer.clearLayers(); marker?.remove(); marker = null;
    $('dayTitle').textContent = 'No data loaded';
    renderPanel(); renderDayList(); drawStrip();
    return;
  }
  state.day = dayData(key);
  drawnCutoff = null;
  state.time = dayEnd();
  $('dayTitle').textContent = dateOfKey(key).toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
  renderDayList();
  renderPanel();
  if (!keepView) fitTo();
  renderTime();
}

function stepDay(delta) {   // +1 = older
  if (!state.days.length) return;
  const i = state.days.findIndex((d) => d.key === state.day?.key);
  const j = Math.min(Math.max((i < 0 ? 0 : i) + delta, 0), state.days.length - 1);
  selectDay(state.days[j].key);
}

// ---------------------------------------------------------------- loading files
const passQueue = [];
let passBusy = false;

function askPassphrase(name, errorText) {
  return new Promise((resolve) => {
    const dlg = $('passDialog');
    $('passFile').textContent = `“${name}”`;
    $('passInput').value = '';
    $('passError').hidden = !errorText;
    $('passError').textContent = errorText ?? '';
    const done = (value) => {
      $('passForm').onsubmit = null; $('passSkip').onclick = null; dlg.oncancel = null;
      dlg.close(); resolve(value);
    };
    $('passForm').onsubmit = (e) => { e.preventDefault(); done($('passInput').value); };
    $('passSkip').onclick = () => done(null);
    dlg.oncancel = (e) => { e.preventDefault(); done(null); };
    dlg.showModal();
    $('passInput').focus();
  });
}

async function loadBytes(bytes, name) {
  if (!isLocked(bytes)) {
    try { merge(await decodePoints(bytes), name); } catch (e) { alert(`${name}: ${e.message}`); }
    return;
  }
  if (state.lastPassphrase) {
    try { merge(await decodePoints(bytes, state.lastPassphrase), name); return; } catch { /* ask below */ }
  }
  // Ask for passphrases one file at a time.
  passQueue.push({ bytes, name });
  if (passBusy) return;
  passBusy = true;
  while (passQueue.length) {
    const job = passQueue.shift();
    if (state.lastPassphrase) {   // an earlier unlock may have given us the right one
      try { merge(await decodePoints(job.bytes, state.lastPassphrase), job.name); continue; } catch { /* ask */ }
    }
    let error = null;
    for (;;) {
      const pass = await askPassphrase(job.name, error);
      if (pass === null) break;
      try {
        const pts = await decodePoints(job.bytes, pass);
        state.lastPassphrase = pass;
        merge(pts, job.name);
        break;
      } catch (e) {
        error = e instanceof FormatError ? e.message : String(e);
      }
    }
  }
  passBusy = false;
}

async function loadFiles(fileList) {
  for (const f of fileList) await loadBytes(new Uint8Array(await f.arrayBuffer()), f.name);
}

let serverFiles = [];
async function refreshServerFiles() {
  const list = $('fileList');
  try {
    const res = await fetch('/api/files', { cache: 'no-store' });
    if (!res.ok) throw new Error(res.statusText);
    const data = await res.json();
    serverFiles = data.files;
    $('filesDir').textContent = data.error ? `Can't read ${data.dir}: ${data.error}` : `in ${data.dir}`;
  } catch {
    serverFiles = [];
    $('filesDir').textContent = 'Folder listing needs serve.py. Use “Open files…” or drag files here.';
  }
  list.replaceChildren();
  for (const f of serverFiles) {
    const li = el('li');
    li.dataset.name = f.name;
    li.title = `Load ${f.name}`;
    li.append(el('span', 'fname', f.name), el('span', 'fmeta', `${fmtBytes(f.size)} · ${new Date(f.mtime * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' })}`));
    li.addEventListener('click', () => loadServerFile(f.name));
    list.append(li);
  }
  if (!serverFiles.length && $('filesDir').textContent.startsWith('in ')) list.append(el('li', 'muted small', 'No exports here yet.'));
  $('loadAll').hidden = serverFiles.length < 2;
  markLoadedFiles();
}

async function loadServerFile(name) {
  const res = await fetch(`/api/files/${encodeURIComponent(name)}`, { cache: 'no-store' });
  if (!res.ok) { alert(`Couldn't read ${name}`); return; }
  await loadBytes(new Uint8Array(await res.arrayBuffer()), name);
}

function markLoadedFiles() {
  for (const li of $('fileList').children) li.classList.toggle('loaded', state.loadedNames.has(li.dataset.name));
}

// ---------------------------------------------------------------- playback
let lastFrame = 0;
function setPlaying(on) {
  state.playing = on;
  $('play').textContent = on ? '❚❚' : '▶';
  $('play').setAttribute('aria-label', on ? 'Pause' : 'Play');
  if (on) {
    if (state.day && state.time >= dayEnd()) state.time = dayStart();
    lastFrame = performance.now();
    requestAnimationFrame(tick);
  }
}
function tick(now) {
  if (!state.playing || !state.day) return;
  const dt = Math.min((now - lastFrame) / 1000, 0.1);
  lastFrame = now;
  state.time += dt * state.speed;
  if (state.time >= dayEnd()) { state.time = dayEnd(); setPlaying(false); }
  renderTime();
  if (state.playing) requestAnimationFrame(tick);
}

// ---------------------------------------------------------------- wiring
function scrubFromPointer(e) {
  if (!state.day) return;
  const r = $('strip').getBoundingClientRect();
  const f = Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1);
  setPlaying(false);
  state.time = dayStart() + f * (dayEnd() - dayStart());
  renderTime();
}

function wire() {
  $('fileInput').addEventListener('change', async (e) => { await loadFiles(e.target.files); e.target.value = ''; });
  $('refreshFiles').addEventListener('click', refreshServerFiles);
  $('loadAll').addEventListener('click', async () => { for (const f of serverFiles) if (!state.loadedNames.has(f.name)) await loadServerFile(f.name); });
  $('forget').addEventListener('click', () => {
    state.points = []; state.loadedNames.clear(); state.lastPassphrase = null;
    rebuildDays(); selectDay(null); markLoadedFiles();
  });
  $('prevDay').addEventListener('click', () => stepDay(1));
  $('nextDay').addEventListener('click', () => stepDay(-1));
  $('showDay').addEventListener('click', () => fitTo());
  $('play').addEventListener('click', () => state.day && setPlaying(!state.playing));
  $('speed').addEventListener('change', (e) => { state.speed = Number(e.target.value); });
  $('follow').addEventListener('change', (e) => { state.follow = e.target.checked; renderTime(); });
  $('slider').addEventListener('input', (e) => {
    if (!state.day) return;
    setPlaying(false);
    state.time = dayStart() + (Number(e.target.value) / 10000) * (dayEnd() - dayStart());
    renderTime();
  });

  const strip = $('strip');
  strip.addEventListener('pointerdown', (e) => { strip.setPointerCapture(e.pointerId); scrubFromPointer(e); });
  strip.addEventListener('pointermove', (e) => { if (strip.hasPointerCapture(e.pointerId)) scrubFromPointer(e); });
  window.addEventListener('resize', drawStrip);
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', drawStrip);

  document.addEventListener('keydown', (e) => {
    if (e.target instanceof Element && e.target.closest('input, select, dialog')) return;
    if (e.key === ' ') { e.preventDefault(); if (state.day) setPlaying(!state.playing); }
    else if (e.key === 'ArrowLeft' && !e.shiftKey) { e.preventDefault(); stepDay(1); }
    else if (e.key === 'ArrowRight' && !e.shiftKey) { e.preventDefault(); stepDay(-1); }
    else if ((e.key === 'ArrowLeft' || e.key === 'ArrowRight') && state.day) {
      e.preventDefault(); setPlaying(false);
      state.time = Math.min(Math.max(state.time + (e.key === 'ArrowLeft' ? -300 : 300), dayStart()), dayEnd());
      renderTime();
    }
  });

  // Drag and drop anywhere.
  let depth = 0;
  document.addEventListener('dragenter', (e) => { if (e.dataTransfer?.types.includes('Files')) { depth++; $('dropHint').hidden = false; } });
  document.addEventListener('dragleave', () => { depth = Math.max(depth - 1, 0); if (!depth) $('dropHint').hidden = true; });
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', async (e) => {
    e.preventDefault(); depth = 0; $('dropHint').hidden = true;
    if (e.dataTransfer?.files.length) await loadFiles(e.dataTransfer.files);
  });
}

buildLegend();
wire();
selectDay(null);
refreshServerFiles();
