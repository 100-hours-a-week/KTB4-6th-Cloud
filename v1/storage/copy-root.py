#!/usr/bin/env python3
"""격리된 Linux 작업 서버에서 원본을 보존하며 V1 루트 디스크를 작은 볼륨에 복제한다.

source는 중지된 V1의 원본, scratch는 30GiB 임시 볼륨, target은 새 빈 볼륨이다.
기본 실행은 장치와 파티션 계획만 출력한다. 승인 후 --execute로 복사한다.
EC2 연결 변경과 원본 볼륨 삭제는 이 프로그램에서 수행하지 않는다.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


GIB = 1024 ** 3
SOURCE_SIZES = {
    "vol-001df8669d4cd68fe": 20,
    "vol-0da64e210b987c0fe": 20,
    "vol-0d98ec7190c840f3a": 10,
}


def run(*args, input_text=None, codes=(0,)):
    # 장치 경로를 셸로 해석하지 않는다. 출력은 SSM 한도를 넘지 않게 실패 시에만 반환한다.
    result = subprocess.run(args, input=input_text, text=True, capture_output=True, timeout=1200)
    if result.returncode not in codes:
        raise RuntimeError(f"{args[0]} 실패 ({result.returncode}): {result.stderr[-4000:]} {result.stdout[-4000:]}")
    return result.stdout.strip()


def partition_plan(table, target_bytes):
    # Ubuntu V1에서 확인한 GPT/ext4 구조만 지원한다. 다른 OS의 디스크를 추정해서 고치지 않는다.
    if table.get("label") != "gpt" or table.get("sectorsize") != 512:
        raise ValueError("512-byte sector GPT만 지원합니다.")
    parts = table["partitions"]
    by_number = {int(re.search(r"p(\d+)$", p["node"]).group(1)): p for p in parts}
    if set(by_number) != {1, 13, 14, 15}:
        raise ValueError("예상한 Ubuntu V1 파티션 1/13/14/15가 아닙니다.")
    root = by_number[1]
    if root["type"].lower() != "4f68bce3-e8cd-4db1-96e7-fbcaf984b709":
        raise ValueError("루트 파티션 종류가 다릅니다.")
    if any(p["start"] + p["size"] > root["start"] for n, p in by_number.items() if n != 1):
        raise ValueError("루트 앞에 부팅 파티션이 있는 구조만 지원합니다.")
    # 마지막 33개 섹터는 GPT 백업 영역으로 남기고 ext4 4KiB 경계로 정렬한다.
    sectors = ((target_bytes // 512 - 34 - root["start"]) // 8) * 8
    if sectors <= 0 or sectors >= root["size"]:
        raise ValueError("목표 용량은 부팅 파티션보다 크고 원본보다 작아야 합니다.")
    return {"root_start": root["start"], "root_sectors": sectors,
            "root_bytes": sectors * 512, "filesystem_blocks": sectors // 8}


def descendants(device):
    yield device
    for child in device.get("children", []):
        yield from descendants(child)


def resize_partition(device, sectors):
    # -N은 지정한 파티션만 바꾸고 생략한 UUID와 종류를 보존한다. 기존 서명은 지우지 않는다.
    run("sfdisk", "--lock=yes", "--wipe", "never", "--wipe-partitions", "never",
        "-N", "1", str(device), input_text=f"size={sectors}\n")


def resolve_volumes(ids):
    tree = json.loads(run("lsblk", "--json", "--bytes", "--output",
                          "PATH,TYPE,SIZE,SERIAL,MOUNTPOINTS"))["blockdevices"]
    resolved = {}
    for volume_id in ids:
        matches = [d for d in tree if d["type"] == "disk" and
                   (d.get("serial") or "").replace("-", "").strip() == volume_id.replace("-", "")]
        if len(matches) != 1:
            raise ValueError(f"{volume_id}: NVMe 장치를 정확히 하나 찾지 못했습니다.")
        device = matches[0]
        if not re.fullmatch(r"/dev/nvme\d+n\d+", device["path"]):
            raise ValueError("NVMe EBS 장치만 지원합니다.")
        if any(any(d.get("mountpoints") or []) for d in descendants(device)):
            raise ValueError(f"{volume_id}: 마운트된 디스크는 작업할 수 없습니다.")
        resolved[volume_id] = device
    return resolved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, choices=SOURCE_SIZES)
    parser.add_argument("--scratch", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--execute", action="store_true", help="승인한 계획대로 scratch와 target에 쓴다")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError("격리된 작업 서버의 root 권한이 필요합니다.")
    ids = [args.source, args.scratch, args.target]
    if len(set(ids)) != 3 or any(not re.fullmatch(r"vol-[0-9a-f]+", v) for v in ids):
        raise ValueError("서로 다른 EBS 볼륨 ID 3개가 필요합니다.")
    if args.scratch in SOURCE_SIZES or args.target in SOURCE_SIZES:
        raise ValueError("V1 원본 볼륨을 쓰기 대상으로 사용할 수 없습니다.")
    disks = resolve_volumes(ids)
    source, scratch, target = (disks[v] for v in ids)
    if source["size"] != 30 * GIB or scratch["size"] != source["size"]:
        raise ValueError("원본과 scratch는 각각 30GiB여야 합니다.")
    if target["size"] != SOURCE_SIZES[args.source] * GIB:
        raise ValueError("실측 후 정한 목표 용량과 다릅니다.")
    if target.get("children") or json.loads(run("wipefs", "--json", target["path"]))["signatures"]:
        raise ValueError("target에 기존 파티션 또는 파일시스템이 있습니다. 빈 새 볼륨만 허용합니다.")
    table = json.loads(run("sfdisk", "--json", source["path"]))["partitiontable"]
    plan = partition_plan(table, target["size"])
    root = source["path"] + "p1"
    if run("blkid", "-s", "TYPE", "-o", "value", root) != "ext4":
        raise ValueError("ext4 루트만 지원합니다.")
    filesystem = dict(line.split(":", 1) for line in run("dumpe2fs", "-h", root).splitlines() if ":" in line)
    if int(filesystem["Block size"].strip()) != 4096:
        raise ValueError("4KiB ext4 block만 지원합니다.")
    used_bytes = (int(filesystem["Block count"].strip()) - int(filesystem["Free blocks"].strip())) * 4096
    if plan["root_bytes"] - used_bytes < max(2 * GIB, used_bytes // 4):
        raise ValueError("목표 루트에 최소 2GiB 또는 사용량의 25% 여유가 없어 중단합니다.")
    print(json.dumps({"source": args.source, "scratch": args.scratch, "target": args.target,
                      "target_gib": SOURCE_SIZES[args.source], **plan}, indent=2), flush=True)
    if not args.execute:
        return

    marker = Path("/var/lib/meety-root-copy") / args.scratch
    # 임시 볼륨은 이 도구가 처음 사용한 기록이 있거나 완전히 비어 있을 때만 덮어쓴다.
    if not marker.exists() and (scratch.get("children") or
            json.loads(run("wipefs", "--json", scratch["path"]))["signatures"]):
        raise ValueError("scratch가 비어 있지 않고 이 도구의 사용 기록도 없습니다.")
    # 원본은 커널에서도 읽기 전용으로 설정한다. 원본 fsck 역시 수정 금지 옵션만 쓴다.
    run("blockdev", "--setro", source["path"])
    run("e2fsck", "-fn", root)
    marker.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    marker.write_text("task-84 scratch; contains V1 root copy\n")
    run("dd", "if=" + source["path"], "of=" + scratch["path"], "bs=16M", "conv=fsync")
    run("blockdev", "--rereadpt", scratch["path"])
    run("udevadm", "settle")
    scratch_root = scratch["path"] + "p1"
    # 원본 대신 임시 복사본의 파일시스템만 축소한다.
    run("e2fsck", "-fy", scratch_root, codes=(0, 1))
    run("resize2fs", scratch_root, str(plan["filesystem_blocks"]))
    resize_partition(scratch["path"], plan["root_sectors"])
    run("blockdev", "--rereadpt", scratch["path"])
    run("udevadm", "settle")
    run("e2fsck", "-fn", scratch_root)
    # EFI, /boot, UUID, 컨테이너 데이터를 함께 복사하고 끝의 GPT 백업을 재배치한다.
    run("dd", "if=" + scratch["path"], "of=" + target["path"], "bs=16M",
        "count=" + str(target["size"]), "iflag=count_bytes", "conv=fsync")
    run("sgdisk", "-e", target["path"])
    run("blockdev", "--rereadpt", target["path"])
    run("udevadm", "settle")
    if "No problems found" not in run("sgdisk", "-v", target["path"]):
        raise RuntimeError("복사 후 GPT 검증에 실패했습니다. 연결을 바꾸지 마세요.")
    run("e2fsck", "-fn", target["path"] + "p1")
    target_table = json.loads(run("sfdisk", "--json", target["path"]))["partitiontable"]
    source_parts = {p["node"].split("p")[-1]: p for p in table["partitions"]}
    for part in target_table["partitions"]:
        before = source_parts[part["node"].split("p")[-1]]
        for key in ("start", "uuid", "type"):
            if part[key] != before[key]:
                raise RuntimeError("복사 후 부팅 파티션 식별 정보가 달라졌습니다. 연결을 바꾸지 마세요.")
    run("blockdev", "--setro", target["path"])
    print("COPY_VERIFIED: 원본 보존, 파일시스템 검사 통과. 실제 부팅과 컨테이너 검증은 별도로 필요합니다.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from error
