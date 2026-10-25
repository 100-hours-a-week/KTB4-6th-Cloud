#!/usr/bin/env python3
"""점검 전용 응답과 기존 prod의 IP 조건을 순서대로 전환한다."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1] / "terraform" / "maintenance"
PROD = ROOT.with_name("prod")
RULES = {"aws_lb_listener_rule.fallback_fe", "aws_lb_listener_rule.fallback_api"}
PROD_RULES = {"aws_lb_listener_rule.be_realtime", "aws_lb_listener_rule.be_api", "aws_lb_listener_rule.fe"}


def terraform(*args, root=ROOT, capture=False):
    # 각 state를 명시하고 셸을 거치지 않아 다른 디렉터리의 적용을 방지한다.
    return subprocess.run(["terraform", "-chdir=" + str(root), *args],
                          check=True, text=True, capture_output=capture)


def outputs(root):
    return json.loads(terraform("output", "-json", root=root, capture=True).stdout)


def recorded_access():
    # 대상 지정 apply에서는 독립 output이 누락될 수 있어 규칙의 저장된 조건을 읽는다.
    state = json.loads(terraform("show", "-json", root=PROD, capture=True).stdout)
    resources = state.get("values", {}).get("root_module", {}).get("resources", [])
    conditions = {}
    for resource in resources:
        if resource["address"] in PROD_RULES:
            conditions[resource["address"]] = sorted(
                cidr for condition in resource["values"].get("condition", [])
                for source in condition.get("source_ip", []) for cidr in source["values"])
    if set(conditions) != PROD_RULES or len({tuple(v) for v in conditions.values()}) != 1:
        raise SystemExit("운영 규칙의 IP 조건 기록이 누락되었거나 서로 다릅니다. 실제 ALB 규칙을 확인하세요.")
    return next(iter(conditions.values()))


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


def persist(root, values):
    # 적용 직후 기록해 다음 일반 plan에서도 마지막 운영 상태를 유지한다.
    (root / "maintenance.auto.tfvars").write_text(
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
        print("기록된 실제 서비스 허용 IP:", recorded_access())
        print("점검 페이지:", current["maintenance_url"]["value"])
        return

    enabled = args.action == "on"
    cidrs = current["maintenance_allowed_cidrs"]["value"] if enabled else []
    if enabled and not cidrs:
        raise SystemExit("허용 IP가 없습니다. 점검 전용 Terraform 구성을 먼저 적용하세요.")
    with tempfile.TemporaryDirectory(prefix="meety-maintenance-") as directory:
        response_plan = str(Path(directory) / "response.tfplan")
        access_plan = str(Path(directory) / "access.tfplan")
        terraform("plan", "-input=false", "-out=" + response_plan,
                  "-var=maintenance_enabled=" + str(enabled).lower())
        verify_plan(json.loads(terraform("show", "-json", response_plan, capture=True).stdout), RULES)
        # prod에서는 기존 라우팅 세 개만 대상으로 계획하고 의존 리소스 차이가 섞이면 차단한다.
        terraform("plan", "-input=false", "-out=" + access_plan,
                  "-var=maintenance_allowed_cidrs=" + json.dumps(cidrs),
                  *("-target=" + rule for rule in sorted(PROD_RULES)), root=PROD)
        verify_plan(json.loads(terraform("show", "-json", access_plan, root=PROD, capture=True).stdout), PROD_RULES)
        label = "운영 점검 시작" if enabled else "운영 서비스 재개"
        if enabled:
            print("허용 IP:", ", ".join(cidrs))
            print("기존 WebSocket·SSE의 종료 여부는 별도로 확인하세요.")
        if input(label + "을 적용하려면 yes를 입력하세요: ").strip() != "yes":
            raise SystemExit("취소했습니다.")
        # 시작은 대체 응답을 먼저 준비하고 IP를 제한한다. 해제는 IP 제한부터 제거한다.
        steps = [(ROOT, response_plan, {"maintenance_enabled": enabled}),
                 (PROD, access_plan, {"maintenance_allowed_cidrs": cidrs})]
        for root, plan, desired in steps if enabled else reversed(steps):
            terraform("apply", "-input=false", plan, root=root)
            persist(root, desired)
        print(label + " 적용 완료. 허용 IP와 다른 네트워크에서 각각 확인하세요.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit("실행에 실패했습니다. status와 실제 ALB 규칙을 확인한 후 재시도하세요.") from error
