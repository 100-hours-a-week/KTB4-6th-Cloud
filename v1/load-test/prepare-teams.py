"""옵션으로 지정한 수만큼 로컬 계정과 팀 멤버를 준비한다."""

import argparse
import re
import secrets
import time
from pathlib import Path

from load_test_prep import base_url_from, request_auth, request_resource, require_id, save_fixture, token_from_response


def prepare_teams(args: argparse.Namespace) -> None:
    base_url = base_url_from(args.base_url)
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("출력 파일이 이미 있습니다. 다른 경로를 지정하세요")
    # 실행마다 새 ID를 사용하므로 이미 팀에 소속된 계정을 재사용하지 않는다.
    run_id = secrets.token_hex(3)
    state = {"schemaVersion": 1, "baseUrl": base_url, "runId": run_id,
             "complete": False, "teams": []}
    save_fixture(args.output, state)
    try:
        for team_number in range(1, args.teams + 1):
            # 팀 이름은 서버 제한(10자)에 맞추고 100번 팀도 세 자리로 구분한다.
            team_name = f"LT{run_id[:5]}{team_number:03d}"
            team = {"name": team_name, "members": []}
            state["teams"].append(team)
            save_fixture(args.output, state)
            tokens = []
            for member_number in range(1, args.members_per_team + 1):
                login_id = f"lt{run_id}t{team_number:02d}u{member_number:02d}"
                password = secrets.token_urlsafe(24)
                display_name = f"참여자{member_number:02d}"
                # 계정 생성 응답을 받으면 즉시 기록한다. 후속 실패 때 생성 계정을 추적할 수 있다.
                status, body = request_auth(base_url, "/api/v1/auth/local/signup", login_id, password)
                token, _ = token_from_response(status, body, 201)
                user_id = require_id(body["data"], "userId")
                team["members"].append({"loginId": login_id, "password": password,
                                        "displayName": display_name, "userId": user_id})
                tokens.append(token)
                save_fixture(args.output, state)
                time.sleep(args.delay_ms / 1000)

            created = request_resource(base_url, "/api/v1/teams", tokens[0], {
                "name": team_name, "displayName": team["members"][0]["displayName"],
            })
            team_id = require_id(created, "teamId")
            team["teamId"] = team_id
            save_fixture(args.output, state)
            invitation_code = created.get("invitationCode")
            if not isinstance(invitation_code, str) or not re.fullmatch(r"[A-Za-z0-9]{8}", invitation_code):
                raise RuntimeError("팀 생성 응답에 유효한 invitationCode가 없습니다")
            for member, token in zip(team["members"][1:], tokens[1:]):
                joined = request_resource(base_url, "/api/v1/team-memberships", token, {
                    "invitationCode": invitation_code, "displayName": member["displayName"],
                })
                if require_id(joined, "teamId") != team_id or joined.get("hasActiveTeam") is not True:
                    raise RuntimeError("팀 참가 응답이 준비한 팀과 다릅니다")
                member["teamJoined"] = True
                save_fixture(args.output, state)
                time.sleep(args.delay_ms / 1000)
            print(f"팀 {team_number}/{args.teams} 준비 완료 (teamId={team_id}, 멤버 {len(team['members'])}명)")
        state["complete"] = True
        save_fixture(args.output, state)
    except Exception:
        print(f"준비 실패: {args.output}에서 생성된 계정·팀 ID를 확인하세요. 자동 재시도하지 않습니다")
        raise
    print(f"팀 {len(state['teams'])}개, 계정 {sum(len(t['members']) for t in state['teams'])}개 준비 완료")


def main() -> None:
    parser = argparse.ArgumentParser(description="부하테스트용 로컬 계정·팀·멤버 준비")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--teams", type=int, required=True, help="생성할 팀 수 (1~100)")
    parser.add_argument("--members-per-team", type=int, required=True, help="팀당 인원 (1~10, 팀장 포함)")
    parser.add_argument("--output", type=Path, required=True, help="비밀번호가 저장될 팀 준비 파일")
    parser.add_argument("--delay-ms", type=int, default=100)
    args = parser.parse_args()
    if not 1 <= args.teams <= 100 or not 1 <= args.members_per_team <= 10 or args.delay_ms < 0:
        parser.error("teams는 1~100, members-per-team은 1~10, delay-ms는 0 이상이어야 합니다")
    try:
        prepare_teams(args)
    except (ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
