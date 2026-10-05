import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { open as openFile } from 'k6/experimental/fs';
import { scenario } from 'k6/execution';
import http from 'k6/http';
import { Trend, Counter, Rate } from 'k6/metrics';
import sse from 'k6/x/sse';
import ws from 'k6/ws';
import { loadBaseUrl, recordResult, singleRunOptions } from './common.js';

// 실행 예: k6 run -e CREDENTIALS_FILE=reports/teams-15.credentials.json -e FIXTURE_FILE=reports/fixtures-15-join.json
//          -e COUNT=15 -e AUDIO_DURATION_MS=60000 meeting-flow.js
// 녹음 VU는 팀 1개, SSE VU는 참여자 1명을 맡는다. 두 시나리오가 같은 회의에서 동시에 실행된다.
// 팀원 SSE 연결 확인 → 녹음 시작·오디오 송신·전사 수신 → 종료·수신 결과 검증 → 요약·전사 조회
// 회의 참여(api.js SCENARIO=join)까지 끝난 회의를 사용한다. 녹음 시작은 참여자만 할 수 있기 때문이다.
// AI는 dev의 가짜 공급자(meety_ai.fake_providers)를 전제로 한다. 실제 공급자에 실행하면 요금이 부과된다.
const baseUrl = loadBaseUrl();

// 액세스 토큰 유효 시간이 30분이라 요약 대기가 길어지면 fixture의 토큰이 만료된다.
// 그래서 토큰 대신 prepare-teams.py가 만든 계정 파일로 VU 안에서 로그인한다.
// 회의 ID는 회의 참여 fixture(prepare-join-from-k6.py 출력)의 preparation.teams에서 읽는다.
const credentialsPath = __ENV.CREDENTIALS_FILE;
const fixturePath = __ENV.FIXTURE_FILE;
if (!credentialsPath || !fixturePath) {
  throw new Error('Set CREDENTIALS_FILE (prepare-teams.py output) and FIXTURE_FILE (join fixture)');
}
const teams = new SharedArray('meety-flow', function () {
  const credentials = JSON.parse(open(credentialsPath));
  const joinFixture = JSON.parse(open(fixturePath));
  if (credentials.complete !== true || credentials.baseUrl !== baseUrl || !Array.isArray(credentials.teams)) {
    throw new Error('CREDENTIALS_FILE must be a complete prepare-teams.py output for BASE_URL');
  }
  const preparation = joinFixture.preparation || {};
  if (preparation.complete !== true || preparation.baseUrl !== baseUrl || !Array.isArray(preparation.teams)) {
    throw new Error('FIXTURE_FILE must be a complete join fixture for BASE_URL');
  }
  const meetingIds = {};
  for (const team of preparation.teams) meetingIds[team.teamId] = team.joinMeetingId;
  return credentials.teams.map(function (team) {
    if (!Number.isSafeInteger(meetingIds[team.teamId])) {
      throw new Error(`Join fixture has no meeting for teamId=${team.teamId}`);
    }
    // 첫 번째 계정이 팀을 만든 팀장이며 회의를 녹음하는 사람이다.
    return {
      teamId: team.teamId,
      meetingId: meetingIds[team.teamId],
      members: team.members.map((member) => ({ loginId: member.loginId, password: member.password })),
    };
  });
});

const countText = __ENV.COUNT;
if (!/^[1-9]\d*$/.test(countText || '')) throw new Error('COUNT (number of teams) must be a positive integer');
const count = Number(countText);
if (count > 1000) throw new Error('COUNT must be between 1 and 1000');
if (teams.length < count) throw new Error(`meeting flow needs ${count} teams; found ${teams.length}`);

// 오디오 송신 설정은 audio-ws.js의 audio 모드와 같다. FE도 MediaRecorder를 20ms 간격으로 자른다.
// 가짜 STT도 ffmpeg로 디코딩한 뒤 1초 분량마다 전사 1건을 만들므로 실제 압축 오디오 파일이 필요하다.
const audioFormat = __ENV.AUDIO_FORMAT || 'webm_opus';
if (!['webm_opus', 'mp4_aac'].includes(audioFormat)) throw new Error('AUDIO_FORMAT must be webm_opus or mp4_aac');
const audioDurationMs = Number(__ENV.AUDIO_DURATION_MS);
const intervalMs = Number(__ENV.CHUNK_INTERVAL_MS || 20);
if (!Number.isInteger(intervalMs) || intervalMs < 20 || intervalMs > 1000) throw new Error('CHUNK_INTERVAL_MS must be 20..1000');
if (!Number.isInteger(audioDurationMs) || audioDurationMs < 1000 || audioDurationMs > 3600000) {
  throw new Error('AUDIO_DURATION_MS must be the actual audio length (1000..3600000)');
}
// 파일 저장 공간을 공유하고 녹음 VU만 송신 버퍼를 읽는다. SSE VU에는 오디오 전체를 복제하지 않는다.
const audioHandle = await openFile(__ENV.AUDIO_FILE || './audio.local.webm');
const audioSize = (await audioHandle.stat()).size;
const chunkCount = Math.ceil(audioDurationMs / intervalMs);
if (audioSize === 0) throw new Error('AUDIO_FILE must contain a valid WebM/Opus or MP4/AAC file');
if (Math.ceil(audioSize / chunkCount) > 262144) throw new Error('Audio chunks would exceed the BE 262144-byte limit');

// BE는 요약을 5초마다 5건씩 순서대로 처리한다. 가짜 요약 지연이 15.5초이므로
// 팀 수가 많으면 마지막 팀의 요약까지 수십 분이 걸릴 수 있어 대기 상한을 넉넉히 둔다.
const summaryWaitSeconds = Number(__ENV.SUMMARY_WAIT_SECONDS || 1800);
const summaryPollSeconds = Number(__ENV.SUMMARY_POLL_SECONDS || 5);
if (!Number.isInteger(summaryWaitSeconds) || summaryWaitSeconds < 30 || summaryWaitSeconds > 7200) {
  throw new Error('SUMMARY_WAIT_SECONDS must be 30..7200');
}
if (!Number.isInteger(summaryPollSeconds) || summaryPollSeconds < 1 || summaryPollSeconds > 60) {
  throw new Error('SUMMARY_POLL_SECONDS must be 1..60');
}
// 토큰 유효 시간(30분)보다 일찍 다시 로그인한다.
const RELOGIN_AFTER_MS = 20 * 60 * 1000;

// VU 간 JS 상태는 공유되지 않으므로 로컬 조율 서버에 준비·종료 결과만 전달한다.
// 계정·토큰·전사 본문은 조율 서버로 보내지 않는다. 실행마다 setup()이 새 ID를 만든다.
const coordinationUrl = (__ENV.COORDINATION_URL || 'http://127.0.0.1:8787').replace(/\/$/, '');
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(coordinationUrl)) {
  throw new Error('COORDINATION_URL must be a loopback HTTP URL');
}
function integerSetting(name, fallback, min, max) {
  const value = Number(__ENV[name] === undefined ? fallback : __ENV[name]);
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`${name} must be ${min}..${max}`);
  return value;
}
const readySeconds = integerSetting('SSE_READY_SECONDS', 60, 1, 300);
const drainMs = integerSetting('TRANSCRIPT_DRAIN_MS', 5000, 0, 60000);
const expectedTranscripts = integerSetting('EXPECTED_TRANSCRIPT_COUNT', Math.floor(audioDurationMs / 1000), 1, 100000);
// BE는 완료 이벤트 직후 SSE를 닫고 AI의 마지막 전사는 뒤늦게 확정될 수 있다.
// 실제 STT 지연·디코더 버퍼를 고려한 live 최소 건수와 종료 후 총 건수를 구분한다.
const minimumLiveTranscripts = integerSetting('MIN_LIVE_TRANSCRIPTS',
  Math.max(1, expectedTranscripts - 5), 1, expectedTranscripts);
const participants = new SharedArray('meety-flow-participants', () => {
  const result = [];
  for (let teamIndex = 0; teamIndex < count; teamIndex += 1) {
    if (!teams[teamIndex].members.length) throw new Error('Each team needs at least one member');
    teams[teamIndex].members.forEach((_, memberIndex) => result.push({ teamIndex, memberIndex }));
  }
  return result;
});
const flowTimeout = `${Math.ceil((audioDurationMs + drainMs) / 1000) + summaryWaitSeconds + readySeconds + 240}s`;
export const options = {
  ...singleRunOptions('meeting_flow', count, flowTimeout),
  setupTimeout: '30s', teardownTimeout: '15s',
  scenarios: {
    ...singleRunOptions('meeting_flow', count, flowTimeout).scenarios,
    meeting_participants: {
      executor: 'per-vu-iterations', exec: 'receiveEvents', vus: participants.length,
      iterations: 1, maxDuration: flowTimeout, gracefulStop: '10s',
    },
  },
};
const flowSuccess = new Rate('meety_flow_success');
const sseEvents = new Counter('meety_transcript_sse_events');
const sseHeld = new Trend('meety_sse_held_ms', true);

function coordinate(runId, team, method, body) {
  const response = http.request(method, `${coordinationUrl}/runs/${runId}/teams/${team.teamId}`,
    body ? JSON.stringify(body) : null, {
      headers: { 'Content-Type': 'application/json' }, timeout: '5s', redirects: 0,
      tags: { name: 'local_coordination', operation: 'coordination' },
    });
  if (response.status !== 200) throw new Error(`Local coordinator failed: status=${response.status}`);
  return response.json();
}
export function setup() {
  const response = http.post(`${coordinationUrl}/runs`, JSON.stringify({
    teams: Array.from({ length: count }, (_, index) => ({ id: teams[index].teamId, members: teams[index].members.length })),
  }), { headers: { 'Content-Type': 'application/json' }, timeout: '10s', tags: { name: 'local_coordination', operation: 'coordination' } });
  if (response.status !== 200) throw new Error('Start python3 meeting-flow-coordinator.py before k6');
  return { runId: response.json().runId };
}
export function teardown(data) {
  // 실행이 끝난 조율 상태를 삭제해 다음 시험과 분리한다.
  http.del(`${coordinationUrl}/runs/${data.runId}`, null, {
    timeout: '5s', tags: { name: 'local_coordination', operation: 'coordination' },
  });
}


// 녹음 종료 응답부터 요약 상태가 COMPLETED가 될 때까지 걸린 시간(AI 요약 처리 대기열 포함)이다.
const summaryReadyTime = new Trend('meety_summary_ready_ms', true);
// 녹음 시작 요청부터 녹음 종료 응답까지 회의 한 건의 진행 시간이다.
const meetingDuration = new Trend('meety_meeting_duration_ms', true);

function requestParams(token, operation) {
  const headers = { Accept: 'application/json' };
  // 한 VU가 여러 계정으로 조회하므로 쿠키 jar의 마지막 로그인 토큰을 요청별 토큰으로 교체한다.
  const cookies = token ? { accessToken: { value: token, replace: true } } : {};
  return { headers, cookies, redirects: 0, timeout: '30s', tags: { name: operation, operation } };
}

function jsonData(response) {
  // 응답 본문이 JSON이 아니거나 success=false이면 null을 돌려 실패로 판정한다.
  try {
    const payload = response.json();
    return payload && payload.success === true ? payload.data : null;
  } catch (_) {
    return null;
  }
}

function judge(operation, response, ok) {
  // check는 k6 기본 보고서에, recordResult는 프로젝트별 지표(meety_*)에 단계별 결과를 남긴다.
  check(response, { [`${operation} expected response`]: () => ok }, { operation });
  recordResult(operation, ok, response ? response.status : 200);
  return ok;
}

function fail(team, step, response) {
  // 토큰이나 응답 본문은 남기지 않고 어느 팀이 어느 단계에서 멈췄는지만 기록한다.
  console.warn(`MEETY_FLOW_FAILED teamId=${team.teamId} meetingId=${team.meetingId} step=${step} status=${response ? response.status : 0}`);
}

function loginRequest(member) {
  return {
    method: 'POST',
    url: `${baseUrl}/api/v1/auth/local/login`,
    body: JSON.stringify({ loginId: member.loginId, password: member.password }),
    params: Object.assign(requestParams(null, 'login'), {
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    }),
  };
}

function loginAll(members) {
  // 팀원 로그인을 동시에 보낸다. 하나라도 실패하면 null을 돌려 이후 단계를 진행하지 않는다.
  const responses = http.batch(members.map(loginRequest));
  const tokens = [];
  for (const response of responses) {
    const data = jsonData(response);
    const ok = response.status === 200 && data !== null && typeof data.accessToken === 'string' && data.accessToken !== '';
    judge('login', response, ok);
    if (!ok) return { tokens: null, failed: response };
    tokens.push(data.accessToken);
  }
  return { tokens, failed: null };
}

function sendAudio(team, recordingSessionId, token, audioFile) {
  // audio-ws.js의 audio 모드와 같은 방식으로 파일을 재생 시간에 맞춰 나눠 보낸다.
  // 핸드셰이크는 BE가 AI 연결 준비(READY)를 기다린 뒤에 완료되므로 101 이후 청크는 AI로 전달된다.
  const url = `${baseUrl.replace(/^http/, 'ws')}/ws/v1/recordings/${encodeURIComponent(recordingSessionId)}/audio?audioFormat=${encodeURIComponent(audioFormat)}`;
  // 마지막 청크를 보낸 뒤 BE가 AI로 전달할 시간을 조금 두고 닫는다.
  const holdMs = audioDurationMs + intervalMs + drainMs;
  let openedAt = 0;
  let closedByTest = false;
  let unexpectedClose = false;
  let socketError = false;
  let sentBytes = 0;
  let nextChunk = 0;
  const response = ws.connect(url, {
    headers: { Cookie: `accessToken=${token}` },
    tags: { name: 'audio_ws', operation: 'ws_audio' },
  }, function (socket) {
    socket.on('open', function () {
      openedAt = Date.now();
      socket.setInterval(function () {
        if (nextChunk >= chunkCount) return;
        // 각 바이트가 정확히 한 조각에 들어가도록 파일 전체를 chunkCount개로 나눈다.
        const start = Math.floor(nextChunk * audioFile.byteLength / chunkCount);
        const end = Math.floor((nextChunk + 1) * audioFile.byteLength / chunkCount);
        nextChunk += 1;
        if (end > start) {
          socket.sendBinary(audioFile.slice(start, end));
          sentBytes += end - start;
        }
      }, intervalMs);
      socket.setTimeout(function () {
        closedByTest = true;
        socket.close();
      }, holdMs);
    });
    socket.on('close', function () {
      if (!closedByTest) unexpectedClose = true;
    });
    socket.on('error', function () { socketError = true; });
  });
  const ok = Boolean(response && response.status === 101 && openedAt && !unexpectedClose && !socketError
    && sentBytes === audioFile.byteLength);
  if (!judge('ws_audio', response, ok)) fail(team, 'ws_audio', response);
  return ok;
}

function waitForSummary(team, leader, completedAt) {
  // 요약은 전사 확정 이벤트 뒤에 서버가 자동 등록하므로 등록 전에는 404(SUMMARY_NOT_FOUND)가 온다.
  // 폴링 요청은 summary_poll로 따로 태깅해 팀원 요약 조회(summary_read) 지표와 섞지 않는다.
  const deadline = completedAt + summaryWaitSeconds * 1000;
  let response = null;
  while (Date.now() < deadline) {
    if (Date.now() - leader.loggedInAt > RELOGIN_AFTER_MS) {
      const relogin = loginAll([leader.member]);
      if (!relogin.tokens) {
        fail(team, 'login', relogin.failed);
        return false;
      }
      leader.token = relogin.tokens[0];
      leader.loggedInAt = Date.now();
    }
    response = http.get(`${baseUrl}/api/v1/meetings/${team.meetingId}/summaries`,
      Object.assign(requestParams(leader.token, 'summary_poll'), {
        // 등록 전 404는 대기 상태이며 기본 HTTP 실패율에도 오류로 섞지 않는다.
        responseCallback: http.expectedStatuses(200, 404),
      }));
    const data = response.status === 200 ? jsonData(response) : null;
    if (data && data.status === 'COMPLETED') {
      summaryReadyTime.add(Date.now() - completedAt);
      return judge('summary_wait', response, true);
    }
    if (data && data.status === 'FAILED') {
      console.warn(`MEETY_FLOW_SUMMARY_FAILED teamId=${team.teamId} meetingId=${team.meetingId} reason=${data.failureReason}`);
      break;
    }
    if (response.status !== 200 && response.status !== 404) break;
    sleep(summaryPollSeconds);
  }
  judge('summary_wait', response, false);
  fail(team, 'summary_wait', response);
  return false;
}

function readAll(team, tokens, operation, path, isValid) {
  // 회의가 끝난 뒤 팀원 전원이 결과 화면을 동시에 여는 상황을 재현한다.
  const responses = http.batch(tokens.map((token) => ({
    method: 'GET', url: `${baseUrl}${path}`, params: requestParams(token, operation),
  })));
  let allOk = true;
  for (const response of responses) {
    const data = response.status === 200 ? jsonData(response) : null;
    const ok = data !== null && isValid(data);
    judge(operation, response, ok);
    if (!ok) {
      allOk = false;
      fail(team, operation, response);
    }
  }
  return allOk;
}

// 종료 직전에도 인증을 갱신한다. 한 시간 녹음 뒤 만료 토큰으로 PATCH하지 않는다.
function refreshLeader(leader) {
  if (Date.now() - leader.loggedInAt < RELOGIN_AFTER_MS) return true;
  const result = loginAll([leader.member]);
  if (!result.tokens) return false;
  leader.token = result.tokens[0];
  leader.loggedInAt = Date.now();
  return true;
}

function completeRecording(team, id, leader, operation) {
  if (!refreshLeader(leader)) return false;
  const params = requestParams(leader.token, operation);
  params.headers['Content-Type'] = 'application/json';
  const response = http.patch(`${baseUrl}/api/v1/recordings/${id}`, JSON.stringify({ status: 'COMPLETED' }), params);
  const data = response.status === 200 ? jsonData(response) : null;
  if (judge(operation, response, data !== null && data.status === 'COMPLETED')) return true;
  // PATCH 응답 유실 후 중복 종료를 시도한 경우 실제 상태를 확인한다.
  const current = http.get(`${baseUrl}/api/v1/meetings/${team.meetingId}`, requestParams(leader.token, 'cleanup_state'));
  const meeting = jsonData(current);
  return operation === 'recording_cleanup' && current.status === 200 && meeting && meeting.status === 'COMPLETED';
}

export async function run(data) {
  // iterationInTest는 시나리오별 0부터 시작한다. 전역 VU ID로 SSE 시나리오와 섞지 않는다.
  const team = teams[scenario.iterationInTest];
  let leader = null;
  let recordingSessionId = null;
  let completed = false;
  let success = false;
  try {
    const leaderLogin = loginAll([team.members[0]]);
    if (!leaderLogin.tokens) return fail(team, 'login', leaderLogin.failed);
    leader = { member: team.members[0], token: leaderLogin.tokens[0], loggedInAt: Date.now() };
    const deadline = Date.now() + readySeconds * 1000;
    let ready = false;
    while (Date.now() < deadline) {
      const state = coordinate(data.runId, team, 'GET');
      if (Object.values(state.results).some((ok) => !ok)) break;
      if (state.ready.length === team.members.length) { ready = true; break; }
      sleep(0.2);
    }
    if (!judge('sse_ready', null, ready)) return fail(team, 'sse_ready', null);
    const startedAt = Date.now();
    const response = http.post(`${baseUrl}/api/v1/meetings/${team.meetingId}/recordings`, null,
      requestParams(leader.token, 'recording_start'));
    const started = response.status === 201 ? jsonData(response) : null;
    recordingSessionId = started && Number.isSafeInteger(started.recordingSessionId) ? started.recordingSessionId : null;
    if (!judge('recording_start', response, recordingSessionId !== null)) {
      // 시작 요청이 timeout이어도 서버에서는 생성됐을 수 있으므로 활성 세션을 회수한다.
      const activeResponse = http.get(`${baseUrl}/api/v1/meetings/${team.meetingId}/recording`,
        requestParams(leader.token, 'cleanup_lookup'));
      const active = activeResponse.status === 200 ? jsonData(activeResponse) : null;
      if (active && Number.isSafeInteger(active.recordingSessionId)) recordingSessionId = active.recordingSessionId;
      return fail(team, 'recording_start', response);
    }
    const audioBuffer = new Uint8Array(audioSize);
    let offset = 0;
    while (offset < audioSize) {
      const read = await audioHandle.read(audioBuffer.subarray(offset));
      if (!read) throw new Error('Audio file ended unexpectedly');
      offset += read;
    }
    if (!sendAudio(team, recordingSessionId, leader.token, audioBuffer.buffer)) return;
    completed = completeRecording(team, recordingSessionId, leader, 'recording_complete');
    if (!completed) return fail(team, 'recording_complete', null);
    const completedAt = Date.now();
    meetingDuration.add(completedAt - startedAt);
    // 모든 참여자의 전사 수신·정상 종료·저장 결과 검증을 기다린다.
    const resultDeadline = Date.now() + 90 * 1000;
    let participantsOk = false;
    while (Date.now() < resultDeadline) {
      const state = coordinate(data.runId, team, 'GET');
      if (Object.keys(state.results).length === team.members.length) {
        participantsOk = Object.values(state.results).every(Boolean);
        break;
      }
      sleep(0.2);
    }
    if (!judge('participants_complete', null, participantsOk)) return fail(team, 'participants_complete', null);
    if (!waitForSummary(team, leader, completedAt)) return;
    const membersLogin = loginAll(team.members);
    if (!membersLogin.tokens) return fail(team, 'login', membersLogin.failed);
    const transcriptsOk = readAll(team, membersLogin.tokens, 'transcript_read', `/api/v1/meetings/${team.meetingId}/transcripts`,
      (result) => Array.isArray(result.segments) && result.segments.length === expectedTranscripts);
    const summariesOk = readAll(team, membersLogin.tokens, 'summary_read', `/api/v1/meetings/${team.meetingId}/summaries`,
      (result) => result.status === 'COMPLETED' && typeof result.content === 'string' && result.content.trim() !== '');
    success = transcriptsOk && summariesOk;
  } catch (_) {
    // 예외 메시지에는 요청 내용이 들어갈 수 있으므로 단계 식별자만 기록한다.
    fail(team, 'flow_exception', null);
  } finally {
    if (recordingSessionId !== null && !completed && leader) {
      try {
        completed = completeRecording(team, recordingSessionId, leader, 'recording_cleanup');
        if (!completed) fail(team, 'recording_cleanup', null);
      } catch (_) { fail(team, 'recording_cleanup', null); }
    }
    flowSuccess.add(success);
  }
}

export function receiveEvents(data) {
  const item = participants[scenario.iterationInTest];
  const team = teams[item.teamIndex];
  const member = team.members[item.memberIndex];
  let ok = false;
  try {
    const login = loginAll([member]);
    if (!login.tokens) return fail(team, 'participant_login', login.failed);
    let token = login.tokens[0];
    const loggedInAt = Date.now();
    let openedAt = 0;
    let connected = false;
    let started = false;
    let completedEvent = false;
    let streamError = false;
    const received = new Map();
    const timeoutMs = readySeconds * 1000 + audioDurationMs + drainMs + 120000;
    const response = sse.open(`${baseUrl}/api/v1/meetings/${team.meetingId}/events`, {
      method: 'GET', headers: { Cookie: `accessToken=${token}`, Accept: 'text/event-stream' },
      timeout: `${timeoutMs}ms`, tags: { name: 'meeting_sse', operation: 'sse' },
    }, function (client) {
      client.on('open', () => { openedAt = Date.now(); });
      client.on('event', function (event) {
        // 서버의 comment/heartbeat와 알 수 없는 이벤트는 JSON 본문 검증 대상이 아니다.
        if (!['CONNECTED', 'RECORDING_STARTED', 'TRANSCRIPT_CREATED', 'RECORDING_COMPLETED'].includes(event.name)) return;
        try {
          const payload = JSON.parse(event.data);
          if (payload.meetingId !== team.meetingId) throw new Error('Wrong meeting');
          if (event.name === 'CONNECTED' && !connected) {
            connected = true;
            coordinate(data.runId, team, 'POST', { ready: item.memberIndex });
          } else if (event.name === 'RECORDING_STARTED') {
            started = true;
          } else if (event.name === 'TRANSCRIPT_CREATED') {
            const segment = payload.segment;
            if (!segment || !Number.isSafeInteger(segment.sequenceNumber) || segment.sequenceNumber !== received.size
              || typeof segment.content !== 'string' || !segment.content.trim()) throw new Error('Invalid transcript');
            received.set(segment.sequenceNumber, segment);
            sseEvents.add(1);
            // recognizedAt에는 타임존이 없으므로 서버의 UTC 설정을 가정하지 않고 지연 계산을 생략한다.
          } else if (event.name === 'RECORDING_COMPLETED') {
            completedEvent = true;
            client.close();
          }
        } catch (_) { streamError = true; client.close(); }
      });
      client.on('error', function () { streamError = true; client.close(); });
    });
    if (openedAt) sseHeld.add(Date.now() - openedAt);
    const streamOk = Boolean(response && response.status === 200 && connected && started && completedEvent
      && !streamError && received.size >= minimumLiveTranscripts);
    judge('sse', response, streamOk);
    if (!streamOk) return fail(team, 'sse', response);
    if (Date.now() - loggedInAt >= RELOGIN_AFTER_MS) {
      const relogin = loginAll([member]);
      if (!relogin.tokens) return fail(team, 'participant_relogin', relogin.failed);
      token = relogin.tokens[0];
    }
    const result = http.get(`${baseUrl}/api/v1/meetings/${team.meetingId}/transcripts`, requestParams(token, 'sse_transcript_verify'));
    const stored = result.status === 200 ? jsonData(result) : null;
    // SSE가 먼저 닫힌 뒤 최종 전사가 저장될 수 있다. 수신한 각 전사가 DB 조회 결과와 일치하는지 검사한다.
    const matches = stored && Array.isArray(stored.segments) && Array.from(received.values()).every((segment) =>
      stored.segments.some((entry) => entry.segmentId === segment.id && entry.sequenceNumber === segment.sequenceNumber
        && entry.content === segment.content && entry.startedAtMs === segment.startedAtMs && entry.endedAtMs === segment.endedAtMs));
    ok = judge('sse_transcript_verify', result, Boolean(matches));
  } catch (_) { fail(team, 'participant_exception', null); }
  finally {
    try { coordinate(data.runId, team, 'POST', { member: item.memberIndex, ok }); }
    catch (_) { judge('coordination_result', null, false); }
  }
}
