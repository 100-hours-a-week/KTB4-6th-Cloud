import { check, sleep } from 'k6';
import http from 'k6/http';
import { cookieHeader, fixtureForVu, loadConfig, recordResult, safePath, singleRunOptions } from './common.js';

// 실행 예: k6 run -e SCENARIO=create -e LEVEL=smoke api.js
// 하나의 VU가 fixture 1개로 HTTP 요청을 정확히 1번 보낸다.
// 회의 생성·입장처럼 데이터를 바꾸는 요청도 반복 실행하지 않도록 구성했다.
const scenario = __ENV.SCENARIO || 'create';
if (!['create', 'join', 'transcript', 'summary'].includes(scenario)) {
  throw new Error('SCENARIO must be create, join, transcript, or summary');
}
const captureMeetingIds = __ENV.CAPTURE_MEETING_IDS === 'YES';
if (captureMeetingIds && scenario !== 'create') {
  throw new Error('CAPTURE_MEETING_IDS is only supported for SCENARIO=create');
}
// 요청이 너무 빨리 끝나면 k6 Web Dashboard가 "test run was short"로 HTML 보고서를 만들지 않는다.
// 요청 완료 후 VU를 잠시 유지해 보고서용 지표 구간을 확보한다. 응답 시간 측정에는 포함되지 않는다.
const holdSeconds = Number(__ENV.REPORT_HOLD_SECONDS || '8');
if (!Number.isFinite(holdSeconds) || holdSeconds < 0 || holdSeconds > 60) {
  throw new Error('REPORT_HOLD_SECONDS must be between 0 and 60');
}
const config = loadConfig(scenario);
// k6는 options를 읽어 VU 수와 실행 방식을 정하고, 각 VU에서 run()을 호출한다.
export const options = singleRunOptions(scenario, config.count, '2m');

// 설정 오류가 섞인 상태로 일부 VU만 실제 서버에 요청하는 일을 막는다.
for (let i = 0; i < config.count; i += 1) {
  const item = config.fixtures[i];
  safePath(item.path);
  if (!Number.isInteger(item.expectedStatus) || item.expectedStatus < 200 || item.expectedStatus >= 400) {
    throw new Error(`${scenario} fixture ${i + 1} needs expectedStatus 200..399`);
  }
  if (typeof item.requiredJsonField !== 'string' || !item.requiredJsonField || item.requiredJsonField.startsWith('REPLACE_')) {
    throw new Error(`${scenario} fixture ${i + 1} needs a real requiredJsonField`);
  }
}

function getField(value, dottedPath) {
  // 'data.meetingId'처럼 점으로 적힌 fixture 경로를 응답 객체에서 차례로 찾아간다.
  // 중간 필드가 없으면 undefined를 반환해 해당 요청을 실패로 판정한다.
  return dottedPath.split('.').reduce((current, key) => current == null ? undefined : current[key], value);
}

export function run() {
  // 이 VU 전용 계정·회의를 고른 뒤 fixture에 적힌 HTTP 요청을 만든다.
  const item = fixtureForVu(config);
  const method = (item.method || (scenario === 'create' || scenario === 'join' ? 'POST' : 'GET')).toUpperCase();
  if (!['GET', 'POST', 'PATCH', 'PUT'].includes(method)) {
    throw new Error(`Unsupported HTTP method in ${scenario} fixture: ${method}`);
  }
  const headers = { Cookie: cookieHeader(item), Accept: 'application/json' };
  // GET에는 본문이 없고, 생성·입장 등 본문이 있는 요청만 JSON으로 직렬화한다.
  const body = item.body === undefined ? null : JSON.stringify(item.body);
  if (body !== null) headers['Content-Type'] = 'application/json';
  // redirects: 0으로 리다이렉트를 따라가지 않는다. 다른 응답으로 성공을 오판하지 않기 위해서다.
  // timeout은 개별 HTTP 요청의 상한이며 위 options의 전체 시험 상한과 별개다.
  const response = http.request(method, `${config.baseUrl}${safePath(item.path)}`, body, {
    headers,
    redirects: 0,
    timeout: '30s',
    tags: { name: scenario, operation: scenario },
  });

  // 상태 코드만 맞아도 본문이 비어 있거나 실패 응답일 수 있으므로 함께 확인한다.
  let contentOk = false;
  let createdMeetingId = null;
  if (response && response.status === item.expectedStatus) {
    try {
      const payload = response.json();
      const field = getField(payload, item.requiredJsonField);
      // 빈 전사 목록과 빈 요약도 성공으로 세지 않는다.
      contentOk = payload.success === true && field !== undefined && field !== null
        && (typeof field !== 'string' || field.trim() !== '')
        && (!Array.isArray(field) || field.length > 0);
      if (contentOk && scenario === 'create' && Number.isSafeInteger(field) && field > 0) {
        createdMeetingId = field;
      }
    } catch (_) {
      contentOk = false;
    }
  }
  const ok = Boolean(response && response.status === item.expectedStatus && contentOk);
  // 회의 ID만 별도 로그에 남긴다. 토큰이나 응답 전체는 기록하지 않는다.
  if (ok && captureMeetingIds && createdMeetingId !== null && Number.isSafeInteger(item.teamId)) {
    console.log(`MEETY_CREATED_MEETING teamId=${item.teamId} meetingId=${createdMeetingId}`);
  }
  // check는 k6 기본 보고서에 판정 결과를 남기고, recordResult는 프로젝트별 지표를 남긴다.
  // 둘 다 요청을 재시도하거나 시험을 즉시 중단시키지는 않는다.
  check(response, { [`${scenario} expected response`]: () => ok }, { operation: scenario });
  recordResult(scenario, ok, response ? response.status : 0);
  if (holdSeconds > 0) sleep(holdSeconds);
}
