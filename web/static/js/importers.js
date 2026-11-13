// Importers for other people's location formats. Everything is parsed locally.
//   • Google Takeout "Records.json" (classic Location History)
//   • Google Maps on-device Timeline export, Android/web ("Timeline.json": semanticSegments/rawSignals)
//   • Google Maps Timeline export from the iPhone app (array of visit/activity/timelinePath entries)
//   • GPX 1.0/1.1 (trkpt, rtept, wpt with <time>)
// Port twin: Shared/Importers.swift. Output is Pos XY points: { t, lat, lon, alt?, acc?, spd?, crs?, act? }.

const GOOGLE_ACTIVITY = {
  STILL: 'stationary', WALKING: 'walking', ON_FOOT: 'walking', RUNNING: 'running',
  ON_BICYCLE: 'cycling', CYCLING: 'cycling', FLYING: 'flying',
  IN_VEHICLE: 'driving', IN_ROAD_VEHICLE: 'driving', IN_CAR: 'driving', IN_PASSENGER_VEHICLE: 'driving',
  IN_BUS: 'driving', IN_TAXI: 'driving', MOTORCYCLING: 'driving', IN_TRAIN: 'driving', IN_SUBWAY: 'driving',
  IN_TRAM: 'driving', IN_RAIL_VEHICLE: 'driving', IN_FERRY: 'driving', IN_BOAT: 'driving', IN_CABLECAR: 'driving',
  IN_GONDOLA_LIFT: 'driving', IN_WHEELCHAIR: 'walking', SKIING: 'unknown', SAILING: 'driving',
};
export const googleActivity = (type) => GOOGLE_ACTIVITY[String(type ?? '').toUpperCase().trim().replace(/[\s-]+/g, '_').replace(/[^A-Z_]/g, '')] ?? 'unknown';

const isoTime = (s) => { const ms = Date.parse(s); return Number.isFinite(ms) ? ms / 1000 : null; };

/** "52.5163°, 13.3777°" or "geo:52.5163,13.3777" or "52.5163,13.3777" → [lat, lon] */
export function parseLatLng(s) {
  if (typeof s !== 'string') return null;
  const m = s.replace(/^geo:/, '').match(/(-?\d+(?:\.\d+)?)\s*°?\s*,\s*(-?\d+(?:\.\d+)?)/);
  return m ? [Number(m[1]), Number(m[2])] : null;
}

function point(t, ll, extra = {}) {
  if (t == null || !ll) return null;
  return { t, lat: ll[0], lon: ll[1], ...extra };
}

/** Classic Takeout Records.json: { locations: [ { latitudeE7, longitudeE7, timestamp|timestampMs, … } ] } */
export function fromGoogleRecords(obj) {
  const out = [];
  for (const l of obj.locations ?? []) {
    const t = l.timestamp ? isoTime(l.timestamp) : l.timestampMs ? Number(l.timestampMs) / 1000 : null;
    if (t == null || l.latitudeE7 == null || l.longitudeE7 == null) continue;
    let lat = l.latitudeE7 / 1e7, lon = l.longitudeE7 / 1e7;
    if (lat > 90) lat -= 2 ** 32 / 1e7;              // old exports stored negatives as unsigned
    if (lon > 180) lon -= 2 ** 32 / 1e7;
    const p = { t, lat, lon };
    if (Number.isFinite(l.accuracy)) p.acc = l.accuracy;
    if (Number.isFinite(l.altitude)) p.alt = l.altitude;
    if (Number.isFinite(l.velocity)) p.spd = l.velocity;
    if (Number.isFinite(l.heading)) p.crs = ((l.heading % 360) + 360) % 360;
    const best = (l.activity?.[0]?.activity ?? []).reduce((a, b) => (!a || b.confidence > a.confidence ? b : a), null);
    if (best && best.confidence >= 50) p.act = googleActivity(best.type);
    out.push(p);
  }
  return out;
}

/** Android/web on-device export: { semanticSegments: [...], rawSignals: [...] } */
export function fromGoogleTimeline(obj) {
  const out = [];
  for (const s of obj.rawSignals ?? []) {
    const pos = s.position;
    if (!pos) continue;
    const p = point(isoTime(pos.timestamp), parseLatLng(pos.LatLng ?? pos.latLng));
    if (!p) continue;
    if (Number.isFinite(pos.accuracyMeters)) p.acc = pos.accuracyMeters;
    if (Number.isFinite(pos.altitudeMeters)) p.alt = pos.altitudeMeters;
    if (Number.isFinite(pos.speedMetersPerSecond) && pos.speedMetersPerSecond >= 0) p.spd = pos.speedMetersPerSecond;
    out.push(p);
  }
  for (const seg of obj.semanticSegments ?? []) out.push(...fromSemanticSegment(seg));
  return out;
}

/** One semantic segment (shared by the Android and iPhone exports, which differ only in spelling). */
function fromSemanticSegment(seg) {
  const out = [];
  const start = isoTime(seg.startTime), end = isoTime(seg.endTime);
  for (const tp of seg.timelinePath ?? []) {
    const t = tp.time ? isoTime(tp.time)
      : start != null && tp.durationMinutesOffsetFromStartTime != null ? start + Number(tp.durationMinutesOffsetFromStartTime) * 60 : null;
    const p = point(t, parseLatLng(tp.point));
    if (p) out.push(p);
  }
  const visit = seg.visit;
  if (visit) {
    const pl = visit.topCandidate?.placeLocation;
    const ll = parseLatLng(typeof pl === 'string' ? pl : pl?.latLng);
    for (const t of [start, end]) { const p = point(t, ll, { act: 'stationary' }); if (p) out.push(p); }
  }
  const act = seg.activity;
  if (act) {
    const type = googleActivity(act.topCandidate?.type);
    const a = point(start, parseLatLng(typeof act.start === 'string' ? act.start : act.start?.latLng), { act: type });
    const b = point(end, parseLatLng(typeof act.end === 'string' ? act.end : act.end?.latLng), { act: type });
    if (a) out.push(a);
    if (b) out.push(b);
  }
  return out;
}

/** iPhone Google Maps export: a bare array of segments with startTime/endTime. */
export function fromGoogleIOS(arr) {
  return arr.flatMap(fromSemanticSegment);
}

const attr = (tag, name) => { const m = tag.match(new RegExp(`\\b${name}\\s*=\\s*["']([^"']*)["']`)); return m ? m[1] : null; };
const child = (body, name) => { const m = body.match(new RegExp(`<(?:\\w+:)?${name}\\b[^>]*>([\\s\\S]*?)</(?:\\w+:)?${name}>`)); return m ? m[1].trim() : null; };

/** GPX track, route and waypoints that have a <time>. */
export function fromGPX(text) {
  const out = [];
  const re = /<(?:\w+:)?(trkpt|rtept|wpt)\b([^>]*?)(?:\/>|>([\s\S]*?)<\/(?:\w+:)?\1>)/g;
  for (let m; (m = re.exec(text));) {
    const lat = Number(attr(m[2], 'lat')), lon = Number(attr(m[2], 'lon'));
    const body = m[3] ?? '';
    const t = isoTime(child(body, 'time'));
    if (t == null || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    const p = { t, lat, lon };
    const ele = Number(child(body, 'ele'));
    if (child(body, 'ele') !== null && Number.isFinite(ele)) p.alt = ele;
    const spd = Number(child(body, 'speed'));
    if (child(body, 'speed') !== null && Number.isFinite(spd)) p.spd = spd;
    out.push(p);
  }
  return out;
}

/** Recognises the format of already-parsed JSON (or GPX text) and converts it, or returns null. */
export function importForeign(text, parsed) {
  if (parsed === undefined && /^\s*(<\?xml|<gpx)/i.test(text)) return { kind: 'GPX', points: fromGPX(text) };
  if (!parsed || typeof parsed !== 'object') return null;
  if (Array.isArray(parsed.locations)) return { kind: 'Google Takeout (Records.json)', points: fromGoogleRecords(parsed) };
  if (Array.isArray(parsed.semanticSegments) || Array.isArray(parsed.rawSignals)) {
    return { kind: 'Google Maps Timeline', points: fromGoogleTimeline(parsed) };
  }
  if (Array.isArray(parsed) && parsed.length && parsed.some((s) => s && (s.visit || s.activity || s.timelinePath) && s.startTime)) {
    return { kind: 'Google Maps Timeline (iPhone)', points: fromGoogleIOS(parsed) };
  }
  return null;
}

/** Pos XY JSON → GPX 1.1 text (for other apps). */
export function toGPX(points, name = 'Pos XY') {
  const esc = (s) => String(s).replace(/[<>&"']/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[c]);
  const lines = points.map((p) => {
    let inner = '';
    if (p.alt != null) inner += `<ele>${p.alt}</ele>`;
    inner += `<time>${new Date(p.t * 1000).toISOString()}</time>`;
    return `      <trkpt lat="${p.lat}" lon="${p.lon}">${inner}</trkpt>`;
  });
  return `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Pos XY" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>${esc(name)}</name>
    <trkseg>
${lines.join('\n')}
    </trkseg>
  </trk>
</gpx>
`;
}
