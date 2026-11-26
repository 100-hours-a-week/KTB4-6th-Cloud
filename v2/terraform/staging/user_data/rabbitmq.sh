#!/bin/bash
# RabbitMQ 서버 첫 부팅 설정 (#102). Docker와 Compose만 설치하고, RabbitMQ는 BE 담당자가 직접 띄운다.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y docker.io docker-compose-v2
systemctl enable --now docker
