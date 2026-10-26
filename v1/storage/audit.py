#!/usr/bin/env python3
"""V1 dev 3대의 디스크를 점검한다. EC2 시작/종료와 볼륨 변경 기능은 제공하지 않는다."""

import argparse
import json
from pathlib import Path
import subprocess
import time


REGION = "us-east-2"
TARGETS = {
    # task-84에서 교체한 현재 루트만 점검한다. 복구용 원본 볼륨은 쓰기 대상으로 삼지 않는다.
    "dev-app-v1": ("i-076b39ef84ef3ddf9", "vol-06f4f35ba387bd1a3"),
    "dev-ai-v1": ("i-0007c84fb4f41d24c", "vol-029be1aadee393e2d"),
    "dev-data-v1": ("i-00b1191f61901d977", "vol-0facbd5c08b7e879e"),
}


def aws(profile, *args):
    # 셸을 거치지 않고 명시한 리전과 프로필만 사용한다.
    result = subprocess.run(
        ["aws", *args, "--profile", profile, "--region", REGION,
         "--output", "json", "--no-cli-pager"],
        text=True, capture_output=True, timeout=90, check=True)
    return json.loads(result.stdout)


def probe(profile, instance_id):
    script = Path(__file__).with_name("inspect-host.py").read_text()
    # SSM은 이미 실행 중인 대상에서 읽기 명령만 실행한다. 서버를 자동 기동하지 않는다.
    response = aws(profile, "ssm", "send-command", "--instance-ids", instance_id,
                   "--document-name", "AWS-RunShellScript", "--comment", "task-84 V1 disk audit",
                   "--parameters", json.dumps({
                       "commands": ["python3 - <<'MEETY_STORAGE_AUDIT_PY'\n" + script +
                                    "\nMEETY_STORAGE_AUDIT_PY"], "executionTimeout": ["600"]}))
    command_id = response["Command"]["CommandId"]
    deadline = time.monotonic() + 660
    while time.monotonic() < deadline:
        try:
            result = aws(profile, "ssm", "get-command-invocation", "--command-id", command_id,
                         "--instance-id", instance_id)
        except subprocess.CalledProcessError as error:
            # SendCommand 직후 조회가 아직 준비되지 않았을 때만 다시 확인한다.
            if "InvocationDoesNotExist" not in error.stderr:
                raise
            time.sleep(3)
            continue
        if result["Status"] in {"Pending", "InProgress", "Delayed", "Cancelling"}:
            time.sleep(3)
            continue
        if result["Status"] != "Success" or result.get("ResponseCode") != 0:
            raise RuntimeError(f"{instance_id}: 점검 실패 ({result['Status']}). Command ID: {command_id}")
        # 잘린 SSM 출력은 JSON 파싱에서 실패하므로 불완전한 용량을 정상 결과로 쓰지 않는다.
        return json.loads(result["StandardOutputContent"])
    raise TimeoutError(f"{instance_id}: 점검 대기 시간 초과. Command ID: {command_id}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="meety-admin")
    parser.add_argument("--probe-running", action="store_true",
                        help="실행 중인 V1 dev 서버에 한해 SSM으로 내부 사용량도 읽는다")
    args = parser.parse_args()
    response = aws(args.profile, "ec2", "describe-instances", "--instance-ids",
                   *(target[0] for target in TARGETS.values()))
    instances = {i["InstanceId"]: i for reservation in response["Reservations"]
                 for i in reservation["Instances"]}
    report = {"region": REGION, "instances": []}
    for name, (instance_id, expected_volume) in TARGETS.items():
        instance = instances[instance_id]
        tags = {tag["Key"]: tag["Value"] for tag in instance.get("Tags", [])}
        if tags.get("Name") != name:
            raise RuntimeError(f"{instance_id}: 대상 이름이 달라 중단합니다.")
        root = next(block["Ebs"]["VolumeId"] for block in instance["BlockDeviceMappings"]
                    if block["DeviceName"] == instance["RootDeviceName"])
        if root != expected_volume:
            raise RuntimeError(f"{name}: 루트 볼륨이 변경됐습니다. 대상 목록을 먼저 검토하세요.")
        volume = aws(args.profile, "ec2", "describe-volumes", "--volume-ids", root)["Volumes"][0]
        entry = {"name": name, "instance_id": instance_id, "state": instance["State"]["Name"],
                 "volume_id": root, "size_gib": volume["Size"], "type": volume["VolumeType"],
                 "root_device": instance["RootDeviceName"], "availability_zone": volume["AvailabilityZone"]}
        if args.probe_running and entry["state"] == "running":
            entry["host"] = probe(args.profile, instance_id)
        else:
            entry["host"] = "미수집: --probe-running과 실행 중인 서버가 필요합니다."
        report["instances"].append(entry)
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError,
            TimeoutError, ValueError, KeyError, StopIteration) as error:
        # CLI 오류 응답을 보여주되 AWS 명령의 인자 전체는 출력하지 않는다.
        raise SystemExit(getattr(error, "stderr", None) or str(error)) from error
