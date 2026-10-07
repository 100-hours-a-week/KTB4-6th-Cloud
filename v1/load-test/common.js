import { SharedArray } from 'k6/data';
import { vu } from 'k6/execution';
import { Counter, Rate } from 'k6/metrics';

// 모든 k6 시나리오가 공유하는 설정과 지표다.
// k6는 스크립트 맨 위 코드를 VU 실행 전에 평가하고, 각 VU가 export된 run()을 수행한다.
// 여기서는 실행 전 fixture 검증과 VU별 자원 배정을 공통화한다.

// 목표 인원은 V1 평균 6명/팀, 음성 송신자는 1명/팀을 기준으로 한다.
// smoke는 형식 검증용 1건, target/max는 V1 목표/최대 동시 요청 또는 연결 수다.
export const LEVEL_COUNTS = {
  smoke: { create: 1, join: 1, transcript: 1, summary: 1, ws: 1, sse: 1 },
  target: { create: 15, join: 90, transcript: 90, summary: 90, ws: 15, sse: 90 },
  max: { create: 20, join: 120, transcript: 120, summary: 120, ws: 20, sse: 120 },
};

// Counter는 누적 건수, Rate는 true/false의 성공 비율을 집계하는 k6 사용자 정의 지표다.
// 기본 http_req_failed만으로는 '예상 상태 코드 + 응답 내용' 성공 여부를 알 수 없다.
export const attempts = new Counter('meety_attempts');
export const successes = new Counter('meety_successes');
export const failures = new Counter('meety_failures');
export const successRate = new Rate('meety_success_rate');
export const serverErrors = new Counter('meety_http_5xx');
export const clientErrors = new Counter('meety_http_4xx');
export const transportErrors = new Counter('meety_transport_errors');

export function loadBaseUrl() {
  // 대상 주소와 실행 허용 여부만 검사한다. fixture 형식이 다른 스크립트(meeting-flow.js)도 함께 쓴다.
  const baseUrl = (__ENV.BASE_URL || '').replace(/\/$/, '');
  if (!/^https?:\/\//.test(baseUrl)) {
    throw new Error('BASE_URL must be an explicit http(s) URL');
  }
  // 쿠키에 인증 토큰이 들어 있으므로 원격 HTTP 대상에는 전송하지 않는다.
  if (!/^https:\/\/[^\/?#@]+$/.test(baseUrl) && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(baseUrl)) {
    throw new Error('BASE_URL must use HTTPS except for localhost/127.0.0.1');
  }
  if (__ENV.ALLOW_LIVE_TEST !== 'YES') {
    throw new Error('Set ALLOW_LIVE_TEST=YES after checking the target and test window');
  }
  return baseUrl;
}

export function loadConfig(scenario) {
  // __ENV는 셸 환경변수 또는 k6의 -e 옵션으로 전달한 실행 설정이다.
  // 실제 요청을 보내기 전에 잘못된 수준·대상 주소·실행 허용 여부를 검사한다.
  const level = __ENV.LEVEL || 'smoke';
  if (!LEVEL_COUNTS[level] || !LEVEL_COUNTS[level][scenario]) {
    throw new Error(`Unsupported LEVEL or SCENARIO: ${level}/${scenario}`);
  }

  const baseUrl = loadBaseUrl();

  // SharedArray는 VU마다 JSON 파일을 다시 읽지 않고 초기화 결과를 공유한다.
  // open()은 k6의 파일 읽기 함수이며 VU 실행 전 init 단계에서만 사용할 수 있다.
  const fixturePath = __ENV.FIXTURE_FILE || './fixtures.local.json';
  const fixtures = new SharedArray(`meety-${scenario}`, function () {
    const parsed = JSON.parse(open(fixturePath));
    // 자원 준비가 중간에 실패한 fixture로 일부 사용자만 시험하는 일을 막는다.
    if (parsed.preparation && parsed.preparation.complete !== true) {
      throw new Error('Resource preparation is incomplete; check preparation before running k6');
    }
    return parsed[scenario] || [];
  });
  // COUNT를 지정하면 기존 LEVEL의 고정 VU 수 대신 원하는 요청 수를 사용한다.
  // 숫자 오입력으로 의도치 않은 대량 요청을 보내지 않도록 상한을 둔다.
  const countText = __ENV.COUNT;
  if (countText !== undefined && !/^[1-9]\d*$/.test(countText)) {
    throw new Error('COUNT must be a positive integer');
  }
  const count = countText === undefined ? LEVEL_COUNTS[level][scenario] : Number(countText);
  if (!Number.isSafeInteger(count) || count > 1000) {
    throw new Error('COUNT must be between 1 and 1000');
  }
  if (fixtures.length < count) {
    throw new Error(`${scenario} needs ${count} fixtures for LEVEL=${level}; found ${fixtures.length}`);
  }
  // 실제로 사용할 앞쪽 count개 계정에 토큰이 모두 있어야 부하를 시작한다.
  for (let i = 0; i < count; i += 1) {
    if (!fixtures[i].accessToken || fixtures[i].accessToken.startsWith('REPLACE_')) {
      throw new Error(`${scenario} fixture ${i + 1} needs a real accessToken`);
    }
  }
  return { baseUrl, fixtures, count, level };
}

export function fixtureForVu(config) {
  // per-vu-iterations에서 VU마다 하나의 계정/자원을 고정해 공유 충돌을 줄인다.
  // vu.idInTest는 1부터 시작하므로 배열 인덱스로 쓰기 위해 1을 뺀다.
  return config.fixtures[vu.idInTest - 1];
}

export function cookieHeader(fixture) {
  // 서비스는 Authorization 헤더가 아니라 accessToken 쿠키를 읽는다.
  return `accessToken=${fixture.accessToken}`;
}

export function recordResult(scenario, ok, status) {
  // operation 태그로 결과를 구분하면 여러 시나리오를 모아 볼 때도 원인을 찾기 쉽다.
  const tags = { operation: scenario };
  attempts.add(1, tags);
  successes.add(ok ? 1 : 0, tags);
  failures.add(ok ? 0 : 1, tags);
  successRate.add(ok, tags);
  // 요청 자체의 실패와 서버 5xx를 분리한다. 예상하지 못한 4xx도 ok=false다.
  if (status >= 500 && status <= 599) serverErrors.add(1, tags);
  else if (status >= 400 && status <= 499) clientErrors.add(1, tags);
  else if (!status) transportErrors.add(1, tags);
}

export function singleRunOptions(scenario, count, timeout) {
  // VU별로 정확히 1번 run()을 실행한다. 즉 VU 수가 동시 요청/연결 수에 가깝다.
  // maxDuration은 연결 또는 요청이 멈췄을 때 전체 시험이 무한 대기하지 않게 한다.
  return {
    scenarios: {
      [scenario]: {
        executor: 'per-vu-iterations',
        exec: 'run',
        vus: count,
        iterations: 1,
        maxDuration: timeout,
        gracefulStop: '10s',
      },
    },
    // 합격률은 팀에서 아직 정하지 않았다. 임의 threshold로 합격 판정을 만들지 않는다.
  };
}

export function safePath(path) {
  // 호스트를 fixture에 넣으면 다른 서비스로 인증 쿠키가 전송될 수 있으므로 상대 경로만 허용한다.
  if (typeof path !== 'string' || !path.startsWith('/') || path.startsWith('//') || path.includes('REPLACE_')) {
    throw new Error(`Fixture path must be a real root-relative path: ${path}`);
  }
  return path;
}
