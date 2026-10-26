"""잘못된 디스크 구조와 마운트된 장치를 쓰기 대상으로 허용하지 않는지 확인한다."""

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("copy_root", Path(__file__).with_name("copy-root.py"))
copy_root = importlib.util.module_from_spec(spec)
spec.loader.exec_module(copy_root)


def ubuntu_table():
    # 부팅 파티션 3개가 앞에 있고 ext4 루트가 마지막인 V1 레이아웃을 축약한다.
    return {"label": "gpt", "sectorsize": 512, "partitions": [
        {"node": "/dev/nvme1n1p1", "start": 2324480, "size": 60590047,
         "type": "4f68bce3-e8cd-4db1-96e7-fbcaf984b709"},
        {"node": "/dev/nvme1n1p13", "start": 227328, "size": 2095104},
        {"node": "/dev/nvme1n1p14", "start": 2048, "size": 8192},
        {"node": "/dev/nvme1n1p15", "start": 10240, "size": 217088},
    ]}


class RootCopySafetyTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("sfdisk"), "실제 sfdisk 통합 검증은 Linux 작업 서버에서 실행")
    def test_native_partition_resize_preserves_identity(self):
        # 실제 도구를 임시 파일에 실행해 지원되지 않는 옵션과 UUID 변경을 함께 검출한다.
        with tempfile.TemporaryDirectory(prefix="task84-sfdisk-") as temporary:
            image = Path(temporary) / "test.img"
            with image.open("wb") as output:
                output.truncate(64 * 1024 ** 2)
            copy_root.run("sfdisk", str(image), input_text="label: gpt\nstart=2048,size=65536,type=L\n")
            before = json.loads(copy_root.run("sfdisk", "--json", str(image)))["partitiontable"]["partitions"][0]
            copy_root.resize_partition(image, 32768)
            after = json.loads(copy_root.run("sfdisk", "--json", str(image)))["partitiontable"]["partitions"][0]
            self.assertEqual(after["size"], 32768)
            for key in ("start", "uuid", "type"):
                self.assertEqual(after[key], before[key])

    def test_root_fits_target_with_backup_gpt_and_boot_partitions_unchanged(self):
        for size in [10, 20]:
            table = ubuntu_table()
            before = deepcopy(table)
            plan = copy_root.partition_plan(table, size * copy_root.GIB)
            self.assertLessEqual(plan["root_start"] + plan["root_sectors"], size * copy_root.GIB // 512 - 34)
            self.assertEqual(plan["root_bytes"], plan["filesystem_blocks"] * 4096)
            self.assertEqual(table, before)

    def test_rejects_boot_partition_past_target_root(self):
        table = ubuntu_table()
        table["partitions"][1]["start"] = 50000000
        with self.assertRaisesRegex(ValueError, "부팅 파티션"):
            copy_root.partition_plan(table, 20 * copy_root.GIB)

    def test_rejects_unknown_partition_layout(self):
        table = ubuntu_table()
        table["partitions"].pop()
        with self.assertRaisesRegex(ValueError, "파티션"):
            copy_root.partition_plan(table, 20 * copy_root.GIB)

    def test_rejects_wrong_sector_size_and_non_shrink(self):
        table = ubuntu_table()
        table["sectorsize"] = 4096
        with self.assertRaises(ValueError):
            copy_root.partition_plan(table, 20 * copy_root.GIB)
        with self.assertRaises(ValueError):
            copy_root.partition_plan(ubuntu_table(), 40 * copy_root.GIB)

    def test_rejects_mounted_root_child_before_disk_writes(self):
        devices = {"blockdevices": [{"path": "/dev/nvme0n1", "type": "disk",
                    "serial": "vol0123", "mountpoints": [],
                    "children": [{"mountpoints": ["/"]}]}]}
        with patch.object(copy_root, "run", return_value=json.dumps(devices)) as run:
            with self.assertRaisesRegex(ValueError, "마운트"):
                copy_root.resolve_volumes(["vol-0123"])
            self.assertEqual(run.call_count, 1)

    def test_rejects_ambiguous_serial(self):
        devices = {"blockdevices": [{"path": f"/dev/nvme{n}n1", "type": "disk",
                    "serial": "vol0123", "mountpoints": []} for n in [1, 2]]}
        with patch.object(copy_root, "run", return_value=json.dumps(devices)):
            with self.assertRaisesRegex(ValueError, "정확히 하나"):
                copy_root.resolve_volumes(["vol-0123"])


if __name__ == "__main__":
    unittest.main()
