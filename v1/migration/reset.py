#!/usr/bin/env python3
"""오하이오 dev 데이터를 기준으로 리허설 복제본을 초기화한다. --preflight는 조회만 한다."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import time

SETTINGS = json.loads(Path(__file__).with_name('settings.json').read_text())
PROFILE = os.environ.get('AWS_PROFILE', 'meety-admin')


def aws(region, *args):
    result = subprocess.run(['aws', '--profile', PROFILE, '--region', region, '--no-cli-pager', *args],
                            text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('AWS 명령 실패: ' + result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def remote(role, body, label, private=False):
    """SSM에 인증값을 넘길 수 있으므로 실패 시 명령 본문이나 전체 출력을 재출력하지 않는다."""
    region, instance = SETTINGS[role + '_REGION'], SETTINGS[role + '_DB']
    helper = MYSQL.replace('__CONTAINER__', SETTINGS[role + '_CONTAINER'])
    script = "set -eu\npython3 - <<'REHEARSAL'\n" + helper + '\n' + body + '\nREHEARSAL\n'
    command = aws(region, 'ssm', 'send-command', '--instance-ids', instance,
                  '--document-name', 'AWS-RunShellScript', '--parameters',
                  json.dumps({'commands': [script], 'executionTimeout': ['900']}),
                  '--comment', 'Ohio rehearsal ' + label)['Command']['CommandId']
    deadline = time.monotonic() + 930
    while time.monotonic() < deadline:
        time.sleep(1)
        try:
            result = aws(region, 'ssm', 'get-command-invocation', '--command-id', command, '--instance-id', instance)
        except RuntimeError as error:
            if 'InvocationDoesNotExist' in str(error):
                continue
            raise
        if result['Status'] in ('Pending', 'Delayed', 'InProgress'):
            continue
        if result['Status'] != 'Success':
            raise RuntimeError(f'{label} 실패. SSM command={command}에서 상태 확인 필요')
        output = result.get('StandardOutputContent', '')
        if not private:
            print(label + ': ' + output.strip(), flush=True)
        return output
    raise RuntimeError(f'{label} 결과 불명확: {command}. 상태 확인 전 재실행 금지')


def app(script, label):
    """앱 서버도 같은 AWS/SSM 구현을 사용하되 대상 ID만 별도로 지정한다."""
    command = aws(SETTINGS['SOURCE_REGION'], 'ssm', 'send-command', '--instance-ids', SETTINGS['SOURCE_APP'],
                  '--document-name', 'AWS-RunShellScript', '--parameters',
                  json.dumps({'commands': ['set -eu\n' + script], 'executionTimeout': ['300']}),
                  '--comment', 'Ohio rehearsal ' + label)['Command']['CommandId']
    for _ in range(330):
        time.sleep(1)
        try:
            result = aws(SETTINGS['SOURCE_REGION'], 'ssm', 'get-command-invocation',
                         '--command-id', command, '--instance-id', SETTINGS['SOURCE_APP'])
        except RuntimeError as error:
            if 'InvocationDoesNotExist' in str(error):
                continue
            raise
        if result['Status'] in ('Pending', 'Delayed', 'InProgress'):
            continue
        if result['Status'] != 'Success':
            raise RuntimeError(f'{label} 실패: SSM command={command}')
        return result.get('StandardOutputContent', '').strip()
    raise RuntimeError(f'{label} 결과 불명확: {command}')


MYSQL = r'''
import json, subprocess, pathlib, time, re, hashlib
container = '__CONTAINER__'
def sql(query):
    p = subprocess.run(['docker','exec','-i',container,'sh','-c',
                        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot --batch --skip-column-names'],
                       input=query, text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError('MySQL operation failed (SQL and credentials omitted)')
    return p.stdout.strip()
def status():
    p = subprocess.run(['docker','exec','-i',container,'sh','-c',
                        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot --batch'],
                       input='SHOW REPLICA STATUS;\n', text=True, capture_output=True)
    assert p.returncode == 0
    rows = p.stdout.splitlines()
    return dict(zip(rows[0].split('\t'),rows[1].split('\t'))) if len(rows)>1 else {}
def counts():
    result = {}
    for table in sql("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='dev_meetyDB' ORDER BY TABLE_NAME;").splitlines():
        assert re.fullmatch(r'[a-zA-Z0-9_]+',table)
        result[table] = int(sql('SELECT COUNT(*) FROM dev_meetyDB.`'+table+'`;'))
    return result
'''


def preflight():
    if SETTINGS['SOURCE_REGION'] != 'us-east-2' or SETTINGS['TARGET_REGION'] != 'us-east-2':
        raise RuntimeError('이 스크립트는 오하이오 리허설 전용이다')
    if SETTINGS['SOURCE_DB'] == SETTINGS['TARGET_DB'] or SETTINGS['DB_NAME'] != 'dev_meetyDB':
        raise RuntimeError('원본/대상 설정 오류')
    account = aws('us-east-2', 'sts', 'get-caller-identity')['Account']
    if account != SETTINGS['ACCOUNT_ID']:
        raise RuntimeError('AWS 계정 불일치')
    for role in ('SOURCE', 'TARGET'):
        instance = aws(SETTINGS[role+'_REGION'], 'ec2', 'describe-instances',
                       '--instance-ids', SETTINGS[role+'_DB'])['Reservations'][0]['Instances'][0]
        if instance['PrivateIpAddress'] != SETTINGS[role+'_DB_IP'] or instance['State']['Name'] != 'running':
            raise RuntimeError(role+' 인스턴스 불일치')
        identity = remote(role, MYSQL_IDENTITY, role+' identity', private=True).strip()
        if identity != SETTINGS[role+'_SERVER_ID']:
            raise RuntimeError(role+' MySQL server_id 불일치')
    # 리허설 이외의 규칙이 있으면 이를 덮어쓰거나 BE를 중지하지 않는다.
    rule_check = "SELECT CONCAT('BAD_RULES=',COUNT(*)) FROM mysql_query_rules WHERE COALESCE(comment,'')<>'migration-hostgroup-wait';"
    running = app("bash " + SETTINGS['PADMIN'] + " " + repr(rule_check) + " | tr -d '| ' | grep -qx 'BAD_RULES=0'\ndocker inspect dev-be --format '{{.State.Running}}'", 'app preflight')
    if running not in ('true', 'false'):
        raise RuntimeError('dev-be 상태 확인 실패')
    print('계정·인스턴스·MySQL 식별자·ProxySQL 확인 완료', flush=True)
    return running == 'true'


MYSQL_IDENTITY = "assert sql('SELECT VERSION();').startswith('8.4.')\nprint(sql('SELECT @@server_id;'))"


def prepare_monitor():
    """원본 모니터 인증 해시를 복제하고 대상의 읽기 전용 상태를 반드시 복원한다."""
    host = SETTINGS['SOURCE_APP_IP']
    account = "'proxysql_monitor'@'" + host + "'"
    query = ("SELECT JSON_ARRAYAGG(JSON_ARRAY(plugin,HEX(authentication_string),ssl_type)) "
             "FROM mysql.user WHERE user='proxysql_monitor' AND host='" + host + "';")
    rows = json.loads(remote('SOURCE', 'print(sql('+repr(query)+'))', 'read monitor credential', private=True))
    if not rows or len(rows) != 1 or rows[0][0] != 'caching_sha2_password' or rows[0][2] not in ('', 'ANY'):
        raise RuntimeError('원본 모니터 계정 인증·TLS 정책 확인 필요')
    authhash = bytes.fromhex(rows[0][1]).decode()
    if not authhash.startswith('$A$') or len(authhash) < 60:
        raise RuntimeError('모니터 계정 해시 형식 확인 필요')
    authhash = authhash.replace('\\', '\\\\').replace("'", "''")
    policy = ' REQUIRE SSL' if rows[0][2] == 'ANY' else ''
    # 계정 관리는 대상 로컬에만 반영한다. read_only는 계속 ON으로 유지한다.
    grant = (f"SET SESSION sql_log_bin=0; CREATE USER IF NOT EXISTS {account} "
             f"IDENTIFIED WITH caching_sha2_password AS '{authhash}'{policy}; "
             f"ALTER USER {account} IDENTIFIED WITH caching_sha2_password AS '{authhash}'{policy}; "
             f"GRANT REPLICATION CLIENT ON *.* TO {account};")
    body = ("assert sql('SELECT @@server_id,@@read_only,@@super_read_only;').split() == " + repr([SETTINGS['TARGET_SERVER_ID'], '1', '1']) + "\n"
            "sql('SET GLOBAL super_read_only=OFF;')\n"
            "try:\n    sql("+repr(grant)+")\n"
            "finally:\n    sql('SET GLOBAL super_read_only=ON;')\n"
            "print('monitor account ready; read_only=1 super_read_only=1')")
    remote('TARGET', body, 'prepare target monitor', private=True)


def reset(was_running):
    """BE를 잠시 중지하고 덤프/복원한다. 복제 실패 시 대상 승격이나 서울 변경은 하지 않는다."""
    source_ready = False
    source_ip, target_ip = SETTINGS['SOURCE_DB_IP'], SETTINGS['TARGET_DB_IP']
    # 기존 복제 암호는 읽지 않고, 이번 초기화용 32자 암호를 생성한다.
    password = secrets.token_hex(16)
    user = "'rehearsal_repl'@'" + target_ip + "'"
    try:
        if was_running:
            app('docker stop -t 30 dev-be', 'pause BE')
        # 초기화 전에 신규 요청을 원본으로만 보내고 기존 대상 연결을 끊는다.
        routing = ("DELETE FROM mysql_query_rules WHERE comment='migration-hostgroup-wait'; "
                   "DELETE FROM mysql_servers WHERE hostgroup_id IN (10,20); "
                   f"INSERT INTO mysql_servers(hostgroup_id,hostname,port,use_ssl,status,max_connections,comment) VALUES(10,'{source_ip}',3306,1,'ONLINE',{SETTINGS['PROXYSQL_MAX_CONNECTIONS']},'dev source'),(20,'{target_ip}',3306,1,'OFFLINE_HARD',{SETTINGS['PROXYSQL_MAX_CONNECTIONS']},'rehearsal target'); "
                   "LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK; "
                   "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; "
                   "UPDATE global_variables SET variable_value='true' WHERE variable_name='mysql-enforce_autocommit_on_reads'; "
                   "UPDATE global_variables SET variable_value='30000' WHERE variable_name='mysql-connect_timeout_server_max'; "
                   "LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;")
        app('bash '+SETTINGS['PADMIN']+' '+repr(routing)+' >/dev/null\ndocker restart dev-proxysql >/dev/null', 'restore route')
        remote('SOURCE', f"assert not status()\nsql('SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF; SET PERSIST max_connections={SETTINGS['DB_MAX_CONNECTIONS']};')\nprint('원본 쓰기 허용')", 'restore source')
        source_ready = True
        # 사용자 관리 SQL은 복제 로그에 남기지 않는다. 덤프 권한은 복원 직후 회수한다.
        grant = (f"SET SESSION sql_log_bin=0; CREATE USER IF NOT EXISTS {user} IDENTIFIED BY '{password}' REQUIRE SSL; "
                 f"ALTER USER {user} IDENTIFIED BY '{password}' REQUIRE SSL; "
                 f"GRANT REPLICATION SLAVE, REPLICATION CLIENT, RELOAD, SHOW_ROUTINE ON *.* TO {user}; "
                 f"GRANT SELECT,SHOW VIEW,TRIGGER,EVENT ON dev_meetyDB.* TO {user};")
        remote('SOURCE', 'sql('+repr(grant)+')', 'prepare replication account', private=True)
        auth = json.loads(remote('SOURCE', "print(sql(\"SELECT JSON_ARRAYAGG(JSON_ARRAY(plugin,HEX(authentication_string))) FROM mysql.user WHERE user='dev_meety_user';\"))", 'read app credential', private=True))
        hashes = {(r[0], bytes.fromhex(r[1]).decode()) for r in auth}
        if len(hashes) != 1 or next(iter(hashes))[0] != 'caching_sha2_password':
            raise RuntimeError('원본 앱 계정 인증 방식 확인 필요')
        authhash = next(iter(hashes))[1].replace('\\', '\\\\').replace("'", "''")
        app_user = (f"CREATE USER IF NOT EXISTS 'dev_meety_user'@'10.0.1.97' IDENTIFIED WITH caching_sha2_password AS '{authhash}'; "
                    f"ALTER USER 'dev_meety_user'@'10.0.1.97' IDENTIFIED WITH caching_sha2_password AS '{authhash}'; "
                    "GRANT ALL PRIVILEGES ON dev_meetyDB.* TO 'dev_meety_user'@'10.0.1.97';")
        body = RESET_TARGET.replace('__PASSWORD__', password).replace('__SOURCE_IP__', source_ip)
        body = body.replace('__APP_USER_SQL__', repr(app_user)).replace('__DB_MAX_CONNECTIONS__', SETTINGS['DB_MAX_CONNECTIONS'])
        remote('TARGET', body, 'rebuild target', private=True)
        prepare_monitor()
        revoke = (f"SET SESSION sql_log_bin=0; REVOKE REPLICATION CLIENT,RELOAD,SHOW_ROUTINE ON *.* FROM {user}; "
                  f"REVOKE SELECT,SHOW VIEW,TRIGGER,EVENT ON dev_meetyDB.* FROM {user};")
        remote('SOURCE', 'sql('+repr(revoke)+')', 'reduce replication privileges', private=True)
        left = json.loads(remote('SOURCE', 'print(json.dumps(counts()))', 'source row counts', private=True))
        right = json.loads(remote('TARGET', 'print(json.dumps(counts()))', 'target row counts', private=True))
        if not left or left != right:
            raise RuntimeError('테이블별 행 수 불일치. 전환 금지')
        print(f'{len(left)}개 테이블 행 수 일치, 복제 정상', flush=True)
        # 다음 실험을 위해 HG20를 등록한다. 앱 기본 경로는 HG10이고 규칙은 비워 둔다.
        app('bash '+SETTINGS['PADMIN']+' '+repr("UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=20; LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;")+' >/dev/null', 'enable standby')
    finally:
        # 초기화 실패 시에도 원본 경로가 확인됐다면 dev를 복구한다. 대상 승격은 하지 않는다.
        if was_running and source_ready:
            app("docker start dev-be >/dev/null\nfor i in $(seq 1 60); do [ \"$(docker inspect dev-be --format '{{.State.Health.Status}}')\" != healthy ] || break; sleep 2; done\n[ \"$(docker inspect dev-be --format '{{.State.Health.Status}}')\" = healthy ]\ndocker exec dev-nginx nginx -t\ndocker exec dev-nginx nginx -s reload", 'resume BE')


RESET_TARGET = r'''
# 대상 서버의 영속 설정은 task-66에서 구성했다. 다른 환경에 재사용하지 않는다.
assert sql('SELECT @@server_id;') == '6'
if status(): sql('STOP REPLICA; RESET REPLICA ALL;')
backup_dir = pathlib.Path('/root/rehearsal-backups'); backup_dir.mkdir(mode=0o700,exist_ok=True)
backup = backup_dir / ('before-reset-'+str(time.time_ns())+'.sql')
with backup.open('wb') as f:
    backup.chmod(0o600)
    p = subprocess.run(['docker','exec',container,'sh','-c','MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --routines --events --triggers --set-gtid-purged=OFF --no-tablespaces --databases dev_meetyDB'],stdout=f,stderr=subprocess.PIPE)
assert p.returncode == 0 and backup.stat().st_size > 0, 'Target backup failed'
seed = backup_dir / ('seed-'+str(time.time_ns())+'.sql')
with seed.open('wb') as f:
    seed.chmod(0o600)
    p = subprocess.run(['docker','exec','-i',container,'sh','-c','IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec mysqldump --host=__SOURCE_IP__ --user=rehearsal_repl --ssl-mode=REQUIRED --single-transaction --source-data=2 --set-gtid-purged=OFF --no-tablespaces --routines --events --triggers --databases dev_meetyDB'],input=('__PASSWORD__'+'\n').encode(),stdout=f,stderr=subprocess.PIPE)
assert p.returncode == 0 and seed.stat().st_size > 0, 'Source dump failed'
match = re.search(r"CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='([^']+)', SOURCE_LOG_POS=(\d+)", seed.read_text())
assert match, 'Binary log coordinates missing'
sql('SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF; SET PERSIST max_connections=__DB_MAX_CONNECTIONS__; DROP DATABASE IF EXISTS dev_meetyDB;')
with seed.open('rb') as f:
    p = subprocess.run(['docker','exec','-i',container,'sh','-c','MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot'],stdin=f,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
assert p.returncode == 0, 'Restore failed'
sql(__APP_USER_SQL__)
sql("CHANGE REPLICATION FILTER REPLICATE_WILD_DO_TABLE=('dev_meetyDB.%');")
sql("CHANGE REPLICATION SOURCE TO SOURCE_HOST='__SOURCE_IP__',SOURCE_PORT=3306,SOURCE_USER='rehearsal_repl',SOURCE_PASSWORD='__PASSWORD__',SOURCE_SSL=1,SOURCE_LOG_FILE='"+match.group(1)+"',SOURCE_LOG_POS="+match.group(2)+",SOURCE_AUTO_POSITION=0;")
sql('SET PERSIST read_only=ON; SET PERSIST super_read_only=ON; SET PERSIST_ONLY skip_replica_start=OFF; START REPLICA;')
for _ in range(60):
    s = status()
    if s.get('Replica_IO_Running') == s.get('Replica_SQL_Running') == 'Yes' and s.get('Seconds_Behind_Source') == '0': break
    time.sleep(2)
else: raise RuntimeError('Replication did not become healthy')
print('Target restored; backup='+str(backup))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight', action='store_true')
    parser.add_argument('--yes', action='store_true')
    args = parser.parse_args()
    was_running = preflight()
    if args.preflight:
        return
    if not args.yes and input('대상 테스트 데이터를 지우고 원본에서 다시 복제합니다. dev 중단을 허용하면 yes: ') != 'yes':
        raise SystemExit('취소')
    reset(was_running)
    print('초기화 완료. switch.sh --preflight로 확인하세요.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, KeyError, ValueError, IndexError) as error:
        raise SystemExit(str(error))
