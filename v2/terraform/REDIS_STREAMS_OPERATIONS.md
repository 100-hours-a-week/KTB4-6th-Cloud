# Redis 8 모듈 및 Streams 운영 가이드

## 상태와 적용 범위

- **현재 구현 완료:** 전용 Redis의 Master/Replica에 빈 모듈 디렉터리 읽기 전용 마운트, 읽기 전용 Streams 진단 스크립트. Redis 8.10.2, 인증, Pub/Sub, Sentinel 설정은 유지한다.
- **로컬 검증 완료:** 검증 명령과 결과는 작업 결과 보고를 참조한다. Staging 서버에서는 검증하지 않았다.
- **미검증:** 배포 중인 BE 이미지의 Redis 확장 모듈 의존성, 실제 Staging의 `redis.conf`와 AOF 상태, 실제 장애 조치·데이터 복구. 로컬 BE `experiment/redis-sentinel-failover` 작업 트리의 `src/main`에서는 확장 모듈 명령을 찾지 못했고, 확인된 Redis 사용은 문자열/키·Pub/Sub 중심이다. 이 작업 트리가 실제 배포 이미지와 일치하는지는 확인되지 않았다.
- **BE와 협의 필요:** Streams 사용 여부, 명령 ID·멱등성, Consumer Group 및 재처리 규칙, 보관 기간·메모리 예산, 지표 이름.
- **도입 결정 이후 작업:** BE의 Streams 생산·소비·ACK와 관련 메트릭 구현, 장애·롤링 배포 실험, 알림 기준 합의.

## 목적과 처리 방식

### 로컬 검증 기록 (2026-10-30)

- `redis:8.10.2` 이미지 digest: `sha256:97ec88159e6d7cfb5ddef9015386087d58a912de80112f06ebdfa78fa5989901`.
- 기본 이미지 `MODULE LIST`: search/timeseries/bf/ReJSON 및 내장 vectorset 확인. 빈 모듈 디렉터리 적용 후 외부 `.so` 모듈은 없고 내장 vectorset만 남았다.
- `CONFIG REWRITE`는 OK, 설정의 `^loadmodule` 검색은 결과 없음. 컨테이너 재시작 후 `PING`은 PONG.
- `XADD`, `XGROUP CREATE`, `XREADGROUP` 성공. Pending 1건은 AOF 재시작 후에도 유지됐고 `XACK` 결과 1, 이후 Pending 0 확인.
- 진단 스크립트의 Master 역할, 메모리/AOF/Stream/Group/Pending 조회 성공. 없는 Stream과 연결 실패는 종료 코드 1 및 명확한 오류 확인. 최종 본문 출력 제외 변경은 Shell 문법 검사와 자체 리뷰로 확인했다.
- Terraform 1.16.0 Redis 모듈 `validate` 성공. 전체 `fmt -check -recursive v2/terraform` 성공. Sentinel 활성/비활성 템플릿을 Terraform으로 렌더링하고 `bash -n`, 추출한 Compose의 `config --quiet` 통과.
- Staging 전체 validate는 임시 복사본의 기존 모니터링 Lambda ZIP/참조 파일 누락으로 실패했다. 저장소의 관련 파일은 수정하지 않았다. AWS 인증·state 조회가 필요한 plan은 실행하지 않았다.
- Master–Replica–Sentinel 런타임 및 Failover, Sentinel 진단 경로, 인증 실패 경로는 미검증이다. Standalone 재시작 결과로 Failover 성공을 주장하지 않는다.

공식 근거: [v8.10.2 진입점](https://github.com/redis/docker-library-redis/blob/v8.10.2/debian/docker-entrypoint.sh), [Redis Issue #14178](https://github.com/redis/redis/issues/14178), [CONFIG REWRITE](https://redis.io/docs/latest/commands/config-rewrite/).

현재 녹음 제어 명령은 BE 간 Redis Pub/Sub으로 전달된다. Pub/Sub은 구독자가 끊긴 동안 메시지를 보관하지 않는다. Streams는 기록과 Consumer Group의 미처리 목록(Pending Entries List)을 제공한다. `XREADGROUP`으로 받은 항목은 처리 성공 후 `XACK`해야 Pending에서 빠진다. `XACK`은 Stream 항목 자체를 삭제하지 않는다. 재연결한 Consumer는 자기 Pending을 확인하고, 다른 Consumer가 남긴 Pending은 합의한 유휴 시간 이후 회수해야 한다. 이 과정에는 명령 ID 기반 멱등 처리가 필요하다. 현재 BE의 Pub/Sub 경로는 그대로 유지한다.

Owner BE가 바뀌면 이전 Owner의 처리 중 명령과 새 Owner의 재처리가 겹칠 수 있다. Owner 판정과 명령 실행을 원자적으로 조정할지, 처리 결과를 DB 상태와 어떻게 맞출지 BE에서 설계해야 한다. 배포 중 구·신 Consumer가 함께 실행될 때도 같은 Group과 명령 형식을 이해해야 한다. 기존 ECS BE 프로세스와 Redis/Sentinel 연결을 활용할 수 있지만, 별도 Consumer 서비스 필요 여부는 처리량과 장애 격리 요구를 확인한 뒤 결정한다.

## 영속화·메모리 및 관측

전용 Redis 템플릿은 `appendonly yes`, `appendfsync everysec`, `save ""`, `maxmemory`, `maxmemory-policy noeviction`을 사용한다. AOF는 쓰기 명령을 보존하지만 `everysec`은 마지막 약 1초의 기록 손실을 허용한다. RDB 스냅샷은 꺼져 있다. Failover 때 Replica가 아직 받지 못한 Stream 항목, Group의 마지막 전달 ID, Pending 변경은 승격 후 사라질 수 있다. 복제는 비동기이므로 AOF만으로 무손실 Failover를 보장하지 않는다. 정상 저장·재시작이라면 Stream과 Pending이 AOF에서 복원되는지 로컬 및 배포 전 실험으로 확인한다.

Stream은 자동으로 잘리지 않는다. `noeviction`에서 누적 데이터가 `maxmemory`에 이르면 새 Stream 쓰기뿐 아니라 세션·토큰 등 다른 쓰기도 실패할 수 있다. 현재 정책을 임의 변경하지 않는다. 길이·보관 시간·Group별 최소 처리 지점·`XTRIM` 시점·디스크 여유·AOF 재작성 여유를 BE/Cloud가 함께 결정한다. 메모리 부족 시 먼저 생산 속도와 Pending을 확인하고, 승인된 보관 정책에 따라 처리 완료 항목만 정리한다. `XTRIM`은 Pending 항목도 Stream에서 제거할 수 있으므로 자동 실행하지 않는다.

현재 Prometheus는 ECS의 BE `/actuator/prometheus`를 수집하고 Grafana/Loki가 있다. BE가 명령 재처리 수, 명령 실패 수, 처리 지연, Pending 복구 등을 노출하면 기존 수집 경로를 이용할 수 있다. Stream 길이·Group Pending·오래된 Pending·Redis 메모리·AOF 오류·복제 및 Failover 상태는 BE 메트릭만으로 실제 Redis 상태가 충분히 드러나는지 먼저 확인한다. 부족하면 읽기 전용 Redis Exporter 또는 제한된 Key만 조회하는 별도 수집기를 검토한다. 현재는 Exporter, Alert, 새 포트·인프라를 만들지 않는다. 알림은 실제 메트릭 존재, 레이블, 정상 범위, 임계값과 대응자를 확인한 뒤 활성화한다.

## 읽기 전용 진단

`scripts/redis-stream-diagnostics.sh --stream KEY --group GROUP --host HOST --port 6379`를 사용한다. 인증이 필요하면 `REDISCLI_AUTH`를 안전한 환경에서 전달한다. 비밀번호를 명령 인자, 셸 기록, 로그에 적지 않는다. 예: 비밀값이 이미 안전하게 주입된 셸에서 `REDISCLI_AUTH="$REDIS_PASSWORD" scripts/redis-stream-diagnostics.sh --stream KEY --group GROUP --host HOST`.

Sentinel이 있는 환경은 `--sentinel-host HOST --sentinel-port 26379 --master-name meety`로 현재 Master를 조회한다. 출력의 `role`, `INFO replication`, `master_link_status`를 확인한다. 스크립트는 `INFO memory/persistence/replication`, `XLEN`, `XINFO STREAM/GROUPS`, `XPENDING` 요약과 ID 순서상 첫 Pending 1건의 유휴 시간(밀리초)을 읽는다. ID 순서는 실제 대기 시간 순서와 다를 수 있다. `XINFO STREAM`의 첫/마지막 항목 본문은 출력하지 않는다. 오류가 발생하면 대상 주소·인증·Key·Group을 확인한다. 명령은 읽기 전용이며 전체 Key 탐색을 하지 않는다.

## 기존 서버의 모듈 설정 복구와 배포

Redis 8 이미지 진입점은 모듈 디렉터리의 `.so`를 자동 전달한다. `CONFIG REWRITE` 후 `loadmodule`이 설정에 기록되면 다음 시작 시 중복 로딩으로 실패할 수 있다. 빈 디렉터리 마운트는 새 자동 로딩을 막지만 **기존 설정에 남은 `loadmodule`을 제거하지 않는다.** 실제 BE의 모듈 의존성 확인과 데이터 백업 없이 적용하지 않는다.

1. 적용 전 Master/Replica 각각의 `redis.conf`, Docker 볼륨의 AOF와 ACL·인증·복제 설정을 백업하고 복원 가능한지 확인한다. 현재 역할과 복제 상태, `MODULE LIST`, 파일 내 `loadmodule`을 읽기 전용으로 확인한다. 비밀번호가 담긴 설정 백업은 제한된 권한으로 보관한다.
2. 각 설정 파일의 사본에서 이미지 자동 로딩으로 생성된 `loadmodule /usr/local/lib/redis/modules/...` 지시문만 선택적으로 제거한다. 다른 `loadmodule`이 있으면 용도를 확인하고 멈춘다. `requirepass`, `masterauth`, `replicaof`, `appendonly`, `dir` 및 Sentinel 파일은 유지한다. 설정 파일 전체를 삭제하거나 재생성하지 않는다.
3. 승인된 점검 창에 Master/Replica의 빈 디렉터리 마운트와 검토한 설정을 적용한다. 컨테이너 재생성·재시작은 배포 승인 후 별도 실행한다. `PING`, `MODULE LIST`, `INFO replication/persistence`, BE 연결, Sentinel의 Master 조회를 확인한다. 단일 노드 재시작과 Sentinel Failover는 별도 검증한다.
4. 기동 실패 시 로그를 확인하고 새 설정과 마운트 변경을 되돌린 뒤 백업한 설정·AOF로 복원한다. 복제 승격이 있었다면 현재 Master와 데이터 최신성을 먼저 판정한다.

Staging의 `user_data_replace_on_change = true` 때문에 이 템플릿 변경의 Terraform Apply는 Redis EC2 교체를 유발할 수 있다. 루트 EBS는 종료 시 삭제되며 Docker AOF도 그 안에 있다. 기존 서버에는 사용자 데이터가 다시 실행되지 않으므로, **기존 EC2를 보존하려면** 변경을 Apply하지 않고 검토된 수동 Compose/설정 수정 절차를 별도로 승인받아야 한다. 교체 배포는 AOF 백업·복원 및 BE 전환 계획을 먼저 마련해야 한다. 현재 Cloud 코드만으로 데이터 보존을 보장할 수 없다.

Cloud 담당은 템플릿·진단·백업/복구·모니터링 경로를 관리한다. BE 담당은 Streams 처리, 멱등성, Owner 전환, 보관 정책과 앱 메트릭을 구현·검증한다. #89 임시 SSM 권한은 실험 종료 후 Ayla가 `redis_test_access.tf` 제거를 검토하고 Terraform Apply까지 완료해야 실제로 회수된다.
