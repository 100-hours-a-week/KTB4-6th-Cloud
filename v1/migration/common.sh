#!/usr/bin/env bash
# 오하이오 리허설의 고정 대상과 SSM 처리를 공유한다. source로만 사용한다.
MIGRATION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROFILE=${AWS_PROFILE:-meety-admin}
settings_lines=$(python3 - "$MIGRATION_DIR/settings.json" <<'PY'
import json, shlex, sys
settings = json.load(open(sys.argv[1]))
for key, value in settings.items():
    print(f'{key}={shlex.quote(value)}')
PY
) || return 1
eval "$settings_lines"
unset settings_lines
SOURCE_SQL="docker exec $SOURCE_CONTAINER sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -uroot -N -e \"\$0\"'"
TARGET_SQL="docker exec $TARGET_CONTAINER sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -uroot -N -e \"\$0\"'"

ssm_run() {
  local region=$1 instance=$2 script=$3 params cid status=Pending
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands":["set -eu\n"+sys.argv[1]],"executionTimeout":["900"]}))' "$script") || return 1
  cid=$(aws ssm send-command --profile "$PROFILE" --region "$region" --instance-ids "$instance" \
    --document-name AWS-RunShellScript --comment "Ohio DB rehearsal" \
    --parameters "$params" --query Command.CommandId --output text) || return 1
  for _ in $(seq 1 3000); do
    status=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$region" \
      --command-id "$cid" --instance-id "$instance" --query Status --output text 2>/dev/null)
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut|Cancelling)
        aws ssm get-command-invocation --profile "$PROFILE" --region "$region" --command-id "$cid" \
          --instance-id "$instance" --query '[StandardOutputContent,StandardErrorContent]' --output text >&2
        return 1 ;;
    esac
    sleep 0.3
  done
  [ "$status" = Success ] || { echo "SSM 결과 불명확: $cid (재실행 전에 상태 확인 필요)" >&2; return 1; }
  aws ssm get-command-invocation --profile "$PROFILE" --region "$region" --command-id "$cid" \
    --instance-id "$instance" --query StandardOutputContent --output text
}
source_db() { ssm_run "$SOURCE_REGION" "$SOURCE_DB" "$1"; }
target_db() { ssm_run "$TARGET_REGION" "$TARGET_DB" "$1"; }
proxysql() { ssm_run "$SOURCE_REGION" "$SOURCE_APP" "$1"; }

validate_targets() {
  # 계정·인스턴스 IP·MySQL 식별자를 확인하기 전에는 원격 변경 명령을 보내지 않는다.
  local account ip identity
  [ "$SOURCE_REGION" = us-east-2 ] && [ "$TARGET_REGION" = us-east-2 ] \
    && [ "$SOURCE_DB" != "$TARGET_DB" ] && [ "$DB_NAME" = dev_meetyDB ] || return 1
  account=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text) || return 1
  [ "$account" = "$ACCOUNT_ID" ] || return 1
  ip=$(aws ec2 describe-instances --profile "$PROFILE" --region "$SOURCE_REGION" --instance-ids "$SOURCE_DB" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text) || return 1
  [ "$ip" = "$SOURCE_DB_IP" ] || return 1
  ip=$(aws ec2 describe-instances --profile "$PROFILE" --region "$TARGET_REGION" --instance-ids "$TARGET_DB" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text) || return 1
  [ "$ip" = "$TARGET_DB_IP" ] || return 1
  identity=$(source_db "$SOURCE_SQL 'SELECT @@server_id;'") || return 1
  [ "$identity" = "$SOURCE_SERVER_ID" ] || return 1
  identity=$(target_db "$TARGET_SQL 'SELECT @@server_id;'") || return 1
  [ "$identity" = "$TARGET_SERVER_ID" ] || return 1
}
