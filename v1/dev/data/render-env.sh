#!/usr/bin/env bash
# 사용법: ./render-env.sh <prod|dev> <app|ai|data> [--check]
#   --check  .env를 바꾸지 않고, 현재 .env와 비교한 결과(키 이름만)를 표시
# Parameter Store의 값으로 이 디렉터리의 .env를 만든다.
#   읽는 경로: /meety/<환경>/<구역>  (app, data는 /meety/<환경>/common도 함께)
# - CD가 관리하는 이미지 태그와 이미지 경로 줄은 기존 .env 값을 유지한다.
# - 기존 .env는 .env.bak-<시각>으로 백업한다 (권한 600).
# - 값은 화면에 출력하지 않는다.
set -euo pipefail

fail() { echo "[실패] $*" >&2; exit 1; }
info() { echo "  $*"; }
warn() { echo "  [주의] $*"; }

ENV_NAME=${1:-}
SVC=${2:-}
case "$ENV_NAME" in prod|dev) ;; *) fail "환경을 입력하세요 (prod|dev)" ;; esac
case "$SVC" in app|ai|data) ;; *) fail "구역을 입력하세요 (app|ai|data)" ;; esac
CHECK_ONLY=false
case "${3:-}" in
  "") ;;
  --check) CHECK_ONLY=true ;;
  *) fail "알 수 없는 옵션: ${3} (사용 가능: --check)" ;;
esac

REGION=${AWS_REGION:-us-east-2}
cd "$(dirname "$0")"   # compose와 .env가 있는 디렉터리에서 실행
command -v aws >/dev/null || fail "AWS CLI가 없습니다"
command -v jq  >/dev/null || fail "jq가 없습니다 (sudo apt install -y jq)"

# ai는 common 경로를 쓰지 않는다 (DB 값이 필요 없음)
case "$SVC" in
  ai) SCOPES="ai" ;;
  *)  SCOPES="common $SVC" ;;
esac

umask 077                                   # 임시 파일과 백업도 권한 600
TMP=$(mktemp .env.render.XXXXXXXX)
trap 'rm -f "$TMP"' EXIT

# SSM Run Command는 root로 실행된다. root가 만든 파일은 ubuntu가 못 읽으므로
# 생성 파일의 소유자를 이 디렉터리의 소유자(ubuntu)로 맞춘다
OWNER=""
if [ "$(id -u)" -eq 0 ]; then
  OWNER=$(stat -c '%u:%g' .)
fi
own() { [ -z "$OWNER" ] || chown "$OWNER" "$@"; }

# ---------- 1. Parameter Store에서 읽기 ----------
echo
echo "[1/3] Parameter Store 읽기 (/meety/$ENV_NAME)"
for scope in $SCOPES; do
  # --recursive: 하위 경로 포함, --with-decryption: SecureString 복호화 (CLI가 페이지를 자동으로 이어받음)
  JSON=$(aws ssm get-parameters-by-path --region "$REGION" \
    --path "/meety/$ENV_NAME/$scope" --recursive --with-decryption --output json) \
    || fail "조회 실패: /meety/$ENV_NAME/$scope (IAM 역할 권한과 리전을 확인하세요)"

  n=$(printf '%s' "$JSON" | jq '.Parameters | length')
  [ "$n" -gt 0 ] || fail "파라미터가 없습니다: /meety/$ENV_NAME/$scope (비어 있는 .env로 덮어쓰지 않도록 중단)"

  # .env 한 줄로 표현할 수 없는 값(홑따옴표, 줄바꿈)은 깨지므로 중단
  bad=$(printf '%s' "$JSON" | jq -r --arg q "'" \
    '.Parameters[] | select((.Value | contains($q)) or (.Value | test("\n"))) | .Name')
  [ -z "$bad" ] || fail "홑따옴표나 줄바꿈이 들어 있는 값: $(echo "$bad" | tr '\n' ' ')"

  # 마지막 경로 조각이 환경변수 이름. 값은 홑따옴표로 감싸 compose의 $ 치환을 막는다
  printf '%s' "$JSON" | jq -r --arg q "'" \
    '.Parameters[] | (.Name | split("/") | last) + "=" + $q + .Value + $q' >> "$TMP"
  info "/meety/$ENV_NAME/$scope  ${n}개"
done

# ---------- 2. CD가 관리하는 줄 유지 ----------
# 이미지 태그는 CD가 sed로 갱신하고, 이미지 경로는 Parameter Store에 두지 않았다
if [ -f .env ]; then
  grep -E '^(FE_IMAGE_TAG|BE_IMAGE_TAG|AI_IMAGE_TAG|FRONTEND_IMAGE|BACKEND_IMAGE|AI_IMAGE)=' .env >> "$TMP" || true
fi

# ---------- 3. 비교, 적용 ----------
echo
echo "[2/3] 현재 .env와 비교 (값은 표시하지 않음)"

# .env를 "키 해시" 줄로 변환. 따옴표는 벗겨서 형식 차이로 다르게 보이지 않게 한다
fp() {
  local k v
  while IFS== read -r k v; do
    case "$k" in ""|\#*) continue ;; esac
    v=${v#\'}; v=${v%\'}; v=${v#\"}; v=${v%\"}
    printf '%s %s\n' "$k" "$(printf %s "$v" | sha256sum | cut -d' ' -f1)"
  done < "$1"
}

if [ -f .env ]; then
  { fp .env | sed 's/^/S /'; fp "$TMP" | sed 's/^/N /'; } | awk '
    $1 == "S" { old[$2] = $3; next }
              { new[$2] = $3 }
    END {
      for (k in new) { if (!(k in old)) print "추가  " k; else if (old[k] != new[k]) print "변경  " k }
      for (k in old) if (!(k in new)) print "삭제  " k
    }' | sort > "$TMP.diff"
  if [ -s "$TMP.diff" ]; then sed 's/^/    /' "$TMP.diff"; else info "변경 없음"; fi
  # '삭제'는 기존 .env에만 있던 키(예: 서버에서 직접 넣은 값). 새 .env에서는 빠지므로 확인이 필요하다
  if grep -q '^삭제' "$TMP.diff"; then
    warn "'삭제' 키는 Parameter Store에 없어서 새 .env에서 빠집니다. 필요한 값이면 먼저 올려 주세요."
  fi
  rm -f "$TMP.diff"
else
  info "기존 .env 없음 (새로 생성)"
fi

if $CHECK_ONLY; then
  echo
  echo "--check: .env는 바꾸지 않았습니다"
  exit 0
fi

echo
echo "[3/3] 적용"
if [ -f .env ]; then
  BAK=".env.bak-$(date +%Y%m%d-%H%M%S)"
  cp .env "$BAK"
  own "$BAK"
  info "기존 .env 백업: $BAK"
fi
chmod 600 "$TMP"
own "$TMP"
mv "$TMP" .env
echo
echo "완료  .env 생성 ($(grep -c '=' .env)줄). 반영하려면 docker compose up -d"
