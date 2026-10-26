#!/usr/bin/env python3
"""V1 디스크 축소 전 용량과 부팅 구조를 읽는다. 데이터와 컨테이너는 변경하지 않는다."""

import json
import os
from pathlib import Path
import shutil
import subprocess


def command(*args, decode_json=False):
    # 환경 변수, 컨테이너 Env, 설정 파일 내용은 수집하지 않는다.
    result = subprocess.run(args, text=True, capture_output=True, timeout=180)
    if result.returncode:
        return {"error": result.stderr.strip(), "exit_code": result.returncode}
    return json.loads(result.stdout) if decode_json else result.stdout.strip()


def main():
    if os.geteuid() != 0:
        raise SystemExit("Docker 저장소와 시스템 디렉터리 크기를 읽으려면 root가 필요합니다.")
    usage = shutil.disk_usage("/")
    report = {
        "root_bytes": {"total": usage.total, "used": usage.used, "free": usage.free},
        "boot_mode": "uefi" if Path("/sys/firmware/efi").exists() else "bios",
        "block_devices": command(
            "lsblk", "--json", "--bytes", "--output",
            "NAME,PATH,SIZE,TYPE,FSTYPE,UUID,PARTUUID,PARTTYPE,MOUNTPOINTS", decode_json=True),
        "root_mount": command("findmnt", "--json", "--target", "/", decode_json=True),
        "directory_bytes": {},
    }
    # du -x는 다른 파일시스템으로 넘어가지 않는다. DB뿐 아니라 이미지와 OS 크기도 본다.
    for path in ["/usr", "/opt", "/home", "/root", "/var/log", "/var/lib/docker",
                 "/var/lib/containerd", "/var/lib/mysql"]:
        if Path(path).exists():
            report["directory_bytes"][path] = command("du", "-sx", "--block-size=1", path)
    if shutil.which("docker"):
        report["docker_root"] = command("docker", "info", "--format", "{{.DockerRootDir}}")
        report["docker_usage"] = command("docker", "system", "df", "--format", "{{json .}}")
        # 명령 인자나 임의 라벨에 민감한 값이 있을 수 있어 필요한 식별 정보만 남긴다.
        containers = command("docker", "ps", "--all", "--format", "{{json .}}")
        report["containers"] = [
            {key: item.get(key) for key in ["ID", "Names", "Image", "State", "Status", "Mounts"]}
            for item in map(json.loads, containers.splitlines())
        ] if isinstance(containers, str) else containers
        volumes = command("docker", "volume", "ls", "--quiet")
        report["volumes"] = []
        if isinstance(volumes, str):
            for name in volumes.splitlines():
                mount = command("docker", "volume", "inspect", "--format", "{{.Mountpoint}}", name)
                entry = {"name": name, "mountpoint": mount}
                if isinstance(mount, str) and Path(mount).is_dir():
                    entry["bytes"] = command("du", "-sx", "--block-size=1", mount)
                report["volumes"].append(entry)
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
