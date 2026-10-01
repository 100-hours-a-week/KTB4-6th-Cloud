"""로컬 인증과 선택적 팀·회의 준비로 k6가 읽을 fixture를 만든다.

이 준비 작업은 k6의 측정 구간 밖에서 실행한다. 입력에는 계정 비밀번호가 있고,
출력에는 access token이 있으므로 두 파일 모두 공유하거나 커밋하지 않는다.
"""

import argparse
import json
import os
import re
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


def base_url_from(value: str) -> str:
    # 비밀번호가 실린 요청을 원격 HTTP나 예상하지 못한 경로로 보내지 않는다.
    base_url = value.rstrip("/")
    parsed = urlparse(base_url)
    if (not parsed.hostname or parsed.path or parsed.query or parsed.fragment
            or parsed.username or parsed.password
            or (parsed.scheme != "https" and not (
                parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1"}
            ))):
        raise ValueError("base-url은 HTTPS 호스트(또는 로컬 HTTP 호스트)만 지정해야 합니다")
    return base_url


def request_auth(base_url: str, path: str, login_id: str, password: str) -> tuple[int, dict]:
    # 로컬 인증 API에 JSON으로 계정을 보내고 (HTTP 상태, 응답 JSON)을 돌려준다.
    # BFF를 거치지 않고 BE 응답 Body에서 Meety access token을 읽는다.
    body = json.dumps({"loginId": login_id, "password": password}).encode("utf-8")
    request = Request(
        f"{base_url}{path}",
        data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with build_opener(NoRedirect()).open(request, timeout=15) as response:
            return response.status, json.load(response)
    except HTTPError as error:
        # urllib는 4xx/5xx를 예외로 던진다. 401은 선택적 회원가입의 판단 근거라
        # 일반 응답처럼 상태와 본문을 반환하고, 네트워크 실패만 별도로 중단한다.
        try:
            return error.code, json.load(error)
        except (ValueError, OSError):
            return error.code, {}
    except URLError as error:
        raise RuntimeError(f"인증 API에 연결할 수 없습니다: {error.reason}") from error


def token_from_response(status: int, body: dict, expected_status: int) -> tuple[str, int]:
    # 로그인(200)과 가입(201)은 모두 data.accessToken과 만료 초를 반환해야 한다.
    # HTTP 상태만 맞고 토큰이 빠진 응답을 정상 fixture로 저장하지 않는다.
    data = body.get("data") if isinstance(body, dict) else None
    if status != expected_status or not isinstance(data, dict):
        raise RuntimeError(f"인증 응답이 예상과 다릅니다: HTTP {status}")
    token = data.get("accessToken")
    expires_in = data.get("accessTokenExpiresIn")
    if (not isinstance(token, str) or not token or not isinstance(expires_in, int)
            or isinstance(expires_in, bool) or expires_in <= 0):
        raise RuntimeError("인증 응답에 accessToken 또는 accessTokenExpiresIn이 없습니다")
    return token, expires_in


def has_placeholder(value: object) -> bool:
    # 예시값이 남은 입력으로 실제 서버에 계정을 생성하지 않도록 사전에 검사한다.
    if isinstance(value, str):
        return "REPLACE_" in value
    if isinstance(value, dict):
        return any(has_placeholder(item) for item in value.values())
    if isinstance(value, list):
        return any(has_placeholder(item) for item in value)
    return False



class NoRedirect(HTTPRedirectHandler):
    # 인증 쿠키나 비밀번호가 다른 주소로 전달되지 않게 준비 API의 리다이렉트를 거부한다.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_resource(base_url: str, path: str, token: str, body: dict | None = None) -> dict:
    # 허용한 BE 준비 API만 호출한다. 녹음 시작·AI·S3 요청은 이 준비 과정에 포함하지 않는다.
    request = Request(
        f"{base_url}{path}",
        data=json.dumps(body).encode("utf-8") if body is not None else None,
        headers={"Cookie": f"accessToken={token}", "Content-Type": "application/json"},
        method="POST" if body is not None else "GET",
    )
    expected_status = 201 if body is not None else 200
    try:
        with build_opener(NoRedirect()).open(request, timeout=15) as response:
            payload = json.load(response)
            if (response.status != expected_status or not isinstance(payload, dict)
                    or payload.get("success") is not True
                    or not isinstance(payload.get("data"), dict)):
                raise RuntimeError(f"준비 API의 응답이 예상과 다릅니다: {path}")
            return payload["data"]
    except HTTPError as error:
        # 응답 본문에는 인증값이나 개인정보가 있을 수 있어 경로와 상태만 보고한다.
        raise RuntimeError(f"준비 API 실패: {path}, HTTP {error.code}") from None
    except (URLError, TimeoutError, ValueError) as error:
        # POST의 성공 여부가 불명확할 수 있으므로 자동 재시도로 중복 자원을 만들지 않는다.
        raise RuntimeError(f"준비 API 통신·응답 오류: {path}, {type(error).__name__}") from None


def save_fixture(path: Path, result: dict) -> None:
    # 중간 실패 때도 생성 자원 ID를 남기고, 토큰이 들어 있는 파일은 0600으로 원자적 저장한다.
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent,
            prefix=f".{path.name}.", suffix=".tmp", delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(result, temporary, ensure_ascii=False, indent=2)
            temporary.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def require_id(data: dict, field: str) -> int:
    # ID 없는 성공 응답으로 다음 준비 요청을 보내지 않는다.
    value = data.get(field)
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise RuntimeError(f"준비 응답에 유효한 {field}가 없습니다")
    return value


def prepare_resources(source: dict, args, base_url: str) -> None:
    """로컬 계정·팀·회의를 준비하고 create/join/sse용 fixture를 생성한다.

    입력 형식: {"teams": [{"name": "부하팀01", "members": [
        {"loginId": "load01", "password": "...", "displayName": "참여자01"}
    ]}]}. 첫 번째 계정이 팀 생성자다. 회의 입장 시험용 회의와 SSE용 회의를 따로 만든다.
    """
    teams = source.get("teams")
    if set(source) != {"teams"} or not isinstance(teams, list) or not 1 <= len(teams) <= 20:
        raise ValueError("--prepare-resources 입력에는 1~20개 팀의 teams 배열만 있어야 합니다")
    if args.output.exists():
        raise ValueError("준비 결과를 덮어쓰지 않습니다. 기존 팀을 확인하고 새 출력 경로를 지정하세요")
    name_pattern = re.compile(r"[가-힣a-zA-Z0-9]{2,10}")
    login_ids = set()
    # 전체 계정 배정을 먼저 검사해 잘못된 입력 때문에 일부 팀만 생성되는 일을 줄인다.
    for team in teams:
        if not isinstance(team, dict) or set(team) != {"name", "members"}:
            raise ValueError("팀에는 name과 members만 지정해야 합니다")
        if not isinstance(team["name"], str) or not name_pattern.fullmatch(team["name"]):
            raise ValueError("팀 이름은 한글·영문·숫자 2~10자여야 합니다")
        members = team["members"]
        if not isinstance(members, list) or not 1 <= len(members) <= 10:
            raise ValueError("팀별 members는 생성자를 포함해 1~10명이어야 합니다")
        display_names = set()
        for member in members:
            if not isinstance(member, dict) or set(member) != {"loginId", "password", "displayName"}:
                raise ValueError("계정에는 loginId, password, displayName만 지정해야 합니다")
            if any(not isinstance(value, str) or not value.strip() for value in member.values()):
                raise ValueError("계정의 모든 필드는 비어 있지 않은 문자열이어야 합니다")
            if not name_pattern.fullmatch(member["displayName"]):
                raise ValueError("표시 이름은 한글·영문·숫자 2~10자여야 합니다")
            if member["loginId"] in login_ids or member["displayName"] in display_names:
                raise ValueError("계정은 팀 간 중복할 수 없고 표시 이름은 팀 안에서 중복할 수 없습니다")
            login_ids.add(member["loginId"])
            display_names.add(member["displayName"])

    issued = {}
    issued_user_ids = set()
    earliest_expiry = None
    # 먼저 모든 계정을 인증하고 소속 팀이 없는지 확인한다. 기존 팀의 탈퇴·삭제는 하지 않는다.
    for team in teams:
        for member in team["members"]:
            status, body = request_auth(base_url, "/api/v1/auth/local/login", member["loginId"], member["password"])
            if status == 401 and args.signup_missing:
                status, body = request_auth(base_url, "/api/v1/auth/local/signup", member["loginId"], member["password"])
                token, expires_in = token_from_response(status, body, 201)
            else:
                token, expires_in = token_from_response(status, body, 200)
            # 로그인 ID의 대소문자 등이 달라도 실제 사용자가 같으면 중복 배정을 거부한다.
            user_id = require_id(body["data"], "userId")
            if user_id in issued_user_ids:
                raise RuntimeError("서로 다른 입력 계정이 같은 사용자로 인증됐습니다")
            issued_user_ids.add(user_id)
            issued[member["loginId"]] = token
            expiry = time.time() + expires_in
            earliest_expiry = min(earliest_expiry, expiry) if earliest_expiry else expiry
            my_team = request_resource(base_url, "/api/v1/teams/me", token)
            if my_team.get("hasActiveTeam") is not False:
                raise RuntimeError("입력 계정에 활성 팀이 있습니다. 새 테스트 전용 계정으로 준비하세요")
            time.sleep(args.delay_ms / 1000)

    result = {"create": [], "join": [], "sse": [], "preparation": {
        "complete": False, "teams": [], "baseUrl": base_url,
        "earliestTokenExpiryUtc": datetime.fromtimestamp(earliest_expiry, timezone.utc).isoformat(),
    }}
    save_fixture(args.output, result)
    try:
        for team in teams:
            owner = team["members"][0]
            owner_token = issued[owner["loginId"]]
            created = request_resource(base_url, "/api/v1/teams", owner_token, {
                "name": team["name"], "displayName": owner["displayName"],
            })
            team_id = require_id(created, "teamId")
            # ID는 응답을 받은 즉시 저장한다. 후속 준비가 실패해도 생성 팀을 추적할 수 있다.
            prepared = {"teamId": team_id}
            result["preparation"]["teams"].append(prepared)
            save_fixture(args.output, result)
            invitation_code = created.get("invitationCode")
            if not isinstance(invitation_code, str) or not re.fullmatch(r"[A-Za-z0-9]{8}", invitation_code):
                raise RuntimeError("팀 생성 응답에 유효한 invitationCode가 없습니다")
            for member in team["members"][1:]:
                joined = request_resource(base_url, "/api/v1/team-memberships", issued[member["loginId"]], {
                    "invitationCode": invitation_code, "displayName": member["displayName"],
                })
                if require_id(joined, "teamId") != team_id or joined.get("hasActiveTeam") is not True:
                    raise RuntimeError("팀 참가 응답이 준비한 팀과 다릅니다")
                time.sleep(args.delay_ms / 1000)
            meeting_body = {"title": "부하테스트 회의", "purpose": "테스트 전용", "note": "", "targetDurationMinutes": 20}
            result["create"].append({"accessToken": owner_token, "teamId": team_id,
                "method": "POST", "path": f"/api/v1/teams/{team_id}/meetings", "body": meeting_body,
                "expectedStatus": 201, "requiredJsonField": "data.meetingId"})
            # 입장 측정용 회의에는 준비 단계에서 아무도 입장시키지 않는다.
            for scenario in ("join", "sse"):
                meeting = request_resource(base_url, f"/api/v1/teams/{team_id}/meetings", owner_token, meeting_body)
                meeting_id = require_id(meeting, "meetingId")
                prepared[f"{scenario}MeetingId"] = meeting_id
                save_fixture(args.output, result)
                for member in team["members"]:
                    token = issued[member["loginId"]]
                    row = {"accessToken": token, "teamId": team_id, "meetingId": meeting_id}
                    if scenario == "join":
                        row.update({"method": "POST", "path": f"/api/v1/meetings/{meeting_id}/participants",
                            "expectedStatus": 201, "requiredJsonField": "data.participantId"})
                    else:
                        # SSE에는 팀 소속 외에 JOINED 상태의 회의 참여자가 필요하다.
                        participant = request_resource(base_url, f"/api/v1/meetings/{meeting_id}/participants", token, {})
                        row["participantId"] = require_id(participant, "participantId")
                    result[scenario].append(row)
                    save_fixture(args.output, result)
                    time.sleep(args.delay_ms / 1000)
            print(f"팀 {team_id} 준비 완료: 입장 측정용 회의와 SSE용 회의를 분리했습니다")
        result["preparation"]["complete"] = True
        save_fixture(args.output, result)
    except Exception:
        # 실패한 출력으로 부하를 실행하지 않도록 complete=false를 유지한다. 자동 삭제도 하지 않는다.
        print(f"준비 실패: {args.output}의 preparation에 남은 자원 ID를 확인하세요")
        raise
    print(f"create {len(result['create'])}건, join {len(result['join'])}건, SSE {len(result['sse'])}건 준비")
    print(f"가장 이른 토큰 만료(UTC): {result['preparation']['earliestTokenExpiryUtc']}")


def main() -> None:
    # 보통 입력은 계정 정보가 있는 fixtures.credentials.local.json,
    # 출력은 k6가 읽는 fixtures.local.json으로 지정한다. 두 경로는 필수 인자다.
    parser = argparse.ArgumentParser(description="Meety 로컬 계정으로 k6 인증 fixture 준비")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--signup-missing", action="store_true", help="로그인 401 계정을 실제 서버에 생성")
    parser.add_argument("--prepare-resources", action="store_true",
                        help="teams 입력으로 팀 생성·팀 참가·회의 생성·SSE용 입장을 사전 준비")
    parser.add_argument("--delay-ms", type=int, default=100)
    args = parser.parse_args()

    # 비밀번호를 전송하므로 원격 HTTP 주소는 허용하지 않는다.
    base_url = args.base_url.rstrip("/")
    parsed_url = urlparse(base_url)
    if not parsed_url.hostname:
        parser.error("base-url에 호스트가 필요합니다")
    if parsed_url.scheme != "https" and not (
        parsed_url.scheme == "http" and parsed_url.hostname in {"localhost", "127.0.0.1"}
    ):
        parser.error("원격 서버에는 HTTPS URL만 사용할 수 있습니다")
    if parsed_url.path or parsed_url.query or parsed_url.fragment or parsed_url.username:
        parser.error("base-url에는 호스트와 포트만 넣어야 합니다")
    if args.delay_ms < 0:
        parser.error("delay-ms는 0 이상이어야 합니다")
    if args.input.resolve() == args.output.resolve():
        parser.error("입력과 출력 파일은 달라야 합니다")

    # 예시값이 남아 있으면 서버에 요청하기 전에 중단한다.
    source = json.loads(args.input.read_text(encoding="utf-8"))
    if not isinstance(source, dict):
        parser.error("fixture 최상위 값은 시나리오별 배열을 가진 JSON 객체여야 합니다")
    if has_placeholder(source):
        parser.error("입력 fixture에 REPLACE_ 예시값이 남아 있습니다")

    if args.prepare_resources:
        try:
            prepare_resources(source, args, base_url)
        except (ValueError, RuntimeError) as error:
            parser.exit(1, f"{error}\n")
        return

    # 입력 JSON은 create/join/ws/sse 등 시나리오별 배열이다.
    # 같은 loginId가 여러 배열에 등장해도 한 번만 인증하고 토큰을 재사용한다.
    issued: dict[str, tuple[str, str, int]] = {}
    result: dict[str, list[dict]] = {}
    earliest_expiry = None
    for scenario, rows in source.items():
        if not isinstance(rows, list):
            parser.error(f"{scenario} 값은 배열이어야 합니다")
        result[scenario] = []
        for index, row in enumerate(rows, start=1):
            if not isinstance(row, dict):
                parser.error(f"{scenario}의 {index}번 항목은 객체여야 합니다")
            login_id, password = row.get("loginId"), row.get("password")
            if not isinstance(login_id, str) or not login_id or not isinstance(password, str) or not password:
                parser.error(f"{scenario}의 {index}번 항목에 loginId와 password가 필요합니다")
            if login_id.startswith("REPLACE_") or password.startswith("REPLACE_"):
                parser.error(f"{scenario}의 {index}번 항목에 예시 계정값이 남아 있습니다")
            if login_id in issued and issued[login_id][0] != password:
                parser.error(f"같은 loginId에 다른 비밀번호가 지정됐습니다: {scenario} {index}번")
            if login_id not in issued:
                # 기본 동작은 로그인만 한다. 401 뒤 회원가입은 명시적 옵션이 있을 때만 한다.
                status, body = request_auth(base_url, "/api/v1/auth/local/login", login_id, password)
                if status == 401 and args.signup_missing:
                    status, body = request_auth(base_url, "/api/v1/auth/local/signup", login_id, password)
                    token, expires_in = token_from_response(status, body, 201)
                else:
                    token, expires_in = token_from_response(status, body, 200)
                issued[login_id] = (password, token, time.time() + expires_in)
                if args.delay_ms:
                    # 인증 준비 요청이 한꺼번에 몰려 측정 대상의 부하로 섞이지 않게 한다.
                    time.sleep(args.delay_ms / 1000)

            _, token, expires_at = issued[login_id]
            earliest_expiry = min(earliest_expiry, expires_at) if earliest_expiry else expires_at
            # 시나리오의 팀·회의·세션 정보는 보존하되 비밀번호와 기존 토큰은 제거한다.
            # 그 자리에 방금 발급받은 access token을 넣어 k6가 바로 사용할 수 있게 한다.
            result[scenario].append({
                **{key: value for key, value in row.items() if key not in {"loginId", "password", "accessToken"}},
                "accessToken": token,
            })

    save_fixture(args.output, result)

    # 가장 먼저 만료되는 토큰을 알려 시험 시작 전에 갱신 필요 여부를 판단하게 한다.
    expires_at_text = datetime.fromtimestamp(earliest_expiry, timezone.utc).isoformat() if earliest_expiry else "없음"
    print(f"인증 fixture {sum(map(len, result.values()))}건 저장. 가장 이른 토큰 만료(UTC): {expires_at_text}")


if __name__ == "__main__":
    # import할 때는 실행하지 않고 CLI에서 직접 호출했을 때만 인증 요청을 보낸다.
    main()
