import http from 'k6/http';
import ws from 'k6/ws';
import exec from 'k6/execution';
import { sleep } from 'k6';
import { Counter } from 'k6/metrics';
import { loadBaseUrl } from '../load-test/common.js';
import { audioFrame } from '../load-test/audio-protocol.js';

// DB 이전 테스트 동안 실시간 회의를 일정한 간격으로 시작한다.
// 회의 하나: 회의 생성 → 참여 → 녹음 시작 → 오디오 실시간 송신 → 일시정지 → 재개 → 송신 끝 → 녹음 종료
// 회의가 겹쳐 진행되므로 전환 순간에 시작, 녹음 중, 일시정지, 재개, 종료 단계가 섞인다.
// 요청과 WebSocket 결과를 한 줄 JSON으로 남기고, verify.py가 서울 DB의 회의 상태, 전사 수와 대조한다.
// AI는 dev의 가짜 공급자(오디오 1초마다 전사 1건)를 전제로 한다. 실제 공급자에 실행하면 요금이 부과된다.
// 사용법은 README.md 참고.

const RUN_ID = __ENV.RUN_ID || '';
if (!/^[a-z0-9]{4,6}$/.test(RUN_ID)) {
  // 회의 목적(purpose), 계정·팀 이름(10자 제한)에 들어가므로 짧은 소문자·숫자만 허용한다.
  throw new Error('RUN_ID는 소문자·숫자 4~6자여야 합니다 (예: l1018a)');
}
const BASE_URL = loadBaseUrl();
// BE가 인증 토큰을 읽는 쿠키 이름 (dev는 dev_accessToken). 녹음 WebSocket도 같은 쿠키로 인증한다
const COOKIE_NAME = __ENV.COOKIE_NAME || 'dev_accessToken';
if (!/^[A-Za-z0-9_]+$/.test(COOKIE_NAME)) throw new Error('COOKIE_NAME은 영문, 숫자, _만 허용합니다');

// 회의 시작 간격. 동시 회의 수 ≈ 회의 한 개 시간(LIFECYCLE_MS) ÷ 간격이므로, 동시 100개 근처는 INTERVAL_MS=1150 정도를 준다.
// INTERVAL_MS가 없으면 기존처럼 INTERVAL_S(초)를 쓴다.
const INTERVAL_MS = __ENV.INTERVAL_MS !== undefined
  ? intSetting('INTERVAL_MS', 20000, 500, 600000)
  : intSetting('INTERVAL_S', 20, 5, 600) * 1000;
const DURATION = __ENV.DURATION || '8m';                            // 새 회의를 시작하는 기간
const AUDIO_DURATION_MS = intSetting('AUDIO_DURATION_MS', 60000, 1000, 600000);  // 오디오 파일 실제 길이
const CHUNK_INTERVAL_MS = intSetting('CHUNK_INTERVAL_MS', 250, 20, 1000);       // 오디오 조각 간격 (FE는 20ms)
const PAUSE_AT_MS = intSetting('PAUSE_AT_MS', 20000, 0, AUDIO_DURATION_MS);     // 오디오를 이만큼 보낸 뒤 일시정지
// 공개 API/오디오 WS에는 AI의 PAUSED 완료 신호가 없어 응답 이후의 여유 시간으로 제어한다.
const PAUSE_MS = intSetting('PAUSE_MS', 30000, 0, 600000);                      // 일시정지 응답 후 대기 시간
const RESUME_SETTLE_MS = intSetting('RESUME_SETTLE_MS', 3000, 0, 60000);        // 재개 응답 후 오디오 송신까지 여유
const DRAIN_MS = intSetting('DRAIN_MS', 3000, 0, 60000);   // 마지막 조각 뒤 종료 요청까지 기다리는 시간 (전사 전달 여유)
// k6는 이 초기화 코드를 VU마다 따로 실행하므로, 무작위 비밀번호는 setup()에서 정한 값을 data로 넘겨 쓴다
const PASSWORD = __ENV.MIG_PASSWORD || `Mig!${RUN_ID}${Math.random().toString(36).slice(2, 10)}`;
const REQUEST_TIMEOUT = '45s';   // 서비스 요청이 이 제한 안에 끝나지 않으면 전환 실패로 기록한다.

// PCM 전송을 WebM 파일로 실행하지 않도록 원시 오디오 경로를 명시하게 한다.
if (!__ENV.AUDIO_FILE) throw new Error('AUDIO_FILE에 16kHz·모노·s16le 원시 PCM 파일을 지정하세요');
const AUDIO = open(__ENV.AUDIO_FILE, 'b');
const CHUNK_COUNT = Math.ceil(AUDIO_DURATION_MS / CHUNK_INTERVAL_MS);
const PAUSE_AT_CHUNK = Math.floor(PAUSE_AT_MS / CHUNK_INTERVAL_MS);
if (AUDIO.byteLength === 0) throw new Error('AUDIO_FILE이 비어 있습니다');
if (Math.ceil(AUDIO.byteLength / CHUNK_COUNT) > 262144) throw new Error('오디오 조각이 BE 한도(262144바이트)를 넘습니다');

// 회의 하나가 끝날 때까지의 대략적인 시간. 같은 팀의 회의가 겹치지 않도록 팀 수를 정할 때 쓴다
const LIFECYCLE_MS = AUDIO_DURATION_MS + PAUSE_MS + RESUME_SETTLE_MS + DRAIN_MS + 15000;
const TEAM_COUNT = Math.ceil(LIFECYCLE_MS / INTERVAL_MS) + 2;
const TOTAL_MEETINGS = Math.ceil(durationSeconds(DURATION) * 1000 / INTERVAL_MS);
// 팀별 하루 회의 생성 제한(dev 100)
if (Math.ceil(TOTAL_MEETINGS / TEAM_COUNT) > 90) throw new Error('팀당 회의 수가 90개를 넘습니다. INTERVAL_MS나 DURATION을 조정하세요');

// FE와 같은 재연결 정책: 예상치 않게 끊기면 즉시, 4초 뒤 두 번까지 다시 연결하고, 모두 실패하면 녹음을 종료한다
const RECONNECT_DELAYS_MS = [0, 4000];
// BE가 녹음 종료 때 닫는 코드 (FE의 CLOSE_CODE_COMPLETED)와 새 연결로 대체될 때 코드
const CLOSE_NORMAL = 1000;
const CLOSE_SUPERSEDED = 4001;

const liveFailures = new Counter('live_op_failures');

export const options = {
  // 동시 회의 100개 근처면 계정·팀을 100개 넘게 순서대로 준비한다 (계정당 약 1초)
  setupTimeout: '10m',
  thresholds: { live_op_failures: ['count==0'], dropped_iterations: ['count==0'] },
  scenarios: {
    meetings: {
      executor: 'constant-arrival-rate',
      rate: 1,
      timeUnit: `${INTERVAL_MS}ms`,
      duration: DURATION,
      preAllocatedVUs: TEAM_COUNT,
      maxVUs: TEAM_COUNT * 2,
      // 시작한 회의는 끝까지 진행되도록 기다린다
      gracefulStop: `${Math.ceil(LIFECYCLE_MS / 1000) + 60}s`,
    },
  },
};

export function setup() {
  const accounts = [];
  for (let i = 1; i <= TEAM_COUNT; i += 1) {
    const loginId = `lv-${RUN_ID}-${String(i).padStart(2, '0')}`;
    signup(loginId, PASSWORD);
    const token = login(loginId, PASSWORD).token;
    if (!token) throw new Error(`${loginId} 로그인 실패`);
    const teamId = createOrFindTeam(token, i);
    accounts.push({ loginId, teamId, teamMemberId: findTeamMemberId(token, teamId) });
  }
  log({ op: 'setup', accounts: accounts.length, totalMeetings: TOTAL_MEETINGS, chunkCount: CHUNK_COUNT });
  return { accounts, password: PASSWORD };
}

export default function (data) {
  const seq = exec.scenario.iterationInTest;
  const account = data.accounts[seq % data.accounts.length];
  const state = { seq, meetingId: null, recordingSessionId: null };

  // 회의마다 새로 로그인한다. 토큰 만료(30분)를 신경 쓰지 않아도 되고, 로그인 실패도 전환 영향으로 기록된다
  const auth = login(account.loginId, data.password);
  record(state, 'login', auth.result);
  if (!auth.token) return;
  const token = auth.token;

  const created = call(state, token, 'm_create', 'POST', `/api/v1/teams/${account.teamId}/meetings`, {
    title: `L${String(seq).padStart(6, '0')}`,
    purpose: `live-${RUN_ID}-${String(seq).padStart(6, '0')}`,
    note: '',
    scheduledAt: currentKstLocalDateTime(),
    targetDurationMinutes: 10,
    attendeeTeamMemberIds: [account.teamMemberId],
    customAttendeeNames: [],
  }, 201);
  if (!created.ok) return;
  state.meetingId = created.data.meetingId;

  // 녹음은 참여자만 시작할 수 있다
  if (!call(state, token, 'join', 'POST', `/api/v1/meetings/${state.meetingId}/participants`, null, 201).ok) return;

  const started = call(state, token, 'rec_start', 'POST', `/api/v1/meetings/${state.meetingId}/recordings`, null, 201);
  if (!started.ok) return;
  state.recordingSessionId = started.data.recordingSessionId;

  const stream = streamAudio(state, token);

  // 녹음이 아직 끝나지 않았으면 (재연결 포기, 예외 등) FE처럼 종료 요청을 보낸다
  if (!stream.completed) {
    complete(state, token, stream, 'rec_complete_cleanup');
  }
  log({
    op: 'meeting_done', seq, meetingId: state.meetingId, recordingSessionId: state.recordingSessionId,
    completed: stream.completed, chunkCount: CHUNK_COUNT, sentSeq: stream.sentSeq, maxAck: stream.maxAck,
    connects: stream.connects, unexpectedCloses: stream.unexpectedCloses, gaveUp: stream.gaveUp,
    paused: stream.pauseOk, resumed: stream.resumeOk,
  });
}

// 녹음 WebSocket으로 오디오를 보낸다. 일시정지, 재개, 종료 요청도 이 안에서 보낸다.
// 예상치 않게 끊기면 FE처럼 다시 연결하고, 서버가 알려 준 마지막 처리 순번 뒤의 조각부터 다시 보낸다.
function streamAudio(state, token) {
  const url = `${BASE_URL.replace(/^http/, 'ws')}/ws/v1/recordings/${state.recordingSessionId}/audio?audioFormat=pcm_s16le`;
  // 재개, 오디오 재송신, 종료는 예정 시각으로 관리한다.
  // 연결이 끊겨 다시 연결해도 예정 시각이 남아 있어 일시정지 상태로 멈추지 않는다
  const s = {
    sentSeq: 0,          // 마지막으로 보낸 조각 순번 (1부터)
    maxAck: 0,           // 서버가 확인한 마지막 순번
    paused: false, pauseDone: false, resumeAt: 0, audioResumeAt: 0, pauseOk: null, resumeOk: null,
    completeAt: 0, completed: false, completing: false,
    connects: 0, unexpectedCloses: 0, gaveUp: false,
  };

  for (let attempt = 0; ; attempt += 1) {
    s.connects += 1;
    let closedExpectedly = false;
    let ready = false;
    let closeCode = null;
    const startedAt = Date.now();
    const res = ws.connect(url, { headers: { Cookie: `${COOKIE_NAME}=${token}` }, tags: { op: 'ws' } }, function (socket) {
      socket.on('message', function (raw) {
        let msg;
        try { msg = JSON.parse(raw); } catch (_) { return; }
        if (msg.type === 'recovery.start') {
          // 서버가 처리한 순번 뒤의 조각을 다시 보낸다. 새 연결이면 0이라 보낼 것이 없다
          const from = Number(msg.lastProcessedSequence) || 0;
          for (let n = from + 1; n <= s.sentSeq; n += 1) socket.sendBinary(frameOf(n));
          socket.send(JSON.stringify({ type: 'recovery.finished', lastSequence: s.sentSeq }));
        } else if (msg.type === 'stream.ready') {
          ready = true;
          log({ op: 'ws_ready', seq: state.seq, meetingId: state.meetingId, attempt, startedAt, ms: Date.now() - startedAt, resumeFrom: s.sentSeq });
        } else if (msg.type === 'ack' && Number.isSafeInteger(msg.seq)) {
          if (msg.seq > s.maxAck) s.maxAck = msg.seq;
        }
      });

      socket.setInterval(function () {
        if (!ready || s.completing || s.completed) return;
        const now = Date.now();
        if (s.paused) {
          if (now < s.resumeAt) return;
          // HTTP 200이 AI의 READY를 뜻하지 않으므로 응답 뒤 별도의 여유를 둔다.
          s.resumeOk = call(state, token, 'resume', 'PATCH', `/api/v1/recordings/${state.recordingSessionId}`, { status: 'RECORDING' }, 200).ok;
          s.audioResumeAt = Date.now() + RESUME_SETTLE_MS;
          s.paused = false;
          log({ op: 'resume_wait', seq: state.seq, recordingSessionId: state.recordingSessionId, audioResumeAt: s.audioResumeAt, settleMs: RESUME_SETTLE_MS });
          return;
        }
        if (now < s.audioResumeAt) return;
        if (!s.pauseDone && s.sentSeq === PAUSE_AT_CHUNK && PAUSE_MS > 0) {
          // 일시정지: FE처럼 오디오 송신을 멈추고 상태를 바꾼다
          s.pauseDone = true;
          s.paused = true;
          s.pauseOk = call(state, token, 'pause', 'PATCH', `/api/v1/recordings/${state.recordingSessionId}`, { status: 'PAUSED' }, 200).ok;
          // DB 대기로 요청이 오래 걸려도 실제 응답 후의 대기 시간이 짧아지지 않게 한다.
          s.resumeAt = Date.now() + PAUSE_MS;
          log({ op: 'pause_wait', seq: state.seq, recordingSessionId: state.recordingSessionId, resumeAt: s.resumeAt, pauseMs: PAUSE_MS });
          return;
        }
        if (s.sentSeq < CHUNK_COUNT) {
          s.sentSeq += 1;
          socket.sendBinary(frameOf(s.sentSeq));
          if (s.sentSeq === CHUNK_COUNT) s.completeAt = now + DRAIN_MS;   // 전사가 전달될 시간을 두고 종료
          return;
        }
        if (now >= s.completeAt) {
          s.completing = true;
          complete(state, token, s, 'rec_complete');
          closedExpectedly = true;
          // 정상 종료면 서버가 연결을 닫는다. 닫지 않으면 10초 뒤 직접 닫는다
          socket.setTimeout(function () { socket.close(); }, 10000);
        }
      }, CHUNK_INTERVAL_MS);

      socket.on('close', function (code) { closeCode = code; });
      socket.on('error', function () {});
    });

    const status = res ? res.status : 0;
    if (status !== 101) {
      record(state, 'ws_connect', { ok: false, status, startedAt, ms: Date.now() - startedAt, error: res ? res.error : 'no response' });
    }
    const expected = closedExpectedly || s.completed || closeCode === CLOSE_NORMAL && s.completing;
    log({
      op: 'ws_close', seq: state.seq, meetingId: state.meetingId, attempt, startedAt, ms: Date.now() - startedAt,
      code: closeCode, connected: status === 101, ready, expected, sentSeq: s.sentSeq, maxAck: s.maxAck,
    });
    if (expected) return s;
    if (closeCode === CLOSE_SUPERSEDED) return s;   // 다른 연결이 이어받았다 (이 테스트에서는 생기지 않아야 한다)

    s.unexpectedCloses += 1;
    if (attempt >= RECONNECT_DELAYS_MS.length) {
      s.gaveUp = true;   // FE는 두 번 실패하면 녹음을 종료한다 (호출부에서 종료 요청)
      return s;
    }
    sleep(RECONNECT_DELAYS_MS[attempt] / 1000);
  }
}

function complete(state, token, s, op) {
  const res = call(state, token, op, 'PATCH', `/api/v1/recordings/${state.recordingSessionId}`, { status: 'COMPLETED' }, 200);
  s.completed = res.ok || s.completed;
  return res;
}

// 오디오 파일 전체를 CHUNK_COUNT개로 나눈 n번째 조각 (1부터). 재전송 때도 같은 내용이 나온다
function frameOf(n) {
  const start = Math.floor((n - 1) * AUDIO.byteLength / CHUNK_COUNT);
  const end = Math.floor(n * AUDIO.byteLength / CHUNK_COUNT);
  return audioFrame(AUDIO.slice(start, end), n);
}

function call(state, token, op, method, path, body, expectStatus) {
  const startedAt = Date.now();
  const res = http.request(method, `${BASE_URL}${path}`, body === null ? null : JSON.stringify(body), {
    headers: { Cookie: `${COOKIE_NAME}=${token}`, 'Content-Type': 'application/json' },
    timeout: REQUEST_TIMEOUT,
    tags: { op },
  });
  const parsed = parse(res);
  const result = {
    ok: res.status === expectStatus, status: res.status, startedAt, ms: res.timings.duration,
    error: res.error || null, data: parsed && parsed.data ? parsed.data : null,
  };
  record(state, op, result);
  return result;
}

function record(state, op, result) {
  liveFailures.add(result.ok ? 0 : 1, { op });
  log({
    op, seq: state.seq, meetingId: state.meetingId, recordingSessionId: state.recordingSessionId,
    status: result.status, ok: result.ok, startedAt: result.startedAt, ms: Math.round(result.ms),
    // 상태 코드 0은 응답을 받지 못한 경우(타임아웃, 연결 실패)다
    error: result.error,
  });
}

function log(entry) {
  // --log-format raw로 실행하면 이 JSON 한 줄만 그대로 파일에 남는다. write-load.js 기록과 구분하려고 kind를 붙인다
  console.log(JSON.stringify({ run: RUN_ID, kind: 'live', ...entry }));
}

function signup(loginId, password) {
  // 이미 있는 계정(같은 RUN_ID로 다시 실행)이면 409를 받고 로그인으로 넘어간다
  http.post(`${BASE_URL}/api/v1/auth/local/signup`, JSON.stringify({ loginId, password }),
    { headers: { 'Content-Type': 'application/json' }, timeout: REQUEST_TIMEOUT });
}

function login(loginId, password) {
  const startedAt = Date.now();
  const res = http.post(`${BASE_URL}/api/v1/auth/local/login`, JSON.stringify({ loginId, password }),
    { headers: { 'Content-Type': 'application/json' }, timeout: REQUEST_TIMEOUT, tags: { op: 'login' } });
  const body = parse(res);
  const token = res.status === 200 && body && body.data ? body.data.accessToken : null;
  return { token, result: { ok: !!token, status: res.status, startedAt, ms: res.timings.duration, error: res.error || null } };
}

function findTeamMemberId(token, teamId) {
  const res = http.get(`${BASE_URL}/api/v1/teams/${teamId}/members`,
    { headers: { Cookie: `${COOKIE_NAME}=${token}` }, timeout: REQUEST_TIMEOUT });
  const body = parse(res);
  const members = res.status === 200 && body && body.data ? body.data.members : null;
  if (!Array.isArray(members) || members.length === 0 || !Number.isSafeInteger(members[0].teamMemberId)) {
    throw new Error(`팀 ${teamId} 팀원 조회 실패: HTTP ${res.status}`);
  }
  return members[0].teamMemberId;
}

function createOrFindTeam(token, index) {
  const headers = { Cookie: `${COOKIE_NAME}=${token}`, 'Content-Type': 'application/json' };
  // 팀 이름과 표시 이름은 한글·영문·숫자 2~10자만 허용된다
  const res = http.post(`${BASE_URL}/api/v1/teams`,
    JSON.stringify({ name: `L${RUN_ID}${index}`, displayName: `Live${index}` }), { headers, timeout: REQUEST_TIMEOUT });
  let body = parse(res);
  if (res.status === 201 && body && body.data) return body.data.teamId;
  const mine = http.get(`${BASE_URL}/api/v1/teams/me`, { headers, timeout: REQUEST_TIMEOUT });
  body = parse(mine);
  if (mine.status === 200 && body && body.data && body.data.hasActiveTeam) return body.data.teamId;
  throw new Error(`계정 ${index} 팀 준비 실패: 생성 HTTP ${res.status}, 조회 HTTP ${mine.status}`);
}

function parse(res) {
  try { return res.body ? JSON.parse(res.body) : null; } catch (_) { return null; }
}

function intSetting(name, fallback, min, max) {
  const value = __ENV[name] === undefined ? fallback : Number(__ENV[name]);
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`${name}는 ${min}..${max} 정수여야 합니다`);
  return value;
}

function currentKstLocalDateTime() {
  // 사전 준비 요청 없이 바로 시작하도록 시간대 없는 KST 예정 시각을 1분 전으로 보낸다.
  return new Date(Date.now() + 9 * 60 * 60 * 1000 - 60 * 1000).toISOString().slice(0, 19);
}

function durationSeconds(text) {
  const match = /^(\d+)(s|m|h)$/.exec(text);
  if (!match) throw new Error('DURATION은 90s, 8m, 1h 형식이어야 합니다');
  return Number(match[1]) * { s: 1, m: 60, h: 3600 }[match[2]];
}
