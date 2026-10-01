import { check } from 'k6';
import ws from 'k6/ws';
import { cookieHeader, fixtureForVu, loadConfig, recordResult, singleRunOptions } from './common.js';

// WebSocket 시험은 두 모드가 있다.
// connect: 연결만 열어 HOLD_MS 동안 유지한다.
// audio: 유효한 압축 오디오 파일을 실제 재생 시간에 맞춰 나누어 한 번 송신한다.
// 두 모드 모두 VU 1개가 녹음 세션 1개를 담당한다.
const config = loadConfig('ws');
const recordingIds = new Set();
// 같은 녹음 세션에 여러 VU가 접속하면 동시 접속 정책 때문에 시험 결과가 왜곡된다.
for (let i = 0; i < config.count; i += 1) {
  const item = config.fixtures[i];
  if (!item.recordingSessionId || !item.audioFormat || item.audioFormat.startsWith('REPLACE_')) {
    throw new Error(`WS fixture ${i + 1} needs recordingSessionId and actual audioFormat`);
  }
  if (recordingIds.has(String(item.recordingSessionId))) {
    throw new Error(`Duplicate recordingSessionId in WS fixtures: ${item.recordingSessionId}`);
  }
  recordingIds.add(String(item.recordingSessionId));
}
const mode = __ENV.WS_MODE || 'connect';
if (!['connect', 'audio'].includes(mode)) throw new Error('WS_MODE must be connect or audio');
// CHUNK_INTERVAL_MS는 바이트 조각 사이의 목표 간격이다. FE의 실제 MediaRecorder
// 청크 경계·시각을 재현하지 않으며, 파일 크기를 시간 축에 균등 분배한다.
const intervalMs = Number(__ENV.CHUNK_INTERVAL_MS || 20);
const audioDurationMs = mode === 'audio' ? Number(__ENV.AUDIO_DURATION_MS) : 0;
const holdMs = Number(__ENV.HOLD_MS || (mode === 'audio' ? audioDurationMs + 1000 : 10000));
// 연결 종료 시점이 마지막 송신 시점보다 뒤여야 전체 파일이 전송될 수 있다.
if (!Number.isInteger(holdMs) || holdMs < 1000 || holdMs > 5400000) throw new Error('HOLD_MS must be 1000..5400000');
if (!Number.isInteger(intervalMs) || intervalMs < 20 || intervalMs > 1000) throw new Error('CHUNK_INTERVAL_MS must be 20..1000');
if (mode === 'audio' && (!Number.isInteger(audioDurationMs) || audioDurationMs < intervalMs)) {
  throw new Error('AUDIO_DURATION_MS must be at least CHUNK_INTERVAL_MS');
}
if (mode === 'audio' && holdMs < audioDurationMs + intervalMs) {
  throw new Error('HOLD_MS must allow the last audio chunk to be sent');
}

// open(path, 'b')는 파일을 문자열이 아닌 바이너리 ArrayBuffer로 읽는다.
// 각 VU의 init 단계에서 읽어 모든 VU가 동일한 내용의 실제 압축 파일을 사용한다.
// ffmpeg 디코딩은 AI mock에서도 실행되므로 빈 파일이나 임의 바이트는 사용할 수 없다.
const audioFile = mode === 'audio' ? open(__ENV.AUDIO_FILE || './audio.local.webm', 'b') : null;
// ceil은 재생 시간이 간격의 배수가 아니어도 마지막 바이트를 보낼 조각을 확보한다.
const chunkCount = mode === 'audio' ? Math.ceil(audioDurationMs / intervalMs) : 0;
if (mode === 'audio' && (!audioFile || audioFile.byteLength === 0)) {
  throw new Error('AUDIO_FILE must contain a valid WebM/Opus or MP4/AAC file');
}
if (mode === 'audio' && Math.ceil(audioFile.byteLength / chunkCount) > 262144) {
  // BE의 WebSocket 바이너리 메시지 크기 상한을 시험 시작 전에 검사한다.
  throw new Error('Audio chunks would exceed the BE 262144-byte limit');
}
export const options = singleRunOptions('ws', config.count, `${Math.ceil(holdMs / 1000) + 60}s`);

export function run() {
  const item = fixtureForVu(config);
  // http(s) 기본 주소를 ws(s)로 바꾼다. 인증은 BE가 읽는 accessToken 쿠키로 보낸다.
  const url = `${config.baseUrl.replace(/^http/, 'ws')}/ws/v1/recordings/${encodeURIComponent(item.recordingSessionId)}/audio?audioFormat=${encodeURIComponent(item.audioFormat)}`;
  // 아래 변수는 이 VU의 연결 결과만 기록하며 다른 VU와 공유하지 않는다.
  let openedAt = 0;
  let closedByTest = false;
  let unexpectedClose = false;
  let sentBytes = 0;
  let nextChunk = 0;

  // ws.connect는 연결이 끝날 때까지 이 VU에서 실행된다. 콜백 안에서 이벤트를 등록한다.
  // 반환 response.status=101은 핸드셰이크 성공이며 전사·저장 성공을 의미하지 않는다.
  const response = ws.connect(url, {
    headers: { Cookie: cookieHeader(item) },
    tags: { name: 'audio_ws', operation: mode === 'audio' ? 'ws_audio' : 'ws_connect' },
  }, function (socket) {
    socket.on('open', function () {
      // 핸드셰이크 이후부터 연결 유지 시간을 잰다.
      openedAt = Date.now();
      if (mode === 'audio') {
        // setInterval은 연결이 열린 동안 반복 호출된다. 정해진 조각 수를 넘으면 송신하지 않는다.
        socket.setInterval(function () {
          if (nextChunk >= chunkCount) return;
          // start/end는 파일 전체에서 이 조각의 범위다. 각 바이트가 정확히 한 범위에 속한다.
          // 예를 들어 100바이트/3조각이면 [0,33), [33,66), [66,100)이다.
          const start = Math.floor(nextChunk * audioFile.byteLength / chunkCount);
          const end = Math.floor((nextChunk + 1) * audioFile.byteLength / chunkCount);
          nextChunk += 1;
          if (end > start) {
            socket.sendBinary(audioFile.slice(start, end));
            sentBytes += end - start;
          }
        }, intervalMs);
      }
      // 지정 시간이 지나면 클라이언트가 직접 닫는다. 서버의 조기 종료와 구분한다.
      socket.setTimeout(function () {
        closedByTest = true;
        socket.close();
      }, holdMs);
    });
    socket.on('close', function () {
      if (!closedByTest) unexpectedClose = true;
    });
    socket.on('error', function () {
      if (!closedByTest) unexpectedClose = true;
    });
  });

  // 계획된 종료인지, 실제 파일 바이트를 전부 보냈는지까지 확인해 송신 측 성공을 판정한다.
  const heldLongEnough = openedAt && Date.now() - openedAt >= holdMs;
  const ok = Boolean(response && response.status === 101 && openedAt && !unexpectedClose && heldLongEnough
    && (mode !== 'audio' || sentBytes === audioFile.byteLength));
  check(response, { 'audio WebSocket connected and held': () => ok }, { operation: mode });
  recordResult(mode === 'audio' ? 'ws_audio' : 'ws_connect', ok, response ? response.status : 0);
}
