# 오하이오 dev DB 전환 리허설

현재 리허설은 오하이오 안에서 dev DB를 기존 prod DB 인스턴스로 전환한다. 서울의 정식 staging·prod에는 접근하지 않는다. 같은 리전에서 실행하므로 이전 오하이오→서울 실험과 절대 지연 시간을 직접 비교하지 않는다.

| 역할 | 인스턴스 / 주소 | MySQL |
|---|---|---|
| 원본 | `i-00b1191f61901d977` / `10.0.1.147` | `dev-db`, server_id=1 |
| 대상 | `i-0ebad3417d7a43bda` / `10.0.1.143` | `mysql`, server_id=6 |
| 앱·ProxySQL | `i-076b39ef84ef3ddf9` | `dev-be`, `dev-proxysql` |

대상은 평소 `dev_meetyDB`만 복제하는 읽기 전용 서버다. 주소·컨테이너·식별자는 `settings.json`에서 관리한다. 계정, 사설 IP, MySQL 식별자가 맞지 않으면 전환·초기화·수집을 중단한다.

| 파일 | 역할 |
|---|---|
| `switch.sh` | 복제 최종 위치를 확인하고 대상을 승격해 ProxySQL을 전환 |
| `hostgroup-wait.sh` | 신규 요청을 HG20에 대기시키는 전환 구현. 직접 실행하지 않음 |
| `reset.sh`, `reset.py` | dev BE 일시 중지, 원본 복귀, 대상 백업·재복제, 행 수 검증, BE 복구 |
| `collect.sh` | 대상 DB에서 이번 실행의 회의·녹음·전사 결과 수집 |
| `write-load.js`, `live-load.js`, `verify.py` | 부하 실행과 결과 비교 |
| `probe-hostgroup.py`, `MigrationJdbcProbe.java` | 별도 ProxySQL 컨테이너에서 세션·트랜잭션 대기 검증 |
| `cutover.sh` | 구 Nginx 진입점. 현재는 `switch.sh`에 인자를 그대로 전달 |

MySQL 연결 한도는 양쪽 64개, ProxySQL 백엔드 한도는 호스트그룹별 서버당 20개로 관리한다(`settings.json`). 롤백 시 동일 DB가 두 호스트그룹에 들어가면 최대 40개를 사용하므로, 나머지는 관리·모니터링·복제 등에 남긴다. 부하 검증으로 확정한 용량은 아니다. 초기화 시 원본의 모니터 계정 인증을 대상에도 준비하며, 권한은 `REPLICATION CLIENT`로 제한한다.

## 1. 초기화

초기화는 대상에만 추가된 테스트 데이터를 버린다. 필요한 결과를 먼저 수집하고 다른 dev 사용·부하를 중지한다. 대상 백업과 덤프는 대상 서버 `/root/rehearsal-backups/`에 권한 600으로 저장된다. 초기화 도중 dev BE가 중단된다.

```bash
# AWS CLI, Python 3 필요. 아래 조회는 DB를 변경하지 않는다.
./reset.sh --preflight
# 확인 후 실행. 자동화할 때만 --yes를 추가한다.
./reset.sh
```

기존 서버의 `/root/mig-1-load.sh`, `/root/mig-2-start.sh`에는 의존하지 않는다. task-66에서 설정한 MySQL 8.4와 대상의 영속 복제 설정을 전제로 한다. 원본 `schema_test`는 복제하거나 초기화하지 않는다.

## 2. 부하와 전환

```bash
# 매번 새로운 RUN_ID를 사용한다. 이 부하는 실제 dev 데이터를 생성한다.
RUN_ID=r1019a
ALLOW_LIVE_TEST=YES k6 run \
  -e BASE_URL=https://api-dev.meety.io.kr -e RUN_ID=$RUN_ID \
  -e RATE=2 -e DURATION=20m \
  --log-format raw --log-output file=ops-$RUN_ID.jsonl write-load.js
```

`INCLUDE_READS=YES`를 추가하면 각 생성 후 상세·목록 조회도 실행한다. `RATE=10 DURATION=5m INCLUDE_READS=YES`는 정상 처리 기준 약 40 RPS(생성 10, 조회 20, 수정 약 6.7, 삭제 약 3.3)이며, 준비 요청을 제외하고 약 12,000건이다. 조회 요청도 `mig_op_failures`에 포함하며, `verify.py`의 DB 정합성 판정은 생성·수정·삭제를 대상으로 한다.

`write-load.js`는 생성·수정·삭제를 반복한다. `PER_TEAM` 기본값 90은 dev의 팀별 하루 생성 제한 100보다 작다. `RATE`·`DURATION`에 따라 계정을 만들며, access token이 만료되면 재로그인하고 한 번 재시도한다. 녹음·가짜 STT 부하는 `live-load.js`의 실행 옵션을 함께 확인한다.

다른 터미널에서 실행한다.

```bash
# 사전 점검만 수행한다. 대상이 대기 상태여도 조회할 수 있다.
./switch.sh --preflight
# 초기화 후 부하를 시작하고 비교할 모드를 명시한다.
./switch.sh --mode hostgroup-wait
# 비교 실험: no-wait 또는 proxysql-wait
# ./switch.sh --mode no-wait
```

- `no-wait`: 원본 쓰기 차단 → 대상 최종 복제 확인·승격 → HG10을 대상으로 교체.
- `proxysql-wait`: 원본을 OFFLINE_SOFT로 둔 뒤 같은 순서로 전환. 기존 세션의 새 쿼리 대기는 보장하지 않는다.
- `hostgroup-wait`: 신규 트랜잭션을 닫힌 HG20에 배정 → 원본 트랜잭션 종료 → 원본 쓰기 차단 → 최종 복제 확인·승격 → HG20 실행 허용. 기존 트랜잭션은 HG10에서 끝낸다. 승격 후 재기동으로 복제가 자동 재개되지 않게 하고, 초기화 시 자동 재개 설정을 되돌린다.

승격 명령 이후 결과가 불명확하면 원본 쓰기를 자동으로 다시 열지 않는다. 양쪽이 동시에 쓰기 가능한 상태가 되지 않도록 DB 상태를 먼저 확인한다. 승격이 확인된 뒤에는 원본으로 자동 롤백하지 않는다. 다음 실험 전 `reset.sh`로 복귀한다.

## 3. 결과 수집과 비교

로컬 MySQL 클라이언트, `nc`, AWS Session Manager 플러그인이 필요하다. dev-app 경유 SSM 원격 호스트 포워딩을 사용하므로 수집을 위해 DB 접근 권한을 추가하지 않는다. 이미 사용 중인 로컬 포트에는 연결하지 않는다. `LOCAL_PORT`로 기본 포트 13306을 바꿀 수 있다.

```bash
# 이번 실행 결과만 대상 DB에서 읽는다. 비밀번호는 출력하지 않는다.
./collect.sh r1019a
# switch.sh가 출력한 epoch 밀리초를 넘긴다.
python3 verify.py --run r1019a --ops ops-r1019a.jsonl \
  --db meetings-r1019a.tsv \
  --mark ohio_ro=1760840000000 --mark promote=1760840001000 --mark switch=1760840002000
```

`collect.sh`는 `meetings-<RUN_ID>.tsv`, `live-<RUN_ID>.tsv`, `segments-<RUN_ID>.tsv`를 만든다. 녹음 부하를 함께 실행했다면 `verify.py`에 해당 로그와 `--live`, `--segments` 파일도 전달한다. 기존 기록의 `ohio_ro` 표식 이름은 호환성을 위해 유지한다.

성공 응답을 받은 쓰기가 대상에 없으면 유실로 판정한다. 실패 응답인데 데이터가 있으면 응답 실패 후 반영된 요청으로 구분한다. 생성은 행 존재, 수정은 note, 삭제는 deleted_at으로 확인한다.

독립 세션/JDBC 검증은 dev-app에 `probe-hostgroup.py`와 `settings.json`을 함께 복사해 실행한다. JDBC 검증을 추가할 때는 `javac --release 17`로 빌드한 `MigrationJdbcProbe.class`를 `--jdbc-class`로 전달한다. 실제 dev 라우팅과 DB 쓰기는 변경하지 않지만 별도 컨테이너와 DB 읽기 연결을 만든다.
