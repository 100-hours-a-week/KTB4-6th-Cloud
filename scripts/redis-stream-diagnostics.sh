#!/usr/bin/env bash
# Read-only diagnostics for one Redis Stream and consumer group.
set -euo pipefail

usage() {
  echo "Usage: $0 --stream KEY --group GROUP [--host HOST --port PORT | --sentinel-host HOST --sentinel-port PORT --master-name NAME]" >&2
  echo "Set REDISCLI_AUTH in the environment when authentication is required; do not pass a password as an argument." >&2
}

stream= group= host=127.0.0.1 port=6379 sentinel_host= sentinel_port=26379 master_name=
while (($#)); do
  case "$1" in
    --stream|--group|--host|--port|--sentinel-host|--sentinel-port|--master-name)
      (($# >= 2)) || { usage; exit 2; }
      case "$1" in
        --stream) stream=$2 ;; --group) group=$2 ;; --host) host=$2 ;;
        --port) port=$2 ;; --sentinel-host) sentinel_host=$2 ;;
        --sentinel-port) sentinel_port=$2 ;; --master-name) master_name=$2 ;;
      esac
      shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n $stream && -n $group ]] || { usage; exit 2; }
[[ $port =~ ^[0-9]+$ && $sentinel_port =~ ^[0-9]+$ ]] || { usage; exit 2; }

# REDISCLI_AUTH is inherited by redis-cli, never placed in process arguments.
query() {
  local output
  if ! output=$(redis-cli --no-auth-warning --raw -h "$host" -p "$port" "$@" 2>/dev/null); then
    echo "Redis connection or command failed ($host:$port). Check address, authentication, and server availability." >&2
    return 1
  fi
  if [[ $output == ERR\ * || $output == NOAUTH\ * || $output == NOGROUP\ * || $output == WRONGTYPE\ * ]]; then
    echo "Redis rejected the read-only command ($host:$port). Check Stream key and group." >&2
    return 1
  fi
  printf '%s\n' "$output"
}

if [[ -n $sentinel_host || -n $master_name ]]; then
  [[ -n $sentinel_host && -n $master_name ]] || { usage; exit 2; }
  host=$sentinel_host port=$sentinel_port
  master=$(query SENTINEL get-master-addr-by-name "$master_name") || exit 1
  read -r discovered_host discovered_port extra <<< "$(printf '%s' "$master" | tr '\n' ' ')"
  [[ -n $discovered_host && $discovered_port =~ ^[0-9]+$ && -z ${extra:-} ]] || {
    echo "Sentinel did not return a Master for $master_name." >&2; exit 1;
  }
  host=$discovered_host port=$discovered_port
  echo "Sentinel Master: $host:$port ($master_name)"
fi

role=$(query ROLE) || exit 1
echo "Target: $host:$port; role: ${role%%$'\n'*}"
type=$(query TYPE "$stream") || exit 1
[[ $type == stream ]] || { echo "Stream '$stream' does not exist or has a different type ($type)." >&2; exit 1; }

for section in memory persistence replication; do
  echo "== INFO $section =="
  query INFO "$section" | tr -d '\r' | awk -F: '/^(used_memory:|maxmemory:|maxmemory_policy:|mem_fragmentation_ratio:|aof_enabled:|aof_last_write_status:|aof_last_bgrewrite_status:|aof_current_size:|role:|connected_slaves:|master_link_status:|master_sync_in_progress:)/ {print}'
done
echo "== XLEN $stream =="
query XLEN "$stream"
echo "== XINFO STREAM $stream =="
# XINFO includes first/last entry payloads; print metadata only.
query XINFO STREAM "$stream" | awk '/^first-entry$/{exit} {print}'
echo "== XINFO GROUPS $stream =="
query XINFO GROUPS "$stream"
echo "== XPENDING $stream $group (summary) =="
query XPENDING "$stream" "$group"
echo "== First pending by ID (ID, consumer, idle milliseconds, deliveries) =="
query XPENDING "$stream" "$group" - + 1
