# Meety V1 k6 요청별 부하테스트

이 코드는 회의 전체 흐름을 검증하는 E2E 테스트가 아니다. 회의 생성, 입장, 전사 조회, 요약 조회와 오디오 WebSocket을 각각 독립적으로 측정한다. 서버에 부하를 보내기 전 [시나리오 문서](https://github.com/100-hours-a-week/KTB4-6th-Cloud/wiki/5.-%EB%B6%80%ED%95%98%ED%85%8C%EC%8A%A4%ED%8A%B8-%EC%8B%9C%EB%82%98%EB%A6%AC%EC%98%A4-%EC%84%A4%EA%B3%84)의 준비 조건을 확인한다.

## 현재 구현 범위

| 파일 | 대상 | 상태 |
| --- | --- | --- |
| `prepare-local-auth.py` | 로컬 계정 로그인 및 선택적 가입 | 토큰만 `fixtures.local.json`에 저장하며 부하 측정에서 제외 |
| `api.js` | 회의 생성, 입장, 전사 조회, 요약 조회 | 실제 자원 ID와 계정별 fixture를 채운 뒤 실행 가능 |
| `audio-ws.js` | 오디오 WebSocket 연결 유지 또는 유효한 파일 순차 송신 | 각기 다른 활성 녹음 세션과 파일 재생 시간이 필요 |
| `sse.js` | 회의 SSE 연결 유지 및 최초 `CONNECTED` 이벤트 확인 | `k6/x/sse` 확장이 포함된 k6 실행 파일 필요 |

S3 원본 업로드와 BE 업로드 완료 알림은 아직 구현하지 않았다. 오디오 WebSocket 시험으로 원본 저장 성공을 판단하지 않는다. 혼합 부하도 단독 시나리오 검증 뒤에 추가한다.

## 실행 준비

1. 가능하면 BE·DB·AI mock이 분리된 시험 환경을 사용한다. 공유 V1 서버를 쓴다면 AI 주소를 mock으로 바꿀 때 일반 사용자 요청도 영향을 받는지, 로컬 가입·로그인 API의 외부 접근 제한과 시험 시간을 먼저 확인한다. AI mock은 `MEETY_ENVIRONMENT=production`에서 실행되지 않는다.
2. `fixtures.credentials.example.json`을 `fixtures.credentials.local.json`으로 복사한다. 계정별 `loginId`, `password`, 팀·회의·세션 ID를 실제 테스트 전용 값으로 바꾼다. 이 파일과 생성되는 `fixtures.local.json`은 `.gitignore` 대상이다.
3. `prepare-local-auth.py`로 로그인한다. 신규 계정을 만들기로 한 경우에만 `--signup-missing`을 사용한다. 출력에는 비밀번호와 refresh token을 남기지 않으며 가장 이른 access token 만료 시각을 표시한다. 준비 후 바로 시험한다.
4. HTTP는 `accessToken` 쿠키, 정상 코드, `ApiResponse.success=true`와 `requiredJsonField`를 확인한다. 전사는 비지 않은 `data.segments`, 요약은 비지 않은 `data.content`를 사용한다. WebSocket의 `audioFormat`은 파일에 맞춰 `webm_opus` 또는 `mp4_aac`를 지정한다.
5. 스크립트는 `ALLOW_LIVE_TEST=YES`를 명시해야 시작한다. 이것은 실행 실수 방지 장치이며 서버 접근 제어를 대신하지 않는다. 로컬 가입·로그인은 BE 코드상 공개 허용 경로이므로 배포 계층의 제한 여부를 별도로 확인한다.

`fixtures.local.json`의 각 배열은 선택한 `LEVEL`의 VU 수 이상이어야 한다. 목표 수준은 생성 15건, 입장·전사·요약·SSE 각 90개, 오디오 WS 15개다. 최대 수준은 각각 20·120·20개다. 생성·입장에는 별도 계정과 자원을 쓰고, 입장은 아직 참여하지 않은 계정을 배정한다. `ws`에는 각기 다른 활성 `recordingSessionId`와 해당 녹음 시작자의 토큰이 필요하다. `sse`에는 이미 입장한 사용자의 `meetingId`가 필요하다. 전사·요약 조회에는 결과가 이미 생성된 회의를 쓴다.

```bash
# 기존 계정 로그인만 수행한다. 401이면 중단한다.
python3 prepare-local-auth.py --base-url https://api.example.com \
  --input fixtures.credentials.local.json --output fixtures.local.json

# 가입을 명시적으로 허용한 경우에만 이 옵션을 추가한다.
python3 prepare-local-auth.py --base-url https://api.example.com \
  --input fixtures.credentials.local.json --output fixtures.local.json --signup-missing
```

AI팀의 별도 mock 서버를 사용한다면 AI 저장소에서 다음을 실행하고, BE의 `AI_WEBSOCKET_URL`과 `AI_HTTP_URL`을 각각 해당 서버로 연결한다. ffmpeg 디코딩은 mock이 아니므로 AI 서버에 ffmpeg가 필요하다.

```bash
# 실시간 녹음 서버. 운영 환경 설정에서는 mock 앱이 실행을 거부한다.
uv run uvicorn meety_ai.fake_providers:create_live_app --factory \
  --env-file .env.loadtest.example --port 8000

# 요약·화자 분리 분석 서버.
uv run uvicorn meety_ai.fake_providers:create_analysis_app --factory \
  --env-file .env.loadtest.example --port 8001
```

## 실행 예시

모든 명령은 이 폴더에서 실행한다. 먼저 `mkdir -p reports`로 출력 폴더를 만든다. 아래 도메인은 실제 대상 URL로 바꾸며, 부하를 발생시키므로 준비가 끝나기 전에는 실행하지 않는다.

```bash
# 한 계정으로 회의 생성 요청 형식을 먼저 확인한다.
BASE_URL=https://api.example.com ALLOW_LIVE_TEST=YES \
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=reports/create-smoke.html \
k6 run -e SCENARIO=create -e LEVEL=smoke api.js

# 각기 다른 15팀이 회의를 동시에 하나씩 생성한다.
BASE_URL=https://api.example.com ALLOW_LIVE_TEST=YES \
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=reports/create-target.html \
k6 run -e SCENARIO=create -e LEVEL=target api.js

# 20개 녹음 세션의 WebSocket 연결을 30초간 유지한다.
BASE_URL=https://api.example.com ALLOW_LIVE_TEST=YES \
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=reports/ws-max.html \
k6 run -e LEVEL=max -e WS_MODE=connect -e HOLD_MS=30000 audio-ws.js

# 유효한 10초 WebM/Opus 파일을 한 번 순차 송신한다. MP4/AAC 파일이면 fixture도 mp4_aac로 바꾼다.
BASE_URL=https://api.example.com ALLOW_LIVE_TEST=YES \
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=reports/ws-audio-target.html \
k6 run -e LEVEL=target -e WS_MODE=audio -e AUDIO_FILE=./audio.local.webm \
  -e AUDIO_DURATION_MS=10000 -e CHUNK_INTERVAL_MS=20 -e HOLD_MS=11000 audio-ws.js

# SSE 확장이 포함된 k6 실행 파일로 단일 연결을 검증한 뒤 목표 수준으로 늘린다.
BASE_URL=https://api.example.com ALLOW_LIVE_TEST=YES \
k6 run -e LEVEL=smoke -e HOLD_MS=30000 sse.js
```

`LEVEL`은 `smoke`, `target`, `max` 중 하나다. HTTP 스크립트의 `SCENARIO`는 `create`, `join`, `transcript`, `summary` 중 하나다. HTML 보고서를 저장할 `reports/` 폴더는 미리 만든다. 짧은 동시 요청 시험은 HTML에 집계 결과만 나올 수 있다. [k6 웹 대시보드 문서](https://grafana.com/docs/k6/latest/results-output/web-dashboard/)

`k6/x/sse`는 커뮤니티 확장이다. 설치된 k6 v2.1.0에서는 자동 확장 해석이 `unknown dependency: k6/x/sse`로 실패했다. 이 환경에서는 Go와 xk6를 설치한 후 k6 v2 호환 [xk6-sse v0.2.0](https://github.com/phymbert/xk6-sse/releases/tag/v0.2.0)을 포함한 실행 파일을 빌드할 수 있다. 다음은 [k6의 xk6 빌드 방법](https://grafana.com/docs/k6/latest/extensions/run/)에 따른 예시이며, 현재 로컬에 Go가 없어 빌드 결과는 검증하지 못했다. 이 실행 파일로 SSE 단일 연결을 먼저 확인한다.

```bash
xk6 build v2.1.0 --with github.com/phymbert/xk6-sse@v0.2.0 --output /tmp/k6-sse
# 실제 fixtures.local.json을 준비한 뒤 실행 전 구문·설정을 검사한다. 서버 요청은 보내지 않는다.
BASE_URL=https://api.example.com ALLOW_LIVE_TEST=YES \
  /tmp/k6-sse inspect -e LEVEL=smoke sse.js
# 위의 SSE 실행 예시에서 k6 대신 /tmp/k6-sse를 사용한다.
```

## 결과 해석

- `meety_attempts`, `meety_successes`, `meety_failures`, `meety_success_rate`는 시나리오별 요청·연결 판정이다.
- `meety_http_4xx`, `meety_http_5xx`, `meety_transport_errors`는 실패 원인을 나누기 위한 값이다. 예상하지 못한 4xx는 부하테스트 요청 실패이지만 운영 SLI의 5xx 장애와 구분한다.
- WebSocket `101`은 연결 성립만 확인한다. 오디오 모드는 파일의 모든 바이트를 한 번 송신했는지도 판정한다. 압축 파일을 일정한 바이트 크기로 나누므로 FE의 `MediaRecorder` 청크 경계와 전송 시각을 정확히 재현하지는 않는다. `request_time_s`는 연결 시간을 포함하므로 API 응답 지연과 비교하지 않는다.
- SSE는 `k6/x/sse`가 JS 이벤트 루프를 차단하므로 요청 시작 후 `HOLD_MS + 5초` timeout을 종료 신호로 사용한다. `CONNECTED` 이벤트를 받고 `HOLD_MS` 이상 유지한 연결만 성공으로 센다. 조기 종료와 다른 오류는 실패다. 따라서 실제 연결 유지 시간은 최소 `HOLD_MS`이며 약 5초 더 길 수 있다.
- 각 HTTP 시나리오는 VU당 요청 1건을 보낸다. 목표·최대 수준은 각각 정해진 수의 **동시 요청**이지 지속 RPS가 아니다. 지속 부하·반복 간격은 별도 시나리오로 설계해야 한다.
- 30분을 넘기는 연결 시험은 현재 조사된 JWT 만료 시간과 SSE 재인증 동작을 확인한 뒤 실행한다. 임의로 토큰 만료를 늘려 시험하지 않는다.
- 현재 합격률 기준은 팀에서 정하지 않았다. 이 코드는 임의의 threshold로 합격·불합격을 선언하지 않는다.

WS 종료만으로 녹음 세션·회의가 완료되지는 않는다. 시험 후 별도 API로 상태를 확인하고 테스트 데이터를 정리한다. 현재 범위는 S3 업로드와 분석 생성 부하를 포함하지 않는다. 실제 사용자 데이터나 인증값을 로그·스크린샷·공유용 HTML에 넣지 않는다. k6 결과와 Nginx `sli_access.log`를 실행 시각으로 대조하되, HTML이 Nginx·DB 데이터를 자동으로 합쳐 주지는 않는다.
