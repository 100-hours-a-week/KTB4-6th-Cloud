"""V1의 1~5단계를 MySQL INSERT로 대체하고 meeting-flow.js 입력을 만든다.

의존성: pip install PyMySQL bcrypt
DB 접속: LOAD_TEST_DB_HOST, LOAD_TEST_DB_PORT(기본 3306), LOAD_TEST_DB_NAME,
         LOAD_TEST_DB_USER, LOAD_TEST_DB_PASSWORD(미설정 시 숨김 입력).
선택: LOAD_TEST_DB_SSL_CA (TLS 인증서 및 호스트 검증).
예: python3 prepare-flow-db.py --base-url https://api-dev.meety.io.kr \\
        --teams 50 --members-per-team 6 --output-dir reports/flow-db-50
기본은 스키마 검사만 수행한다. 실제 준비에는 --execute를 붙인다.
생성 파일: teams.credentials.json, fixtures-flow.json (기존 6단계에서 사용).
"""

import argparse
import getpass
import os
import secrets
import string
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from load_test_prep import base_url_from, save_fixture


# BE의 V1 엔티티와 동일한 필드를 넣는다. 추가 NOT NULL 컬럼은 검사에서 거부한다.
FIELDS = {
    "users": (),
    "user_auth_accounts": ("user_id", "provider", "provider_user_id", "password_hash"),
    "teams": ("name",),
    "team_members": ("user_id", "team_id", "display_name", "role", "membership_status"),
    "team_invitation_codes": ("team_id", "code"),
    "meetings": ("team_id", "created_by_team_member_id", "title", "purpose", "note",
                 "scheduled_at", "target_duration_minutes", "status"),
    "meeting_participants": ("meeting_id", "team_member_id", "participation_status"),
}
AUDIT_FIELDS = ("created_at", "updated_at", "deleted_at")


def check_schema(cursor):
    """불일치한 스키마나 비트랜잭션 테이블에 일부 데이터만 남기지 않는다."""
    cursor.execute("SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES "
                   "WHERE TABLE_SCHEMA = DATABASE()")
    tables = dict(cursor.fetchall())
    # V2는 크레딧 원장과 정책까지 재현해야 한다. V1처럼 준비하면 녹음 시작이 실패한다.
    if "team_credits" in tables or "credit_ledgers" in tables:
        raise ValueError("크레딧 테이블이 있는 DB입니다. 이 스크립트는 V1 전용입니다")
    for table, fields in FIELDS.items():
        if str(tables.get(table, "")).lower() != "innodb":
            raise ValueError(f"{table}: InnoDB 테이블이 필요합니다")
        cursor.execute("SELECT COLUMN_NAME, IS_NULLABLE, COLUMN_DEFAULT, EXTRA "
                       "FROM information_schema.COLUMNS "
                       "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s", (table,))
        columns = {row[0]: row[1:] for row in cursor.fetchall()}
        supplied = set(fields) | set(AUDIT_FIELDS)
        if not supplied.issubset(columns) or "id" not in columns:
            raise ValueError(f"{table}: V1에 필요한 컬럼이 없습니다")
        if "auto_increment" not in columns["id"][2].lower():
            raise ValueError(f"{table}: 자동 증가 id가 필요합니다")
        for name, (nullable, default, extra) in columns.items():
            if (name not in supplied and nullable == "NO" and default is None
                    and "auto_increment" not in extra.lower() and "GENERATED" not in extra.upper()):
                raise ValueError(f"{table}.{name}: 지원하지 않는 필수 컬럼입니다")


def insert(cursor, table, now, **values):
    """테이블·컬럼은 코드 상수만 사용하고 모든 값은 바인딩한다."""
    if table not in FIELDS or set(values) != set(FIELDS[table]):
        raise ValueError("정의되지 않은 INSERT입니다")
    row = {**values, "created_at": now, "updated_at": now, "deleted_at": None}
    columns = ", ".join(f"`{name}`" for name in row)
    placeholders = ", ".join(["%s"] * len(row))
    cursor.execute(f"INSERT INTO `{table}` ({columns}) VALUES ({placeholders})", tuple(row.values()))
    return cursor.lastrowid


def seed(cursor, args, bcrypt):
    """새 계정·새 팀만 생성한다. 녹음 세션과 런타임 연결은 6단계에서 만든다."""
    run_id = secrets.token_hex(8)
    now = datetime.now(ZoneInfo("Asia/Seoul")).replace(tzinfo=None)
    credentials = {"schemaVersion": 1, "baseUrl": args.base_url, "runId": run_id,
                   "complete": False, "source": "db-v1", "teams": []}
    fixture = {"preparation": {"complete": False, "baseUrl": args.base_url,
                               "runId": run_id, "source": "db-v1", "teams": []}}
    for number in range(1, args.teams + 1):
        name = f"LT{run_id[:5]}{number:03d}"
        team_id = insert(cursor, "teams", now, name=name)
        code = "".join(secrets.choice(string.ascii_uppercase + string.digits) for _ in range(8))
        insert(cursor, "team_invitation_codes", now, team_id=team_id, code=code)
        team = {"name": name, "teamId": team_id, "members": []}
        member_ids = []
        for index in range(1, args.members_per_team + 1):
            login_id = f"lt{run_id}t{number:03d}u{index:02d}"
            password = secrets.token_urlsafe(24)
            # Spring의 기본 BCryptPasswordEncoder와 같은 cost=10, $2a$ 형식이다.
            password_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=10, prefix=b"2a")).decode()
            user_id = insert(cursor, "users", now)
            insert(cursor, "user_auth_accounts", now, user_id=user_id, provider="local",
                   provider_user_id=login_id, password_hash=password_hash)
            display_name = f"참여자{index:02d}"
            member_id = insert(cursor, "team_members", now, user_id=user_id, team_id=team_id,
                               display_name=display_name, role="LEADER" if index == 1 else "MEMBER",
                               membership_status="ACTIVE")
            member_ids.append(member_id)
            team["members"].append({"loginId": login_id, "password": password, "userId": user_id,
                                    "displayName": display_name, "teamJoined": True})
        meeting_id = insert(cursor, "meetings", now, team_id=team_id,
                            created_by_team_member_id=member_ids[0], title="부하테스트 회의",
                            purpose="테스트 전용", note="", scheduled_at=now,
                            target_duration_minutes=20, status="WAITING")
        for member_id in member_ids:
            insert(cursor, "meeting_participants", now, meeting_id=meeting_id,
                   team_member_id=member_id, participation_status="JOINED")
        credentials["teams"].append(team)
        fixture["preparation"]["teams"].append({"teamId": team_id, "joinMeetingId": meeting_id})
        print(f"DB 준비 {number}/{args.teams}팀 (미커밋)", flush=True)
    return credentials, fixture


def prepare(connection, args, bcrypt):
    """미완료 파일을 커밋 전에 저장하고, 커밋 후에만 complete=true로 바꾼다."""
    credentials_path = args.output_dir / "teams.credentials.json"
    fixture_path = args.output_dir / "fixtures-flow.json"
    with connection.cursor() as cursor:
        check_schema(cursor)
    print(f"V1 스키마 검사 완료: {args.teams}팀, {args.teams * args.members_per_team}명, 회의 {args.teams}개")
    if not args.execute:
        print("DB 쓰기 없이 종료했습니다. 실제 준비에는 --execute를 지정하세요")
        return
    # mkdir의 배타적 생성으로 기존 결과 및 같은 경로의 동시 실행을 보호한다.
    args.output_dir.mkdir(parents=True, exist_ok=False, mode=0o700)
    commit_attempted = False
    try:
        connection.begin()
        with connection.cursor() as cursor:
            credentials, fixture = seed(cursor, args, bcrypt)
        save_fixture(credentials_path, credentials)
        save_fixture(fixture_path, fixture)
        commit_attempted = True
        connection.commit()
    except BaseException:
        connection.rollback()
        # COMMIT 중 연결이 끊기면 서버의 반영 여부는 클라이언트에서 확정할 수 없다.
        if commit_attempted:
            print("COMMIT 결과를 확인하지 못했습니다. 출력 ID로 DB 반영 여부를 확인하세요")
        else:
            print("준비 실패: 트랜잭션을 롤백했습니다. 출력 파일은 사용하지 마세요")
        raise
    credentials["complete"] = True
    fixture["preparation"]["complete"] = True
    try:
        save_fixture(credentials_path, credentials)
        save_fixture(fixture_path, fixture)
    except Exception:
        print("DB COMMIT은 완료됐지만 파일 저장에 실패했습니다. 출력 ID로 복구하고 다시 INSERT하지 마세요")
        raise
    print(f"DB 준비 완료. CREDENTIALS_FILE={credentials_path}, FIXTURE_FILE={fixture_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--teams", required=True, type=int)
    parser.add_argument("--members-per-team", type=int, default=6)
    parser.add_argument("--output-dir", required=True, type=Path, help="새 디렉터리 경로")
    parser.add_argument("--execute", action="store_true", help="스키마 검사 후 실제 INSERT 및 COMMIT")
    args = parser.parse_args()
    try:
        args.base_url = base_url_from(args.base_url)
        if not 1 <= args.teams <= 100 or not 1 <= args.members_per_team <= 10:
            raise ValueError("teams는 1~100, members-per-team은 1~10이어야 합니다")
        if args.output_dir.exists() or args.output_dir.is_symlink():
            raise ValueError("output-dir은 존재하지 않는 새 경로여야 합니다")
        # 접속 정보는 명령행 인자나 출력 파일에 기록하지 않는다.
        settings = {}
        for key in ("HOST", "NAME", "USER"):
            value = os.environ.get(f"LOAD_TEST_DB_{key}")
            if not value:
                raise ValueError(f"LOAD_TEST_DB_{key} 환경 변수가 필요합니다")
            settings[{"HOST": "host", "NAME": "database", "USER": "user"}[key]] = value
        settings["port"] = int(os.environ.get("LOAD_TEST_DB_PORT", "3306"))
        if not 1 <= settings["port"] <= 65535:
            raise ValueError("LOAD_TEST_DB_PORT는 1~65535여야 합니다")
        try:
            import pymysql
            import bcrypt
        except ImportError:
            raise ValueError("의존성이 필요합니다: pip install PyMySQL bcrypt") from None
        password = os.environ.get("LOAD_TEST_DB_PASSWORD")
        if password is None:
            password = getpass.getpass("DB password: ")
        ca = os.environ.get("LOAD_TEST_DB_SSL_CA")
        tls = {"ssl_ca": ca, "ssl_verify_cert": True, "ssl_verify_identity": True} if ca else {}
        connection = pymysql.connect(**settings, password=password, charset="utf8mb4",
                                     autocommit=False, connect_timeout=10, read_timeout=60,
                                     write_timeout=60, **tls)
        try:
            prepare(connection, args, bcrypt)
        finally:
            connection.close()
    except Exception as error:
        # DB 예외에는 접속 정보나 SQL 값이 포함될 수 있어 원문을 출력하지 않는다.
        message = str(error) if isinstance(error, (ValueError, FileExistsError)) else type(error).__name__
        parser.exit(1, f"준비 중단: {message}\n")


if __name__ == "__main__":
    main()
