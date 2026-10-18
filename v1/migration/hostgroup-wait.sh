#!/usr/bin/env bash
# switch.sh에서 불러오는 서버 등록 보존 방식. 직접 실행하지 않는다.
# 진행 중 트랜잭션은 HG10, 신규 트랜잭션은 닫힌 HG20에 배정한다.

hostgroup_preflight() {
  local out
  out=$(proxysql "bash $PADMIN \"SELECT CONCAT('RULES=',COUNT(*)) FROM mysql_query_rules; SELECT CONCAT('BAD_USER=',COUNT(*)) FROM runtime_mysql_users WHERE username='dev_meety_user' AND (transaction_persistent<>1 OR fast_forward<>0 OR default_hostgroup<>10); SELECT CONCAT('TARGET_CONN=',IFNULL(SUM(ConnUsed+ConnFree),0)) FROM stats_mysql_connection_pool WHERE hostgroup=20; SELECT CONCAT('READ_TX=',variable_value) FROM runtime_global_variables WHERE variable_name='mysql-enforce_autocommit_on_reads'; SELECT CONCAT('OLD_TIMEOUT=',variable_value) FROM global_variables WHERE variable_name='mysql-connect_timeout_server_max';\" 2>/dev/null | tr -d '| ' | grep -E '^(RULES|BAD_USER|TARGET_CONN|READ_TX|OLD_TIMEOUT)='") || die "hostgroup 사전 점검 실패"
  [ "$(value_of "$out" RULES)" = 0 ] && [ "$(value_of "$out" BAD_USER)" = 0 ] && [ "$(value_of "$out" TARGET_CONN)" = 0 ] || die "기존 규칙/사용자/서울 연결 확인 필요: $out"
  [ "$(value_of "$out" READ_TX)" = true ] || die "mysql-enforce_autocommit_on_reads=true를 부하 시작 전에 적용해야 합니다"
  OLD_TIMEOUT=$(value_of "$out" OLD_TIMEOUT)
  [[ "$OLD_TIMEOUT" =~ ^[0-9]+$ ]] || die "기존 연결 대기 설정을 읽지 못함"
}

hostgroup_rollback() {
  # HG20에 이미 배정된 요청은 규칙만 되돌려서는 HG10으로 이동하지 않는다.
  # 서울을 닫고 HG20에 오하이오 별칭을 추가해 대기 요청도 오하이오에서 처리한다.
  ohio "set -e
$OHIO_SQL 'SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF;'" || die "오하이오 쓰기 복구 실패. 대기를 유지합니다"
  proxysql "set -e
bash $PADMIN \"UPDATE mysql_servers SET status='OFFLINE_HARD' WHERE hostgroup_id=20 AND hostname='$SEOUL_DB_IP'; INSERT OR REPLACE INTO mysql_servers(hostgroup_id,hostname,port,use_ssl,status,comment) VALUES(20,'$OHIO_DB_IP',3306,1,'ONLINE','migration rollback alias'); LOAD MYSQL SERVERS TO RUNTIME; UPDATE mysql_query_rules SET destination_hostgroup=10 WHERE comment='migration-hostgroup-wait'; LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL SERVERS TO DISK; SAVE MYSQL QUERY RULES TO DISK; UPDATE global_variables SET variable_value='$OLD_TIMEOUT' WHERE variable_name='mysql-connect_timeout_server_max'; LOAD MYSQL VARIABLES TO RUNTIME;\"" || die "대기 요청 복구 실패. 수동 확인 필요"
  log "오하이오 쓰기·라우팅 복구. 대기 요청을 위한 HG20 오하이오 별칭은 유지합니다"
  exit 1
}

switch_hostgroup() {
  local out file pos t_hold t_ro t_promote t_switch
  out=$(proxysql "set -e
bash $PADMIN \"UPDATE mysql_servers SET status='OFFLINE_HARD' WHERE hostgroup_id=20 AND hostname='$SEOUL_DB_IP'; LOAD MYSQL SERVERS TO RUNTIME; UPDATE global_variables SET variable_value='90000' WHERE variable_name='mysql-connect_timeout_server_max'; LOAD MYSQL VARIABLES TO RUNTIME; INSERT INTO mysql_query_rules(rule_id,active,username,destination_hostgroup,apply,comment) VALUES(1,1,'dev_meety_user',20,1,'migration-hostgroup-wait'); LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL SERVERS TO DISK; SAVE MYSQL QUERY RULES TO DISK;\" >/dev/null
echo AT=$NOW
bash $PADMIN \"SELECT CONCAT('GATE=',destination_hostgroup) FROM runtime_mysql_query_rules WHERE comment='migration-hostgroup-wait'; SELECT CONCAT('PARKED=',hostname,':',status) FROM mysql_servers WHERE hostgroup_id=20; SELECT CONCAT('TARGET_RUNTIME=',COUNT(*)) FROM runtime_mysql_servers WHERE hostgroup_id=20;\"") || rollback "서울 대기·신규 요청 라우팅 실패"
  echo "$out" | tr -d '| ' | grep -qx 'GATE=20' || rollback "신규 요청 HG20 라우팅 적용 확인 실패"
  echo "$out" | tr -d '| ' | grep -qx "PARKED=$SEOUL_DB_IP:OFFLINE_HARD" || rollback "서울 실행 대기 상태 확인 실패"
  # OFFLINE_HARD 서버는 설정에는 남지만 runtime_mysql_servers에서는 제외된다.
  echo "$out" | tr -d '| ' | grep -qx 'TARGET_RUNTIME=0' || rollback "서울 runtime 실행 차단 확인 실패"
  t_hold=$(value_of "$out" AT)
  [[ "$t_hold" =~ ^[0-9]+$ ]] || rollback "대기 시작 시각 확인 실패"
  log "hold: 신규 요청 HG20 대기, 기존 트랜잭션 HG10 유지"

  # 연결 수 대신 실제 InnoDB 트랜잭션을 확인한다. 종료되지 않으면 전환을 강행하지 않는다.
  out=$(ohio "set -eu
n=1
for i in \$(seq 1 50); do
  n=\$($OHIO_SQL \"SELECT COUNT(*) FROM information_schema.innodb_trx\")
  [ \"\$n\" = 0 ] && break
  sleep 0.2
done
[ \"\$n\" = 0 ] || { echo 'ERROR: active transactions did not drain'; exit 1; }
echo DRAIN_TRX=\$n
coordinates=\$($OHIO_SQL 'SET PERSIST super_read_only=ON; SET PERSIST read_only=ON; SHOW BINARY LOG STATUS;')
printf '%s\\n' \"\$coordinates\" | awk '{print \"FILE=\" \$1; print \"POS=\" \$2}'
echo AT=$NOW") || rollback "기존 트랜잭션 종료 또는 오하이오 쓰기 차단 실패"
  file=$(value_of "$out" FILE); pos=$(value_of "$out" POS); t_ro=$(value_of "$out" AT)
  [[ "$file" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ "$pos" =~ ^[0-9]+$ ]] || rollback "최종 binlog 위치 확인 실패"
  log "ohio_ro: 기존 작업 종료(active_tx=$(value_of "$out" DRAIN_TRX))·쓰기 차단, 최종 위치 $file:$pos"

  # 승격 결과가 불명확하면 오하이오를 자동으로 다시 열지 않는다.
  CAN_ROLLBACK=false
  out=$(seoul "set -e
r=\$($SEOUL_SQL \"SELECT SOURCE_POS_WAIT('$file',$pos,10)\")
echo WAIT=\$r
case \"\$r\" in ''|-1|NULL) echo NOT_PROMOTED=1; exit 0 ;; esac
$SEOUL_SQL 'STOP REPLICA; SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF;'
echo PROMOTED=1
echo AT=$NOW") || die "서울 승격 결과 불명확. 오하이오 쓰기 차단·HG20 대기를 유지합니다. DB 상태 확인 필요"
  if [ "$(value_of "$out" NOT_PROMOTED)" = 1 ]; then
    CAN_ROLLBACK=true
    rollback "최종 위치까지 복제되지 않음"
  fi
  [ "$(value_of "$out" PROMOTED)" = 1 ] || die "서울 승격 완료 확인 실패. 대기를 유지합니다"
  t_promote=$(value_of "$out" AT)
  log "promote: 최종 위치 복제 적용 확인(SOURCE_POS_WAIT=$(value_of "$out" WAIT)), 서울 쓰기 허용(아직 HG20 대기)"

  out=$(proxysql "set -e
bash $PADMIN \"UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=20 AND hostname='$SEOUL_DB_IP'; LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; UPDATE global_variables SET variable_value='$OLD_TIMEOUT' WHERE variable_name='mysql-connect_timeout_server_max'; LOAD MYSQL VARIABLES TO RUNTIME; SELECT CONCAT('TARGET=',hostname,':',status) FROM runtime_mysql_servers WHERE hostgroup_id=20;\"
echo AT=$NOW") || die "서울 승격 후 실행 허용 결과 불명확. HG20 확인 필요. 오하이오로 되돌리지 마세요"
  echo "$out" | tr -d '| ' | grep -qx "TARGET=$SEOUL_DB_IP:ONLINE" || die "HG20 서울 ONLINE 확인 실패"
  t_switch=$(value_of "$out" AT)
  log "switch: HG20 서울 실행 허용. HG10 오하이오 등록 유지·쓰기 차단"
  log "대기 구간 $((t_switch-t_hold)) ms. 복제 메타데이터 보존(STOP REPLICA만 실행)"
  echo "verify.py: --mark hold=$t_hold --mark ohio_ro=$t_ro --mark promote=$t_promote --mark switch=$t_switch"
}
