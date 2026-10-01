import { check } from 'k6';
import sse from 'k6/x/sse';
import { cookieHeader, fixtureForVu, loadConfig, recordResult, singleRunOptions } from './common.js';

// SSE(Server-Sent Events)는 서버가 하나의 HTTP 응답에 이벤트를 계속 보내는 연결이다.
// k6 기본 모듈이 아닌 k6/x/sse 확장이 필요하므로 확장 포함 실행 파일을 먼저 준비한다.
// 각 VU는 이미 회의에 입장한 사용자 1명으로 SSE 연결 1개를 연다.
const config = loadConfig('sse');
const holdMs = Number(__ENV.HOLD_MS || 30000);
if (!Number.isInteger(holdMs) || holdMs < 1000 || holdMs > 5400000) {
  throw new Error('HOLD_MS must be 1000..5400000');
}
for (let i = 0; i < config.count; i += 1) {
  // SSE를 구독할 회의가 빠진 계정이 있으면 전체 부하를 시작하지 않는다.
  if (!config.fixtures[i].meetingId) throw new Error(`SSE fixture ${i + 1} needs meetingId`);
}
export const options = singleRunOptions('sse', config.count, `${Math.ceil(holdMs / 1000) + 60}s`);

export function run() {
  const item = fixtureForVu(config);
  // 모두 이 VU의 연결에서만 바뀌는 상태다. 서버의 조기 종료와 계획된 종료를 구분한다.
  let openedAt = 0;
  let connectedEvent = false;
  let closedByTest = false;
  let unexpectedError = false;
  // sse.open은 연결이 끝날 때까지 반환하지 않는다. 콜백에서 이벤트 핸들러를 등록한다.
  const response = sse.open(`${config.baseUrl}/api/v1/meetings/${encodeURIComponent(item.meetingId)}/events`, {
    method: 'GET',
    headers: { Cookie: cookieHeader(item), Accept: 'text/event-stream' },
    // xk6-sse가 연결 중 JS 이벤트 루프를 막으므로 setTimeout 콜백은 실행되지 않는다.
    // Go HTTP 클라이언트의 timeout을 종료 신호로 사용한다. 시작 지연 5초를 여유로 둔다.
    timeout: `${holdMs + 5000}ms`,
    tags: { name: 'meeting_sse', operation: 'sse' },
  }, function (client) {
    client.on('open', function () {
      // HTTP 연결이 열린 시점부터 실제 유지 시간을 잰다.
      openedAt = Date.now();
    });
    client.on('event', function (event) {
      // BE가 최초 연결 확인용으로 보내는 이름 있는 이벤트다.
      // 상태·전사 이벤트의 정확한 전달 여부는 이 스크립트의 판정 범위 밖이다.
      if (event.name === 'CONNECTED') connectedEvent = true;
    });
    client.on('error', function (error) {
      // xk6-sse는 timeout도 error 이벤트로 전한다. 유지 시간을 채운 timeout만
      // 계획된 종료 신호로 보고, 인증 오류·조기 단절·다른 네트워크 오류는 실패로 남긴다.
      const elapsedMs = openedAt ? Date.now() - openedAt : 0;
      const message = error && typeof error.error === 'function' ? String(error.error()) : String(error);
      // 계획한 timeout만 정상 종료로 취급한다. 다른 오류나 조기 종료는 실패다.
      if (elapsedMs >= holdMs && /timeout|deadline exceeded/i.test(message)) {
        closedByTest = true;
      } else {
        unexpectedError = true;
      }
      // 오류를 기록한 뒤 클라이언트와 응답 본문을 닫아 VU가 무한 대기하지 않게 한다.
      client.close();
    });
  });

  // sse.open이 반환된 뒤에는 더 이상 연결 중이 아니므로 여기서 최종 결과를 집계한다.
  const heldMs = openedAt ? Date.now() - openedAt : 0;
  const ok = Boolean(response && response.status === 200 && openedAt && heldMs >= holdMs
    && closedByTest && !unexpectedError && connectedEvent);
  check(response, { 'SSE connected and held': () => ok }, { operation: 'sse' });
  recordResult('sse', ok, response ? response.status : 0);
  if (!ok) console.warn(`SSE fixture failed; heldMs=${heldMs}, connectedEvent=${connectedEvent}`);
}
