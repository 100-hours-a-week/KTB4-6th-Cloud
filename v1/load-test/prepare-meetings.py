"""준비된 팀을 재사용해 필요한 회의 시나리오의 k6 fixture를 만든다."""

import argparse
import html
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

from load_test_prep import base_url_from, request_auth, request_resource, require_id, save_fixture, token_from_response


def write_html_report(path: Path, result: dict) -> None:
    """완료·실패 fixture의 진행 건수만 HTML로 저장한다. 인증 토큰은 넣지 않는다."""
    preparation = result.get("preparation")
    if not isinstance(preparation, dict) or not isinstance(preparation.get("complete"), bool):
        raise ValueError("회의 준비 fixture의 완료 상태가 올바르지 않습니다")
    teams = preparation.get("teams")
    if not isinstance(teams, list) or not all(isinstance(team, dict) for team in teams):
        raise ValueError("회의 준비 fixture의 팀 정보가 올바르지 않습니다")
    counts = {}
    for scenario in ("create", "join", "sse"):
        rows = result.get(scenario)
        if not isinstance(rows, list):
            raise ValueError(f"회의 준비 fixture의 {scenario} 배열이 올바르지 않습니다")
        counts[scenario] = len(rows)
    join_meetings = sum("joinMeetingId" in team for team in teams)
    sse_meetings = sum("sseMeetingId" in team for team in teams)
    status = "완료" if preparation["complete"] else "미완료"
    failure = preparation.get("failure")
    failure_details = ""
    if isinstance(failure, dict):
        phase = html.escape(str(failure.get("phase", "알 수 없음")))
        team_id = html.escape(str(failure.get("teamId", "알 수 없음")))
        error_type = html.escape(str(failure.get("errorType", "알 수 없음")))
        message = html.escape(str(failure.get("message", "")))
        failure_details = f"<p>중단 지점: {phase}, teamId={team_id}, {error_type}: {message}</p>"
    generated_at = datetime.now(timezone.utc).isoformat()
    # 준비 작업은 순차 실행이므로 이 HTML을 k6 동시 부하 결과로 표시하지 않는다.
    document = f"""<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>회의 테스트 자료 준비 결과</title>
  <style>
    body {{ font-family: system-ui, sans-serif; max-width: 48rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.6; }}
    table {{ border-collapse: collapse; width: 100%; }}
    th, td {{ border: 1px solid #ccc; padding: .55rem; text-align: left; }}
    th {{ background: #f4f4f4; }}
  </style>
</head>
<body>
  <h1>회의 테스트 자료 준비 결과</h1>
  <p>보고서 생성 시각(UTC): {html.escape(generated_at)}</p>
  <p>준비 상태: <strong>{status}</strong></p>
  {failure_details}
  <p>이 보고서는 순차 준비 작업의 결과입니다. k6 동시 부하테스트 결과가 아닙니다.</p>
  <table>
    <tbody>
      <tr><th scope="row">기록된 팀</th><td>{len(teams)}</td></tr>
      <tr><th scope="row">계정·팀 확인 완료</th><td>{html.escape(str(preparation.get('authenticatedTeams', '기록 없음')))}</td></tr>
      <tr><th scope="row">실제 생성한 참여용 회의</th><td>{join_meetings}</td></tr>
      <tr><th scope="row">실제 생성한 SSE용 회의</th><td>{sse_meetings}</td></tr>
      <tr><th scope="row">회의 생성 테스트용 요청 정보</th><td>{counts['create']}</td></tr>
      <tr><th scope="row">회의 참여 테스트용 요청 정보</th><td>{counts['join']}</td></tr>
      <tr><th scope="row">SSE 테스트용 요청 정보</th><td>{counts['sse']}</td></tr>
    </tbody>
  </table>
  <p>가장 이른 토큰 만료(UTC): {html.escape(str(preparation.get('earliestTokenExpiryUtc', '알 수 없음')))}</p>
</body>
</html>
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    # 기존 보고서는 덮어쓰지 않고, 보고서 파일 권한도 fixture와 같이 제한한다.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(document)


def save_failure_report(args: argparse.Namespace, result: dict, phase: str,
                        team_id: int | None, error: BaseException) -> None:
    """원인과 부분 진행 상태를 저장하고 완료 보고서와 다른 이름으로 HTML을 남긴다."""
    preparation = result["preparation"]
    preparation["complete"] = False
    preparation["failure"] = {"phase": phase, "teamId": team_id,
                              "errorType": type(error).__name__, "message": str(error)[:500]}
    save_fixture(args.output, result)
    if args.report_html is None:
        return
    stem = args.report_html.stem
    candidate = args.report_html.with_name(f"{stem}.failed.html")
    attempt = 2
    while candidate.exists() or candidate.is_symlink():
        candidate = args.report_html.with_name(f"{stem}.failed-{attempt}.html")
        attempt += 1
    write_html_report(candidate, result)
    print(f"미완료 준비 작업 HTML 저장: {candidate}")


def find_existing_join_meeting(base_url: str, team_id: int, token: str) -> int | None:
    """응답을 받지 못한 POST가 회의를 만들었는지 읽기 전용 API로 확인한다."""
    listing = request_resource(base_url, f"/api/v1/teams/{team_id}/meetings", token)
    groups = listing.get("groups")
    if not isinstance(groups, list):
        raise RuntimeError(f"팀 {team_id}의 회의 목록 응답이 예상과 다릅니다")
    candidates = []
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("meetings"), list):
            raise RuntimeError(f"팀 {team_id}의 회의 목록 응답이 예상과 다릅니다")
        for meeting in group["meetings"]:
            if (isinstance(meeting, dict) and meeting.get("title") == "부하테스트 회의"
                    and meeting.get("targetDurationMinutes") == 20):
                candidates.append(require_id(meeting, "meetingId"))
    if len(candidates) > 1:
        raise RuntimeError(f"팀 {team_id}에 같은 조건의 회의가 여러 개 있어 자동 재개할 수 없습니다")
    return candidates[0] if candidates else None


def prepare_meetings(args: argparse.Namespace) -> None:
    base_url = base_url_from(args.base_url)
    if args.report_html is not None:
        if args.report_html.resolve() in {args.input.resolve(), args.output.resolve()}:
            raise ValueError("HTML 보고서는 입력·출력 fixture와 다른 경로여야 합니다")
        if args.report_html.exists() or args.report_html.is_symlink():
            raise ValueError("HTML 보고서 파일이 이미 있습니다. 다른 경로를 지정하세요")
    if args.report_only:
        # 이미 끝난 준비 작업은 API를 다시 호출하지 않고 저장된 fixture만 요약한다.
        result = json.loads(args.output.read_text(encoding="utf-8"))
        if (not isinstance(result, dict) or not isinstance(result.get("preparation"), dict)
                or result["preparation"].get("baseUrl") != base_url):
            raise ValueError("회의 fixture와 일치하는 base-url이 필요합니다")
        write_html_report(args.report_html, result)
        print(f"준비 작업 HTML 저장: {args.report_html}")
        return
    if args.input.resolve() == args.output.resolve():
        raise ValueError("입력과 출력은 다른 파일이어야 합니다")
    if not args.resume and (args.output.exists() or args.output.is_symlink()):
        raise ValueError("출력 파일이 이미 있습니다. 다른 경로를 지정하세요")
    if args.resume and (not args.output.is_file() or args.output.is_symlink()):
        raise ValueError("--resume에는 기존 부분 fixture 파일이 필요합니다")
    state = json.loads(args.input.read_text(encoding="utf-8"))
    if (not isinstance(state, dict) or state.get("schemaVersion") != 1
            or state.get("complete") is not True or state.get("baseUrl") != base_url
            or not isinstance(state.get("teams"), list) or not state["teams"]):
        raise ValueError("완료된 팀 준비 파일과 일치하는 base-url이 필요합니다")
    # 모든 계정을 재로그인하고 소속 팀을 확인한 뒤 회의 준비를 시작한다.
    # 첫 번째 준비로부터 시간이 지나 토큰이 만료돼도 새 fixture를 만들 수 있다.
    tokens = {}
    earliest_expiry = None
    authenticated_teams = 0
    team_id = None
    try:
        for team_number, team in enumerate(state["teams"], start=1):
            team_id = require_id(team, "teamId")
            for member in team["members"]:
                status, body = request_auth(base_url, "/api/v1/auth/local/login",
                                            member["loginId"], member["password"])
                token, expires_in = token_from_response(status, body, 200)
                if require_id(body["data"], "userId") != member["userId"]:
                    raise RuntimeError("로그인 계정이 준비된 사용자와 다릅니다")
                my_team = request_resource(base_url, "/api/v1/teams/me", token)
                if my_team.get("hasActiveTeam") is not True or my_team.get("teamId") != team_id:
                    raise RuntimeError(f"계정의 활성 팀이 준비 기록과 다릅니다: teamId={team_id}")
                tokens[member["loginId"]] = token
                expiry = time.time() + expires_in
                earliest_expiry = min(earliest_expiry, expiry) if earliest_expiry else expiry
                time.sleep(args.delay_ms / 1000)
            authenticated_teams = team_number
            # 대량 계정 재로그인은 오래 걸릴 수 있으므로 팀별 진행 상황을 표시한다.
            print(f"계정·팀 확인 {team_number}/{len(state['teams'])}팀 완료", flush=True)
    except (Exception, KeyboardInterrupt) as error:
        if args.resume:
            result = json.loads(args.output.read_text(encoding="utf-8"))
        else:
            result = {"create": [], "join": [], "sse": [], "preparation": {
                "complete": False, "teams": [], "baseUrl": base_url}}
        result["preparation"]["authenticatedTeams"] = authenticated_teams
        save_failure_report(args, result, "계정·팀 확인", team_id, error)
        raise

    selected = ({"create", "join", "sse"} if args.scenarios == "all"
                else {"create", "join"} if args.scenarios == "create-join"
                else {args.scenarios})
    if args.resume:
        result = json.loads(args.output.read_text(encoding="utf-8"))
        preparation = result.get("preparation") if isinstance(result, dict) else None
        if (not isinstance(preparation, dict) or preparation.get("complete") is not False
                or preparation.get("baseUrl") != base_url
                or not isinstance(preparation.get("teams"), list)
                or len(preparation["teams"]) > len(state["teams"])):
            raise ValueError("입력 팀과 일치하는 미완료 fixture만 재개할 수 있습니다")
        for index, prepared in enumerate(preparation["teams"]):
            if require_id(prepared, "teamId") != require_id(state["teams"][index], "teamId"):
                raise ValueError("부분 fixture의 팀 순서가 입력 팀과 다릅니다")
        if any(not isinstance(result.get(key), list) for key in ("create", "join", "sse")):
            raise ValueError("부분 fixture의 시나리오 배열이 올바르지 않습니다")
        previous_team_count = len(preparation["teams"])
        # 저장된 회의 ID는 유지하고 만료 가능성이 있는 토큰·요청 행만 다시 만든다.
        result["create"], result["join"], result["sse"] = [], [], []
        preparation["earliestTokenExpiryUtc"] = datetime.fromtimestamp(earliest_expiry, timezone.utc).isoformat()
        preparation.pop("failure", None)
    else:
        result = {"create": [], "join": [], "sse": [], "preparation": {
            "complete": False, "teams": [], "baseUrl": base_url,
            "earliestTokenExpiryUtc": datetime.fromtimestamp(earliest_expiry, timezone.utc).isoformat(),
        }}
        previous_team_count = 0
    result["preparation"]["authenticatedTeams"] = authenticated_teams
    save_fixture(args.output, result)
    meeting_body = {"title": "부하테스트 회의", "purpose": "테스트 전용",
                    "note": "", "targetDurationMinutes": 20}
    team_id = None
    try:
        for team_number, team in enumerate(state["teams"], start=1):
            team_id = team["teamId"]
            owner_token = tokens[team["members"][0]["loginId"]]
            if team_number <= previous_team_count:
                prepared = result["preparation"]["teams"][team_number - 1]
            else:
                prepared = {"teamId": team_id}
                result["preparation"]["teams"].append(prepared)
                save_fixture(args.output, result)
            if "create" in selected:
                # 실제 회의 생성은 k6 실행 때 일어난다. 이 단계는 요청 정보만 만든다.
                result["create"].append({"accessToken": owner_token, "teamId": team_id,
                    "method": "POST", "path": f"/api/v1/teams/{team_id}/meetings",
                    "body": meeting_body, "expectedStatus": 201,
                    "requiredJsonField": "data.meetingId"})
                save_fixture(args.output, result)
            for scenario in ("join", "sse"):
                if scenario not in selected:
                    continue
                meeting_id = prepared.get(f"{scenario}MeetingId")
                if meeting_id is not None:
                    meeting_id = require_id(prepared, f"{scenario}MeetingId")
                else:
                    # 기존 부분 기록에 ID가 없으면 타임아웃된 POST의 성공 여부를 먼저 조회한다.
                    if args.resume and team_number <= previous_team_count:
                        meeting_id = find_existing_join_meeting(base_url, team_id, owner_token)
                    if meeting_id is None:
                        meeting = request_resource(base_url, f"/api/v1/teams/{team_id}/meetings",
                                                   owner_token, meeting_body)
                        meeting_id = require_id(meeting, "meetingId")
                    prepared[f"{scenario}MeetingId"] = meeting_id
                    save_fixture(args.output, result)
                for member in team["members"]:
                    token = tokens[member["loginId"]]
                    row = {"accessToken": token, "teamId": team_id, "meetingId": meeting_id}
                    if scenario == "join":
                        row.update({"method": "POST", "path": f"/api/v1/meetings/{meeting_id}/participants",
                                    "expectedStatus": 201, "requiredJsonField": "data.participantId"})
                    else:
                        # SSE는 회의 참여가 선행돼야 하므로 이 회의에만 실제로 입장시킨다.
                        participant = request_resource(base_url, f"/api/v1/meetings/{meeting_id}/participants", token, {})
                        row["participantId"] = require_id(participant, "participantId")
                    result[scenario].append(row)
                    save_fixture(args.output, result)
                    time.sleep(args.delay_ms / 1000)
            print(f"회의 준비 {team_number}/{len(state['teams'])}팀 완료", flush=True)
        result["preparation"]["complete"] = True
        save_fixture(args.output, result)
    except (Exception, KeyboardInterrupt) as error:
        save_failure_report(args, result, "회의 준비", team_id, error)
        print(f"회의 준비 실패: {args.output}의 preparation에서 생성된 회의 ID를 확인하세요")
        raise
    if args.report_html is not None:
        write_html_report(args.report_html, result)
    print(f"fixture 준비 완료: create {len(result['create'])}건, "
          f"join {len(result['join'])}건, SSE {len(result['sse'])}건")
    print(f"가장 이른 토큰 만료(UTC): {result['preparation']['earliestTokenExpiryUtc']}")


def main() -> None:
    parser = argparse.ArgumentParser(description="준비된 팀의 회의 생성·입장·SSE fixture 준비")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--input", type=Path, required=True, help="prepare-teams.py의 완료 파일")
    parser.add_argument("--output", type=Path, required=True, help="k6가 읽을 fixture")
    parser.add_argument("--scenarios", choices=("create", "join", "create-join", "sse", "all"),
                        default="create", help="준비할 시나리오 (기본값: create)")
    parser.add_argument("--delay-ms", type=int, default=100)
    parser.add_argument("--report-html", type=Path, help="순차 준비 결과를 저장할 HTML 경로")
    parser.add_argument("--report-only", action="store_true", help="기존 완료·미완료 fixture로 HTML만 생성하고 API를 호출하지 않음")
    parser.add_argument("--resume", action="store_true", help="중단된 create-join fixture를 기존 회의 ID부터 재개")
    args = parser.parse_args()
    if args.delay_ms < 0:
        parser.error("delay-ms는 0 이상이어야 합니다")
    if args.report_only and args.report_html is None:
        parser.error("--report-only에는 --report-html이 필요합니다")
    if args.resume and (args.report_only or args.scenarios != "create-join"):
        parser.error("--resume은 create-join 시나리오에서만 단독으로 사용할 수 있습니다")
    try:
        prepare_meetings(args)
    except (ValueError, RuntimeError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    except KeyboardInterrupt:
        parser.exit(130, "사용자가 회의 준비를 중단했습니다. 부분 fixture와 실패 HTML을 확인하세요\n")


if __name__ == "__main__":
    main()
