"""준비된 팀을 재사용해 필요한 회의 시나리오의 k6 fixture를 만든다."""

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path

from load_test_prep import base_url_from, request_auth, request_resource, require_id, save_fixture, token_from_response


def prepare_meetings(args: argparse.Namespace) -> None:
    base_url = base_url_from(args.base_url)
    if args.input.resolve() == args.output.resolve():
        raise ValueError("입력과 출력은 다른 파일이어야 합니다")
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("출력 파일이 이미 있습니다. 다른 경로를 지정하세요")
    state = json.loads(args.input.read_text(encoding="utf-8"))
    if (not isinstance(state, dict) or state.get("schemaVersion") != 1
            or state.get("complete") is not True or state.get("baseUrl") != base_url
            or not isinstance(state.get("teams"), list) or not state["teams"]):
        raise ValueError("완료된 팀 준비 파일과 일치하는 base-url이 필요합니다")
    # 모든 계정을 재로그인하고 소속 팀을 확인한 뒤 회의 준비를 시작한다.
    # 첫 번째 준비로부터 시간이 지나 토큰이 만료돼도 새 fixture를 만들 수 있다.
    tokens = {}
    earliest_expiry = None
    for team in state["teams"]:
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

    selected = ({"create", "join", "sse"} if args.scenarios == "all"
                else {"create", "join"} if args.scenarios == "create-join"
                else {args.scenarios})
    result = {"create": [], "join": [], "sse": [], "preparation": {
        "complete": False, "teams": [], "baseUrl": base_url,
        "earliestTokenExpiryUtc": datetime.fromtimestamp(earliest_expiry, timezone.utc).isoformat(),
    }}
    save_fixture(args.output, result)
    meeting_body = {"title": "부하테스트 회의", "purpose": "테스트 전용",
                    "note": "", "targetDurationMinutes": 20}
    try:
        for team in state["teams"]:
            team_id = team["teamId"]
            owner_token = tokens[team["members"][0]["loginId"]]
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
        result["preparation"]["complete"] = True
        save_fixture(args.output, result)
    except Exception:
        print(f"회의 준비 실패: {args.output}의 preparation에서 생성된 회의 ID를 확인하세요")
        raise
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
    args = parser.parse_args()
    if args.delay_ms < 0:
        parser.error("delay-ms는 0 이상이어야 합니다")
    try:
        prepare_meetings(args)
    except (ValueError, RuntimeError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
