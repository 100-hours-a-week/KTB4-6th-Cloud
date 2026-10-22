#!/usr/bin/env python3
"""알림 Lambda의 배포 ZIP을 일정한 메타데이터로 만들어 Terraform plan 전에 준비한다."""
from pathlib import Path
import io
import zipfile


def main():
    root = Path(__file__).resolve().parent
    archive = io.BytesIO()
    info = zipfile.ZipInfo('discord_notifier.py', date_time=(2026, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    with zipfile.ZipFile(archive, 'w') as output:
        output.writestr(info, (root / 'discord_notifier.py').read_bytes())
    target = root / '.artifacts' / 'discord-notifier.zip'
    target.parent.mkdir(exist_ok=True)
    if not target.exists() or target.read_bytes() != archive.getvalue():
        target.write_bytes(archive.getvalue())
    print('알림 Lambda 패키지 준비됨:', target)


if __name__ == '__main__':
    main()
