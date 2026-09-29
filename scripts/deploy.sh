#!/usr/bin/env bash
# 사용법: ./scripts/deploy.sh <app|data|ai> [--env]
#   --env  로컬 .env도 서버에 반영 (키만 비교해서 표시, 기존 .env는 백업)
# 레포의 v1/<대상> 디렉토리를 서버에 반영하고 컨테이너를 갱신한다
# - main: origin/main과 일치할 때만 배포 (정식 배포)
# - 그 외 브랜치: 경고 후 배포 허용 (테스트 배포)
set -euo pipefail

# ---------- 출력 형식 ----------
# 터미널에서 실행할 때만 색상 사용 (파일로 저장할 때 제어 문자가 섞이지 않게)
if [ -t 1 ]; then
  BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; RESET=$'\e[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

TOTAL_STEPS=5
step() { echo; echo "${BOLD}[$1/$TOTAL_STEPS] $2${RESET}"; }  # 단계 제목
info() { echo "  $*"; }                                       # 일반 정보
ok()   { echo "  ${GREEN}$*${RESET}"; }                       # 성공
warn() { echo "  ${YELLOW}[주의] $*${RESET}"; }               # 경고 (진행은 계속)
fail() { echo "${RED}[실패] $*${RESET}" >&2; exit 1; }        # 중단

# ---------- 대상 설정 ----------
TARGET=${1:-}
case "$TARGET" in
  app)  HOST=app-v1-meety ;;
  data) HOST=data-v1-meety ;;
  ai)   HOST=ai-v1-meety ;;
  *)    fail "대상 인스턴스를 입력하세요 (app|data|ai) [--env]" ;;
esac
REMOTE_DIR=meety   # 서버 홈 기준 경로

ENV_SYNC=false     # --env: 로컬 .env를 서버에 반영
for opt in "${@:2}"; do
  case "$opt" in
    --env) ENV_SYNC=true ;;
    *)     fail "알 수 없는 옵션: $opt (사용 가능: --env)" ;;
  esac
done

# 변경 파일 출력 형식(--out-format)은 GNU rsync에서만 동작
[[ "$(rsync --version)" == "rsync  version 3"* ]] \
  || fail "GNU rsync 3.x가 필요합니다 (brew install rsync)"

# 레포 루트에서 실행되도록 이동 (어느 위치에서 실행해도 동작)
cd "$(git rev-parse --show-toplevel)"
SRC_DIR=v1/$TARGET
[ -d "$SRC_DIR" ] || fail "디렉토리 없음: $SRC_DIR"

# ---------- 공통 함수 ----------
# 서버에 C.UTF-8 로케일을 보내서 setlocale 경고 제거 (C.UTF-8은 우분투 기본 로케일)
remote() { LC_ALL=C.UTF-8 ssh "$HOST" "$@"; }

# 서버에서 스크립트(stdin)를 인자와 함께 실행
# ssh는 인자를 공백으로 이어 붙여 서버 셸이 다시 해석하므로, 값마다 따옴표 처리해서 전달
remote_script() { remote "bash -s -- $(printf '%q ' "$@")"; }

# .env 형식 파일에서 키 이름만 추출
keys() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | tr -d '=' | sort -u; }

# .env 각 줄을 "키 해시(값)"로 변환. 값이 화면에 노출되지 않고, 로컬/서버 양쪽에서 같은 코드로 실행됨
FP_FN='fp() {
  local k v
  while IFS== read -r k v; do
    case "$k" in ""|\#*) continue ;; esac
    printf "%s %s\n" "$k" "$(printf %s "$v" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d" " -f1)"
  done < "$1"
}'
eval "$FP_FN"

# 서버 .env와 로컬 .env의 차이를 키 단위로 출력 ($1: 서버 fp, $2: 로컬 fp)
env_diff() {
  { printf '%s\n' "$1" | sed '/^$/d; s/^/S /'; printf '%s\n' "$2" | sed '/^$/d; s/^/L /'; } | awk '
    $1 == "S" { srv[$2] = $3; next }
              { loc[$2] = $3 }
    END {
      for (k in loc) { if (!(k in srv)) print "추가  " k; else if (srv[k] != loc[k]) print "변경  " k }
      for (k in srv) if (!(k in loc)) print "삭제  " k
    }' | sort
}

# git이 추적하는 파일만 전송 대상
# .env는 추적 대상이 아니라 자동 제외 (--env 옵션일 때만 아래에서 따로 전송), .env.example은 서버에 필요 없어 목록에서 제외
tracked_files() { git -C "$SRC_DIR" ls-files -z -- . ':(exclude)*.env.example'; }

# 추적 파일을 내용(checksum) 기준으로 동기화
# rsync가 내부적으로 쓰는 ssh에도 로케일 설정이 전달됨
rsync_files() {
  tracked_files \
    | LC_ALL=C.UTF-8 rsync -lptc --from0 --files-from=- "$@" "$SRC_DIR/" "$HOST:$REMOTE_DIR/"
}

# ---------- 1. 사전 확인 ----------
step 1 "사전 확인"

# 커밋되지 않은 변경이 있으면 중단 (커밋돼 있어야 SHA로 서버 상태를 재현 가능)
[ -z "$(git status --porcelain -- "$SRC_DIR")" ] \
  || fail "커밋되지 않은 변경이 있습니다: $SRC_DIR"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
SHA=$(git rev-parse --short HEAD)
git fetch origin --quiet   # 원격 정보 갱신 (main 비교, push 여부 확인용)

info "대상    $TARGET ($HOST)"
info "브랜치  $BRANCH @ $SHA"

if [ "$BRANCH" = "main" ]; then
  # 정식 배포: 원격 main과 같은 상태일 때만 허용
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || fail "origin/main과 다릅니다. pull 또는 push 먼저"
else
  # 테스트 배포: 막지 않고 경고만 표시
  warn "main이 아닌 브랜치입니다. 머지 후 main으로 다시 배포하세요."
  [ -n "$(git branch -r --contains HEAD)" ] || warn "이 커밋은 아직 push되지 않았습니다."
fi

# --env: 로컬 .env가 .env.example의 키를 모두 갖췄는지 서버 접속 전에 확인
if $ENV_SYNC; then
  [ -f "$SRC_DIR/.env" ] || fail "로컬 $SRC_DIR/.env 가 없습니다"
  if [ -f "$SRC_DIR/.env.example" ]; then
    missing=$(comm -13 <(keys "$SRC_DIR/.env") <(keys "$SRC_DIR/.env.example"))
    [ -z "$missing" ] || fail "로컬 .env에 없는 키: $(echo "$missing" | tr '\n' ' ')"
  fi
  info "환경변수 로컬 .env를 서버에 반영 (--env)"
fi

# 서버에 마지막으로 배포된 상태 (형식: 시각 커밋 브랜치)
LAST=$(remote 'tail -n 1 ~/deploy-history.log 2>/dev/null' || true)
info "서버    ${LAST:-배포 기록 없음}"
LAST_BRANCH=$(echo "$LAST" | awk '{print $3}')
if [ -n "$LAST_BRANCH" ] && [ "$LAST_BRANCH" != "main" ]; then
  warn "서버가 main이 아닌 브랜치($LAST_BRANCH) 상태입니다."
fi

# ---------- 2. 변경 파일 ----------
step 2 "변경 파일"

# 미리보기(-n)로 전송될 목록 수집 (%i: 변경 유형, %n: 파일명)
PREVIEW=$(rsync_files -n --out-format='%i %n') \
  || fail "서버 접속 또는 미리보기에 실패했습니다. SSH 설정을 확인하세요."

# '<'로 시작하는 줄 = 서버로 전송될 파일. 디렉토리나 속성만 바뀐 항목은 제외
# 변경 유형에 '+++'가 있으면 서버에 없던 새 파일
CHANGED=$(printf '%s\n' "$PREVIEW" | awk '
  /^</ {
    type = ($1 ~ /\+\+\+/) ? "신규" : "수정"
    sub(/^[^ ]+ /, "")
    print type "  " $0
  }')

if [ -z "$CHANGED" ]; then
  info "변경된 파일 없음"
  COUNT=0
else
  printf '%s\n' "$CHANGED" | sed 's/^/  /'
  COUNT=$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')
fi

# --env: 값은 해시로만 비교해서 키 단위 변경만 표시
ENV_CHANGED=false
SERVER_FP=""
if $ENV_SYNC; then
  echo
  info "환경변수 .env (값은 표시하지 않음)"
  LOCAL_FP=$(fp "$SRC_DIR/.env")
  SERVER_FP=$(printf '%s\n%s\n' "$FP_FN" 'cd "$1"; if [ -f .env ]; then fp .env; fi' | remote_script "$REMOTE_DIR") \
    || fail "서버 .env 조회에 실패했습니다."
  ENV_DIFF=$(env_diff "$SERVER_FP" "$LOCAL_FP")

  if [ -z "$ENV_DIFF" ]; then
    info "  변경 없음"
  else
    ENV_CHANGED=true
    printf '%s\n' "$ENV_DIFF" | sed 's/^/    /'
    if printf '%s\n' "$ENV_DIFF" | grep -q '^삭제'; then
      warn "'삭제' 키는 서버에만 있고 로컬에 없어서, 덮어쓰면 사라집니다."
    fi
  fi
fi

ENV_NOTE=""
if $ENV_CHANGED; then ENV_NOTE="+ .env "; fi

echo
read -rp "${BOLD}[$TARGET] $BRANCH @ $SHA ${ENV_NOTE}적용할까요? (y/N)${RESET} " answer
[ "$answer" = "y" ] || { echo "취소됨"; exit 1; }
SECONDS=0   # 확인 대기 시간을 빼고 실제 배포 시간만 측정

# ---------- 3. 파일 전송 ----------
step 3 "파일 전송"
rsync_files -q \
  || fail "파일 전송 실패. 서버 디렉토리 소유자(ubuntu)와 권한을 확인하세요. 일부만 전송됐을 수 있으니 재실행하면 이어서 반영됩니다."
ok "${COUNT}개 파일 전송 완료"

if $ENV_CHANGED; then
  # 기존 .env를 백업한 뒤 덮어씀 (백업도 비밀값이 있으므로 권한 600)
  BAK=".env.bak-$(date +%Y%m%d-%H%M%S)"
  remote_script "$REMOTE_DIR" "$BAK" <<'EOF' || fail ".env 백업에 실패했습니다. 서버 상태를 확인하세요."
set -e
cd "$1"
if [ -f .env ]; then
  cp -p .env "$2"
  chmod 600 "$2"
fi
EOF
  LC_ALL=C.UTF-8 rsync -t "$SRC_DIR/.env" "$HOST:$REMOTE_DIR/.env" \
    || fail ".env 전송 실패"
  remote "chmod 600 $REMOTE_DIR/.env"
  if [ -n "$SERVER_FP" ]; then
    ok ".env 반영 완료 (기존 파일 백업: ~/$REMOTE_DIR/$BAK)"
  else
    ok ".env 반영 완료 (서버에 기존 파일 없음)"
  fi
fi

# ---------- 4. 검증 ----------
step 4 "검증"

# .env.example은 서버로 보내지 않으므로, 로컬에서 키 목록을 뽑아 인자로 전달
EXPECTED_KEYS=""
if [ -f "$SRC_DIR/.env.example" ]; then
  EXPECTED_KEYS=$(keys "$SRC_DIR/.env.example")
fi

# 키 이름은 공백이 없어서 따옴표 없이 넘겨 인자 여러 개로 전달
remote_script "$TARGET" "$REMOTE_DIR" "$GREEN" "$RESET" $EXPECTED_KEYS <<'EOF' \
  || fail "검증 실패. 파일은 전송됐지만 컨테이너에는 적용되지 않았습니다."
set -eo pipefail
TARGET=$1; cd "$2"; G=$3; R=$4; shift 4   # 남은 인자 = .env.example의 키 목록

keys() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | tr -d '=' | sort -u; }

# 1) .env.example의 키가 서버 .env에 모두 있는지 확인
if [ $# -gt 0 ]; then
  [ -f .env ] || { echo "  서버에 .env가 없습니다"; exit 1; }
  missing=$(comm -13 <(keys .env) <(printf '%s\n' "$@" | sort -u))
  if [ -n "$missing" ]; then
    echo "  서버 .env에 없는 키:"
    printf '    %s\n' $missing
    exit 1
  fi
  echo "  ${G}.env 키 확인 통과${R}"
fi

# 2) compose 문법 검증 (미설정 변수 경고는 그대로 출력됨)
docker compose config -q
echo "  ${G}compose 문법 통과${R}"

# 3) nginx 설정 검증 (-q: 정상이면 출력 없음, 에러일 때만 출력)
if [ "$TARGET" = "app" ]; then
  docker compose exec -T nginx nginx -t -q
  echo "  ${G}nginx 설정 통과${R}"
fi
EOF

# ---------- 5. 적용 ----------
step 5 "적용"

remote_script "$TARGET" "$REMOTE_DIR" "$SHA" "$BRANCH" "$GREEN" "$RESET" <<'EOF' \
  || fail "적용 중 오류가 발생했습니다. 서버 상태를 확인하세요."
set -eo pipefail
TARGET=$1; cd "$2"; SHA=$3; BRANCH=$4; G=$5; R=$6

# 컨테이너별 처리 결과를 줄 단위로 출력 (Recreate, Started, Running 등)
# --wait: healthcheck 통과까지 대기 (최대 90초). 실패하면 상태와 최근 로그를 보여주고 중단
if ! docker compose --progress plain up -d --wait --wait-timeout 90 2>&1 | sed 's/^/  /'; then
  echo
  docker compose ps --format 'table {{.Name}}\t{{.Status}}' | sed 's/^/  /'
  echo
  echo "  최근 로그 (각 20줄)"
  docker compose logs --tail 20 2>&1 | sed 's/^/    /'
  exit 1
fi

# conf만 바뀐 경우 재생성 없이 반영. 정상이면 원문 생략, 실패하면 원문 출력
if [ "$TARGET" = "app" ]; then
  out=$(docker compose exec -T nginx nginx -s reload 2>&1) || { echo "$out"; exit 1; }
  echo "  ${G}nginx 설정 다시 불러옴${R}"
fi

# 최종 컨테이너 상태
echo
docker compose ps --format 'table {{.Name}}\t{{.Status}}' | sed 's/^/  /'

# 배포 이력 (시각 커밋 브랜치)
echo "$(date -Is) $SHA $BRANCH" >> ~/deploy-history.log
EOF

echo
echo "${GREEN}${BOLD}완료${RESET}  $TARGET @ $BRANCH $SHA (${SECONDS}초)"