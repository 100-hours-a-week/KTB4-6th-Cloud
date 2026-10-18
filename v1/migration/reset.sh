#!/usr/bin/env bash
# switch.sh 실행 뒤, 다음 실행을 위해 처음 상태로 되돌린다.
#   1. ProxySQL: 그룹 10 = 오하이오, 그룹 20 = 서울(대기)
#   2. 오하이오 dev DB: 쓰기 허용, 리허설 연결 한도 64 (유지 연결+복구 HG 별칭 수용)
#   3. 서울 리허설용 DB: 복제 정리 → dev_meetyDB 비우기 → 오하이오에서 다시 덤프·복원 → 복제 시작, 읽기 전용
#      (서버의 /root/mig-1-load.sh, /root/mig-2-start.sh를 쓴다)
#   4. 오하이오와 서울의 테이블별 행 수 비교
#      초기화 때만 ProxySQL을 재시작해 이전 시험의 HG20 연결을 정리한다. BE는 재시작하지 않는다.
#
# 전환 후 서울에만 쓰인 테스트 데이터는 버린다. 테스트 동안 dev 사용을 멈추는 전제다.
# 반드시 collect.sh로 결과를 받은 뒤 실행한다. 서울 데이터가 지워진다.
#
# 사용법: ./reset.sh [--yes]
set -uo pipefail

PROFILE=${AWS_PROFILE:-meety-admin}
OHIO_REGION=us-east-2
OHIO_APP=i-076b39ef84ef3ddf9
OHIO_DB=i-00b1191f61901d977
OHIO_DB_IP=10.0.1.147
SEOUL_REGION=ap-northeast-2
SEOUL_DB=i-0bdf97a1cf0ba7025
SEOUL_DB_IP=10.1.10.140
PADMIN=/home/ubuntu/mig/padmin-disk.sh
OHIO_SQL='docker exec dev-db sh -c '\''MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "$0"'\'
SEOUL_SQL='docker exec migration-db sh -c '\''MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "$0"'\'
# 테이블별 정확한 행 수를 해시로 묶는다. 두 DB에서 같은 값이면 행 수가 모두 같다
ROWS_MD5='T=$(MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema=\"dev_meetyDB\" ORDER BY 1"); Q=""; for t in $T; do Q="$Q SELECT \"$t\", COUNT(*) FROM dev_meetyDB.\`$t\` UNION ALL"; done; MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "${Q% UNION ALL}" | md5sum | cut -c1-32'

[ "${1:-}" = "--yes" ] || {
  read -r -p "collect.sh로 결과를 받았나요? 서울 리허설용 DB의 데이터를 지우고 다시 복제합니다. 진행하려면 yes 입력: " answer
  [ "$answer" = yes ] || { echo "취소"; exit 1; }
}

log() { echo "[$(date +%T)] $*"; }
die() { log "중단: $*"; exit 1; }

ssm_run() { # 지역 인스턴스 스크립트 [타임아웃 초]
  local region=$1 instance=$2 script=$3 limit=${4:-120} params cid status
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["900"]}))' "$script")
  cid=$(aws ssm send-command --profile "$PROFILE" --region "$region" --instance-ids "$instance" \
    --document-name AWS-RunShellScript --comment "db-migration reset" \
    --parameters "$params" --query Command.CommandId --output text) || return 1
  for _ in $(seq 1 "$limit"); do
    status=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$region" \
      --command-id "$cid" --instance-id "$instance" --query Status --output text 2>/dev/null)
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation --profile "$PROFILE" --region "$region" --command-id "$cid" \
          --instance-id "$instance" --query '[StandardOutputContent,StandardErrorContent]' --output text >&2
        return 1 ;;
    esac
    sleep 2
  done
  [ "$status" = Success ] || return 1
  aws ssm get-command-invocation --profile "$PROFILE" --region "$region" --command-id "$cid" \
    --instance-id "$instance" --query StandardOutputContent --output text
}

# 1. ProxySQL을 오하이오로 되돌린다
ssm_run "$OHIO_REGION" "$OHIO_APP" "bash $PADMIN \"DELETE FROM mysql_query_rules WHERE comment='migration-hostgroup-wait'; LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK; DELETE FROM mysql_servers WHERE hostgroup_id IN (10, 20); INSERT INTO mysql_servers (hostgroup_id, hostname, port, use_ssl, comment) VALUES (10, '$OHIO_DB_IP', 3306, 1, 'ohio-dev-db'), (20, '$SEOUL_DB_IP', 3306, 1, 'seoul-migration-db (전환 대기)'); LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; UPDATE global_variables SET variable_value='true' WHERE variable_name='mysql-enforce_autocommit_on_reads'; UPDATE global_variables SET variable_value='30000' WHERE variable_name='mysql-connect_timeout_server_max'; LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;\" >/dev/null 2>&1 && echo OK" >/dev/null \
  || die "ProxySQL 복구 실패"
log "1. ProxySQL: 그룹 10 = 오하이오, 그룹 20 = 서울(대기)"

# 2. 오하이오 쓰기 허용
ssm_run "$OHIO_REGION" "$OHIO_DB" "$OHIO_SQL 'SET GLOBAL max_connections=64; SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;' && echo OK" >/dev/null \
  || die "오하이오 쓰기 복구 실패"
log "2. 오하이오 dev DB: 쓰기 허용"

# 3. 서울: 복제 정리 → DB 비우기 → 다시 덤프·복원 → 복제 시작
out=$(ssm_run "$SEOUL_REGION" "$SEOUL_DB" "set -e
$SEOUL_SQL 'SET GLOBAL max_connections=64; STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF; DROP DATABASE IF EXISTS dev_meetyDB; CREATE DATABASE dev_meetyDB;'
bash /root/mig-1-load.sh
bash /root/mig-2-start.sh" 300) || die "서울 리허설용 DB 재구성 실패"
echo "$out" | grep -E 'dump bytes|CHANGE|restored|Replica_(IO|SQL)_Running|Seconds_Behind|read_only' | sed 's/^/   /'
log "3. 서울 리허설용 DB: 다시 복제"

# 같은 HG/주소를 삭제 후 재등록하고 한 번만 LOAD하면 이전 연결이 남을 수 있다.
# 부하를 걸기 전 초기화 단계에서만 풀을 비운다. 실제 switch.sh 전환은 재시작하지 않는다.
ssm_run "$OHIO_REGION" "$OHIO_APP" "set -e
docker restart dev-proxysql >/dev/null
for i in \$(seq 1 30); do
  if bash $PADMIN 'SELECT 1' >/dev/null 2>&1; then echo PROXY_READY=1; exit 0; fi
  sleep 1
done
exit 1" >/dev/null || die "ProxySQL 초기 풀 정리 실패"
log "   ProxySQL 초기 풀 정리 완료 (BE 재시작 없음)"

# 4. 행 수 비교
sleep 3
a=$(ssm_run "$OHIO_REGION" "$OHIO_DB" "docker exec dev-db sh -c '$ROWS_MD5'") || die "오하이오 행 수 조회 실패"
b=$(ssm_run "$SEOUL_REGION" "$SEOUL_DB" "docker exec migration-db sh -c '$ROWS_MD5'") || die "서울 행 수 조회 실패"
if [ -n "$a" ] && [ "$a" = "$b" ]; then
  log "4. 행 수 일치 ($a)"
else
  die "4. 행 수 불일치 (오하이오 $a, 서울 $b). switch.sh를 실행하지 마세요"
fi
log "초기화 완료. switch.sh --preflight로 확인한 뒤 다음 실행을 시작하세요"
