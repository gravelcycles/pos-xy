// Pos XY web viewer. Everything happens in this tab: files are decrypted here and kept in memory.
import { decodePoints, isLocked, FormatError } from './format.js';
import { ACTIVITY, ACTIVITY_ORDER, isDashed, clean, segments as segmentDay, totals, gapThreshold, distance } from './segmenter.js';
import { staysFromDay, detectPlaces, PLACE_RADIUS } from './places.js';
import { toGPX } from './importers.js';

const $ = (id) => document.getElementById(id);
const ICON = { stationary: '📍', walking: '🚶', running: '🏃', cycling: '🚲', driving: '🚗', flying: '✈️', unknown: '❔' };
const PLACE_ICON = { home: '🏠', work: '💼' };

// ---------------------------------------------------------------- state
const state = {
  points: [],             // all loaded points, sorted, de-duplicated
  days: [],               // [{ key, date, count, distance? }] newest first
  dayCache: new Map(),
  loadedNames: new Set(),
  lastPassphrase: null,
  mode: 'day',            // 'day' | 'overview'
  day: null,              // { key, points, segments, gap }
  time: 0,                // unix seconds
  playing: false,
  speed: 300,
  follow: false,
  places: [],             // detected places (see places.js), with .display (custom or detected name)
  finding: false,         // "Where was I?" click mode
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
  if (h >= 48) return `${Math.round(h / 24)} days`;
  return h ? `${h} h ${m} min` : `${m} min`;
}
const fmtTime = (t, seconds = false) => new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', ...(seconds && { second: '2-digit' }) });
const dayKeyOf = (t) => { const d = new Date(t * 1000); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
const dateOfKey = (k) => { const [y, m, d] = k.split('-').map(Number); return new Date(y, m - 1, d); };
const fmtBytes = (n) => (n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : `${(n / 1048576).toFixed(1)} MB`);
const fmtDay = (k, opts = { weekday: 'short', month: 'short', day: 'numeric' }) => dateOfKey(k).toLocaleDateString([], opts);

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

let toastTimer = null;
function toast(text) {
  const t = $('toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 4000);
}

// ---------------------------------------------------------------- custom place names (this browser only)
const NAMES_KEY = 'posxy.placeNames';
function loadNames() {
  try { return JSON.parse(localStorage.getItem(NAMES_KEY) || '[]'); } catch { return []; }
}
function saveNames(list) {
  try { localStorage.setItem(NAMES_KEY, JSON.stringify(list)); } catch { /* private mode: names last this session */ }
}
let customNames = loadNames();

function customNameFor(lat, lon) {
  let best = null, bestD = Infinity;
  for (const n of customNames) {
    const d = distance(n, { lat, lon });
    if (d <= PLACE_RADIUS && d < bestD) { best = n; bestD = d; }
  }
  return best;
}

function renamePlace(place) {
  const current = place.display ?? '';
  const name = prompt('Name this place (leave empty to reset):', current);
  if (name === null) return;
  customNames = customNames.filter((n) => distance(n, place) > PLACE_RADIUS);
  if (name.trim()) customNames.push({ lat: Number(place.lat.toFixed(5)), lon: Number(place.lon.toFixed(5)), name: name.trim().slice(0, 60) });
  saveNames(customNames);
  applyPlaceNames();
  render();
}

// ---------------------------------------------------------------- map
const map = L.map('map', { preferCanvas: true, zoomControl: true, worldCopyJump: true }).setView([20, 0], 2);
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 19,
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
}).addTo(map);
map.attributionControl.setPrefix(false);
const trackLayer = L.layerGroup().addTo(map);
// Permanent place labels only make sense once you're zoomed in to city level.
const syncZoomClass = () => map.getContainer().classList.toggle('low-zoom', map.getZoom() < 10);
map.on('zoomend', syncZoomClass);
syncZoomClass();
const overviewLayer = L.layerGroup().addTo(map);
const searchLayer = L.layerGroup().addTo(map);
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

const latlng = (p) => [p.lat, p.lon];

function tipFor(text) {
  // A DOM node (not an HTML string), so a place name can never inject markup.
  return el('span', null, text);
}

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
      const c = stayCenter(s);
      const circle = L.circle(c, {
        radius: 35, color: ACTIVITY.stationary.color, weight: 2, opacity: faded ? 0.3 : 0.9,
        fillOpacity: faded ? 0.1 : 0.3, interactive: false,
      }).addTo(trackLayer);
      const place = placeAt(c[0], c[1]);
      if (place?.display) circle.bindTooltip(tipFor(place.display), { permanent: true, direction: 'top', className: 'place-tip perm', offset: [0, -8] });
      continue;
    }
    if (s.first < cutoff) line(s.first, Math.min(s.last, cutoff), s.type, false);
    if (s.last > cutoff) line(Math.max(s.first, cutoff), s.last, s.type, true);
  }
}

function stayCenter(s) {
  const pts = state.day.points;
  let lat = 0, lon = 0;
  for (let i = s.first; i <= s.last; i++) { lat += pts[i].lat; lon += pts[i].lon; }
  const n = s.last - s.first + 1;
  return [lat / n, lon / n];
}

function fitPoints(pts) {
  if (!pts.length) return;
  const bounds = L.latLngBounds(pts.map(latlng));
  if (bounds.getNorthEast().distanceTo(bounds.getSouthWest()) < 600) map.setView(bounds.getCenter(), 16);
  else map.fitBounds(bounds, { padding: [50, 50] });
}
function fitTo(lo, hi) {
  const pts = state.day?.points;
  if (pts?.length) fitPoints(pts.slice(lo ?? 0, (hi ?? pts.length - 1) + 1));
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
  if (dt <= 0 || dt > state.day.gap) return latlng(a);
  const f = Math.min(Math.max((state.time - a.t) / dt, 0), 1);
  return [a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f];
}
const dayStart = () => state.day.points[0].t;
const dayEnd = () => state.day.points[state.day.points.length - 1].t;

// ---------------------------------------------------------------- render: day mode
let lastCurrentFirst = null;
function renderTime() {
  if (state.mode !== 'day' || !state.day?.points.length) return;
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
    b.dataset.key = d.key;
    b.append(d.date.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' }),
      el('span', 'dist', d.distance != null ? fmtDistance(d.distance) : `${d.count} pts`));
    b.classList.toggle('selected', state.mode === 'day' && state.day?.key === d.key);
    b.addEventListener('click', () => selectDay(d.key));
    list.append(b);
  }
}

function totalsList(target, segs, extraRows) {
  target.replaceChildren();
  for (const t of totals(segs)) {
    if (t.type === 'unknown') continue;
    const li = el('li');
    const label = el('span'); const dot = el('i', 'dot'); dot.style.background = ACTIVITY[t.type].color;
    label.append(dot, ` ${ACTIVITY[t.type].label}`);
    li.append(label, el('span', 'tval', t.type === 'stationary' ? fmtDuration(t.duration) : `${fmtDistance(t.distance)} · ${fmtDuration(t.duration)}`));
    target.append(li);
  }
  for (const [k, v] of extraRows) {
    const li = el('li'); li.append(el('span', null, k), el('span', 'tval', v));
    target.append(li);
  }
}

function renderDayPanel() {
  const segEl = $('segments');
  segEl.replaceChildren();
  lastCurrentFirst = null;
  $('summaryTitle').textContent = 'Summary';
  $('showDay').textContent = 'Show whole day';
  if (!state.day) { $('totals').replaceChildren(); return; }
  totalsList($('totals'), state.day.segments, [['Points', state.day.points.length.toLocaleString()]]);

  for (const s of state.day.segments) {
    const li = el('li'); li.dataset.first = String(s.first);
    const icon = el('div', 'seg-icon', ICON[s.type]); icon.style.background = ACTIVITY[s.type].color;
    const main = el('div', 'seg-main');
    const title = el('div', 'seg-title');
    const place = s.type === 'stationary' ? placeAt(...stayCenter(s)) : null;
    if (place?.display) {
      title.append(`${PLACE_ICON[place.label] ?? ''} ${place.display}`.trim(), el('span', 'seg-sub', 'Stay'));
    } else {
      title.append(ACTIVITY[s.type].label);
    }
    if (place) {
      const btn = el('button', 'rename', '✎');
      btn.title = 'Name this place';
      btn.addEventListener('click', (e) => { e.stopPropagation(); renamePlace(place); });
      title.append(btn);
    }
    main.append(title, el('div', 'seg-time', `${fmtTime(s.start)} – ${fmtTime(s.end)}`));
    const right = el('div', 'seg-right');
    if (s.type !== 'stationary') right.append(el('div', null, fmtDistance(s.distance)));
    right.append(el('div', 'seg-dur', fmtDuration(s.end - s.start)));
    li.append(icon, main, right);
    li.addEventListener('click', () => { setPlaying(false); state.time = s.start; fitTo(s.first, s.last); renderTime(); });
    segEl.append(li);
  }
}

// ---------------------------------------------------------------- render: overview mode
function renderOverview() {
  overviewLayer.clearLayers();
  // Until the background analysis finishes, draw only the days already analyzed.
  const all = state.analyzed ? state.days.map((d) => dayData(d.key)) : state.days.map((d) => state.dayCache.get(d.key)).filter(Boolean);
  const segs = all.flatMap((d) => d.segments);
  totalsList($('totals'), segs, [
    ['Days recorded', state.days.length.toLocaleString()],
    ['Points', state.points.length.toLocaleString()],
    ...(state.days.length ? [['Range', `${fmtDay(state.days.at(-1).key, { month: 'short', day: 'numeric', year: 'numeric' })} – ${fmtDay(state.days[0].key, { month: 'short', day: 'numeric', year: 'numeric' })}`]] : []),
  ]);
  $('summaryTitle').textContent = 'All time';
  $('showDay').textContent = 'Show everything';

  // All movement, thin, one polyline per segment. Thinned so years of data stay drawable.
  const step = 25 * Math.max(1, state.points.length / 150000);
  for (const d of all) {
    for (const s of d.segments) {
      if (s.type === 'stationary') continue;
      const coords = [];
      let last = null;
      for (let i = s.first; i <= s.last; i++) {
        const p = d.points[i];
        if (!last || i === s.last || distance(last, p) >= step) { coords.push(latlng(p)); last = p; }
      }
      if (coords.length > 1) {
        L.polyline(coords, { color: ACTIVITY[s.type].color, weight: 2.5, opacity: 0.55, interactive: false,
                             dashArray: isDashed(s.type) ? '6 6' : null }).addTo(overviewLayer);
      }
    }
  }
  // Places, sized by time spent.
  const maxSec = Math.max(1, ...state.places.map((p) => p.seconds));
  state.places.filter((p) => p.display).slice(0, 40).forEach((p, i) => {
    const c = L.circleMarker(latlng(p), {
      radius: 5 + 11 * Math.sqrt(p.seconds / maxSec), color: '#fff', weight: 2,
      fillColor: ACTIVITY.stationary.color, fillOpacity: 0.85,
    }).addTo(overviewLayer);
    c.bindTooltip(tipFor(`${PLACE_ICON[p.label] ?? ''} ${p.display}`.trim()), { permanent: i < 8, direction: 'top', className: i < 8 ? 'place-tip perm' : 'place-tip', offset: [0, -6] });
    c.on('click', () => findVisits(L.latLng(p.lat, p.lon)));
  });

  renderCalendar();
  renderPlacesList();
}

function renderCalendar() {
  const cal = $('calendar');
  cal.replaceChildren();
  if (!state.days.length) return;
  const byKey = new Map(state.days.map((d) => [d.key, d]));
  const maxDist = Math.max(1, ...state.days.map((d) => d.distance ?? 0));
  // Only months that have data, newest first (at most three years).
  const months = [];
  for (const d of state.days) {
    const y = d.date.getFullYear(), m = d.date.getMonth();
    if (!months.some(([yy, mm]) => yy === y && mm === m)) months.push([y, m]);
    if (months.length >= 36) break;
  }
  const weekStart = 1;   // Monday
  for (const [y, m] of months) {
    const box = el('div');
    box.append(el('div', 'cal-month', new Date(y, m, 1).toLocaleDateString([], { month: 'long', year: 'numeric' })));
    const grid = el('div', 'cal-grid');
    for (let i = 0; i < 7; i++) grid.append(el('div', 'dow', new Date(2024, 0, 1 + i).toLocaleDateString([], { weekday: 'narrow' })));
    const lead = (new Date(y, m, 1).getDay() - weekStart + 7) % 7;
    for (let i = 0; i < lead; i++) grid.append(el('div', 'cal-cell blank'));
    const daysIn = new Date(y, m + 1, 0).getDate();
    for (let d = 1; d <= daysIn; d++) {
      const key = `${y}-${String(m + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
      const info = byKey.get(key);
      const cell = el('button', 'cal-cell', String(d));
      if (info) {
        cell.classList.add('has');
        const f = Math.sqrt((info.distance ?? 0) / maxDist);
        cell.style.background = `color-mix(in srgb, ${ACTIVITY.driving.color} ${Math.round(20 + 80 * f)}%, transparent)`;
        cell.title = `${fmtDay(key)}: ${info.distance != null ? fmtDistance(info.distance) : `${info.count} points`}`;
        cell.addEventListener('click', () => selectDay(key));
      } else {
        cell.disabled = true;
      }
      grid.append(cell);
    }
    box.append(grid);
    cal.append(box);
  }
}

function renderPlacesList() {
  const list = $('placesList');
  list.replaceChildren();
  for (const p of state.places.filter((x) => x.display).slice(0, 25)) {
    const li = el('li');
    li.append(el('span', 'badge', PLACE_ICON[p.label] ?? '📍'), el('span', 'pname', p.display),
      el('span', 'pmeta', `${p.visits}× · ${fmtDuration(p.seconds)}`));
    const btn = el('button', 'rename', '✎');
    btn.title = 'Rename';
    btn.addEventListener('click', (e) => { e.stopPropagation(); renamePlace(p); });
    li.append(btn);
    li.addEventListener('click', () => { map.setView([p.lat, p.lon], 16); findVisits(L.latLng(p.lat, p.lon)); });
    list.append(li);
  }
  if (!list.children.length) list.append(el('li', 'muted small', 'No places yet. They appear once you stay somewhere for a while.'));
}

// ---------------------------------------------------------------- render: shared
function render({ fit = false } = {}) {
  const hasData = state.days.length > 0;
  $('empty').hidden = hasData;
  const overview = state.mode === 'overview' && hasData;
  $('overviewBtn').setAttribute('aria-pressed', String(overview));
  $('timeline').hidden = overview;
  $('segmentsSection').hidden = overview;
  $('calendarSection').hidden = !overview;
  $('placesSection').hidden = !overview;
  $('exportGpx').hidden = !hasData;

  if (overview) {
    trackLayer.clearLayers(); marker?.remove(); marker = null; drawnCutoff = null;
    $('dayTitle').textContent = 'All time';
    renderOverview();
    if (fit) fitPoints(state.points.length > 50000 ? state.points.filter((_, i) => i % 20 === 0) : state.points);
  } else {
    overviewLayer.clearLayers();
    if (!state.day) {
      trackLayer.clearLayers(); marker?.remove(); marker = null;
      $('dayTitle').textContent = hasData ? '' : 'No data loaded';
    } else {
      $('dayTitle').textContent = dateOfKey(state.day.key).toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
      drawnCutoff = null;
    }
    renderDayPanel();
    if (fit) fitTo();
    renderTime();
    drawStrip();
  }
  renderDayList();
  updateHash();
}

// ---------------------------------------------------------------- data
/** Groups the (time-sorted) points into local days in one pass: each day is an index range. */
function rebuildDays() {
  const ranges = new Map();
  let key = null, startOfNext = -Infinity, cur = null;
  for (let i = 0; i < state.points.length; i++) {
    const t = state.points[i].t;
    if (t >= startOfNext || cur === null) {
      key = dayKeyOf(t);
      const d = dateOfKey(key);
      startOfNext = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime() / 1000;
      cur = ranges.get(key);
      if (!cur) { cur = { lo: i, hi: i + 1 }; ranges.set(key, cur); }
    }
    cur.hi = i + 1;
  }
  state.days = [...ranges].map(([k, r]) => ({ key: k, lo: r.lo, hi: r.hi, count: r.hi - r.lo, date: dateOfKey(k) }))
    .sort((a, b) => (a.key < b.key ? 1 : -1));
  state.dayIndex = new Map(state.days.map((d) => [d.key, d]));
  state.dayCache.clear();
}

function dayData(key) {
  if (state.dayCache.has(key)) return state.dayCache.get(key);
  const info = state.dayIndex?.get(key);
  const pts = info ? clean(state.points.slice(info.lo, info.hi)) : [];
  const segs = segmentDay(pts);
  const data = { key, points: pts, segments: segs, gap: gapThreshold(pts) };
  state.dayCache.set(key, data);
  if (info) info.distance = segs.reduce((sum, s) => sum + (s.type === 'stationary' ? 0 : s.distance), 0);
  return data;
}

function applyPlaceNames() {
  for (const p of state.places) p.display = customNameFor(p.lat, p.lon)?.name ?? p.name;
}

/**
 * Segments every day and detects places, in ~40 ms slices so the page stays responsive even with
 * years of Google Takeout history. A newer import cancels a running analysis.
 */
let analysisRun = 0;
async function analyzeAll() {
  const run = ++analysisRun;
  const stays = [];
  const days = [...state.days];
  let sliceStart = performance.now();
  for (let i = 0; i < days.length; i++) {
    const data = dayData(days[i].key);
    stays.push(...staysFromDay(data.points, data.segments));
    if (performance.now() - sliceStart > 40) {
      if (days.length > 60) toast(`Analyzing your history… ${Math.round((i / days.length) * 100)}%`);
      await new Promise((r) => setTimeout(r, 0));
      if (run !== analysisRun) return false;
      sliceStart = performance.now();
    }
  }
  if (run !== analysisRun) return false;
  state.places = detectPlaces(stays);
  applyPlaceNames();
  state.analyzed = true;
  return true;
}

function placeAt(lat, lon) {
  let best = null, bestD = Infinity;
  for (const p of state.places) {
    const d = distance(p, { lat, lon });
    if (d <= PLACE_RADIUS && d < bestD) { best = p; bestD = d; }
  }
  return best;
}

function merge(newPoints, name) {
  const seen = new Set();
  const all = [];
  for (const p of [...state.points, ...newPoints].sort((a, b) => a.t - b.t)) {
    const k = Math.round(p.t * 1000);
    if (!seen.has(k)) { seen.add(k); all.push(p); }
  }
  const firstLoad = state.points.length === 0;
  state.points = all;
  state.loadedNames.add(name);
  state.analyzed = false;
  rebuildDays();
  markLoadedFiles();
  // Show something right away; places and day distances fill in when the analysis finishes.
  const show = () => {
    if (firstLoad && applyHash()) return;
    if (state.mode === 'overview') { render({ fit: firstLoad }); return; }
    if (!state.day || !state.dayIndex.has(state.day.key)) selectDay(state.days[0]?.key);
    else selectDay(state.day.key, { keepView: true });
  };
  if (state.mode !== 'overview') show();
  analyzeAll().then((done) => {
    if (!done) return;
    if (state.mode === 'overview') show();
    else { renderDayPanel(); drawnCutoff = null; renderTime(); renderDayList(); }
    if (state.days.length > 60) toast(`${state.days.length.toLocaleString()} days analyzed · ${state.places.filter((p) => p.name).length} places found.`);
  });
}

function selectDay(key, { keepView = false, time = null } = {}) {
  setPlaying(false);
  state.mode = 'day';
  state.day = key ? dayData(key) : null;
  if (state.day) state.time = time ?? dayEnd();
  render({ fit: !keepView && !!state.day });
}

function setMode(mode) {
  if (!state.days.length) return;
  if (mode === 'overview' && !state.analyzed) toast('Still analyzing your history; the overview fills in when it\'s done.');
  setPlaying(false);
  if (mode === 'day' && !state.day) state.day = dayData(state.days[0].key);
  state.mode = mode;
  render({ fit: true });
}

function stepDay(delta) {   // +1 = older
  if (!state.days.length) return;
  const i = state.days.findIndex((d) => d.key === state.day?.key);
  const j = Math.min(Math.max((i < 0 ? 0 : i) + delta, 0), state.days.length - 1);
  selectDay(state.days[j].key);
}

// ---------------------------------------------------------------- URL (#2026-11-12 or #overview)
function updateHash() {
  if (!state.days.length) return;   // keep a bookmarked #day until data arrives
  const want = state.mode === 'overview' ? '#overview' : state.day ? `#${state.day.key}` : '';
  if (location.hash !== want) history.replaceState(null, '', want || location.pathname);
}
function applyHash() {
  const h = decodeURIComponent(location.hash.slice(1));
  if (h === 'overview' && state.days.length) { setMode('overview'); return true; }
  if (/^\d{4}-\d{2}-\d{2}$/.test(h) && state.days.some((d) => d.key === h)) { selectDay(h); return true; }
  return false;
}

// ---------------------------------------------------------------- where was I?
function setFinding(on) {
  state.finding = on;
  document.body.classList.toggle('finding', on);
  $('findBtn').setAttribute('aria-pressed', String(on));
  if (on) toast('Click the map to find every visit near that spot.');
}

function findVisits(latlng) {
  setFinding(false);
  if (!state.points.length) return;
  // Search radius: at least 150 m, or ~25 screen pixels when zoomed out.
  const metresPerPixel = 40075016.686 * Math.abs(Math.cos(latlng.lat * Math.PI / 180)) / 2 ** (map.getZoom() + 8);
  const radius = Math.max(150, 25 * metresPerPixel);
  const here = { lat: latlng.lat, lon: latlng.lng };
  const dLat = radius / 111320, dLon = radius / (111320 * Math.max(Math.cos(here.lat * Math.PI / 180), 0.01));
  const visits = [];
  let cur = null;
  for (const p of state.points) {
    const near = Math.abs(p.lat - here.lat) <= dLat && Math.abs(p.lon - here.lon) <= dLon && distance(p, here) <= radius;
    if (!near) continue;
    if (cur && p.t - cur.end <= 30 * 60 && dayKeyOf(p.t) === cur.key) { cur.end = p.t; cur.n++; }
    else { cur = { key: dayKeyOf(p.t), start: p.t, end: p.t, n: 1 }; visits.push(cur); }
  }
  visits.reverse();

  searchLayer.clearLayers();
  L.circle(latlng, { radius, color: '#111', weight: 2, dashArray: '4 4', fillOpacity: 0.06, interactive: false }).addTo(searchLayer);
  const place = placeAt(here.lat, here.lon);
  const dayCount = new Set(visits.map((v) => v.key)).size;
  $('searchSection').hidden = false;
  $('searchSummary').textContent = visits.length
    ? `${place?.display ? `${place.display}: ` : ''}${visits.length} visit${visits.length === 1 ? '' : 's'} on ${dayCount} day${dayCount === 1 ? '' : 's'} within ${fmtDistance(radius)}.`
    : `You haven't been within ${fmtDistance(radius)} of here.`;
  const list = $('searchResults');
  list.replaceChildren();
  for (const v of visits.slice(0, 200)) {
    const li = el('li');
    li.append(el('span', null, fmtDay(v.key, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })),
      el('span', 'vtime', v.end - v.start < 60 ? fmtTime(v.start) : `${fmtTime(v.start)} – ${fmtTime(v.end)}`));
    li.addEventListener('click', () => selectDay(v.key, { time: v.start }));
    list.append(li);
  }
}

function closeSearch() {
  $('searchSection').hidden = true;
  searchLayer.clearLayers();
}

// ---------------------------------------------------------------- GPX export
function exportGPX() {
  const overview = state.mode === 'overview' || !state.day;
  const pts = overview ? state.points : state.day.points;
  if (!pts.length) return;
  const name = overview
    ? `PosXY ${state.days.at(-1).key} to ${state.days[0].key}`
    : `PosXY ${state.day.key}`;
  const blob = new Blob([toGPX(pts, name)], { type: 'application/gpx+xml' });
  const a = el('a');
  a.href = URL.createObjectURL(blob);
  a.download = `${name}.gpx`;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 10000);
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

function imported(pts, name, info) {
  const before = state.points.length;
  merge(pts, name);
  const added = state.points.length - before;
  const from = info.kind && info.kind !== 'Pos XY' ? ` from ${info.kind}` : '';
  toast(`${name}: ${added.toLocaleString()} new point${added === 1 ? '' : 's'}${from}.`);
}

async function loadBytes(bytes, name) {
  if (!isLocked(bytes)) {
    const info = {};
    try { imported(await decodePoints(bytes, undefined, info), name, info); } catch (e) { alert(`${name}: ${e.message}`); }
    return;
  }
  if (state.lastPassphrase) {
    try { imported(await decodePoints(bytes, state.lastPassphrase), name, {}); return; } catch { /* ask below */ }
  }
  passQueue.push({ bytes, name });
  if (passBusy) return;
  passBusy = true;
  while (passQueue.length) {
    const job = passQueue.shift();
    if (state.lastPassphrase) {
      try { imported(await decodePoints(job.bytes, state.lastPassphrase), job.name, {}); continue; } catch { /* ask */ }
    }
    let error = null;
    for (;;) {
      const pass = await askPassphrase(job.name, error);
      if (pass === null) break;
      try {
        const pts = await decodePoints(job.bytes, pass);
        state.lastPassphrase = pass;
        imported(pts, job.name, {});
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
  if (!state.playing || !state.day || state.mode !== 'day') return;
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
    if (customNames.length && !confirm('Forget all loaded data and your place names?')) return;
    state.points = []; state.loadedNames.clear(); state.lastPassphrase = null; state.places = [];
    state.day = null; state.mode = 'day';
    customNames = []; saveNames([]);
    try { localStorage.removeItem(NAMES_KEY); } catch { /* ignore */ }
    analysisRun++; state.analyzed = false;
    rebuildDays(); closeSearch(); markLoadedFiles(); render();
  });
  $('prevDay').addEventListener('click', () => stepDay(1));
  $('nextDay').addEventListener('click', () => stepDay(-1));
  $('showDay').addEventListener('click', () => (state.mode === 'overview' ? fitPoints(state.points) : fitTo()));
  $('overviewBtn').addEventListener('click', () => setMode(state.mode === 'overview' ? 'day' : 'overview'));
  $('findBtn').addEventListener('click', () => setFinding(!state.finding));
  $('closeSearch').addEventListener('click', closeSearch);
  $('exportGpx').addEventListener('click', exportGPX);
  $('helpBtn').addEventListener('click', () => $('helpDialog').showModal());
  $('helpClose').addEventListener('click', () => $('helpDialog').close());
  $('play').addEventListener('click', () => state.day && setPlaying(!state.playing));
  $('speed').addEventListener('change', (e) => { state.speed = Number(e.target.value); });
  $('follow').addEventListener('change', (e) => { state.follow = e.target.checked; renderTime(); });
  $('slider').addEventListener('input', (e) => {
    if (!state.day) return;
    setPlaying(false);
    state.time = dayStart() + (Number(e.target.value) / 10000) * (dayEnd() - dayStart());
    renderTime();
  });

  map.on('click', (e) => { if (state.finding) findVisits(e.latlng); });
  map.on('contextmenu', (e) => findVisits(e.latlng));

  const strip = $('strip');
  strip.addEventListener('pointerdown', (e) => { strip.setPointerCapture(e.pointerId); scrubFromPointer(e); });
  strip.addEventListener('pointermove', (e) => { if (strip.hasPointerCapture(e.pointerId)) scrubFromPointer(e); });
  window.addEventListener('resize', drawStrip);
  window.addEventListener('hashchange', applyHash);
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', drawStrip);

  document.addEventListener('keydown', (e) => {
    if (e.target instanceof Element && e.target.closest('input, select, dialog, textarea')) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === ' ') { e.preventDefault(); if (state.day && state.mode === 'day') setPlaying(!state.playing); }
    else if (e.key === 'ArrowLeft' && !e.shiftKey) { e.preventDefault(); stepDay(1); }
    else if (e.key === 'ArrowRight' && !e.shiftKey) { e.preventDefault(); stepDay(-1); }
    else if ((e.key === 'ArrowLeft' || e.key === 'ArrowRight') && state.day && state.mode === 'day') {
      e.preventDefault(); setPlaying(false);
      state.time = Math.min(Math.max(state.time + (e.key === 'ArrowLeft' ? -300 : 300), dayStart()), dayEnd());
      renderTime();
    } else if (e.key === 'o' || e.key === 'O') setMode(state.mode === 'overview' ? 'day' : 'overview');
    else if (e.key === 'f' || e.key === 'F') setFinding(!state.finding);
    else if (e.key === '?') $('helpDialog').showModal();
    else if (e.key === 'Escape') { setFinding(false); closeSearch(); }
  });

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
render();
refreshServerFiles();
