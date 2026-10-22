#!/usr/bin/env bash
# 모니터링 서버에 설정 파일을 반영한다.
# Terraform은 user_data를 첫 부팅 때만 쓰므로(ignore_changes), 이후 설정 변경은 이 스크립트로 보낸다.
# 파일 내용은 Terraform output(monitoring_config_files)에서 가져온다. 설정을 고친 뒤 해당 환경에서 apply를 먼저 한다.
#
# 사용: ./sync-config.sh <staging|prod> [--profile 프로필]
# 바뀐 파일에 따라:
#   - docker-compose.yml → 바뀐 컨테이너만 다시 만든다
#   - prometheus.yml     → promtool로 검사한 뒤 재시작 없이 다시 읽는다. 검사에 실패하면 이전 파일로 되돌린다
#   - loki.yml           → loki만 다시 시작한다
#   - grafana-datasources.yml → grafana만 다시 시작한다
# Prometheus 이미지 변경 전에는 데이터 볼륨과 기존 설정을 백업한다.
set -euo pipefail

ENV=${1:?환경(staging 또는 prod)을 지정하세요}
case "$ENV" in staging|prod) ;; *) echo "환경은 staging 또는 prod만 가능합니다: $ENV"; exit 1 ;; esac
# macOS 기본 bash(3.2)에서 빈 배열이 set -u에 걸리므로 프로필은 환경 변수로 넘긴다
if [ "${2:-}" = "--profile" ]; then export AWS_PROFILE=${3:?프로필 이름}; fi
REGION=ap-northeast-2
DIR=$(cd "$(dirname "$0")" && pwd)
export AWS_PAGER=""

FILES_JSON=$(terraform -chdir="$DIR/../terraform/$ENV" output -json monitoring_config_files)

INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=meety-v2-${ENV}-monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[[ "$INSTANCE_ID" == i-* ]] || { echo "실행 중인 ${ENV} 모니터링 서버를 찾지 못했습니다"; exit 1; }

# 파일마다 "put <이름> <base64>" 줄을 만든다
PUT_LINES=$(echo "$FILES_JSON" | jq -r 'to_entries[] | "put \(.key) \(.value | @base64)"')

REMOTE=$(cat <<'EOF'
#!/bin/bash
set -euo pipefail
cd /opt/meety/monitoring
STAGE=$(mktemp -d .config-sync.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
CHANGED=""
# 내용이 다를 때만 바꾼다. 컨테이너에 파일 하나만 연결(bind mount)한 경우 새 파일로 바꿔 끼우면
# 컨테이너가 이전 파일을 계속 보므로, 같은 파일에 덮어쓴다
put() {
  echo "$2" | base64 -d > "$STAGE/$1"
  if [ -f "$1" ] && cmp -s "$1" "$STAGE/$1"; then return; fi
  CHANGED="$CHANGED $1"
}
EOF
)
REMOTE+=$'\n'"$PUT_LINES"$'\n'
REMOTE+=$(cat <<'EOF'
echo "바뀐 파일:${CHANGED:- 없음}"
has() { [[ " $CHANGED " == *" $1 "* ]]; }

if [ -z "$CHANGED" ]; then
  echo '설정 변경 없음'
  exit 0
fi

OLD_IMAGE=$(docker inspect prometheus --format '{{.Config.Image}}')
NEW_IMAGE=$(docker compose -f "$STAGE/docker-compose.yml" config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["prometheus"]["image"])')
docker compose -f "$STAGE/docker-compose.yml" config --quiet
if has docker-compose.yml || has prometheus.yml; then
  docker pull "$NEW_IMAGE" >/dev/null
  # 현재 실행 중인 구버전 대신 적용할 버전의 promtool로 검사한다. 실제 파일은 아직 바꾸지 않는다.
  docker run --rm --network none --entrypoint /bin/promtool \
    --mount "type=bind,src=$(pwd)/$STAGE/prometheus.yml,dst=/etc/prometheus/prometheus.yml,readonly" \
    "$NEW_IMAGE" check config /etc/prometheus/prometheus.yml
fi

BACKUP="$(pwd)/backups/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$BACKUP"
for file in $CHANGED; do [ ! -f "$file" ] || cp -p "$file" "$BACKUP/$file"; done
if [ "$OLD_IMAGE" != "$NEW_IMAGE" ]; then
  VOLUME=$(docker inspect prometheus --format '{{range .Mounts}}{{if eq .Destination "/prometheus"}}{{.Name}}{{end}}{{end}}')
  [ -n "$VOLUME" ] || { echo 'Prometheus 데이터 볼륨을 확인할 수 없음'; exit 1; }
  docker stop prometheus >/dev/null
  # 중지한 데이터 볼륨을 백업한다. 백업 실패 시 기존 컨테이너를 바로 다시 시작한다.
  if ! docker run --rm --network none --user 0 --entrypoint /bin/sh \
    --mount "type=volume,src=$VOLUME,dst=/data,readonly" \
    --mount "type=bind,src=$BACKUP,dst=/backup" "$OLD_IMAGE" \
    -c 'tar -czf /backup/prometheus-data.tar.gz -C /data .'; then
    docker start prometheus >/dev/null
    exit 1
  fi
fi

for file in $CHANGED; do
  # 파일 bind mount가 같은 inode를 보도록 기존 파일에 덮어쓴다.
  cat "$STAGE/$file" > "$file"
done
if has docker-compose.yml; then
  docker compose up -d --wait --wait-timeout 180
elif has prometheus.yml; then
  curl -fsS -X POST http://127.0.0.1:9090/-/reload
fi
if has loki.yml && ! has docker-compose.yml; then docker compose restart loki; fi
if has grafana-datasources.yml && ! has docker-compose.yml; then docker compose restart grafana; fi

for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:9090/-/ready >/dev/null
# 내장 ECS 탐색이 파일 주소록을 대체한다. 이미 설치된 레거시 timer만 비활성화한다.
if [ -f /etc/systemd/system/meety-ecs-targets.timer ]; then
  systemctl disable --now meety-ecs-targets.timer
fi
echo "설정 적용 완료. 이전 설정과 데이터 백업: $BACKUP"
docker ps --format '{{.Names}} {{.Status}}'
EOF
)

echo "${ENV} 모니터링 서버(${INSTANCE_ID})에 설정을 반영합니다"
CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --comment "monitoring config sync" \
  --parameters "$(jq -n --arg c "$REMOTE" '{commands: [$c], executionTimeout: ["600"]}')" \
  --query Command.CommandId --output text)
STATUS=Pending
for _ in $(seq 1 210); do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed) sleep 3 ;; *) break ;; esac
done
aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" --query '[StandardOutputContent,StandardErrorContent]' --output text
[ "$STATUS" = Success ] || { echo "반영 실패 (status=$STATUS)"; exit 1; }
