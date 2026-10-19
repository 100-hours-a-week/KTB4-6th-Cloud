#!/usr/bin/env bash
# 구 Nginx/서울 전환 진입점은 오하이오 ProxySQL 리허설로 위임한다.
# switch.sh와 동일하게 --mode 또는 --preflight를 명시해야 한다.
exec bash "$(dirname "${BASH_SOURCE[0]}")/switch.sh" "$@"
