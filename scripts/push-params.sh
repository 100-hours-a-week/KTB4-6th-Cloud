#!/usr/bin/env bash
# 사용법: ./scripts/push-params.sh <prod|dev> <app|ai|data> [--dry-run] [--overwrite] [--yes] [--env-file 경로]
#   --dry-run   AWS를 호출하지 않고 올릴 키와 분류만 표시
#   --yes       확인 질문 없이 진행
#   --overwrite 기존 값이 다를 때 변경 허용 (기본값: 추가만 허용)
#   --env-file  기본값(v1/<환경>/<구역>/.env) 대신 다른 .env 사용
# 로컬 .env의 값을 Parameter Store(/meety/<환경>/<구역>/<KEY>)에 등록한다.
# - 값은 화면에 출력하지 않고 키 이름과 변경 여부(추가/변경/동일)만 표시한다.
# - 비밀 값은 SecureString, 나머지는 String으로 저장한다.
# - 같은 값이면 다시 쓰지 않고, 변경은 --overwrite를 명시해야 한다.
set -euo pipefail

REGION=${AWS_REGION:-us-east-2}

fail() { echo "[실패] $*" >&2; exit 1; }
info() { echo "  $*"; }
warn() { echo "  [주의] $*"; }

# ---------- 인자 ----------
ENV_NAME=${1:-}
SVC=${2:-}
case "$ENV_NAME" in prod|dev) ;; *) fail "환경을 입력하세요 (prod|dev)" ;; esac
case "$SVC" in app|ai|data) ;; *) fail "구역을 입력하세요 (app|ai|data)" ;; esac
shift 2

DRY_RUN=false
ASSUME_YES=false
OVERWRITE=false
ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --yes)     ASSUME_YES=true ;;
    --overwrite) OVERWRITE=true ;;
    --env-file) shift; ENV_FILE=${1:-}; [ -n "$ENV_FILE" ] || fail "--env-file 뒤에 경로가 필요합니다" ;;
    *) fail "알 수 없는 옵션: $1 (사용 가능: --dry-run, --overwrite, --yes, --env-file)" ;;
  esac
  shift
done

# 레포 루트에서 실행되도록 이동 (어느 위치에서 실행해도 동작)
cd "$(git rev-parse --show-toplevel)"
SRC_DIR=v1/$ENV_NAME/$SVC
[ -n "$ENV_FILE" ] || ENV_FILE=$SRC_DIR/.env
EXAMPLE=$SRC_DIR/.env.example
[ -f "$ENV_FILE" ] || fail "파일 없음: $ENV_FILE"

# ---------- 분류 규칙 ----------
# 이름에 이 패턴이 있으면 SecureString으로 저장
SECRET_RE='(PASSWORD|SECRET|TOKEN|API_KEY|ADMIN_KEY|DSN|WEBHOOK)'

# 올리지 않는 키면 사유를 출력하고 0을 반환, 올리는 키면 1을 반환
skip_reason() {
  case "$1" in
    *_IMAGE_TAG)                             echo "CD가 관리하는 이미지 태그" ;;
    FRONTEND_IMAGE|BACKEND_IMAGE|AI_IMAGE)   echo "이미지 경로는 .env에 유지" ;;
    DB_ROOT_PASSWORD)
      [ "$SVC" = app ] && echo "app에서 사용하지 않음" ;;
    *) return 1 ;;
  esac
}

# DB 공용 값은 common, 나머지는 해당 구역에 저장
scope_of() {
  case "$1" in
    DB_NAME|DB_USER|DB_PASSWORD) echo common ;;
    *) echo "$SVC" ;;
  esac
}

# NEXT_PUBLIC_*은 브라우저에 노출되는 값이라 String, 나머지는 이름으로 판별
type_of() {
  case "$1" in
    NEXT_PUBLIC_*) echo String; return ;;
    AWS_ACCESS_KEY_ID) echo SecureString; return ;;
  esac
  if [[ "$1" =~ $SECRET_RE ]]; then echo SecureString; else echo String; fi
}

# ---------- 1. .env 파싱 ----------
KEYS=(); VALS=()
SEEN=" "
RE_DQ='^"(.*)"$'
RE_SQ="^'(.*)'\$"

echo
echo "[1/3] $ENV_FILE 읽기"
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}                       # 윈도우 개행 제거
  case "$line" in ''|\#*) continue ;; esac # 빈 줄, 주석 제외
  line=${line#export }
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue

  key=${line%%=*}
  val=${line#*=}
  # 같은 종류의 따옴표로 감싼 경우만 벗김
  if [[ "$val" =~ $RE_DQ ]] || [[ "$val" =~ $RE_SQ ]]; then val=${BASH_REMATCH[1]}; fi

  # IAM 역할 검증이 끝난 dev에는 정적 키를 다시 등록하지 않는다. prod는 현재 키를 사용한다.
  if [ "$ENV_NAME" = dev ]; then
    case "$key" in AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY) fail "$ENV_FILE 에 $key 가 남아 있습니다" ;; esac
  fi
  if reason=$(skip_reason "$key"); then info "건너뜀  $key ($reason)"; continue; fi
  [ -n "$val" ] || fail "$ENV_FILE 의 $key 값이 비어 있습니다"

  # 중복 키를 허용하면 실제 적용값을 잘못 판단하기 쉬우므로 중단한다.
  case "$SEEN" in
    *" $key "*) fail "$ENV_FILE 에 $key 가 중복되어 있습니다" ;;
  esac
  SEEN="$SEEN$key "
  KEYS+=("$key"); VALS+=("$val")
done < "$ENV_FILE"

[ ${#KEYS[@]} -gt 0 ] || fail "올릴 키가 없습니다"

# 공용 DB 파라미터는 app/data에서 같은 이름으로 저장하므로 업로드 전에 값을 대조한다.
read_env_value() {
  local wanted=$1 file=$2 row found_key found_val result="" found=false
  while IFS= read -r row || [ -n "$row" ]; do
    row=${row%$'\r'}
    row=${row#export }
    [[ "$row" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    found_key=${row%%=*}
    [ "$found_key" = "$wanted" ] || continue
    $found && fail "$file 에 $wanted 가 중복되어 있습니다"
    found_val=${row#*=}
    if [[ "$found_val" =~ $RE_DQ ]] || [[ "$found_val" =~ $RE_SQ ]]; then found_val=${BASH_REMATCH[1]}; fi
    result=$found_val
    found=true
  done < "$file"
  $found || fail "$file 에 $wanted 가 없습니다"
  printf '%s' "$result"
}
if [ "$SVC" = app ] || [ "$SVC" = data ]; then
  app_file="v1/$ENV_NAME/app/.env"
  data_file="v1/$ENV_NAME/data/.env"
  if [ "$SVC" = app ]; then app_file=$ENV_FILE; else data_file=$ENV_FILE; fi
  for key in DB_NAME DB_USER DB_PASSWORD; do
    app_value=$(read_env_value "$key" "$app_file")
    data_value=$(read_env_value "$key" "$data_file")
    [ "$app_value" = "$data_value" ] || fail "$ENV_NAME app/data의 $key 값이 다릅니다"
  done
fi

# 예시 파일을 허용 목록으로 삼아 빠진 키와 의도하지 않은 추가 키를 차단한다.
[ -f "$EXAMPLE" ] || fail "파일 없음: $EXAMPLE"
EXPECTED=" "
while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
  key=${line%%=*}
  skip_reason "$key" >/dev/null && continue
  EXPECTED="$EXPECTED$key "
  case "$SEEN" in *" $key "*) ;; *) fail "$ENV_FILE 에 필수 키 $key 가 없습니다" ;; esac
done < "$EXAMPLE"
for key in "${KEYS[@]}"; do
  case "$EXPECTED" in *" $key "*) ;; *) fail "$key 는 $EXAMPLE 에 정의되지 않았습니다" ;; esac
done

# ---------- 2. 변경 계획 ----------
echo
echo "[2/3] 변경 계획 (값은 표시하지 않음)"

if ! $DRY_RUN; then
  command -v aws >/dev/null || fail "AWS CLI가 없습니다"
  IDENTITY=$(aws sts get-caller-identity --region "$REGION" --query Arn --output text) \
    || fail "AWS 인증 실패. aws configure 또는 로그인 상태를 확인하세요"
  info "계정    $IDENTITY ($REGION)"
  case "$IDENTITY" in *":root") warn "루트 계정입니다. 관리자 IAM 사용자 사용을 권장합니다" ;; esac
fi

# 서버 값 조회: 0 있음(CUR에 저장), 1 없음, 2 오류(권한 등)
CUR=""
fetch() {
  local err; err=$(mktemp)
  if CUR=$(aws ssm get-parameter --region "$REGION" --name "$1" --with-decryption \
        --query Parameter.Value --output text 2>"$err"); then
    rm -f "$err"; return 0
  fi
  if grep -q ParameterNotFound "$err"; then rm -f "$err"; return 1; fi
  cat "$err" >&2; rm -f "$err"; return 2
}

NAMES=(); TYPES=(); STATES=()
n_add=0; n_chg=0; n_same=0
i=0
while [ $i -lt ${#KEYS[@]} ]; do
  key=${KEYS[$i]}
  name=/meety/$ENV_NAME/$(scope_of "$key")/$key
  type=$(type_of "$key")

  if $DRY_RUN; then
    state=예정
  else
    rc=0; fetch "$name" || rc=$?
    case $rc in
      0) # 값이 같아도 저장 유형이 다르면 잘못 등록된 상태이므로 중단한다.
         cur_type=$(aws ssm get-parameter --region "$REGION" --name "$name" \
           --query Parameter.Type --output text) || fail "유형 조회 실패: $name"
         [ "$cur_type" = "$type" ] || fail "$name 유형이 $cur_type 입니다 (예상: $type)"
         if [ "$CUR" = "${VALS[$i]}" ]; then state=동일; n_same=$((n_same + 1))
         else state=변경; n_chg=$((n_chg + 1)); fi ;;
      1) state=추가; n_add=$((n_add + 1)) ;;
      *) fail "조회 실패: $name (권한과 리전을 확인하세요)" ;;
    esac
  fi
  printf '  %-4s  %s (%s)\n' "$state" "$name" "$type"
  NAMES+=("$name"); TYPES+=("$type"); STATES+=("$state")
  i=$((i + 1))
done

if $DRY_RUN; then
  echo
  echo "드라이런이라 AWS에는 아무것도 쓰지 않았습니다 (대상 ${#KEYS[@]}개)"
  exit 0
fi

if [ $((n_add + n_chg)) -eq 0 ]; then
  echo
  echo "변경 사항 없음 (동일 $n_same개)"
  exit 0
fi

# 기존 값을 바꾸는 작업은 명시적으로 허용해야 새 값 업로드를 시작한다.
if [ "$n_chg" -gt 0 ] && ! $OVERWRITE; then
  fail "기존 파라미터 $n_chg 개의 값이 다릅니다. 변경을 검토한 뒤 --overwrite를 명시하세요"
fi

echo
if $ASSUME_YES; then
  echo "추가 ${n_add}개, 변경 ${n_chg}개를 /meety/$ENV_NAME/ 에 적용합니다 (--yes: 확인 생략)"
else
  read -rp "추가 ${n_add}개, 변경 ${n_chg}개를 /meety/$ENV_NAME/ 에 적용할까요? (y/N) " answer
  [ "$answer" = "y" ] || { echo "취소됨"; exit 1; }
fi

# ---------- 3. 적용 ----------
echo
echo "[3/3] 적용"
# 값은 임시 파일(권한 600)로 넘긴다. 명령행 인자로 넘기면 프로세스 목록에 노출되고,
# 값이 '-'로 시작하거나 http://로 시작할 때 CLI가 옵션/URL로 오해할 수 있다.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

i=0
while [ $i -lt ${#KEYS[@]} ]; do
  if [ "${STATES[$i]}" != 동일 ]; then
    printf '%s' "${VALS[$i]}" > "$TMP"
    overwrite_args=()
    [ "${STATES[$i]}" = 변경 ] && overwrite_args=(--overwrite)
    aws ssm put-parameter --region "$REGION" \
      --name "${NAMES[$i]}" --type "${TYPES[$i]}" \
      --value "file://$TMP" "${overwrite_args[@]}" >/dev/null
    info "완료  ${NAMES[$i]}"
  fi
  i=$((i + 1))
done

echo
echo "완료  /meety/$ENV_NAME/$SVC (추가 $n_add, 변경 $n_chg, 동일 $n_same)"
