# V1 dev DB 이전 리허설 쓰기 검증

오하이오 → 서울 DB 이전 중에 회의 생성·수정·삭제를 계속 보내고, 전환 후 서울 DB와 대조해 다음을 확인한다.

- 실패한 요청 수
- 데이터 유실 (성공 응답을 받았는데 서울 DB에 반영되지 않은 쓰기)
- 전환 전·중·후 응답 지연

| 파일 | 역할 |
|---|---|
| `write-load.js` | k6 부하 스크립트. 테스트 계정·팀을 만들고 회의 생성 → 수정 → 삭제를 반복하며 요청마다 결과를 기록 |
| `verify.py` | 요청 기록과 서울 DB 조회 결과를 대조해 판정표와 구간별 지연을 출력 |

`write-load.js`는 `../load-test/common.js`의 `loadBaseUrl`을 함께 쓴다.

## 1. 부하 실행 (로컬 PC)

전환을 시작하기 전에 실행해 두고, 전환이 끝난 뒤 몇 분 더 유지한다.

```bash
cd v1/migration
RUN_ID=r1013a   # 테스트마다 새 값. 소문자·숫자 4~6자
ALLOW_LIVE_TEST=YES k6 run \
  -e BASE_URL=https://api-dev.meety.io.kr \
  -e RUN_ID=$RUN_ID -e RATE=2 -e DURATION=20m \
  --log-format raw --log-output file=ops-$RUN_ID.jsonl \
  write-load.js
```

| 설정 | 기본값 | 설명 |
|---|---|---|
| `RATE` | 2 | 초당 시작할 회의 사이클 수 |
| `DURATION` | 20m | 부하 유지 시간 (`90s`, `20m`, `1h`) |
| `PER_TEAM` | 90 | 팀 하나로 만들 회의 수. dev의 팀별 하루 생성 제한(100, 삭제한 회의 포함)보다 작게 둔다 |
| `MIG_PASSWORD` | 무작위 | 테스트 계정 비밀번호. 같은 `RUN_ID`로 다시 실행할 때만 처음과 같은 값을 준다 |

- 계정 수는 `RATE × DURATION ÷ PER_TEAM`만큼 자동으로 만든다(`mig-<RUN_ID>-01` …, 최대 50개).
- 사이클 번호를 3으로 나눈 나머지에 따라 생성만, 수정까지, 삭제까지 진행해 세 가지 최종 상태를 고르게 만든다.
- access token(30분)이 만료되면 401을 기록하고 재로그인한 뒤 한 번 다시 보낸다.
- 요청 기록(`ops-<RUN_ID>.jsonl`)에는 토큰을 남기지 않는다.

## 2. 전환 (`cutover.sh`)

부하를 실행해 둔 상태에서 다른 로컬 터미널로 실행한다. Nginx 전환, 오하이오 읽기 전용, 서울 승격, 게이트 개방을 SSM으로 이어서 처리한다.

```bash
./cutover.sh --preflight   # 사전 점검만 (변경 없음)
./cutover.sh               # 사전 점검 → yes 입력 → 전환
```

- 사전 점검: 서울이 오하이오를 지연 없이 복제 중인지, 오하이오가 쓰기 가능한지, 오하이오 Nginx가 원래 설정이고 프록시 설정이 준비됐는지, 서울 게이트가 닫혔는지 확인한다.
- 서울이 오하이오의 마지막 위치까지 반영하지 못하면 서울을 승격하지 않고 Nginx와 오하이오 쓰기를 자동으로 되돌린다.
- 서울 승격 이후에는 되돌리지 않는다.
- 끝나면 아래 세 시각과 `verify.py` 명령을 출력하고, 실행 기록을 `cutover-<시각>.log`로 남긴다.

수동으로 전환했다면 아래 시각을 직접 적어 둔다. 구간을 나누는 기준이다.

| 이름 | 시점 |
|---|---|
| `dns` | 가비아에서 DNS를 서울로 바꾼 시각 |
| `ohio_ro` | 오하이오 DB를 `super_read_only=ON`으로 바꾼 시각 |
| `gate_open` | 서울 게이트를 연 시각 |

## 3. 서울 DB 조회

k6를 끝낸 뒤 서울 DB에서 실행해 결과를 로컬 파일로 저장한다.

```bash
mysql -B -N dev_meetyDB -e "
  SELECT id, purpose, IFNULL(note, 'NULL'), IFNULL(deleted_at, 'NULL')
  FROM meetings WHERE purpose LIKE 'mig-r1013a-%'" > meetings-r1013a.tsv
```

`verify.py`는 형식에 맞는 줄만 읽으므로 SSM 세션 안내 문구 등이 섞여 있어도 된다.

## 4. 검증

```bash
python3 verify.py --run r1013a --ops ops-r1013a.jsonl --db meetings-r1013a.tsv \
  --mark dns=22:40:00 --mark ohio_ro=22:41:30 --mark gate_open=22:42:10
```

### 판정 기준

작업마다 마지막 시도(401 재시도 후)의 응답과 서울 DB 상태를 대조한다.

| 응답 | 서울 DB 반영 | 판정 |
|---|---|---|
| 성공 | 반영됨 | 정상 |
| 성공 | 반영 안 됨 | **유실** (0건이어야 함) |
| 실패 | 반영 안 됨 | 실패 (실패한 요청 수) |
| 실패·타임아웃 | 반영됨 | 응답 실패인데 반영됨 (사용자가 재시도하면 중복) |

반영 여부: 생성은 행 존재, 수정은 `note = u-<seq>`, 삭제는 `deleted_at` 존재로 본다.
같은 사이클의 회의가 여러 행이면 중복 생성으로 따로 센다.
