"""write-load.js 요청 기록과 서울 DB의 회의 행을 대조해 데이터 정합성과 지연을 정리한다.

사용법은 README.md 참고.
    python3 verify.py --run r1013a --ops ops-r1013a.jsonl --db meetings-r1013a.tsv \
        --mark dns=22:40:00 --mark ohio_ro=22:41:30 --mark gate_open=22:42:10
"""
import argparse
import json
import re
from collections import Counter, defaultdict
from datetime import datetime

OPS = ("create", "patch", "delete")
# 판정 이름. 표의 순서대로 출력한다.
VERDICTS = ("정상", "유실", "실패", "응답 실패인데 반영됨")


def load_ops(path, run):
    """요청 기록을 (seq, op)별 마지막 시도로 모은다. 401 재시도 전 기록은 마지막 시도로 덮인다."""
    last = {}
    attempts = []
    for line in open(path, encoding="utf-8"):
        entry = parse_log_line(line)
        if not entry or entry.get("run") != run or entry.get("op") not in OPS + ("relogin",):
            continue
        attempts.append(entry)
        if entry["op"] in OPS:
            last[(entry["seq"], entry["op"])] = entry
    return last, attempts


def parse_log_line(line):
    # --log-format raw면 JSON 한 줄이다. 다른 형식으로 남긴 경우 msg="..." 안의 JSON을 꺼낸다.
    line = line.strip()
    if line.startswith("{"):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None
    match = re.search(r'msg="((?:[^"\\]|\\.)*)"', line)
    if not match:
        return None
    try:
        return json.loads(json.loads(f'"{match.group(1)}"'))
    except json.JSONDecodeError:
        return None


def load_db(path, run):
    """mysql -B -N 출력(id, purpose, note, deleted_at)을 읽는다. 형식이 맞지 않는 줄은 건너뛴다."""
    rows = defaultdict(list)
    pattern = re.compile(rf"^(\d+)\t(mig-{re.escape(run)}-(\d{{6}}))\t([^\t]*)\t([^\t]*)$")
    for line in open(path, encoding="utf-8"):
        match = pattern.match(line.rstrip("\r\n"))
        if not match:
            continue
        note = None if match.group(4) == "NULL" else match.group(4)
        deleted = match.group(5) != "NULL"
        rows[int(match.group(3))].append({"id": int(match.group(1)), "note": note, "deleted": deleted})
    return rows


def judge(last, rows):
    """작업마다 응답(성공/실패)과 DB 반영 여부를 대조한다."""
    verdicts = Counter()
    details = []
    for (seq, op), entry in sorted(last.items()):
        found = rows.get(seq, [])
        row = found[0] if found else None
        if op == "create":
            applied = row is not None
        elif op == "patch":
            applied = row is not None and row["note"] == f"u-{seq}"
        else:
            applied = row is not None and row["deleted"]

        if entry["ok"]:
            verdict = "정상" if applied else "유실"
        else:
            verdict = "응답 실패인데 반영됨" if applied else "실패"
        verdicts[(op, verdict)] += 1
        if verdict in ("유실", "응답 실패인데 반영됨"):
            details.append((seq, op, verdict, entry))

    duplicates = {seq: len(found) for seq, found in rows.items() if len(found) > 1}
    # 기록에 없는 회의가 DB에 있으면 k6 기록이 빠진 것이다(예: 강제 종료).
    unknown = sorted(seq for seq in rows if (seq, "create") not in last)
    return verdicts, details, duplicates, unknown


def parse_marks(values):
    marks = {}
    for value in values:
        name, _, text = value.partition("=")
        if name not in ("dns", "ohio_ro", "gate_open"):
            raise SystemExit(f"--mark 이름은 dns, ohio_ro, gate_open 중 하나여야 합니다: {name}")
        marks[name] = parse_time(text)
    return marks


def parse_time(text):
    # HH:MM:SS만 주면 오늘 날짜(로컬 시간)로 본다.
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%H:%M:%S"):
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        if fmt == "%H:%M:%S":
            parsed = datetime.combine(datetime.now().date(), parsed.time())
        return parsed.timestamp() * 1000
    raise SystemExit(f"시각 형식은 HH:MM:SS 또는 YYYY-MM-DDTHH:MM:SS여야 합니다: {text}")


def phase_of(started_at, marks):
    # dns 전은 전환 전, gate_open 이후는 전환 후, 그 사이는 전환 중이다.
    if "dns" in marks and started_at < marks["dns"]:
        return "1.전환 전"
    if "gate_open" in marks and started_at >= marks["gate_open"]:
        return "3.전환 후"
    return "2.전환 중" if marks else "전체"


def percentile(values, ratio):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(ratio * (len(ordered) - 1))))]


def print_latency(attempts, marks):
    groups = defaultdict(list)
    for entry in attempts:
        groups[(phase_of(entry["startedAt"], marks), entry["op"])].append(entry)
    print("\n## 구간별 응답 시간과 실패")
    print(f"{'구간':<10}{'작업':<9}{'요청':>6}{'실패':>6}{'p50(ms)':>9}{'p95(ms)':>9}{'p99(ms)':>9}{'최대(ms)':>9}  상태 코드")
    for (phase, op), entries in sorted(groups.items()):
        times = [e["ms"] for e in entries]
        failed = sum(1 for e in entries if not e["ok"])
        codes = Counter(e["status"] for e in entries)
        code_text = ", ".join(f"{code}:{count}" for code, count in sorted(codes.items()))
        print(f"{phase:<10}{op:<9}{len(entries):>6}{failed:>6}{percentile(times, .5):>9}"
              f"{percentile(times, .95):>9}{percentile(times, .99):>9}{max(times):>9}  {code_text}")


def main():
    parser = argparse.ArgumentParser(description="DB 이전 리허설 쓰기 결과 검증")
    parser.add_argument("--run", required=True, help="write-load.js에 준 RUN_ID")
    parser.add_argument("--ops", required=True, help="k6 요청 기록 파일")
    parser.add_argument("--db", required=True, help="서울 DB에서 조회한 회의 TSV 파일")
    parser.add_argument("--mark", action="append", default=[], help="전환 시각. dns=, ohio_ro=, gate_open=")
    args = parser.parse_args()

    last, attempts = load_ops(args.ops, args.run)
    rows = load_db(args.db, args.run)
    if not last:
        raise SystemExit("요청 기록이 없습니다. --run 값과 --ops 파일을 확인하세요")
    marks = parse_marks(args.mark)
    verdicts, details, duplicates, unknown = judge(last, rows)

    print(f"# 검증 결과: RUN_ID={args.run}")
    print(f"요청 기록 {len(attempts)}건(재시도 포함), DB 회의 행 {sum(len(v) for v in rows.values())}건")
    print("\n## 작업별 판정")
    print(f"{'작업':<9}" + "".join(f"{v:>14}" for v in VERDICTS))
    for op in OPS:
        print(f"{op:<9}" + "".join(f"{verdicts[(op, v)]:>14}" for v in VERDICTS))

    lost = sum(verdicts[(op, "유실")] for op in OPS)
    print(f"\n데이터 유실: {lost}건 {'(통과)' if lost == 0 else '(확인 필요)'}")
    print(f"중복 생성: {len(duplicates)}건 {dict(list(duplicates.items())[:10]) if duplicates else ''}")
    if unknown:
        print(f"기록 없이 DB에만 있는 회의: {len(unknown)}건 (seq 예: {unknown[:10]})")

    if details:
        print("\n## 유실 / 응답 실패인데 반영됨 상세 (최대 30건)")
        for seq, op, verdict, entry in details[:30]:
            started = datetime.fromtimestamp(entry["startedAt"] / 1000).strftime("%H:%M:%S.%f")[:-3]
            print(f"seq={seq} op={op} 판정={verdict} 상태={entry['status']} 시작={started} "
                  f"{entry['ms']}ms meetingId={entry.get('meetingId')} error={entry.get('error')}")

    print_latency([e for e in attempts if e["op"] in OPS], marks)
    relogins = [e for e in attempts if e["op"] == "relogin"]
    if relogins:
        print(f"\n재로그인 {len(relogins)}건, 실패 {sum(1 for e in relogins if not e['ok'])}건")


if __name__ == "__main__":
    main()
