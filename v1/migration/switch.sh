#!/usr/bin/env bash
# ProxySQL로 오하이오 dev BE의 DB 접속 대상을 오하이오 dev DB에서 서울 리허설용 DB로 바꾼다.
# 쿼리를 모아 두는 장치 없이 바꾸면 무엇이 실패하고 빠지는지 재는 기준 실험용이다 (ADR-0012 첫 검증).
#
# 사용법:
#   ./switch.sh --preflight                 # 사전 점검만 (변경 없음)
#   ./switch.sh --mode no-wait              # 실험 1: 오하이오 쓰기를 막고 바로 전환. 전환 구간의 쓰기는 거부된다
#   ./switch.sh --mode proxysql-wait        # 이전 OFFLINE_SOFT 실험. 기존 세션의 새 쿼리 대기를 보장하지 않는다
#   ./switch.sh --mode hostgroup-wait       # 신규 HG20 대기 → 기존 HG10 종료 → 최종 복제 확인 → HG20 실행
#   ./switch.sh --mode ... --yes            # 확인 질문 없이 진행 (단계별 반복 실행용)
#
# 순서
#   no-wait:       ohio_ro → promote → switch
#   proxysql-wait: hold(오하이오 OFFLINE_SOFT, 진행 중 쿼리 최대 5초 대기) → ohio_ro → promote → switch
#   ohio_ro: 오하이오 super_read_only ON, 마지막 binlog 위치 기록
#   promote: 서울이 그 위치까지 반영했을 때만 복제를 끊고 쓰기를 연다. 반영하지 못하면 롤백한다
#   switch:  ProxySQL 그룹 10(BE 기본 그룹)을 서울 서버로 교체한다. 오하이오 연결은 즉시 끊긴다
#
# 서버 명령은 SSM send-command로 보낸다. DB 비밀번호는 각 컨테이너의 MYSQL_ROOT_PASSWORD를,
# ProxySQL 관리자 계정은 dev-app 서버의 ~/mig/padmin-disk.sh(설정 파일의 값)를 쓴다. 비밀값은 출력하지 않는다.
# 시각은 서버 시계의 epoch 밀리초로 기록하고, verify.py --mark에 그대로 넘긴다.
# 실행 후 서울에만 새 데이터가 생기므로 다음 실행 전에 reset.sh로 되돌린다 (dev 사용 중지 전제).
# macOS 기본 bash(3.2)에서도 동작하도록 연관 배열 등은 쓰지 않는다.
set -uo pipefail

PROFILE=${AWS_PROFILE:-meety-admin}

OHIO_REGION=us-east-2
OHIO_APP=i-076b39ef84ef3ddf9     # dev-app-v1 (dev-be, dev-proxysql)
OHIO_DB=i-00b1191f61901d977      # dev-data-v1 (dev-db)
OHIO_DB_IP=10.0.1.147

SEOUL_REGION=ap-northeast-2
SEOUL_DB=i-0bdf97a1cf0ba7025     # meety-v2-staging-migration-db (migration-db)
SEOUL_DB_IP=10.1.10.140

PADMIN=/home/ubuntu/mig/padmin-disk.sh
OHIO_SQL='docker exec dev-db sh -c '\''MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "$0"'\'
SEOUL_SQL='docker exec migration-db sh -c '\''MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "$0"'\'
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

# SSM으로 원격 명령을 실행하고 표준 출력을 돌려준다. 실패하면 표준 에러를 보여 주고 1을 반환한다.
# 전환 구간을 줄이려고 0.3초 간격으로 결과를 확인한다.
ssm_run() {
  local region=$1 instance=$2 script=$3 params cid status
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$script")
  cid=$(aws ssm send-command --profile "$PROFILE" --region "$region" --instance-ids "$instance" \
    --document-name AWS-RunShellScript --comment "db-migration switch" \
    --parameters "$params" --query Command.CommandId --output text) || return 1
  for _ in $(seq 1 400); do
    status=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$region" \
      --command-id "$cid" --instance-id "$instance" --query Status --output text 2>/dev/null)
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation --profile "$PROFILE" --region "$region" --command-id "$cid" \
          --instance-id "$instance" --query '[StandardOutputContent,StandardErrorContent]' --output text >&2
        return 1 ;;
    esac
    sleep 0.3
  done
  [ "$status" = Success ] || return 1
  aws ssm get-command-invocation --profile "$PROFILE" --region "$region" --command-id "$cid" \
    --instance-id "$instance" --query StandardOutputContent --output text
}

# 원격 출력에서 KEY=값 줄의 값을 꺼낸다.
value_of() { echo "$1" | sed -n "s/^$2=//p" | head -1; }
# epoch 밀리초를 로컬 시각(KST)으로 바꾼다.
kst() { echo "$(date -r $(( $1 / 1000 )) +%T).$(printf '%03d' $(( $1 % 1000 )))"; }

ohio() { ssm_run "$OHIO_REGION" "$OHIO_DB" "$1"; }
seoul() { ssm_run "$SEOUL_REGION" "$SEOUL_DB" "$1"; }
proxysql() { ssm_run "$OHIO_REGION" "$OHIO_APP" "$1"; }

# ---------- 0. 사전 점검 (변경 없음) ----------
preflight() {
  local ok=1 out lag lag_ok
  log "사전 점검"

  out=$(seoul "$SEOUL_SQL \"SELECT CONCAT('SRO=', @@super_read_only); SELECT CONCAT('MAX_CONN=',@@max_connections)\"
docker exec migration-db sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -uroot -e \"SHOW REPLICA STATUS\\G\"' | sed -n 's/^ *Replica_IO_Running: /IO=/p; s/^ *Replica_SQL_Running: /SQL=/p; s/^ *Seconds_Behind_Source: /LAG=/p; s/^ *Source_Host: /SRC=/p'") \
    || die "서울 DB 점검 실패"
  lag=$(value_of "$out" LAG)
  lag_ok=false
  [ "$lag" = 0 ] && lag_ok=true
  # 최종 복제는 별도 위치로 확인한다. 부하 중 순간 지연 1~2초는 새 모드의 사전 중단 사유로 삼지 않는다.
  if [ "$MODE" = hostgroup-wait ] && [[ "$lag" =~ ^[0-9]+$ ]] && [ "$lag" -le 2 ]; then lag_ok=true; fi
  if [ "$(value_of "$out" IO)" = Yes ] && [ "$(value_of "$out" SQL)" = Yes ] && $lag_ok \
    && [ "$(value_of "$out" SRO)" = 1 ] && [ "$(value_of "$out" SRC)" = "$OHIO_DB_IP" ]; then
    log "  ✅ 서울 DB: 오하이오 복제 중, 지연 ${lag}초, 읽기 전용"
  else
    log "  ❌ 서울 DB: $(echo "$out" | tr '\n' ' ')"; ok=0
  fi
  if [ "$MODE" = hostgroup-wait ]; then
    [ "$(value_of "$out" MAX_CONN)" -ge 32 ] || die "서울 연결 한도가 부족합니다. 리허설은 최소 32 필요(BE pool 10 전제)"
  fi

  out=$(ohio "$OHIO_SQL \"SELECT CONCAT('RO=', @@read_only, ' SRO=', @@super_read_only); SELECT CONCAT('MAX_CONN=',@@max_connections)\"") || die "오하이오 DB 점검 실패"
  if echo "$out" | grep -q '^RO=0 SRO=0$'; then
    log "  ✅ 오하이오 DB: 쓰기 가능"
  else
    log "  ❌ 오하이오 DB: $out"; ok=0
  fi
  if [ "$MODE" = hostgroup-wait ]; then
    [ "$(value_of "$out" MAX_CONN)" -ge 32 ] || die "오하이오 연결 한도가 부족합니다. 리허설은 최소 32 필요(BE pool 10 전제)"
  fi

  out=$(proxysql "bash $PADMIN \"SELECT CONCAT('SRV=', hostgroup_id, ':', hostname, ':', status) FROM runtime_mysql_servers ORDER BY hostgroup_id; SELECT CONCAT('MON=', IFNULL(connect_error, 'ok')) FROM monitor.mysql_server_connect_log WHERE hostname='$SEOUL_DB_IP' ORDER BY time_start_us DESC LIMIT 1\" 2>/dev/null | tr -d '| ' | grep -E '^(SRV|MON)='") \
    || die "ProxySQL 점검 실패"
  if echo "$out" | grep -qx "SRV=10:$OHIO_DB_IP:ONLINE" && echo "$out" | grep -qx "SRV=20:$SEOUL_DB_IP:ONLINE" \
    && [ "$(echo "$out" | grep -c '^SRV=')" = 2 ] && [ "$(value_of "$out" MON)" = ok ]; then
    log "  ✅ ProxySQL: 그룹 10 = 오하이오, 그룹 20 = 서울(대기), 서울 상태 확인 정상"
  else
    log "  ❌ ProxySQL: $(echo "$out" | tr '\n' ' ')"; ok=0
  fi

  [ $ok = 1 ] || die "사전 점검 실패. 위 항목을 확인하세요"
  if [ "$MODE" = hostgroup-wait ]; then
    hostgroup_preflight
  fi
  log "사전 점검 통과"
}

# ---------- 롤백 (서울 쓰기를 열기 전에만) ----------
CAN_ROLLBACK=true
rollback() {
  log "롤백 시작: $1"
  $CAN_ROLLBACK || die "서울 승격 이후라 롤백하지 않습니다. 서울 DB를 기준으로 복구하세요"
  if [ "$MODE" = hostgroup-wait ]; then
    hostgroup_rollback
  fi
  proxysql "bash $PADMIN \"UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=10 AND hostname='$OHIO_DB_IP'; LOAD MYSQL SERVERS TO RUNTIME;\" >/dev/null 2>&1 && echo OK" \
    && log "  ProxySQL 오하이오 ONLINE 복구" || log "  ⚠️ ProxySQL 복구 실패. dev-app에서 runtime_mysql_servers를 직접 확인하세요"
  ohio "$OHIO_SQL 'SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;' && echo OK" \
    && log "  오하이오 DB 쓰기 복구" || log "  ⚠️ 오하이오 DB 쓰기 복구 실패. 직접 확인하세요"
  log "롤백 끝. 서울 복제는 그대로 두었습니다"
  exit 1
}

# ---------- 전환 ----------
switch_db() {
  local out file pos t_hold="" t_ro t_promote t_switch started
  started=$(date +%s)

  if [ "$MODE" = proxysql-wait ]; then
    # 0. hold: 새 쿼리는 오하이오로 가지 않고 ProxySQL에서 기다린다. 진행 중인 쿼리가 끝날 때까지 최대 5초 기다린다
    out=$(proxysql "bash $PADMIN \"UPDATE mysql_servers SET status='OFFLINE_SOFT' WHERE hostgroup_id=10 AND hostname='$OHIO_DB_IP'; LOAD MYSQL SERVERS TO RUNTIME;\" >/dev/null 2>&1 || exit 1
echo AT=$NOW
for i in \$(seq 1 25); do
  # 열 이름에 숫자가 섞이지 않도록 별칭(n)을 붙이고 값의 숫자만 남긴다
  n=\$(bash $PADMIN \"SELECT IFNULL(SUM(ConnUsed),0) AS n FROM stats_mysql_connection_pool WHERE hostgroup=10 AND srv_host='$OHIO_DB_IP'\" 2>/dev/null | tr -dc '0-9')
  [ \"\$n\" = 0 ] && break; sleep 0.2
done
echo IN_USE=\$n") || rollback "ProxySQL OFFLINE_SOFT 전환 실패"
    t_hold=$(value_of "$out" AT)
    log "hold: 오하이오 OFFLINE_SOFT (새 쿼리 대기 시작, 남은 사용 중 연결 $(value_of "$out" IN_USE))"
  fi

  # 1. ohio_ro: 오하이오 쓰기를 막고 마지막 위치를 읽는다. 읽기 전용 설정은 진행 중인 커밋을 기다린 뒤 적용된다
  out=$(ohio "$OHIO_SQL 'SET GLOBAL super_read_only = ON; SHOW BINARY LOG STATUS;' | awk '{print \"FILE=\" \$1; print \"POS=\" \$2}'
echo AT=$NOW") || rollback "오하이오 읽기 전용 전환 실패"
  file=$(value_of "$out" FILE); pos=$(value_of "$out" POS); t_ro=$(value_of "$out" AT)
  [ -n "$file" ] && [ -n "$pos" ] || rollback "오하이오 마지막 위치를 읽지 못함"
  log "ohio_ro: 오하이오 읽기 전용 (마지막 위치 $file:$pos)"

  # 2. promote: 서울이 마지막 위치까지 반영했을 때만 복제를 끊고 쓰기를 연다
  out=$(seoul "r=\$($SEOUL_SQL \"SELECT SOURCE_POS_WAIT('$file', $pos, 10)\")
echo WAIT=\$r
case \"\$r\" in ''|-1|NULL) exit 0 ;; esac
$SEOUL_SQL 'STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;' && echo PROMOTED=1
echo AT=$NOW") || rollback "서울 승격 명령 실패 (승격 여부를 서울 DB에서 직접 확인하세요)"
  [ "$(value_of "$out" PROMOTED)" = 1 ] || rollback "서울이 마지막 위치까지 반영하지 못함 (SOURCE_POS_WAIT=$(value_of "$out" WAIT))"
  CAN_ROLLBACK=false
  t_promote=$(value_of "$out" AT)
  log "promote: 서울 승격 (SOURCE_POS_WAIT=$(value_of "$out" WAIT)) — 이후 롤백 불가"

  # 3. switch: 그룹 10을 서울로 교체한다. 오하이오 연결은 즉시 끊기고, 기다리던 쿼리(실험 2)는 서울에서 실행된다
  out=$(proxysql "bash $PADMIN \"DELETE FROM mysql_servers WHERE hostgroup_id IN (10, 20); INSERT INTO mysql_servers (hostgroup_id, hostname, port, use_ssl, comment) VALUES (10, '$SEOUL_DB_IP', 3306, 1, 'seoul-migration-db (전환 후)'); LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;\" >/dev/null 2>&1 && echo AT=$NOW") \
    || die "ProxySQL 전환 실패. 서울은 이미 승격됐으니 dev-app에서 그룹 10을 서울로 직접 바꾸세요"
  t_switch=$(value_of "$out" AT)
  log "switch: ProxySQL 그룹 10 = 서울"

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
  echo "  오하이오 마지막 위치 = $file:$pos"
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
  read -r -p "전환($MODE)을 시작합니다. 서울 승격 이후에는 reset.sh로만 되돌릴 수 있습니다. 진행하려면 yes 입력: " answer
  [ "$answer" = yes ] || die "취소"
fi
if [ "$MODE" = hostgroup-wait ]; then
  switch_hostgroup
else
  switch_db
fi
