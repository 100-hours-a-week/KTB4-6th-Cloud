#!/usr/bin/env bash
# prod를 수동으로 끄고 켠다. 매일 한국 시간 00:00에는 AWS 예약(terraform/prod/power_schedule.tf)이 같은 대상을 한 번에 끄며, 자동 켜기는 없다.
# 대상: BE ECS 서비스 2개, AI 서버 2대, 모니터링 서버, FE(NAT 겸용), DB Primary와 Replica, Redis
# 꺼 둔 상태에서 terraform/prod를 apply하면 ECS 최소·최대값이 되돌아가 BE만 켜지므로, apply 전에 on을 먼저 실행한다
# 꺼 두는 동안 BE, FE, AI의 main 머지(prod 배포)는 실패하므로 팀에 배포 중지를 알린다
# hold 중에 apply하면 예약 상태(DISABLED, 예약 확장 중지)가 코드 값으로 되돌아가므로, apply 전에 release를 실행한다
#
# 사용: ./prod-power.sh <on|off|status|hold|release> [--profile 프로필]
#   on      FE(NAT) → DB, Redis → Replica 복제 시작 → AI, 모니터링 → BE 순서로 켜고 정상이 될 때까지 기다린다
#   off     BE → AI, 모니터링 → DB, Redis(MySQL, Redis를 먼저 정상 종료) → FE 순서로 끈다
#   status  서버, ECS, 자정 예약, Replica 복제 상태를 보여준다
#   hold    자정 자동 종료 예약을 멈춘다 (켜 둔 채 밤을 넘겨야 할 때)
#   release 멈춘 자정 예약을 다시 켠다
set -euo pipefail

ACTION=${1:?on, off, status, hold, release 중 하나를 지정하세요}
case "$ACTION" in on|off|status|hold|release) ;; *) echo "on, off, status, hold, release만 가능합니다: $ACTION"; exit 1 ;; esac
# macOS 기본 bash(3.2)에서 빈 배열이 set -u에 걸리므로 프로필은 환경 변수로 넘긴다
if [ "${2:-}" = "--profile" ]; then export AWS_PROFILE=${3:?프로필 이름}; fi
export AWS_PAGER=""
export AWS_DEFAULT_REGION=ap-northeast-2

ENV=prod
PREFIX=meety-v2-$ENV
CLUSTER=$PREFIX
SERVICES="be-api be-realtime"
# 켤 때 되돌릴 최소·최대 태스크 수. terraform/prod/variables.tf의 be_*_min_count, be_*_max_count와 맞춘다
ON_RANGE_be_api="1 3"
ON_RANGE_be_realtime="1 3"
# 켜는 순서대로 묶는다. 끌 때는 반대 순서로 끈다
FE_NAMES="$PREFIX-fe"
DATA_NAMES="$PREFIX-db-primary,$PREFIX-db-replica,$PREFIX-redis"
REPLICA_NAME="$PREFIX-db-replica"
APP_NAMES="$PREFIX-ai,$PREFIX-ai-analysis,$PREFIX-monitoring"
SCHEDULE_GROUP="$PREFIX-power"
SCHEDULE_NAME="$PREFIX-ec2-off"
# DB, Redis 서버의 compose 파일 위치 (terraform user_data와 같다)
COMPOSE=/opt/meety/docker-compose.yml

ids() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}
running_ids() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

FE_IDS=$(ids "$FE_NAMES"); DATA_IDS=$(ids "$DATA_NAMES"); APP_IDS=$(ids "$APP_NAMES")
for v in FE_IDS DATA_IDS APP_IDS; do [ -n "${!v}" ] || { echo "대상 서버를 찾지 못했습니다: $v"; exit 1; }; done
ALL_IDS="$FE_IDS $DATA_IDS $APP_IDS"

# SSM으로 셸 명령을 실행하고 출력을 보여준다. 실패하면 0이 아닌 값을 돌려준다
ssm_run() {
  local id=$1 cmd=$2 params cid status
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["600"]}))' "$cmd")
  cid=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$params" --query Command.CommandId --output text)
  aws ssm wait command-executed --command-id "$cid" --instance-id "$id" 2>/dev/null || true
  status=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text)
  echo "$status"
  [ "${status%%[[:space:]]*}" = Success ]
}

# 서버를 켠 직후에는 SSM 에이전트가 아직 연결되지 않았을 수 있어 Online이 될 때까지 기다린다
wait_ssm_online() {
  local id
  for id in $1; do
    for _ in $(seq 1 60); do
      [ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
        --query 'InstanceInformationList[0].PingStatus' --output text)" = Online ] && break
      sleep 5
    done
  done
}

# Replica는 MySQL 옵션 --skip-replica-start=ON이라 재부팅 뒤 복제를 직접 시작해야 한다
REPLICA_STATUS_CMD='c=$(docker ps --format "{{.Names}}" | grep -E "replica-db$" | head -n1)
[ -n "$c" ] || { echo "Replica MySQL 컨테이너가 실행 중이 아닙니다"; exit 1; }
docker exec "$c" sh -c '"'"'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SHOW REPLICA STATUS\G"'"'"' \
  | grep -E "Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:"'
REPLICA_START_CMD='c=$(docker ps --format "{{.Names}}" | grep -E "replica-db$" | head -n1)
[ -n "$c" ] || { echo "Replica MySQL 컨테이너가 실행 중이 아닙니다"; exit 1; }
for i in $(seq 1 36); do
  docker exec "$c" sh -c '"'"'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqladmin -uroot ping'"'"' >/dev/null 2>&1 && break
  sleep 5
done
docker exec "$c" sh -c '"'"'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "START REPLICA;"'"'"'
sleep 5
'"$REPLICA_STATUS_CMD"

show_status() {
  echo "[서버]"
  aws ec2 describe-instances --instance-ids $ALL_IDS \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name]' --output text | sort
  echo "[ECS] 서비스  최소  최대  예약 확장 중지  실행 중"
  for s in $SERVICES; do
    range=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
      --resource-ids "service/$CLUSTER/$PREFIX-$s" \
      --query 'ScalableTargets[0].[MinCapacity,MaxCapacity,SuspendedState.ScheduledScalingSuspended]' --output text)
    running=$(aws ecs describe-services --cluster "$CLUSTER" --services "$PREFIX-$s" \
      --query 'services[0].runningCount' --output text)
    echo "$s  $range  $running"
  done
  echo "[자정 EC2 종료 예약] $(aws scheduler get-schedule --group-name "$SCHEDULE_GROUP" --name "$SCHEDULE_NAME" --query State --output text 2>/dev/null || echo '없음 (terraform 반영 전)')"
  replica=$(running_ids "$REPLICA_NAME")
  if [ -n "$replica" ]; then
    echo "[Replica 복제]"
    ssm_run "$replica" "$REPLICA_STATUS_CMD" || echo "::warning:: Replica 복제 상태 조회 실패"
  fi
}

set_range() {
  aws application-autoscaling register-scalable-target --service-namespace ecs \
    --resource-id "service/$CLUSTER/$PREFIX-$1" --scalable-dimension ecs:service:DesiredCount \
    --min-capacity "$2" --max-capacity "$3" >/dev/null
}

# 자정 예약을 멈추거나 다시 켠다. EC2 예약은 상태(ENABLED/DISABLED)를, ECS 예약은 예약 확장 중지 여부를 바꾼다
set_schedule() {
  local state=$1 suspended=$2 tmp
  tmp=$(mktemp)
  aws scheduler get-schedule --group-name "$SCHEDULE_GROUP" --name "$SCHEDULE_NAME" --output json \
    | python3 -c 'import json,sys
d = json.load(sys.stdin)
keep = ["Name", "GroupName", "ScheduleExpression", "ScheduleExpressionTimezone", "FlexibleTimeWindow",
        "Target", "Description", "StartDate", "EndDate", "KmsKeyArn", "ActionAfterCompletion"]
out = {k: d[k] for k in keep if k in d}
for k in ("StartDate", "EndDate"):
    if k in out:
        out[k] = str(out[k])
out["State"] = sys.argv[1]
print(json.dumps(out))' "$state" > "$tmp"
  aws scheduler update-schedule --cli-input-json "file://$tmp" >/dev/null
  rm -f "$tmp"
  for s in $SERVICES; do
    aws application-autoscaling register-scalable-target --service-namespace ecs \
      --resource-id "service/$CLUSTER/$PREFIX-$s" --scalable-dimension ecs:service:DesiredCount \
      --suspended-state "ScheduledScalingSuspended=$suspended" >/dev/null
  done
}

# prod는 실제 사용자 서비스다. 상태를 바꾸는 명령은 확인 문구를 입력해야 실행한다
if [ "$ACTION" != status ]; then
  read -r -p "prod에 ${ACTION}을 실행합니다. 계속하려면 prod를 입력하세요: " answer
  [ "$answer" = prod ] || { echo "취소했습니다"; exit 1; }
fi

case "$ACTION" in
  status)
    show_status
    ;;
  hold)
    set_schedule DISABLED true
    echo "자정 자동 종료를 멈췄습니다. 끝나면 release를 실행하세요"
    show_status
    ;;
  release)
    set_schedule ENABLED false
    echo "자정 자동 종료를 다시 켰습니다"
    show_status
    ;;
  off)
    # 1. BE: 최소·최대를 0으로 바꾸고 태스크가 모두 내려갈 때까지 기다린다
    for s in $SERVICES; do set_range "$s" 0 0; done
    echo "BE 태스크를 내리는 중입니다"
    aws ecs wait services-stable --cluster "$CLUSTER" --services $(for s in $SERVICES; do printf '%s ' "$PREFIX-$s"; done)
    # 2. AI, 모니터링
    aws ec2 stop-instances --instance-ids $APP_IDS >/dev/null
    # 3. DB, Redis: 컨테이너를 먼저 정상 종료한다. 실패해도 crash recovery로 복구되므로 경고만 남기고 계속 끈다
    #    직접 멈춘 컨테이너는 재부팅해도 자동으로 뜨지 않으므로 on에서 compose start를 실행한다
    for id in $(running_ids "$DATA_NAMES"); do
      echo "DB, Redis 컨테이너 정상 종료: $id"
      ssm_run "$id" "docker compose -f $COMPOSE stop -t 120" || echo "::warning:: $id 컨테이너 정상 종료 실패. 서버 종료는 계속합니다"
    done
    aws ec2 stop-instances --instance-ids $DATA_IDS >/dev/null
    echo "AI, 모니터링, DB, Redis가 멈출 때까지 기다립니다"
    aws ec2 wait instance-stopped --instance-ids $APP_IDS $DATA_IDS
    # 4. FE(NAT): 다른 서버의 SSM 연결과 외부 통신이 끝난 뒤 마지막에 끈다
    aws ec2 stop-instances --instance-ids $FE_IDS >/dev/null
    aws ec2 wait instance-stopped --instance-ids $FE_IDS
    show_status
    ;;
  on)
    # 1. FE(NAT): private 서브넷 서버의 SSM 연결과 외부 통신이 FE를 거치므로 먼저 켠다
    echo "FE(NAT)를 켜는 중입니다"
    aws ec2 start-instances --instance-ids $FE_IDS >/dev/null
    aws ec2 wait instance-running --instance-ids $FE_IDS
    # 2. DB, Redis: off에서 직접 멈춘 컨테이너도 다시 띄운다 (이미 실행 중이면 변화 없음)
    echo "DB, Redis를 켜는 중입니다"
    aws ec2 start-instances --instance-ids $DATA_IDS >/dev/null
    aws ec2 wait instance-running --instance-ids $DATA_IDS
    wait_ssm_online "$DATA_IDS"
    for id in $DATA_IDS; do
      ssm_run "$id" "docker compose -f $COMPOSE start" || { echo "$id 컨테이너 시작 실패"; exit 1; }
    done
    # 3. Replica 복제 시작과 확인
    echo "Replica 복제를 시작합니다"
    ssm_run "$(running_ids "$REPLICA_NAME")" "$REPLICA_START_CMD" || echo "::warning:: Replica 복제 시작 확인 실패. status로 다시 확인하세요"
    # 4. AI, 모니터링
    echo "AI, 모니터링을 켜는 중입니다"
    aws ec2 start-instances --instance-ids $APP_IDS >/dev/null
    aws ec2 wait instance-running --instance-ids $APP_IDS
    # 5. BE: DB, Redis가 뜬 뒤 마지막에 켠다
    for s in $SERVICES; do
      var="ON_RANGE_${s//-/_}"
      read -r min max <<< "${!var}"
      set_range "$s" "$min" "$max"
    done
    echo "BE 태스크가 정상이 될 때까지 기다립니다 (보통 3~5분)"
    aws ecs wait services-stable --cluster "$CLUSTER" --services $(for s in $SERVICES; do printf '%s ' "$PREFIX-$s"; done)
    show_status
    ;;
esac
