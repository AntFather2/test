// Vercel 서버리스 API (모든 /api/* 요청이 이 파일로 들어옴: vercel.json rewrites 참고)
const crypto = require('crypto');
const { Redis } = require('@upstash/redis');

const redis = new Redis({
  url: process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL,
  token: process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN,
});
const DB_KEY = 'admission-db';
const RESULTS = ['합격', '불합격', '예비', '추가합격', '등록', '미발표'];
const SECRET = process.env.SESSION_SECRET || '';
const TOKEN_TTL = 12 * 3600 * 1000;

class HttpError extends Error { constructor(code, msg) { super(msg); this.code = code; } }
const fail = (c, m) => { throw new HttpError(c, m); };

/* ---------- 암호 ---------- */
const hashPw = (salt, pw) => crypto.scryptSync(String(pw), salt, 32).toString('hex');
const newSalt = () => crypto.randomBytes(16).toString('hex');
function safeEq(a, b) {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}
function sign(payload) {
  if (!SECRET) fail(500, '서버 설정 오류: SESSION_SECRET 환경변수가 없습니다.');
  const body = Buffer.from(JSON.stringify({ ...payload, exp: Date.now() + TOKEN_TTL })).toString('base64url');
  return body + '.' + crypto.createHmac('sha256', SECRET).update(body).digest('base64url');
}
function verify(token) {
  if (!token || !SECRET) return null;
  const [body, sig] = String(token).split('.');
  if (!body || !sig) return null;
  const good = crypto.createHmac('sha256', SECRET).update(body).digest('base64url');
  if (!safeEq(sig, good)) return null;
  try {
    const p = JSON.parse(Buffer.from(body, 'base64url').toString());
    return p.exp > Date.now() ? p : null;
  } catch { return null; }
}

/* ---------- DB ---------- */
async function loadDb() {
  let db = await redis.get(DB_KEY);
  if (typeof db === 'string') db = JSON.parse(db);
  if (!db) db = { viewerCode: '', nextId: 1, classes: [], students: [], results: [] };
  if (!db.adminHash) {
    const pw = process.env.ADMIN_PASSWORD;
    if (!pw) fail(500, '서버 설정 오류: ADMIN_PASSWORD 환경변수가 없습니다.');
    db.adminSalt = newSalt(); db.adminHash = hashPw(db.adminSalt, pw);
  }
  return db;
}
const saveDb = (db) => redis.set(DB_KEY, JSON.stringify(db));
const nextId = (db) => db.nextId++;
const pubClass = (c) => ({ id: c.id, grade: c.grade, num: c.num });

function removeStudent(db, sid) {
  db.results = db.results.filter((r) => r.studentId !== sid);
  db.students = db.students.filter((s) => s.id !== sid);
}
function requireClass(s, classId) {
  if (!s) fail(401, '로그인이 필요합니다.');
  if (s.role !== 'admin' && s.classId !== classId) fail(403, '본인 반만 수정할 수 있습니다.');
}
function requireAdmin(s) { if (s.role !== 'admin') fail(403, '관리자 전용입니다.'); }
const str = (v) => (v == null ? '' : String(v));

/* ---------- 라우팅 ---------- */
async function handle(req, route, body) {
  const m = req.method;
  const db = await loadDb();
  const s = verify(req.headers['x-token']);
  const viewOk = () => s || !db.viewerCode || safeEq(req.headers['x-viewer'] || '', db.viewerCode);
  const key = `${m} ${route}`;

  if (key === 'GET info') {
    return { viewerProtected: !!db.viewerCode, classes: db.classes.map(pubClass), results: RESULTS };
  }
  if (key === 'POST login') {
    await new Promise((r) => setTimeout(r, 400));
    if (body.role === 'admin') {
      if (!safeEq(hashPw(db.adminSalt, str(body.password)), db.adminHash)) fail(401, '비밀번호가 올바르지 않습니다.');
      return { token: sign({ role: 'admin', classId: 0 }), role: 'admin' };
    }
    const c = db.classes.find((x) => x.id === Number(body.classId));
    if (!c || !safeEq(hashPw(c.salt, str(body.password)), c.hash)) fail(401, '반 또는 비밀번호가 올바르지 않습니다.');
    return { token: sign({ role: 'teacher', classId: c.id }), role: 'teacher', classId: c.id };
  }
  if (key === 'GET data') {
    if (!viewOk()) fail(401, '열람 코드가 필요합니다.');
    return { classes: db.classes.map(pubClass), students: db.students, results: db.results };
  }
  if (!s) fail(401, '로그인이 필요합니다.');

  switch (key) {
    case 'POST result': {
      const st = db.students.find((x) => x.id === Number(body.studentId));
      if (!st) fail(404, '학생을 찾을 수 없습니다.');
      requireClass(s, st.classId);
      const univ = str(body.univ).trim();
      if (!univ) fail(400, '대학명을 입력하세요.');
      if (!RESULTS.includes(body.result)) fail(400, '결과 값이 올바르지 않습니다.');
      const f = {
        univ, major: str(body.major).trim(), admType: str(body.admType), result: body.result,
        note: str(body.note).trim(), updated: new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 16).replace('T', ' '),
      };
      if (body.id) {
        const r = db.results.find((x) => x.id === Number(body.id));
        if (!r || r.studentId !== st.id) fail(404, '기록을 찾을 수 없습니다.');
        Object.assign(r, f);
      } else db.results.push({ id: nextId(db), studentId: st.id, ...f });
      break;
    }
    case 'POST result/delete': {
      const r = db.results.find((x) => x.id === Number(body.id));
      if (!r) fail(404, '기록을 찾을 수 없습니다.');
      requireClass(s, db.students.find((x) => x.id === r.studentId).classId);
      db.results = db.results.filter((x) => x !== r);
      break;
    }
    case 'POST students': {
      const cid = Number(body.classId);
      requireClass(s, cid);
      if (!db.classes.some((c) => c.id === cid)) fail(404, '반을 찾을 수 없습니다.');
      let max = Math.max(0, ...db.students.filter((x) => x.classId === cid).map((x) => x.no));
      let added = 0;
      for (let line of str(body.text).split(/\r?\n/)) {
        line = line.trim(); if (!line) continue;
        let no, name; const mt = line.match(/^(\d+)[\s,.\t]+(.+)$/);
        if (mt) { no = Number(mt[1]); name = mt[2].trim(); } else { no = ++max; name = line; }
        if (no > max) max = no;
        db.students.push({ id: nextId(db), classId: cid, no, name }); added++;
      }
      await saveDb(db);
      return { added };
    }
    case 'POST student/delete': {
      const st = db.students.find((x) => x.id === Number(body.id));
      if (!st) fail(404, '학생을 찾을 수 없습니다.');
      requireClass(s, st.classId);
      removeStudent(db, st.id);
      break;
    }
    case 'POST admin/class': {
      requireAdmin(s);
      const grade = Number(body.grade), num = Number(body.num);
      if (!(grade >= 1) || !(num >= 1)) fail(400, '학년/반을 확인하세요.');
      if (str(body.password).length < 4) fail(400, '비밀번호는 4자 이상이어야 합니다.');
      if (db.classes.some((c) => c.grade === grade && c.num === num)) fail(409, '이미 있는 반입니다.');
      const salt = newSalt();
      db.classes.push({ id: nextId(db), grade, num, salt, hash: hashPw(salt, str(body.password)) });
      break;
    }
    case 'POST admin/class/password': {
      requireAdmin(s);
      const c = db.classes.find((x) => x.id === Number(body.classId));
      if (!c) fail(404, '반을 찾을 수 없습니다.');
      if (str(body.password).length < 4) fail(400, '비밀번호는 4자 이상이어야 합니다.');
      c.salt = newSalt(); c.hash = hashPw(c.salt, str(body.password));
      break;
    }
    case 'POST admin/class/delete': {
      requireAdmin(s);
      const cid = Number(body.classId);
      db.students.filter((x) => x.classId === cid).forEach((x) => removeStudent(db, x.id));
      db.classes = db.classes.filter((c) => c.id !== cid);
      break;
    }
    case 'POST admin/settings': {
      requireAdmin(s);
      if (body.viewerCode != null) db.viewerCode = str(body.viewerCode);
      if (body.adminPassword) {
        if (str(body.adminPassword).length < 6) fail(400, '관리자 비밀번호는 6자 이상이어야 합니다.');
        db.adminSalt = newSalt(); db.adminHash = hashPw(db.adminSalt, str(body.adminPassword));
      }
      break;
    }
    default: fail(404, '존재하지 않는 요청입니다.');
  }
  await saveDb(db);
  return { ok: true };
}

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  try {
    const route = str(req.query.route).replace(/^\/+|\/+$/g, '');
    let body = req.body;
    if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = {}; } }
    res.status(200).json(await handle(req, route, body || {}));
  } catch (e) {
    if (!(e instanceof HttpError)) console.error(e);
    res.status(e instanceof HttpError ? e.code : 500).json({ error: e instanceof HttpError ? e.message : '서버 오류가 발생했습니다.' });
  }
};
