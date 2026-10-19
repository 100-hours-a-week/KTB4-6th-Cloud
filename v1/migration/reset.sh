#!/usr/bin/env bash
# 대상 테스트 데이터를 폐기하고 오하이오 dev DB에서 재복제한다. dev BE를 잠시 중지한다.
# --preflight는 조회만 하며, --yes를 생략하면 초기화 확인을 받는다.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/reset.py" "$@"
