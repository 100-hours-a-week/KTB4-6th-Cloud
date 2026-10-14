import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { loadBaseUrl } from '../load-test/common.js';

// DB 이전 리허설 동안 회의 생성 → 수정 → 삭제를 일정한 속도로 반복한다.
// 요청마다 결과를 한 줄 JSON으로 남기고, 전환 후 verify.py가 서울 DB와 대조한다.
// 사용법은 README.md 참고.

const RUN_ID = __ENV.RUN_ID || '';
if (!/^[a-z0-9]{4,6}$/.test(RUN_ID)) {
  // 회의 목적(purpose), 계정·팀 이름(10자 제한)에 들어가므로 짧은 소문자·숫자만 허용한다.
  throw new Error('RUN_ID는 소문자·숫자 4~6자여야 합니다 (예: r1013a)');
}
const BASE_URL = loadBaseUrl();
// 초당 시작할 회의 사이클 수. 전환 구간에 요청이 끊기지 않을 정도면 충분하다.
const RATE = positiveInt('RATE', 2);
const DURATION = __ENV.DURATION || '20m';
// 팀별 하루 회의 생성 제한(dev 100, 삭제한 회의도 포함)보다 여유를 두고 팀을 넘긴다.
const PER_TEAM = positiveInt('PER_TEAM', 90);
const PASSWORD = __ENV.MIG_PASSWORD || `Mig!${RUN_ID}${Math.random().toString(36).slice(2, 10)}`;

const TOTAL_CYCLES = RATE * durationSeconds(DURATION);
const ACCOUNT_COUNT = Math.ceil(TOTAL_CYCLES / PER_TEAM);
if (ACCOUNT_COUNT > 50) {
  throw new Error(`계정 ${ACCOUNT_COUNT}개가 필요합니다. RATE나 DURATION을 줄이세요 (최대 50개)`);
}

// 게이트 대기(최대 30초)와 리전 간 지연을 넉넉히 넘기도록 잡는다. ALB 유휴 타임아웃(60초)보다는 짧게 둔다.
const REQUEST_TIMEOUT = '45s';

const opDuration = new Trend('mig_op_duration', true);
const opFailures = new Counter('mig_op_failures');

export const options = {
  setupTimeout: '5m',
  scenarios: {
    writes: {
      // 응답이 늦어져도 정해진 속도로 새 사이클을 시작해, 전환 구간에도 요청이 계속 들어가게 한다.
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(10, RATE * 10),
      // 사이클 하나가 게이트 대기로 30초 이상 걸릴 수 있어 그만큼 VU를 더 허용한다.
      maxVUs: Math.max(50, RATE * 40),
    },
  },
  // 합격 기준은 verify.py 결과로 판단한다. 여기서는 threshold를 두지 않는다.
};

export function setup() {
  // 계정마다 팀 1개를 만든다. 같은 RUN_ID로 다시 실행하면 기존 계정과 팀을 그대로 쓴다.
  const accounts = [];
  for (let i = 1; i <= ACCOUNT_COUNT; i += 1) {
    const loginId = `mig-${RUN_ID}-${String(i).padStart(2, '0')}`;
    const token = signupOrLogin(loginId);
    const teamId = createOrFindTeam(token, i);
    accounts.push({ loginId, teamId, token });
  }
  log({ op: 'setup', accounts: accounts.length, totalCycles: TOTAL_CYCLES });
  return { accounts, password: PASSWORD };
}

// VU마다 갱신한 토큰을 기억한다. access token(30분)이 테스트 중에 만료되면 다시 로그인한다.
const refreshedTokens = {};

export default function (data) {
  const seq = exec.scenario.iterationInTest;
  const account = data.accounts[Math.min(Math.floor(seq / PER_TEAM), data.accounts.length - 1)];
  const tag = `mig-${RUN_ID}-${String(seq).padStart(6, '0')}`;
  // 세 가지 최종 상태(생성만, 수정까지, 삭제까지)를 고르게 만든다.
  const lastStep = ['create', 'patch', 'delete'][seq % 3];

  const created = call(account, data, seq, 'create', 'POST', `/api/v1/teams/${account.teamId}/meetings`, {
    title: `M${String(seq).padStart(6, '0')}`,
    purpose: tag,
    note: `c-${seq}`,
    targetDurationMinutes: 30,
  });
  const meetingId = created.ok ? created.body.data.meetingId : null;
  if (!meetingId || lastStep === 'create') return;

  const patched = call(account, data, seq, 'patch', 'PATCH', `/api/v1/meetings/${meetingId}`, { note: `u-${seq}` }, meetingId);
  if (!patched.ok || lastStep === 'patch') return;

  call(account, data, seq, 'delete', 'DELETE', `/api/v1/meetings/${meetingId}`, null, meetingId);
}

const EXPECTED_STATUS = { create: 201, patch: 200, delete: 204, relogin: 200 };

function call(account, data, seq, op, method, path, body, meetingId = null) {
  let result = send(account, op, method, path, body);
  if (result.status === 401) {
    // 만료된 토큰으로 실패한 요청은 기록하고, 재로그인 후 한 번만 다시 보낸다.
    record(seq, op, meetingId, result);
    if (!relogin(account, data, seq)) return result;
    result = send(account, op, method, path, body);
  }
  record(seq, op, meetingId || (result.ok && op === 'create' ? result.body.data.meetingId : null), result);
  return result;
}

function send(account, op, method, path, body) {
  const token = refreshedTokens[account.loginId] || account.token;
  const startedAt = Date.now();
  const res = http.request(method, `${BASE_URL}${path}`, body === null ? null : JSON.stringify(body), {
    headers: { Cookie: `accessToken=${token}`, 'Content-Type': 'application/json' },
    timeout: REQUEST_TIMEOUT,
    tags: { op },
  });
  const ok = res.status === EXPECTED_STATUS[op];
  return { ok, status: res.status, startedAt, ms: res.timings.duration, error: res.error || null, body: parse(res) };
}

function relogin(account, data, seq) {
  const startedAt = Date.now();
  const res = http.post(`${BASE_URL}/api/v1/auth/local/login`,
    JSON.stringify({ loginId: account.loginId, password: data.password }),
    { headers: { 'Content-Type': 'application/json' }, timeout: REQUEST_TIMEOUT, tags: { op: 'relogin' } });
  const body = parse(res);
  const ok = res.status === 200 && body && body.data && body.data.accessToken;
  record(seq, 'relogin', null, { ok: !!ok, status: res.status, startedAt, ms: res.timings.duration, error: res.error || null });
  if (ok) refreshedTokens[account.loginId] = body.data.accessToken;
  return !!ok;
}

function record(seq, op, meetingId, result) {
  opDuration.add(result.ms, { op });
  if (!result.ok) opFailures.add(1, { op });
  log({
    op,
    seq,
    meetingId,
    status: result.status,
    ok: result.ok,
    startedAt: result.startedAt,
    ms: Math.round(result.ms),
    // 상태 코드 0은 응답을 받지 못한 경우(타임아웃, 연결 실패)다.
    error: result.error,
  });
}

function log(entry) {
  // --log-format raw로 실행하면 이 JSON 한 줄만 그대로 파일에 남는다.
  console.log(JSON.stringify({ run: RUN_ID, ...entry }));
}

function signupOrLogin(loginId) {
  let res = http.post(`${BASE_URL}/api/v1/auth/local/signup`, JSON.stringify({ loginId, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' }, timeout: REQUEST_TIMEOUT });
  if (res.status === 409) {
    // 같은 RUN_ID로 다시 실행한 경우다. MIG_PASSWORD를 처음과 같게 줘야 로그인된다.
    res = http.post(`${BASE_URL}/api/v1/auth/local/login`, JSON.stringify({ loginId, password: PASSWORD }),
      { headers: { 'Content-Type': 'application/json' }, timeout: REQUEST_TIMEOUT });
  }
  const body = parse(res);
  if (![200, 201].includes(res.status) || !body || !body.data || !body.data.accessToken) {
    throw new Error(`${loginId} 인증 실패: HTTP ${res.status}`);
  }
  return body.data.accessToken;
}

function createOrFindTeam(token, index) {
  const headers = { Cookie: `accessToken=${token}`, 'Content-Type': 'application/json' };
  // 팀 이름과 표시 이름은 한글·영문·숫자 2~10자만 허용된다.
  const res = http.post(`${BASE_URL}/api/v1/teams`,
    JSON.stringify({ name: `M${RUN_ID}${index}`, displayName: `Mig${index}` }),
    { headers, timeout: REQUEST_TIMEOUT });
  let body = parse(res);
  if (res.status === 201 && body && body.data) return body.data.teamId;

  // 이미 팀이 있는 계정이면 그 팀을 쓴다.
  const mine = http.get(`${BASE_URL}/api/v1/teams/me`, { headers, timeout: REQUEST_TIMEOUT });
  body = parse(mine);
  if (mine.status === 200 && body && body.data && body.data.hasActiveTeam) return body.data.teamId;
  throw new Error(`계정 ${index} 팀 준비 실패: 생성 HTTP ${res.status}, 조회 HTTP ${mine.status}`);
}

function parse(res) {
  try {
    return res.body ? JSON.parse(res.body) : null;
  } catch (e) {
    return null;
  }
}

function positiveInt(name, fallback) {
  const text = __ENV[name];
  if (text === undefined) return fallback;
  if (!/^[1-9]\d*$/.test(text)) throw new Error(`${name}는 1 이상의 정수여야 합니다`);
  return Number(text);
}

function durationSeconds(text) {
  const match = /^(\d+)(s|m|h)$/.exec(text);
  if (!match) throw new Error('DURATION은 90s, 20m, 1h 형식이어야 합니다');
  return Number(match[1]) * { s: 1, m: 60, h: 3600 }[match[2]];
}
