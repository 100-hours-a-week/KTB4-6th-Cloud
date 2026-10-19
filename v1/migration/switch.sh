#!/usr/bin/env bash
# ProxySQL로 원본 dev BE의 DB 접속 대상을 원본 dev DB에서 대상 리허설용 DB로 바꾼다.
# 쿼리를 모아 두는 장치 없이 바꾸면 무엇이 실패하고 빠지는지 재는 기준 실험용이다 (ADR-0012 첫 검증).
#
# 사용법:
#   ./switch.sh --preflight                 # 사전 점검만 (변경 없음)
#   ./switch.sh --mode no-wait              # 실험 1: 원본 쓰기를 막고 바로 전환. 전환 구간의 쓰기는 거부된다
#   ./switch.sh --mode proxysql-wait        # 이전 OFFLINE_SOFT 실험. 기존 세션의 새 쿼리 대기를 보장하지 않는다
#   ./switch.sh --mode hostgroup-wait       # 신규 HG20 대기 → 기존 HG10 종료 → 최종 복제 확인 → HG20 실행
#   ./switch.sh --mode ... --yes            # 확인 질문 없이 진행 (단계별 반복 실행용)
#
# 순서
#   no-wait:       ohio_ro → promote → switch
#   proxysql-wait: hold(원본 OFFLINE_SOFT, 진행 중 쿼리 최대 5초 대기) → ohio_ro → promote → switch
#   ohio_ro: 원본 super_read_only ON, 마지막 binlog 위치 기록
#   promote: 대상이 그 위치까지 반영했을 때만 복제를 끊고 쓰기를 연다. 반영하지 못하면 롤백한다
#   switch:  ProxySQL 그룹 10(BE 기본 그룹)을 대상 서버로 교체한다. 원본 연결은 즉시 끊긴다
#
# 서버 명령은 SSM send-command로 보낸다. DB 비밀번호는 각 컨테이너의 MYSQL_ROOT_PASSWORD를,
# ProxySQL 관리자 계정은 dev-app 서버의 ~/mig/padmin-disk.sh(설정 파일의 값)를 쓴다. 비밀값은 출력하지 않는다.
# 시각은 서버 시계의 epoch 밀리초로 기록하고, verify.py --mark에 그대로 넘긴다.
# 실행 후 대상에만 새 데이터가 생기므로 다음 실행 전에 reset.sh로 되돌린다 (dev 사용 중지 전제).
# macOS 기본 bash(3.2)에서도 동작하도록 연관 배열 등은 쓰지 않는다.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" || exit 1
# 서버 시각(epoch 밀리초). 서버(Ubuntu 26.04)의 date는 %3N을 9자리로 출력해서, 나노초(%N)를 받아 나눈다
NOW='$(( $(date +%s%N) / 1000000 ))'

MODE=""
ASSUME_YES=false
PREFLIGHT_ONLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) shift; MODE=${1:-} ;;
    --yes) ASSUME_YES=true ;;
    --preflight) PREFLIGHT_ONLY=true ;;
    *) echo "알 수 없는 옵션: $1"; exit 1 ;;
  esac
  shift
done
if ! $PREFLIGHT_ONLY; then
  case "$MODE" in no-wait|proxysql-wait|hostgroup-wait) ;; *) echo "--mode no-wait, proxysql-wait 또는 hostgroup-wait를 지정하세요"; exit 1 ;; esac
fi

LOG=switch-$(date +%Y%m%d-%H%M%S)${MODE:+-$MODE}.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date +%T)] $*"; }
die() { log "중단: $*"; exit 1; }

# 원격 출력에서 KEY=값 줄의 값을 꺼낸다.
value_of() { echo "$1" | sed -n "s/^$2=//p" | head -1; }
# epoch 밀리초를 로컬 시각(KST)으로 바꾼다.
kst() { echo "$(date -r $(( $1 / 1000 )) +%T).$(printf '%03d' $(( $1 % 1000 )))"; }

# ---------- 0. 사전 점검 (변경 없음) ----------
preflight() {
  validate_targets || die "리허설 계정·대상·server_id 불일치"
  local ok=1 out lag lag_ok
  log "사전 점검"

  out=$(target_db "$TARGET_SQL \"SELECT CONCAT('SRO=', @@super_read_only); SELECT CONCAT('MAX_CONN=',@@max_connections)\"
docker exec $TARGET_CONTAINER sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -uroot -e \"SHOW REPLICA STATUS\\G\"' | sed -n 's/^ *Replica_IO_Running: /IO=/p; s/^ *Replica_SQL_Running: /SQL=/p; s/^ *Seconds_Behind_Source: /LAG=/p; s/^ *Source_Host: /SRC=/p'") \
    || die "대상 DB 점검 실패"
  lag=$(value_of "$out" LAG)
  lag_ok=false
  [ "$lag" = 0 ] && lag_ok=true
  # 최종 복제는 별도 위치로 확인한다. 부하 중 순간 지연 1~2초는 새 모드의 사전 중단 사유로 삼지 않는다.
  if [ "$MODE" = hostgroup-wait ] && [[ "$lag" =~ ^[0-9]+$ ]] && [ "$lag" -le 2 ]; then lag_ok=true; fi
  if [ "$(value_of "$out" IO)" = Yes ] && [ "$(value_of "$out" SQL)" = Yes ] && $lag_ok \
    && [ "$(value_of "$out" SRO)" = 1 ] && [ "$(value_of "$out" SRC)" = "$SOURCE_DB_IP" ]; then
    log "  ✅ 대상 DB: 원본 복제 중, 지연 ${lag}초, 읽기 전용"
  else
    log "  ❌ 대상 DB: $(echo "$out" | tr '\n' ' ')"; ok=0
  fi
  if [ "$MODE" = hostgroup-wait ]; then
    [ "$(value_of "$out" MAX_CONN)" -ge 32 ] || die "대상 연결 한도가 부족합니다. 리허설은 최소 32 필요(BE pool 10 전제)"
  fi

  out=$(source_db "$SOURCE_SQL \"SELECT CONCAT('RO=', @@read_only, ' SRO=', @@super_read_only); SELECT CONCAT('MAX_CONN=',@@max_connections)\"") || die "원본 DB 점검 실패"
  if echo "$out" | grep -q '^RO=0 SRO=0$'; then
    log "  ✅ 원본 DB: 쓰기 가능"
  else
    log "  ❌ 원본 DB: $out"; ok=0
  fi
  if [ "$MODE" = hostgroup-wait ]; then
    [ "$(value_of "$out" MAX_CONN)" -ge 32 ] || die "원본 연결 한도가 부족합니다. 리허설은 최소 32 필요(BE pool 10 전제)"
  fi

  out=$(proxysql "bash $PADMIN \"SELECT CONCAT('SRV=', hostgroup_id, ':', hostname, ':', status) FROM runtime_mysql_servers ORDER BY hostgroup_id; SELECT CONCAT('TARGET=',hostname,':',status) FROM mysql_servers WHERE hostgroup_id=20\" 2>/dev/null | tr -d '| ' | grep -E '^(SRV|TARGET)='") \
    || die "ProxySQL 점검 실패"
  local target_ok=false
  echo "$out" | grep -qx "TARGET=$TARGET_DB_IP:ONLINE" && target_ok=true
  if [ "$MODE" = hostgroup-wait ] || $PREFLIGHT_ONLY; then
    echo "$out" | grep -qx "TARGET=$TARGET_DB_IP:OFFLINE_HARD" && target_ok=true
  fi
  if echo "$out" | grep -qx "SRV=10:$SOURCE_DB_IP:ONLINE" && $target_ok \
    && ! echo "$out" | grep '^SRV=' | grep -Ev "^SRV=(10:$SOURCE_DB_IP|20:$TARGET_DB_IP):ONLINE$"; then
    log "  ✅ ProxySQL: 그룹 10 = 원본, 그룹 20 = 대상(대기), 대상 상태 확인 정상"
  else
    log "  ❌ ProxySQL: $(echo "$out" | tr '\n' ' ')"; ok=0
  fi

  [ $ok = 1 ] || die "사전 점검 실패. 위 항목을 확인하세요"
  if [ "$MODE" = hostgroup-wait ]; then
    hostgroup_preflight
  fi
  log "사전 점검 통과"
}

# ---------- 롤백 (대상 쓰기를 열기 전에만) ----------
CAN_ROLLBACK=true
rollback() {
  log "롤백 시작: $1"
  $CAN_ROLLBACK || die "대상 승격 이후라 롤백하지 않습니다. 대상 DB를 기준으로 복구하세요"
  if [ "$MODE" = hostgroup-wait ]; then
    hostgroup_rollback
  fi
  proxysql "bash $PADMIN \"UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=10 AND hostname='$SOURCE_DB_IP'; LOAD MYSQL SERVERS TO RUNTIME;\" >/dev/null 2>&1 && echo OK" \
    && log "  ProxySQL 원본 ONLINE 복구" || log "  ⚠️ ProxySQL 복구 실패. dev-app에서 runtime_mysql_servers를 직접 확인하세요"
  source_db "$SOURCE_SQL 'SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;' && echo OK" \
    && log "  원본 DB 쓰기 복구" || log "  ⚠️ 원본 DB 쓰기 복구 실패. 직접 확인하세요"
  log "롤백 끝. 대상 복제는 그대로 두었습니다"
  exit 1
}

# ---------- 전환 ----------
switch_db() {
  local out file pos t_hold="" t_ro t_promote t_switch started
  started=$(date +%s)

  if [ "$MODE" = proxysql-wait ]; then
    # 0. hold: 새 쿼리는 원본으로 가지 않고 ProxySQL에서 기다린다. 진행 중인 쿼리가 끝날 때까지 최대 5초 기다린다
    out=$(proxysql "bash $PADMIN \"UPDATE mysql_servers SET status='OFFLINE_SOFT' WHERE hostgroup_id=10 AND hostname='$SOURCE_DB_IP'; LOAD MYSQL SERVERS TO RUNTIME;\" >/dev/null 2>&1 || exit 1
echo AT=$NOW
for i in \$(seq 1 25); do
  # 열 이름에 숫자가 섞이지 않도록 별칭(n)을 붙이고 값의 숫자만 남긴다
  n=\$(bash $PADMIN \"SELECT IFNULL(SUM(ConnUsed),0) AS n FROM stats_mysql_connection_pool WHERE hostgroup=10 AND srv_host='$SOURCE_DB_IP'\" 2>/dev/null | tr -dc '0-9')
  [ \"\$n\" = 0 ] && break; sleep 0.2
done
echo IN_USE=\$n") || rollback "ProxySQL OFFLINE_SOFT 전환 실패"
    t_hold=$(value_of "$out" AT)
    log "hold: 원본 OFFLINE_SOFT (새 쿼리 대기 시작, 남은 사용 중 연결 $(value_of "$out" IN_USE))"
  fi

  # 1. ohio_ro: 원본 쓰기를 막고 마지막 위치를 읽는다. 읽기 전용 설정은 진행 중인 커밋을 기다린 뒤 적용된다
  out=$(source_db "$SOURCE_SQL 'SET PERSIST super_read_only = ON; SET PERSIST read_only = ON; SHOW BINARY LOG STATUS;' | awk '{print \"FILE=\" \$1; print \"POS=\" \$2}'
echo AT=$NOW") || rollback "원본 읽기 전용 전환 실패"
  file=$(value_of "$out" FILE); pos=$(value_of "$out" POS); t_ro=$(value_of "$out" AT)
  [[ "$file" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ "$pos" =~ ^[0-9]+$ ]] || rollback "원본 마지막 위치를 읽지 못함"
  log "ohio_ro: 원본 읽기 전용 (마지막 위치 $file:$pos)"

  # 2. promote: 대상이 마지막 위치까지 반영했을 때만 복제를 끊고 쓰기를 연다
  CAN_ROLLBACK=false
  out=$(target_db "set -e
r=\$($TARGET_SQL \"SELECT SOURCE_POS_WAIT('$file', $pos, 10)\")
echo WAIT=\$r
case \"\$r\" in ''|-1|NULL) echo NOT_PROMOTED=1; exit 0 ;; esac
$TARGET_SQL 'STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;' && echo PROMOTED=1
echo AT=$NOW") || die "대상 승격 결과 불명확. 원본 쓰기 차단을 유지하고 DB 상태를 확인하세요"
  [ "$(value_of "$out" NOT_PROMOTED)" != 1 ] || { CAN_ROLLBACK=true; rollback "최종 위치까지 복제되지 않음"; }
  [ "$(value_of "$out" PROMOTED)" = 1 ] || die "대상이 마지막 위치까지 반영하지 못함 (SOURCE_POS_WAIT=$(value_of "$out" WAIT))"
  CAN_ROLLBACK=false
  t_promote=$(value_of "$out" AT)
  log "promote: 대상 승격 (SOURCE_POS_WAIT=$(value_of "$out" WAIT)) — 이후 롤백 불가"

  # 3. switch: 그룹 10을 대상으로 교체한다. 원본 연결은 즉시 끊기고, 기다리던 쿼리(실험 2)는 대상에서 실행된다
  out=$(proxysql "bash $PADMIN \"DELETE FROM mysql_servers WHERE hostgroup_id IN (10, 20); INSERT INTO mysql_servers (hostgroup_id, hostname, port, use_ssl, max_connections, comment) VALUES (10, '$TARGET_DB_IP', 3306, 1, $PROXYSQL_MAX_CONNECTIONS, 'target-rehearsal-db (전환 후)'); LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;\" >/dev/null 2>&1 && echo AT=$NOW") \
    || die "ProxySQL 전환 실패. 대상은 이미 승격됐으니 dev-app에서 그룹 10을 대상으로 직접 바꾸세요"
  t_switch=$(value_of "$out" AT)
  log "switch: ProxySQL 그룹 10 = 대상"

  echo
  if [ -n "$t_hold" ]; then
    log "전환 완료 ($MODE): hold부터 switch까지 $(( (t_switch - t_hold) )) ms, ohio_ro부터 switch까지 $(( t_switch - t_ro )) ms (스크립트 전체 $(( $(date +%s) - started ))초)"
    echo "  hold    = $(kst "$t_hold")"
  else
    log "전환 완료 ($MODE): ohio_ro부터 switch까지 $(( t_switch - t_ro )) ms (스크립트 전체 $(( $(date +%s) - started ))초)"
  fi
  echo "  ohio_ro = $(kst "$t_ro")"
  echo "  promote = $(kst "$t_promote")"
  echo "  switch  = $(kst "$t_switch")"
  echo "  원본 마지막 위치 = $file:$pos"
  echo
  echo "verify.py에 넘길 시각:"
  echo "  ${t_hold:+--mark hold=$t_hold }--mark ohio_ro=$t_ro --mark promote=$t_promote --mark switch=$t_switch"
  echo "로그: $LOG"
}

# 새 모드는 기존 실험과 분리하되 SSM·인증·로그 처리는 이 파일의 함수를 사용한다.
source "$(dirname "${BASH_SOURCE[0]}")/hostgroup-wait.sh"
preflight
$PREFLIGHT_ONLY && exit 0

if ! $ASSUME_YES; then
  echo
  read -r -p "전환($MODE)을 시작합니다. 대상 승격 이후에는 reset.sh로만 되돌릴 수 있습니다. 진행하려면 yes 입력: " answer
  [ "$answer" = yes ] || die "취소"
fi
if [ "$MODE" = hostgroup-wait ]; then
  switch_hostgroup
else
  switch_db
fi
