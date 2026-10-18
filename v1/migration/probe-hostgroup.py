#!/usr/bin/env python3
"""dev-app에서 실행하는 독립 ProxySQL hostgroup 대기 실험. 기존 라우팅과 DB 데이터는 변경하지 않는다.

기존 이미지와 BE 환경의 인증값을 메모리에서 사용하며 비밀값은 출력하지 않는다.
별도 컨테이너 안의 mysql 클라이언트로 기존/신규 세션과 트랜잭션을 검사한다.
"""
import concurrent.futures
import argparse
import json
import pathlib
import queue
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile


NAME = "migration-hostgroup-probe"
CLIENTS = []


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        # 명령 전체나 환경 변수 대신 결과만 남긴다. 인증값이 포함된 설정은 출력하지 않는다.
        raise RuntimeError((result.stdout + result.stderr)[-5000:])
    return result.stdout


def report(event, **values):
    print(json.dumps({"event": event, "at": time.time(), **values}), flush=True)


class Session:
    def __init__(self, user):
        # 비밀번호는 명령 인자 대신 컨테이너 안의 보호된 옵션 파일에서 읽는다.
        self.proc = subprocess.Popen(
            ["docker", "exec", "-i", NAME, "mysql", "--defaults-extra-file=/tmp/client.cnf",
             "-h127.0.0.1", "-P6033", "-u" + user, "--skip-ssl", "-N", "-B", "-n",
             "--unbuffered", "--force", "dev_meetyDB"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1)
        self.lines = queue.Queue()
        def reader():
            for line in self.proc.stdout:
                self.lines.put(line.rstrip())
            self.lines.put(None)
        threading.Thread(target=reader, daemon=True).start()
        CLIENTS.append(self)

    def sql(self, sql, timeout=25):
        marker = "end_" + uuid.uuid4().hex
        self.proc.stdin.write(sql + "; SELECT '" + marker + "';\n")
        self.proc.stdin.flush()
        lines = []
        deadline = time.monotonic() + timeout
        while True:
            line = self.lines.get(timeout=max(.01, deadline - time.monotonic()))
            if line is None:
                raise RuntimeError("mysql client exited: " + repr(lines))
            if line == marker:
                if any("ERROR" in s for s in lines):
                    raise RuntimeError(repr(lines))
                return lines
            lines.append(line)

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jdbc-class", help="javac --release 17로 컴파일한 MigrationJdbcProbe.class")
    args = parser.parse_args()
    # 이름이 충돌하면 기존 컨테이너를 삭제하지 않고 중단한다.
    names = run(["docker", "ps", "-a", "--format", "{{.Names}} "]).split()
    if NAME in names:
        raise RuntimeError("probe container already exists")
    be = json.loads(run(["docker", "inspect", "dev-be"]))[0]
    env = dict(item.split("=", 1) for item in be["Config"]["Env"])
    user = env["SPRING_DATASOURCE_USERNAME"]
    password = env["SPRING_DATASOURCE_PASSWORD"]
    network = json.loads(run(["docker", "inspect", "dev-proxysql"]))[0]["HostConfig"]["NetworkMode"]
    with tempfile.TemporaryDirectory(prefix="migration-probe-") as directory:
        path = pathlib.Path(directory)
        config = '''datadir="/var/lib/proxysql";
admin_variables={admin_credentials="admin:admin";mysql_ifaces="127.0.0.1:6032";};
mysql_variables={threads=2;interfaces="0.0.0.0:6033";monitor_enabled=false;connect_timeout_server_max=20000;enforce_autocommit_on_reads=true;};
mysql_servers=(
{hostgroup=10;address="10.0.1.147";port=3306;use_ssl=1;},
{hostgroup=20;address="10.1.10.140";port=3306;use_ssl=1;status="OFFLINE_HARD";});
mysql_users=({username=USER;password=PASSWORD;default_hostgroup=10;transaction_persistent=1;});
mysql_query_rules=(
{rule_id=0;active=1;username=USER;match_pattern="^SELECT 'end_";destination_hostgroup=10;apply=1;},
{rule_id=1;active=1;username=USER;destination_hostgroup=10;apply=1;});
'''.replace("USER", json.dumps(user)).replace("PASSWORD", json.dumps(password))
        (path / "proxysql.cnf").write_text(config)
        (path / "proxysql.cnf").chmod(0o600)
        # mysql 옵션 파일은 JSON 문자열이 아니라 MySQL 옵션 파일의 이스케이프 규칙을 사용한다.
        escaped = password.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        (path / "client.cnf").write_text('[client]\npassword="' + escaped + '"\n')
        (path / "client.cnf").chmod(0o600)
        created = False
        try:
            run(["docker", "run", "-d", "--name", NAME, "--network", network,
                 "--memory", "160m", "--cpus", "0.5", "--user", "0",
                 "-v", str(path / "proxysql.cnf") + ":/etc/proxysql.cnf:ro",
                 "-v", str(path / "client.cnf") + ":/tmp/client.cnf:ro",
                 "proxysql/proxysql:3.0.11"])
            created = True
            def admin(sql):
                return run(["docker", "exec", NAME, "mysql", "-h127.0.0.1", "-P6032",
                            "-uadmin", "-padmin", "--skip-ssl", "-N", "-B", "-e", sql])
            for attempt in range(30):
                try:
                    admin("SELECT 1")
                    break
                except RuntimeError:
                    time.sleep(.2)
            else:
                raise RuntimeError("probe startup failed")
            # 완료 표식만 오하이오로 보내 COMMIT 이후의 표식 자체가 서울에서 대기하지 않게 한다.
            old = Session(user)
            reused = Session(user)
            assert reused.sql("SELECT @@server_id") == ["1"]
            assert old.sql("START TRANSACTION; SELECT @@server_id, id FROM meetings LIMIT 1")[0].startswith("1\t")
            report("ohio_transaction_started")
            admin("UPDATE mysql_query_rules SET destination_hostgroup=20 WHERE rule_id=1; LOAD MYSQL QUERY RULES TO RUNTIME")
            report("new_requests_routed_to_parked_seoul")
            fresh = Session(user)
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                futures = {"fresh": pool.submit(fresh.sql, "SELECT @@server_id"),
                           "reused": pool.submit(reused.sql, "SELECT @@server_id")}
                time.sleep(1)
                assert all(not f.done() for f in futures.values()), "new query did not wait"
                assert old.sql("SELECT @@server_id; COMMIT")[0] == "1"
                report("old_transaction_committed_while_new_queries_wait")
                futures["after_commit"] = pool.submit(old.sql, "SELECT @@server_id")
                time.sleep(1)
                assert all(not f.done() for f in futures.values()), "post-commit query did not wait"
                # 실제 전환에서는 최종 복제 확인 후에만 이 단계를 실행한다.
                admin("UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=20; LOAD MYSQL SERVERS TO RUNTIME")
                report("seoul_execution_enabled")
                for kind, future in futures.items():
                    result = future.result(timeout=23)
                    assert result == ["3"], (kind, result)
                    report("query_resumed", session=kind, result=result)
            report("PASS", scope="mysql client routing and connection-wait; no replication cutover")
            for client in CLIENTS:
                client.close()
            CLIENTS.clear()
            # 승격 이전 실패 시 HG20 대기 요청을 오하이오 별칭으로 풀어 주는 경로도 검증한다.
            admin("UPDATE mysql_servers SET status='OFFLINE_HARD' WHERE hostgroup_id=20; LOAD MYSQL SERVERS TO RUNTIME")
            rollback_client = Session(user)
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(rollback_client.sql, "SELECT @@server_id")
                time.sleep(1)
                assert not pending.done(), "rollback query did not wait"
                admin("INSERT INTO mysql_servers(hostgroup_id,hostname,port,use_ssl,status) VALUES(20,'10.0.1.147',3306,1,'ONLINE'); LOAD MYSQL SERVERS TO RUNTIME; UPDATE mysql_query_rules SET destination_hostgroup=10 WHERE rule_id=1; LOAD MYSQL QUERY RULES TO RUNTIME")
                assert pending.result(timeout=23) == ["1"]
                report("ROLLBACK_PASS", scope="already queued HG20 request resumed on Ohio alias")
            rollback_client.close()
            CLIENTS.clear()
            admin("DELETE FROM mysql_servers WHERE hostgroup_id=20 AND hostname='10.0.1.147'; LOAD MYSQL SERVERS TO RUNTIME")
            if args.jdbc_class:
                for client in CLIENTS:
                    client.close()
                CLIENTS.clear()
                admin("UPDATE mysql_query_rules SET destination_hostgroup=10 WHERE rule_id=1; LOAD MYSQL QUERY RULES TO RUNTIME; UPDATE mysql_servers SET status='OFFLINE_HARD' WHERE hostgroup_id=20; LOAD MYSQL SERVERS TO RUNTIME")
                (path / "MigrationJdbcProbe.class").write_bytes(pathlib.Path(args.jdbc_class).read_bytes())
                # 실행 중 BE 이미지에서 드라이버를 추출해 버전 차이를 없앤다.
                run(["docker", "cp", "dev-be:/app/app.jar", str(path / "app.jar")])
                with zipfile.ZipFile(path / "app.jar") as jar:
                    driver = next(n for n in jar.namelist() if n.startswith("BOOT-INF/lib/mysql-connector-j-") and n.endswith(".jar"))
                    (path / "mysql-connector.jar").write_bytes(jar.read(driver))
                    report("jdbc_driver", artifact=driver.split("/")[-1])
                url = env["SPRING_DATASOURCE_URL"]
                import re
                url = re.sub(r"^jdbc:mysql://[^/]+/", "jdbc:mysql://" + NAME + ":6033/", url)
                (path / "jdbc.env").write_text("PROBE_JDBC_URL=" + url + "\nSPRING_DATASOURCE_USERNAME=" + user + "\nSPRING_DATASOURCE_PASSWORD=" + password + "\n")
                (path / "jdbc.env").chmod(0o600)
                java_name = "migration-jdbc-probe-" + uuid.uuid4().hex[:8]
                java = subprocess.Popen(["docker", "run", "--rm", "-i", "--name", java_name, "--network", network, "--user", "0",
                              "--memory", "192m", "--cpus", "0.5", "--entrypoint", "java",
                              "--env-file", str(path / "jdbc.env"), "-v", str(path) + ":/probe:ro",
                              be["Config"]["Image"], "-Xmx64m", "-cp", "/probe:/probe/mysql-connector.jar", "MigrationJdbcProbe"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
                output_lines = queue.Queue()
                def read_java():
                    for line in java.stdout:
                        output_lines.put(line.rstrip())
                    output_lines.put(None)
                threading.Thread(target=read_java, daemon=True).start()
                deadline = time.monotonic() + 70
                passed = False
                try:
                    while True:
                        line = output_lines.get(timeout=max(.01, deadline - time.monotonic()))
                        if line is None:
                            break
                        print(line, flush=True)
                        if line == "JDBC_READY_FOR_ROUTE":
                            admin("UPDATE mysql_query_rules SET destination_hostgroup=20 WHERE rule_id=1; LOAD MYSQL QUERY RULES TO RUNTIME")
                        elif line == "JDBC_READY_FOR_OPEN":
                            admin("UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=20; LOAD MYSQL SERVERS TO RUNTIME")
                        else:
                            passed = passed or line.startswith("JDBC_PASS ")
                            continue
                        java.stdin.write("CONTINUE\n")
                        java.stdin.flush()
                    assert java.wait(timeout=5) == 0 and passed, "JDBC probe failed"
                finally:
                    if java.poll() is None:
                        java.terminate()
                    # docker CLI 종료만으로 컨테이너가 종료된다고 가정하지 않는다.
                    subprocess.run(["docker", "rm", "-f", java_name], text=True, capture_output=True)
        finally:
            for client in CLIENTS:
                client.close()
            if created:
                run(["docker", "rm", "-f", NAME])
                report("probe_container_removed")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        report("FAIL", error=str(exc))
        raise SystemExit(1)
