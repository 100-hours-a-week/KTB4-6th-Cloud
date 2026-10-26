#!/usr/bin/env python3
"""점검 응답 규칙을 미리보기 전용과 전체 적용 사이에서 전환한다."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1] / "terraform" / "maintenance"
RULES = {"aws_lb_listener_rule.preview_fe", "aws_lb_listener_rule.preview_api"}


def terraform(*args, root=ROOT, capture=False):
    # 각 state를 명시하고 셸을 거치지 않아 다른 디렉터리의 적용을 방지한다.
    return subprocess.run(["terraform", "-chdir=" + str(root), *args],
                          check=True, text=True, capture_output=capture)


def outputs(root):
    return json.loads(terraform("output", "-json", root=root, capture=True).stdout)


def verify_plan(data, allowed):
    # 조건 외의 변경이나 대상 그룹 교체가 있으면 운영 전환을 중단한다.
    changes = [r for r in data.get("resource_changes", [])
               if r["mode"] == "managed" and r["change"]["actions"] != ["no-op"]]
    for resource in changes:
        if resource["address"] not in allowed or resource["change"]["actions"] != ["update"]:
            raise SystemExit("중단: 허용한 ALB 규칙 조건 외의 변경이 있습니다.")
        before, after = resource["change"]["before"], resource["change"]["after"]
        changed = {k for k in before.keys() | after.keys() if before.get(k) != after.get(k)}
        if changed - {"condition"}:
            raise SystemExit("중단: ALB 전달 동작·우선순위 등 조건 외의 변경이 있습니다.")


def persist(values):
    # 적용 직후 기록해 다음 일반 plan에서도 마지막 운영 상태를 유지한다.
    (ROOT / "maintenance.auto.tfvars").write_text(
        "# control.py가 마지막 적용한 운영 상태\n" + "\n".join(
            key + " = " + json.dumps(value) for key, value in values.items()) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "on", "off"])
    parser.add_argument("--profile", help="사용할 AWS 프로필")
    args = parser.parse_args()
    if args.profile:
        os.environ["AWS_PROFILE"] = args.profile
    current = outputs(ROOT)
    if args.action == "status":
        print("기록된 점검 응답:", current["maintenance_enabled"]["value"])
        print("점검 페이지:", current["maintenance_url"]["value"])
        return

    enabled = args.action == "on"
    with tempfile.TemporaryDirectory(prefix="meety-maintenance-") as directory:
        plan = str(Path(directory) / "maintenance.tfplan")
        terraform("plan", "-input=false", "-out=" + plan,
                  "-var=maintenance_enabled=" + str(enabled).lower())
        verify_plan(json.loads(terraform("show", "-json", plan, capture=True).stdout), RULES)
        label = "운영 점검 시작" if enabled else "운영 서비스 재개"
        if enabled:
            print("헬스 체크를 제외한 모든 FE·API 요청에 점검 안내를 응답합니다.")
            print("기존 WebSocket·SSE의 종료 여부는 별도로 확인하세요.")
        if input(label + "을 적용하려면 yes를 입력하세요: ").strip() != "yes":
            raise SystemExit("취소했습니다.")
        terraform("apply", "-input=false", plan)
        persist({"maintenance_enabled": enabled})
        print(label + " 적용 완료.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit("실행에 실패했습니다. status와 실제 ALB 규칙을 확인한 후 재시도하세요.") from error
