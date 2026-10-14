#!/usr/bin/env bash
# V1 dev DB를 오하이오에서 서울로 넘기는 전환 단계(Nginx 전환 → 오하이오 읽기 전용 → 서울 승격 → 게이트 개방)를
# 로컬에서 한 번에 실행한다. 쓰기가 게이트에서 대기하는 구간을 줄이는 것이 목적이다.
#
# 사용법:
#   ./cutover.sh --preflight   # 사전 점검만 실행 (변경 없음)
#   ./cutover.sh               # 사전 점검 → 확인 → 전환
#
# 전제: 서울 DB가 오하이오를 복제 중이고, 서울 게이트가 닫혀 있으며, 오하이오 Nginx에 proxy-to-seoul 설정이 있다.
# 서버 명령은 SSM send-command로 보낸다. 비밀번호는 각 서버 안에서 Parameter Store로 읽고 명령 인자에 넣지 않는다.
# macOS 기본 bash(3.2)에서도 동작하도록 연관 배열 등은 쓰지 않는다.
set -uo pipefail

PROFILE=${AWS_PROFILE:-meety-admin}

OHIO_REGION=us-east-2
OHIO_APP=i-076b39ef84ef3ddf9     # dev-app-v1 (dev-nginx)
OHIO_DB=i-00b1191f61901d977      # dev-data-v1 (dev-db)
OHIO_DB_IP=10.0.1.147
OHIO_PUBLIC_IP=3.147.128.193

SEOUL_REGION=ap-northeast-2
SEOUL_DB=i-0ba844539a7064cc8     # meety-v2-staging-db (staging-db)
SEOUL_ALB=meety-v2-alb-1443176425.ap-northeast-2.elb.amazonaws.com

NGINX_DIR=/home/ubuntu/meety/nginx
GATE_URL=https://api-dev.meety.io.kr/internal/db-migration/gate
TOKEN_PARAM=/meety/staging/be/MIGRATION_WRITE_GATE_ADMIN_TOKEN

# 서버 안에서 root 비밀번호를 읽어 MYSQL_PWD로 넘긴다. 값은 출력하지 않는다.
OHIO_PWD='export MYSQL_PWD=$(aws ssm get-parameter --region us-east-2 --name /meety/dev/data/DB_ROOT_PASSWORD --with-decryption --query Parameter.Value --output text)'
SEOUL_PWD='export MYSQL_PWD=$(aws ssm get-parameter --region ap-northeast-2 --name /meety/staging/db/DB_ROOT_PASSWORD --with-decryption --query Parameter.Value --output text)'

LOG=cutover-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date +%T)] $*"; }
die() { log "중단: $*"; exit 1; }

# SSM으로 원격 명령을 실행하고 표준 출력을 돌려준다. 실패하면 표준 에러를 보여 주고 1을 반환한다.
# 전환 구간의 시간을 줄이려고 0.5초 간격으로 결과를 확인한다.
ssm_run() {
  local region=$1 instance=$2 script=$3 params cid status
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$script")
  cid=$(aws ssm send-command --profile "$PROFILE" --region "$region" --instance-ids "$instance" \
    --document-name AWS-RunShellScript --comment "db-migration cutover" \
    --parameters "$params" --query Command.CommandId --output text) || return 1
  for _ in $(seq 1 240); do
    status=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$region" \
      --command-id "$cid" --instance-id "$instance" --query Status --output text 2>/dev/null)
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation --profile "$PROFILE" --region "$region" --command-id "$cid" \
          --instance-id "$instance" --query '[StandardOutputContent,StandardErrorContent]' --output text >&2
        return 1 ;;
    esac
    sleep 0.5
  done
  [ "$status" = Success ] || return 1
  aws ssm get-command-invocation --profile "$PROFILE" --region "$region" --command-id "$cid" \
    --instance-id "$instance" --query StandardOutputContent --output text
}

# 원격 출력에서 KEY=값 줄의 값을 꺼낸다.
value_of() { echo "$1" | sed -n "s/^$2=//p" | head -1; }

# 서버가 출력한 epoch 초를 로컬 시각(KST)으로 바꾼다.
kst() { date -r "${1%.*}" +%T; }

gate() { # gate <GET|PUT> <경로 접미사>
  curl -s --max-time 10 -X "$1" --resolve "api-dev.meety.io.kr:443:$SEOUL_IP" \
    "$GATE_URL$2" -H "Authorization: Bearer $TOKEN"
}

# ---------- 0. 사전 점검 (변경 없음) ----------
preflight() {
  local ok=1 out
  log "사전 점검"

  SEOUL_IP=$(dig +short "$SEOUL_ALB" | tail -1)
  [ -n "$SEOUL_IP" ] || die "서울 ALB 주소를 찾지 못함"
  TOKEN=$(aws ssm get-parameter --profile "$PROFILE" --region "$SEOUL_REGION" --name "$TOKEN_PARAM" \
    --with-decryption --query Parameter.Value --output text) || die "관리 토큰을 읽지 못함"

  out=$(ssm_run "$SEOUL_REGION" "$SEOUL_DB" "$SEOUL_PWD
docker exec -e MYSQL_PWD staging-db mysql -uroot -N -e \"SELECT CONCAT('SRO=', @@super_read_only)\"
docker exec -e MYSQL_PWD staging-db mysql -uroot -e 'SHOW REPLICA STATUS\G' | sed -n 's/^ *Replica_IO_Running: /IO=/p; s/^ *Replica_SQL_Running: /SQL=/p; s/^ *Seconds_Behind_Source: /LAG=/p; s/^ *Source_Host: /SRC=/p'") \
    || die "서울 DB 점검 실패"
  if [ "$(value_of "$out" IO)" = Yes ] && [ "$(value_of "$out" SQL)" = Yes ] && [ "$(value_of "$out" LAG)" = 0 ] \
    && [ "$(value_of "$out" SRO)" = 1 ] && [ "$(value_of "$out" SRC)" = "$OHIO_DB_IP" ]; then
    log "  ✅ 서울 DB: 오하이오 복제 중, 지연 0, 읽기 전용"
  else
    log "  ❌ 서울 DB: $(echo "$out" | tr '\n' ' ')"; ok=0
  fi

  out=$(ssm_run "$OHIO_REGION" "$OHIO_DB" "$OHIO_PWD
docker exec -e MYSQL_PWD dev-db mysql -uroot -N -e \"SELECT CONCAT('RO=', @@read_only)\"") || die "오하이오 DB 점검 실패"
  if [ "$(value_of "$out" RO)" = 0 ]; then
    log "  ✅ 오하이오 DB: 쓰기 가능 (Primary)"
  else
    log "  ❌ 오하이오 DB: 읽기 전용 상태"; ok=0
  fi

  out=$(ssm_run "$OHIO_REGION" "$OHIO_APP" "cd $NGINX_DIR
echo PROXY_FILES=\$(ls proxy-to-seoul/*.conf 2>/dev/null | wc -l)
echo ACTIVE=\$(cat conf.d/*.conf | grep -c seoul_alb)
IP=\$(dig +short $SEOUL_ALB | tail -1)
echo HEALTH=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve api-dev.meety.io.kr:443:\$IP https://api-dev.meety.io.kr/actuator/health)") \
    || die "오하이오 앱 서버 점검 실패"
  if [ "$(value_of "$out" PROXY_FILES)" = 2 ] && [ "$(value_of "$out" ACTIVE)" = 0 ] && [ "$(value_of "$out" HEALTH)" = 200 ]; then
    log "  ✅ 오하이오 Nginx: 원래 설정 적용 중, 프록시 설정 2개 준비, 서울 ALB 접속 200"
  else
    log "  ❌ 오하이오 Nginx: $(echo "$out" | tr '\n' ' ')"; ok=0
  fi

  out=$(gate GET "")
  case "$out" in
    *'"closed":true'*) log "  ✅ 서울 게이트: 닫힘 ($out)" ;;
    *) log "  ❌ 서울 게이트: $out"; ok=0 ;;
  esac

  # DNS는 프록시가 처리하므로 경고만 한다.
  log "  ℹ️  api-dev DNS: $(dig +short api-dev.meety.io.kr | tr '\n' ' ')"

  [ $ok = 1 ] || die "사전 점검 실패. 위 항목을 확인하세요"
  log "사전 점검 통과"
}

# ---------- 롤백 (서울 쓰기를 열기 전에만) ----------
BACKUP=""
rollback() {
  log "롤백 시작: $1"
  if [ -n "$BACKUP" ]; then
    ssm_run "$OHIO_REGION" "$OHIO_APP" "cd $NGINX_DIR && cp $BACKUP/*.conf conf.d/ && docker exec dev-nginx nginx -t && docker exec dev-nginx nginx -s reload && echo NGINX_RESTORED" \
      && log "  Nginx 원래 설정 복구" || log "  ⚠️ Nginx 복구 실패. 백업 $BACKUP 으로 직접 복구하세요"
  fi
  ssm_run "$OHIO_REGION" "$OHIO_DB" "$OHIO_PWD
docker exec -e MYSQL_PWD dev-db mysql -uroot -e 'SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;'" \
    && log "  오하이오 DB 쓰기 복구" || log "  ⚠️ 오하이오 DB 쓰기 복구 실패. 직접 확인하세요"
  log "롤백 끝. 서울 복제는 그대로 두었으니 원인을 확인한 뒤 다시 실행하면 됩니다"
  exit 1
}

# ---------- 전환 ----------
cutover() {
  local out file pos t_dns t_ro t_gate started
  started=$(date +%s)

  # 2. Nginx 전환: 이 순간부터 새 요청은 서울 BE로 가고, 쓰기는 게이트에서 대기한다.
  out=$(ssm_run "$OHIO_REGION" "$OHIO_APP" "cd $NGINX_DIR && BK=conf.d.bak-\$(date +%H%M%S) && cp -a conf.d \$BK && echo BACKUP=\$BK && cp proxy-to-seoul/*.conf conf.d/ && docker exec dev-nginx nginx -t 2>&1 && docker exec dev-nginx nginx -s reload && echo AT=\$(date +%s) || { cp \$BK/*.conf conf.d/; docker exec dev-nginx nginx -s reload; echo FAILED; exit 1; }") \
    || { BACKUP=""; die "Nginx 전환 실패 (원래 설정으로 자동 복구됨)"; }
  BACKUP=$(value_of "$out" BACKUP)
  NGINX_BACKUP=$BACKUP   # 롤백 대상이 아니게 된 뒤에도 출력용으로 남긴다.
  t_dns=$(value_of "$out" AT)
  log "Nginx 전환 완료 (백업 $BACKUP)"

  # 3. 오하이오 마무리: 처리 중 쿼리가 끝나길 최대 5초 기다린 뒤 읽기 전용으로 바꾸고 마지막 위치를 읽는다.
  #    5초가 지나도 남아 있으면 그대로 진행한다. 읽기 전용 설정이 진행 중인 커밋을 기다린 뒤 적용된다.
  out=$(ssm_run "$OHIO_REGION" "$OHIO_DB" "$OHIO_PWD
for i in \$(seq 1 25); do
  n=\$(docker exec -e MYSQL_PWD dev-db mysql -uroot -N -e \"SELECT COUNT(*) FROM information_schema.processlist WHERE command NOT IN ('Sleep','Binlog Dump','Daemon') AND id <> CONNECTION_ID()\")
  [ \"\$n\" = 0 ] && break; sleep 0.2
done
echo ACTIVE_QUERIES=\$n
docker exec -e MYSQL_PWD dev-db mysql -uroot -N -e 'SET GLOBAL super_read_only = ON; SHOW BINARY LOG STATUS;' | awk '{print \"FILE=\" \$1; print \"POS=\" \$2}'
echo AT=\$(date +%s)") || rollback "오하이오 읽기 전용 전환 실패"
  file=$(value_of "$out" FILE); pos=$(value_of "$out" POS); t_ro=$(value_of "$out" AT)
  [ -n "$file" ] && [ -n "$pos" ] || rollback "오하이오 마지막 위치를 읽지 못함"
  log "오하이오 읽기 전용 (마지막 위치 $file:$pos, 남은 쿼리 $(value_of "$out" ACTIVE_QUERIES))"

  # 4. 서울 승격: 마지막 위치까지 반영됐을 때만 복제를 끊고 쓰기를 연다. 반영되지 않으면 아무것도 바꾸지 않는다.
  out=$(ssm_run "$SEOUL_REGION" "$SEOUL_DB" "$SEOUL_PWD
r=\$(docker exec -e MYSQL_PWD staging-db mysql -uroot -N -e \"SELECT SOURCE_POS_WAIT('$file', $pos, 10)\")
echo WAIT=\$r
case \"\$r\" in
  ''|-1|NULL) exit 0 ;;
esac
docker exec -e MYSQL_PWD staging-db mysql -uroot -e 'STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;' && echo PROMOTED=1") \
    || rollback "서울 승격 명령 실패 (승격 여부를 서울 DB에서 직접 확인하세요)"
  if [ "$(value_of "$out" PROMOTED)" != 1 ]; then
    rollback "서울이 마지막 위치까지 반영하지 못함 (SOURCE_POS_WAIT=$(value_of "$out" WAIT))"
  fi
  BACKUP=""   # 여기부터는 롤백하지 않는다.
  log "서울 승격 완료 (SOURCE_POS_WAIT=$(value_of "$out" WAIT)) — 이후 롤백 불가"

  # 5. 게이트 개방. 실패하면 세 번까지 다시 시도한다.
  for _ in 1 2 3; do
    out=$(gate PUT /open)
    case "$out" in *'"closed":false'*) break ;; esac
    sleep 1
  done
  t_gate=$(date +%s)
  case "$out" in
    *'"closed":false'*) log "게이트 개방 ($out)" ;;
    *) log "⚠️ 게이트 개방 실패: $out — 직접 PUT $GATE_URL/open 을 호출하세요" ;;
  esac

  # 6. 기록 출력
  echo
  log "전환 완료: Nginx 전환부터 게이트 개방까지 $(( t_gate - ${t_dns%.*} ))초 (스크립트 전체 $(( t_gate - started ))초)"
  echo "  dns       = $(kst "$t_dns")"
  echo "  ohio_ro   = $(kst "$t_ro")"
  echo "  gate_open = $(kst "$t_gate")"
  echo "  오하이오 마지막 위치 = $file:$pos"
  echo "  Nginx 백업 = $NGINX_BACKUP (오하이오 앱 서버 $NGINX_DIR, 원래 설정으로 되돌릴 때 사용)"
  echo
  echo "검증 명령:"
  echo "  python3 verify.py --run <RUN_ID> --ops ops-<RUN_ID>.jsonl --db meetings-<RUN_ID>.tsv --mark dns=$(kst "$t_dns") --mark ohio_ro=$(kst "$t_ro") --mark gate_open=$(kst "$t_gate")"
  echo "로그: $LOG"
}

preflight
[ "${1:-}" = "--preflight" ] && exit 0

echo
read -r -p "전환을 시작합니다. 서울 승격 이후에는 되돌릴 수 없습니다. 진행하려면 yes 입력: " answer
[ "$answer" = yes ] || die "취소"
cutover
