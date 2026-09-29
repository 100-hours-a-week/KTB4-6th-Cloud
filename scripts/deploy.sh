#!/usr/bin/env bash
# 사용법: ./scripts/deploy.sh app
set -euo pipefail

TARGET=${1:?"대상 인스턴스를 입력하세요 (app|data|ai)"}

case "$TARGET" in
  app)  HOST=app-v1-meety ;;
  data) HOST=data-v1-meety ;;
  ai)   HOST=ai-v1-meety ;;
  *)    echo "알 수 없는 대상: $TARGET"; exit 1 ;;
esac
REMOTE_DIR=meety

cd "$(git rev-parse --show-toplevel)"
SRC_DIR=v1/$TARGET
[ -d "$SRC_DIR" ] || { echo "디렉토리 없음: $SRC_DIR"; exit 1; }

# 1) 대상 디렉토리에 커밋되지 않은 변경이 있으면 중단
if [ -n "$(git status --porcelain -- "$SRC_DIR")" ]; then
  echo "커밋되지 않은 변경이 있습니다"; exit 1
fi

# 2) main + origin/main 일치할 때만 배포
git fetch origin main
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "main 브랜치에서만 배포 가능"; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "origin/main과 다릅니다. pull 먼저"; exit 1; }
SHA=$(git rev-parse --short HEAD)

# git이 추적하는 파일만, 내용(checksum) 기준으로 전송. .env는 서버 전용이라 제외
sync() {
  git -C "$SRC_DIR" ls-files -z \
    | rsync -lptvc --from0 --files-from=- --exclude '.env' "$@" "$SRC_DIR/" "$HOST:$REMOTE_DIR/"
}

# 3) 미리보기
sync -n
read -rp "[$TARGET] $SHA 적용할까요? (y/N) " ok
[ "$ok" = "y" ] || { echo "취소됨"; exit 1; }

# 4) 반영
sync

# 5) 서버에서 검증 → 적용 → 기록 (값은 인자로 전달)
ssh "$HOST" bash -s -- "$TARGET" "$SHA" "$REMOTE_DIR" <<'EOF'
set -e
TARGET=$1; SHA=$2; cd "$3"

# .env.example에 있는 키가 서버 .env에 없으면 중단
keys() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*(=)' "$1" | tr -d '=' | sort -u; }
if [ -f .env.example ]; then
  missing=$(comm -13 <(keys .env) <(keys .env.example))
  [ -z "$missing" ] || { echo "서버 .env에 없는 키:"; echo "$missing"; exit 1; }
fi

docker compose config -q

if [ "$TARGET" = "app" ]; then
  docker compose exec -T nginx nginx -t
fi

docker compose up -d

if [ "$TARGET" = "app" ]; then
  docker compose exec -T nginx nginx -s reload
fi

echo "$(date -Is) $SHA" >> ~/deploy-history.log
EOF

echo "배포 완료: $TARGET @ $SHA"