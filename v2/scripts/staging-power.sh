#!/usr/bin/env bash
# staging을 수동으로 끄고 켠다. 매일 한국 시간 00:00에는 AWS 예약이 종료하며, 자동 켜기는 없다.
# 대상: BE ECS 서비스 2개, AI 서버 2대, 모니터링 서버 (FE, DB, Replica, Redis는 그대로 둔다)
# 꺼 둔 상태에서 terraform/staging을 apply하면 ECS 최소·최대값이 되돌아가 BE만 켜지므로, apply 전에 on을 먼저 실행한다
#
# 사용: ./staging-power.sh <on|off|status> [--profile 프로필]
#   on     서버를 켜고, ECS 태스크 수 범위를 자동 켜기 값으로 되돌린 뒤 정상이 될 때까지 기다린다
#   off    ECS 태스크 수 범위를 0으로 바꾸고 서버를 끈다
#   status 지금 상태를 보여준다
set -euo pipefail

ACTION=${1:?on, off, status 중 하나를 지정하세요}
case "$ACTION" in on|off|status) ;; *) echo "on, off, status만 가능합니다: $ACTION"; exit 1 ;; esac
# macOS 기본 bash(3.2)에서 빈 배열이 set -u에 걸리므로 프로필은 환경 변수로 넘긴다
if [ "${2:-}" = "--profile" ]; then export AWS_PROFILE=${3:?프로필 이름}; fi
export AWS_PAGER=""
export AWS_DEFAULT_REGION=ap-northeast-2

PREFIX=meety-v2-staging
CLUSTER=$PREFIX
SERVICES="be-api be-realtime"
# 켤 때 되돌릴 최소·최대 태스크 수. terraform/staging/variables.tf의 be_*_min_count, be_*_max_count와 맞춘다
ON_RANGE_be_api="1 3"
ON_RANGE_be_realtime="1 3"
INSTANCE_NAMES="$PREFIX-ai,$PREFIX-ai-analysis,$PREFIX-monitoring"

INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAMES" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$INSTANCE_IDS" ] || { echo "대상 서버를 찾지 못했습니다"; exit 1; }

show_status() {
  echo "[서버]"
  aws ec2 describe-instances --instance-ids $INSTANCE_IDS \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name]' --output text
  echo "[ECS] 서비스  최소  최대  실행 중"
  for s in $SERVICES; do
    range=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
      --resource-ids "service/$CLUSTER/$PREFIX-$s" \
      --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text)
    running=$(aws ecs describe-services --cluster "$CLUSTER" --services "$PREFIX-$s" \
      --query 'services[0].runningCount' --output text)
    echo "$s  $range  $running"
  done
}

set_range() {
  aws application-autoscaling register-scalable-target --service-namespace ecs \
    --resource-id "service/$CLUSTER/$PREFIX-$1" --scalable-dimension ecs:service:DesiredCount \
    --min-capacity "$2" --max-capacity "$3" >/dev/null
}

case "$ACTION" in
  status)
    show_status
    ;;
  off)
    for s in $SERVICES; do set_range "$s" 0 0; done
    aws ec2 stop-instances --instance-ids $INSTANCE_IDS >/dev/null
    echo "끄는 중입니다. 서버가 완전히 멈출 때까지 기다립니다"
    aws ec2 wait instance-stopped --instance-ids $INSTANCE_IDS
    show_status
    ;;
  on)
    aws ec2 start-instances --instance-ids $INSTANCE_IDS >/dev/null
    # BE가 AI보다 먼저 떠도 되지만, 확인을 쉽게 하려고 서버가 켜진 뒤 ECS를 켠다
    echo "서버를 켜는 중입니다"
    aws ec2 wait instance-running --instance-ids $INSTANCE_IDS
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
