"""DB 준비의 연관 데이터, 실패 시 롤백, 출력 파일 계약을 외부 접속 없이 검증한다."""

import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location("prepare_flow_db", Path(__file__).with_name("prepare-flow-db.py"))
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)


class Cursor:
    # INSERT와 FK 검증은 SQLite에서 실제 실행하고 MySQL 스키마 조회만 대체한다.
    def __init__(self, connection):
        self.connection = connection
        self.rows = []
        self.lastrowid = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def execute(self, sql, params=()):
        if "information_schema.TABLES" in sql:
            self.rows = [(name, "InnoDB") for name in prep.FIELDS]
        elif "information_schema.COLUMNS" in sql:
            self.rows = [("id", "NO", None, "auto_increment")]
            self.rows += [(name, "YES", None, "") for name in (*prep.FIELDS[params[0]], *prep.AUDIT_FIELDS)]
        else:
            values = tuple(value.isoformat() if isinstance(value, prep.datetime) else value for value in params)
            self.lastrowid = self.connection.db.execute(sql.replace("%s", "?"), values).lastrowid

    def fetchall(self):
        return self.rows


class Connection:
    def __init__(self):
        self.db = sqlite3.connect(":memory:")
        self.db.execute("PRAGMA foreign_keys=ON")
        refs = {"user_id": "users", "team_id": "teams", "meeting_id": "meetings",
                "team_member_id": "team_members", "created_by_team_member_id": "team_members"}
        for table, fields in prep.FIELDS.items():
            columns = ["id INTEGER PRIMARY KEY"]
            for field in (*fields, *prep.AUDIT_FIELDS):
                reference = f" REFERENCES {refs[field]}(id)" if field in refs else ""
                columns.append(f"{field} TEXT{reference}")
            self.db.execute(f"CREATE TABLE {table} ({', '.join(columns)})")

    def cursor(self):
        return Cursor(self)

    def begin(self):
        self.db.execute("BEGIN")

    def commit(self):
        self.db.commit()

    def rollback(self):
        self.db.rollback()


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.args = SimpleNamespace(base_url="https://api-dev.meety.io.kr", teams=2,
                                    members_per_team=3, execute=True,
                                    output_dir=Path(self.temp.name) / "new")
        self.connection = Connection()
        self.addCleanup(self.connection.db.close)
        # 실제 bcrypt 호환성 검증은 별도로 필요하다. 이 테스트는 데이터·트랜잭션 검증이다.
        self.bcrypt = Mock()
        self.bcrypt.hashpw.return_value = b"test-hash"

    def test_seed_matches_flow_inputs_and_memberships(self):
        prep.prepare(self.connection, self.args, self.bcrypt)
        credentials_path = self.args.output_dir / "teams.credentials.json"
        credentials = json.loads(credentials_path.read_text())
        fixture = json.loads((self.args.output_dir / "fixtures-flow.json").read_text())
        self.assertTrue(credentials["complete"])
        self.assertTrue(fixture["preparation"]["complete"])
        self.assertEqual(credentials_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(credentials["baseUrl"], fixture["preparation"]["baseUrl"])
        self.assertEqual(len(credentials["teams"]), 2)
        for team, prepared in zip(credentials["teams"], fixture["preparation"]["teams"]):
            self.assertEqual(team["teamId"], prepared["teamId"])
            rows = self.connection.db.execute(
                "SELECT m.status, tm.user_id, tm.role, tm.membership_status, p.participation_status "
                "FROM meetings m JOIN meeting_participants p ON p.meeting_id=m.id "
                "JOIN team_members tm ON tm.id=p.team_member_id AND tm.team_id=m.team_id "
                "WHERE m.id=? ORDER BY tm.id", (prepared["joinMeetingId"],)).fetchall()
            self.assertEqual(len(rows), 3)
            for index, row in enumerate(rows):
                self.assertEqual(row, ("WAITING", str(team["members"][index]["userId"]),
                                       "LEADER" if index == 0 else "MEMBER", "ACTIVE", "JOINED"))
        self.bcrypt.gensalt.assert_called_with(rounds=10, prefix=b"2a")

    def test_file_failure_rolls_back_all_teams(self):
        with patch.object(prep, "save_fixture", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                prep.prepare(self.connection, self.args, self.bcrypt)
        for table in prep.FIELDS:
            self.assertEqual(self.connection.db.execute(f"SELECT count(*) FROM {table}").fetchone()[0], 0)

    def test_check_only_creates_no_files_or_records(self):
        self.args.execute = False
        prep.prepare(self.connection, self.args, self.bcrypt)
        self.assertFalse(self.args.output_dir.exists())
        self.bcrypt.hashpw.assert_not_called()

    def test_existing_directory_is_not_overwritten(self):
        self.args.output_dir.mkdir()
        with self.assertRaises(FileExistsError):
            prep.prepare(self.connection, self.args, self.bcrypt)
        self.bcrypt.hashpw.assert_not_called()

    def test_v2_schema_is_rejected(self):
        cursor = Mock()
        cursor.fetchall.return_value = [("team_credits", "InnoDB")]
        with self.assertRaisesRegex(ValueError, "V1 전용"):
            prep.check_schema(cursor)


if __name__ == "__main__":
    unittest.main()
