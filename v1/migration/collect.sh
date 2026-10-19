#!/usr/bin/env bash
# 전환 후 오하이오 리허설 DB에서 이번 실행(RUN_ID)의 결과를 TSV로 받는다. 조회만 한다.
# - SSM 포트 포워딩으로 대상 DB의 3306을 로컬 13306에 연결하고, 로컬 mysql 클라이언트로 앱 계정(dev_meety_user)으로 조회한다.
#   SSM 명령 출력은 24KB까지만 돌려줘서, 회의가 수천 개인 실행 결과를 받을 수 없기 때문이다.
# - dev-app을 경유하는 원격 호스트 포워딩으로 앱 계정의 접속 허용 범위를 유지한다.
#
# 사용법: ./collect.sh <RUN_ID>
#   결과: meetings-<RUN_ID>.tsv (write-load.js 회의), live-<RUN_ID>.tsv (live-load.js 회의, 녹음, 전사 수)
set -uo pipefail

RUN_ID=${1:-}
[[ "$RUN_ID" =~ ^[a-z0-9]{4,6}$ ]] || { echo "사용법: $0 <RUN_ID>"; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" || exit 1
validate_targets || { echo "리허설 계정·대상 불일치" >&2; exit 1; }
LOCAL_PORT=${LOCAL_PORT:-13306}
[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && [ "$LOCAL_PORT" -ge 1024 ] && [ "$LOCAL_PORT" -le 65535 ] || exit 1
nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null && { echo "로컬 포트가 이미 사용 중입니다" >&2; exit 1; }
# 실행 중 BE의 인증값을 메모리로만 읽는다. 명령줄/파일/로그에는 비밀번호를 남기지 않는다.
credentials=$(proxysql "python3 - <<'AUTH'
import subprocess,json
x=json.loads(subprocess.check_output(['docker','inspect','dev-be']))[0]
e=dict(v.split('=',1) for v in x['Config']['Env'])
print(json.dumps([e['SPRING_DATASOURCE_USERNAME'],e['SPRING_DATASOURCE_PASSWORD']]))
AUTH") || { echo "앱 인증값 조회 실패" >&2; exit 1; }
DB_USER=$(printf '%s' "$credentials" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])') || exit 1
MYSQL_PWD=$(printf '%s' "$credentials" | python3 -c 'import json,sys; print(json.load(sys.stdin)[1],end="")') || exit 1
export MYSQL_PWD
unset credentials

# 포트 포워딩 세션을 띄우고, 스크립트가 끝나면 닫는다
aws ssm start-session --profile "$PROFILE" --region "$SOURCE_REGION" --target "$SOURCE_APP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$TARGET_DB_IP,portNumber=3306,localPortNumber=$LOCAL_PORT" > /dev/null 2>&1 &
TUNNEL=$!
trap 'kill "$TUNNEL" 2>/dev/null || true; unset MYSQL_PWD' EXIT
for _ in $(seq 1 30); do
  nc -z 127.0.0.1 $LOCAL_PORT 2>/dev/null && kill -0 "$TUNNEL" 2>/dev/null && break
  sleep 1
done
kill -0 "$TUNNEL" 2>/dev/null && nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null || { echo "포트 포워딩 연결 실패"; exit 1; }

q() { mysql -h 127.0.0.1 -P "$LOCAL_PORT" -u "$DB_USER" --ssl-mode=REQUIRED -B -N "$DB_NAME" -e "$1"; }

[ "$(q 'SELECT @@server_id;')" = "$TARGET_SERVER_ID" ] || { echo "수집 대상 DB 식별자 불일치" >&2; exit 1; }

# write-load.js 회의: id, purpose, note, deleted_at (verify.py load_db 형식)
q "SELECT id, purpose, IFNULL(note, 'NULL'), IFNULL(deleted_at, 'NULL')
   FROM meetings WHERE purpose LIKE 'mig-${RUN_ID}-%'" > "meetings-${RUN_ID}.tsv" || { echo "회의 조회 실패"; exit 1; }

# live-load.js 회의: 회의 id, purpose, 녹음 id, 상태, 누적 일시정지(ms), 종료 시각, 저장된 전사 수
# 녹음이 없는 회의(녹음 시작 전 실패)도 남기려고 LEFT JOIN 한다
q "SELECT m.id, m.purpose, IFNULL(r.id, 'NULL'), IFNULL(r.status, 'NULL'), IFNULL(r.total_paused_duration_ms, 'NULL'),
          IFNULL(r.ended_at, 'NULL'),
          (SELECT COUNT(*) FROM transcript_segments t WHERE t.meeting_id = m.id)
   FROM meetings m LEFT JOIN recording_sessions r ON r.meeting_id = m.id AND r.deleted_at IS NULL
   WHERE m.purpose LIKE 'live-${RUN_ID}-%'" > "live-${RUN_ID}.tsv" || { echo "실시간 회의 조회 실패"; exit 1; }

echo "meetings-${RUN_ID}.tsv: $(wc -l < "meetings-${RUN_ID}.tsv" | tr -d ' ')행"
echo "live-${RUN_ID}.tsv: $(wc -l < "live-${RUN_ID}.tsv" | tr -d ' ')행"

# 원문 대신 해시를 수집해 가짜 STT 내용과 비교하고, 순번·원본 키의 중복/누락도 검사한다.
q "SELECT m.purpose,t.source_segment_key,t.sequence_number,SHA2(t.content,256)
   FROM transcript_segments t JOIN meetings m ON m.id=t.meeting_id
   WHERE m.purpose LIKE 'live-${RUN_ID}-%' ORDER BY m.id,t.sequence_number,t.id" > "segments-${RUN_ID}.tsv" || { echo "전사 상세 조회 실패"; exit 1; }
echo "segments-${RUN_ID}.tsv: $(wc -l < "segments-${RUN_ID}.tsv" | tr -d ' ')행"
