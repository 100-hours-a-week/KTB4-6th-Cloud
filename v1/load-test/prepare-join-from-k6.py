"""k6 회의 생성 로그의 ID로 회의 참여 시험 fixture를 만든다."""

import argparse
import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path

from load_test_prep import base_url_from, request_auth, request_resource, require_id, save_fixture, token_from_response


MEETING_LOG_PATTERN = re.compile(r"MEETY_CREATED_MEETING teamId=([1-9]\d*) meetingId=([1-9]\d*)")


def with_retry(call, *args):
    """읽기 전용 조회와 로그인만 일시적인 통신 오류(URLError 등)일 때 재시도한다. 참여 요청은 여기서 보내지 않는다."""
    for attempt in range(1, 4):
        try:
            return call(*args)
        except RuntimeError as error:
            if "통신" not in str(error) and "연결" not in str(error) or attempt == 3:
                raise
            time.sleep(2 * attempt)


def meeting_ids_from_log(path: Path, expected_team_ids: set[int]) -> dict[int, int]:
    """k6 성공 로그가 모든 팀에 정확히 하나씩 있는지 확인한다."""
    meeting_ids = {}
    used_meeting_ids = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = MEETING_LOG_PATTERN.search(line)
        if match is None:
            continue
        team_id, meeting_id = map(int, match.groups())
        if team_id not in expected_team_ids or team_id in meeting_ids or meeting_id in used_meeting_ids:
            raise ValueError("k6 회의 ID 로그에 예상하지 못한 팀 또는 중복 ID가 있습니다")
        meeting_ids[team_id] = meeting_id
        used_meeting_ids.add(meeting_id)
    if set(meeting_ids) != expected_team_ids:
        raise ValueError(f"k6 회의 생성 성공 로그가 부족합니다: {len(meeting_ids)}/{len(expected_team_ids)}팀")
    return meeting_ids


def prepare_join(args: argparse.Namespace) -> None:
    base_url = base_url_from(args.base_url)
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("출력 파일이 이미 있습니다. 다른 경로를 지정하세요")
    if args.output.resolve() in {args.input.resolve(), args.meeting_log.resolve()}:
        raise ValueError("출력 파일은 입력 파일과 다른 경로여야 합니다")
    state = json.loads(args.input.read_text(encoding="utf-8"))
    if (not isinstance(state, dict) or state.get("schemaVersion") != 1
            or state.get("complete") is not True or state.get("baseUrl") != base_url
            or not isinstance(state.get("teams"), list) or not state["teams"]):
        raise ValueError("완료된 팀 준비 파일과 일치하는 base-url이 필요합니다")
    team_ids = [require_id(team, "teamId") for team in state["teams"]]
    if len(set(team_ids)) != len(team_ids):
        raise ValueError("팀 준비 파일에 중복 teamId가 있습니다")
    meeting_ids = meeting_ids_from_log(args.meeting_log, set(team_ids))

    result = {"join": [], "preparation": {
        "complete": False, "baseUrl": base_url, "teams": [],
    }}
    save_fixture(args.output, result)
    earliest_expiry = None
    try:
        for team_number, team in enumerate(state["teams"], start=1):
            team_id = team["teamId"]
            meeting_id = meeting_ids[team_id]
            members = []
            for member in team["members"]:
                status, body = with_retry(request_auth, base_url, "/api/v1/auth/local/login",
                                                member["loginId"], member["password"])
                token, expires_in = token_from_response(status, body, 200)
                if require_id(body["data"], "userId") != member["userId"]:
                    raise RuntimeError(f"팀 {team_id}의 로그인 계정이 준비된 사용자와 다릅니다")
                my_team = with_retry(request_resource, base_url, "/api/v1/teams/me", token)
                if my_team.get("hasActiveTeam") is not True or my_team.get("teamId") != team_id:
                    raise RuntimeError(f"계정의 활성 팀이 준비 기록과 다릅니다: teamId={team_id}")
                members.append(token)
                expiry = time.time() + expires_in
                earliest_expiry = min(earliest_expiry, expiry) if earliest_expiry else expiry
                time.sleep(args.delay_ms / 1000)
            # 로그의 회의 ID가 실제 해당 팀의 회의인지 읽기 전용 목록 API로 확인한다.
            listing = with_retry(request_resource, base_url, f"/api/v1/teams/{team_id}/meetings", members[0])
            groups = listing.get("groups")
            if not isinstance(groups, list):
                raise RuntimeError(f"팀 {team_id}의 회의 목록 응답이 예상과 다릅니다")
            listed_ids = {meeting.get("meetingId") for group in groups if isinstance(group, dict)
                          and isinstance(group.get("meetings"), list)
                          for meeting in group["meetings"] if isinstance(meeting, dict)}
            if meeting_id not in listed_ids:
                raise RuntimeError(f"k6 로그의 회의 ID가 팀 {team_id}의 회의 목록에 없습니다")
            result["preparation"]["teams"].append({"teamId": team_id, "joinMeetingId": meeting_id})
            for token in members:
                result["join"].append({
                    "accessToken": token, "teamId": team_id, "meetingId": meeting_id,
                    "method": "POST", "path": f"/api/v1/meetings/{meeting_id}/participants",
                    "expectedStatus": 201, "requiredJsonField": "data.participantId",
                })
            save_fixture(args.output, result)
            print(f"회의 참여 fixture {team_number}/{len(state['teams'])}팀 완료", flush=True)
        result["preparation"]["earliestTokenExpiryUtc"] = datetime.fromtimestamp(
            earliest_expiry, timezone.utc).isoformat()
        result["preparation"]["complete"] = True
        save_fixture(args.output, result)
    except Exception:
        print(f"참여 fixture 준비 실패: {args.output}은 미완료 상태입니다. API를 다시 호출하지 않고 원인을 확인하세요")
        raise
    print(f"회의 참여 fixture {len(result['join'])}건 준비 완료")
    print(f"가장 이른 토큰 만료(UTC): {result['preparation']['earliestTokenExpiryUtc']}")


def main() -> None:
    parser = argparse.ArgumentParser(description="k6 회의 생성 결과로 참여 fixture 준비")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--input", type=Path, required=True, help="완료된 prepare-teams.py 출력")
    parser.add_argument("--meeting-log", type=Path, required=True, help="k6 --console-output 파일")
    parser.add_argument("--output", type=Path, required=True, help="k6 참여 fixture 파일")
    parser.add_argument("--delay-ms", type=int, default=100)
    args = parser.parse_args()
    if args.delay_ms < 0:
        parser.error("delay-ms는 0 이상이어야 합니다")
    try:
        prepare_join(args)
    except (ValueError, RuntimeError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
