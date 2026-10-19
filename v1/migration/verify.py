"""write-load.js, live-load.js 요청 기록과 리허설 대상 DB 조회 결과를 대조해 데이터 정합성과 지연을 정리한다.

사용법은 README.md 참고.
    python3 verify.py --run r1018a --ops ops-r1018a.jsonl --db meetings-r1018a.tsv --live live-r1018a.tsv \
        --mark ohio_ro=1760751234567 --mark promote=1760751236789 --mark switch=1760751238901
"""
import argparse
import json
import re
import hashlib
from collections import Counter, defaultdict
from datetime import datetime

OPS = ("create", "patch", "delete")
# 판정 이름. 표의 순서대로 출력한다.
VERDICTS = ("정상", "유실", "실패", "응답 실패인데 반영됨")
# 전환 단계 이름. 처음 이름 전은 전환 전, 마지막 이름 이후는 전환 후, 그 사이는 전환 중이다.
# dns, gate_open은 2026-10-14 Nginx 방식 리허설 기록을 다시 볼 때 쓴다.
MARK_NAMES = ("dns", "hold", "ohio_ro", "promote", "switch", "gate_open")
LIVE_HTTP_OPS = ("login", "m_create", "join", "rec_start", "pause", "resume", "rec_complete", "rec_complete_cleanup")


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


def load_entries(paths, run):
    """여러 기록 파일을 읽어 write-load.js 기록과 live-load.js 기록(kind=live)으로 나눈다."""
    rest, live = [], []
    for path in paths:
        for line in open(path, encoding="utf-8"):
            entry = parse_log_line(line)
            if not entry or entry.get("run") != run:
                continue
            (live if entry.get("kind") == "live" else rest).append(entry)
    return rest, live


# ---------- REST 쓰기 (write-load.js) ----------

def rest_last(rest):
    """요청 기록을 (seq, op)별 마지막 시도로 모은다. 401 재시도 전 기록은 마지막 시도로 덮인다."""
    last, attempts = {}, []
    for entry in rest:
        if entry.get("op") not in OPS + ("relogin",):
            continue
        attempts.append(entry)
        if entry["op"] in OPS:
            last[(entry["seq"], entry["op"])] = entry
    return last, attempts


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


def judge_rest(last, rows):
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


def print_rest(last, attempts, rows, marks):
    verdicts, details, duplicates, unknown = judge_rest(last, rows)
    print(f"\n# REST 쓰기 (write-load.js)")
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
            print(f"seq={seq} op={op} 판정={verdict} 상태={entry['status']} 시작={clock(entry['startedAt'])} "
                  f"{entry['ms']}ms meetingId={entry.get('meetingId')} error={entry.get('error')}")

    print_latency([e for e in attempts if e["op"] in OPS], marks, "REST 구간별 응답 시간과 실패")
    relogins = [e for e in attempts if e["op"] == "relogin"]
    if relogins:
        print(f"\n재로그인 {len(relogins)}건, 실패 {sum(1 for e in relogins if not e['ok'])}건")


# ---------- 실시간 회의 (live-load.js) ----------

def load_live_db(path, run):
    """collect.sh의 live TSV(회의 id, purpose, 녹음 id, 상태, 누적 일시정지 ms, 종료 시각, 전사 수)를 seq별로 읽는다."""
    rows = defaultdict(list)
    pattern = re.compile(rf"^(\d+)\tlive-{re.escape(run)}-(\d{{6}})\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(\d+)$")
    for line in open(path, encoding="utf-8"):
        match = pattern.match(line.rstrip("\r\n"))
        if not match:
            continue
        nullable = lambda v: None if v == "NULL" else v
        paused = nullable(match.group(5))
        rows[int(match.group(2))].append({
            "meetingId": int(match.group(1)),
            "recordingId": nullable(match.group(3)),
            "status": nullable(match.group(4)),
            "pausedMs": int(paused) if paused is not None else None,
            "ended": nullable(match.group(6)) is not None,
            "transcripts": int(match.group(7)),
        })
    return rows


def group_live(live):
    """회의(seq)별로 요청 마지막 결과, WebSocket 기록, 요약(meeting_done)을 모은다."""
    meetings = defaultdict(lambda: {"ops": {}, "ws": [], "done": None, "first": None, "last": None})
    for entry in live:
        if "seq" not in entry:
            continue
        m = meetings[entry["seq"]]
        started = entry.get("startedAt")
        if started is not None:
            m["first"] = started if m["first"] is None else min(m["first"], started)
            end = started + (entry.get("ms") or 0)
            m["last"] = end if m["last"] is None else max(m["last"], end)
        op = entry.get("op")
        if op in LIVE_HTTP_OPS or op == "ws_connect":
            m["ops"][op] = entry
        elif op in ("ws_close", "ws_ready"):
            m["ws"].append(entry)
        elif op == "meeting_done":
            m["done"] = entry
    return meetings


def judge_live(meetings, rows, window):
    """회의마다 요청 결과와 DB 상태를 대조한다. 성공 응답을 받았는데 DB에 없으면 유실로 센다."""
    results = []
    for seq, m in sorted(meetings.items()):
        found = rows.get(seq, [])
        row = found[0] if found else None
        ops = m["ops"]
        issues = []

        def ok(op):
            return op in ops and ops[op]["ok"]

        if ok("m_create") and row is None:
            issues.append("유실:회의")
        if not ok("m_create") and row is not None:
            issues.append("응답실패인데반영:회의")
        if ok("rec_start") and (row is None or row["recordingId"] is None):
            issues.append("유실:녹음시작")
        if "rec_start" in ops and not ops["rec_start"]["ok"] and row is not None and row["recordingId"] is not None:
            issues.append("응답실패인데반영:녹음시작")
        if ok("pause") and ok("resume") and row is not None and not row["pausedMs"]:
            issues.append("유실:일시정지·재개")
        completed_ok = ok("rec_complete") or ok("rec_complete_cleanup")
        if completed_ok and row is not None and row["status"] != "COMPLETED":
            issues.append("유실:녹음종료")
        for op in LIVE_HTTP_OPS:
            if op in ops and not ops[op]["ok"]:
                issues.append(f"실패:{op}({ops[op]['status']})")

        done = m["done"] or {}
        overlap = window is not None and m["first"] is not None and m["last"] is not None \
            and m["first"] <= window[1] and m["last"] >= window[0]
        results.append({
            "seq": seq, "row": row, "issues": issues, "overlap": overlap, "done": done,
            "unexpected": done.get("unexpectedCloses", 0), "gaveUp": done.get("gaveUp", False),
            "clean": not issues and done.get("unexpectedCloses", 0) == 0 and done.get("sentSeq") == done.get("chunkCount"),
            "first": m["first"],
        })
    return results


def print_live(meetings, rows, marks, live, expected_override=None):
    window = (min(marks.values()), max(marks.values())) if marks else None
    results = judge_live(meetings, rows, window)
    print(f"\n# 실시간 회의 (live-load.js)")
    print(f"회의 {len(results)}개 (DB 회의 행 {sum(len(v) for v in rows.values())}개)")

    # 전사 기대값: 전환과 겹치지 않고 문제없이 끝난 회의들의 전사 수 최빈값 (가짜 STT는 오디오 1초마다 1건)
    baseline = [r["row"]["transcripts"] for r in results if r["clean"] and not r["overlap"] and r["row"]]
    expected = expected_override if expected_override is not None else (Counter(baseline).most_common(1)[0][0] if baseline else None)
    if expected is None:
        print("전사 기대값: 기준으로 삼을 정상 회의가 없어 계산하지 못했습니다")
    elif expected_override is not None:
        print(f"전사 기대값: {expected}건 (실행 인자로 지정한 가짜 STT 기준)")
    else:
        print(f"전사 기대값: {expected}건 (전환과 겹치지 않은 정상 회의 {len(baseline)}개의 최빈값, "
              f"범위 {min(baseline)}~{max(baseline)})")

    # 조용히 전사만 빠진 회의도 문제 상세와 실패 종료에 포함한다.
    for result in results:
        row = result["row"]
        if expected is not None and row and row["transcripts"] != expected:
            result["issues"].append(f"전사수불일치({row['transcripts']}/{expected})")
        if not result["done"] or result["done"].get("sentSeq") != result["done"].get("chunkCount"):
            result["issues"].append("오디오송신미완료")
        if not result["done"].get("completed"):
            result["issues"].append("회의정상종료미확인")

    for group_name, members in (("전환과 겹친 회의", [r for r in results if r["overlap"]]),
                                ("전환과 겹치지 않은 회의", [r for r in results if not r["overlap"]])):
        if not members:
            continue
        print(f"\n## {group_name}: {len(members)}개")
        counts = Counter()
        shortfalls = []
        for r in members:
            for issue in r["issues"]:
                counts[issue.split("(")[0]] += 1
            if r["unexpected"]:
                counts["WebSocket 예상치 못한 끊김"] += 1
            if r["gaveUp"]:
                counts["재연결 포기(FE라면 회의 종료)"] += 1
            if expected is not None and r["row"] and r["row"]["status"] == "COMPLETED":
                short = expected - r["row"]["transcripts"]
                if short > 0:
                    shortfalls.append((r["seq"], short))
        if counts:
            for name, count in counts.most_common():
                print(f"  {name}: {count}")
        else:
            print("  문제 없음")
        if expected is not None:
            missing = sum(s for _, s in shortfalls)
            print(f"  전사 부족: 회의 {len(shortfalls)}개, 합계 {missing}건"
                  + (f" (seq별 부족: {shortfalls[:15]})" if shortfalls else ""))

    problems = [r for r in results if r["issues"] or r["unexpected"]]
    if problems:
        print("\n## 문제 회의 상세 (최대 30개)")
        for r in problems[:30]:
            row = r["row"] or {}
            print(f"seq={r['seq']} 시작={clock(r['first']) if r['first'] else '-'} 겹침={'예' if r['overlap'] else '아니오'} "
                  f"상태={row.get('status')} 전사={row.get('transcripts')} 끊김={r['unexpected']} "
                  f"보낸조각={r['done'].get('sentSeq')}/{r['done'].get('chunkCount')} 확인={r['done'].get('maxAck')} "
                  f"문제={', '.join(r['issues']) or '-'}")

    print_latency([e for e in live if e.get("op") in LIVE_HTTP_OPS and "startedAt" in e], marks,
                  "실시간 회의 구간별 응답 시간과 실패")
    return expected is not None and bool(results) and all(not r["issues"] and not r["unexpected"] and not r["gaveUp"] for r in results)


# ---------- 공통 ----------

def check_segments(path, run, meetings, expected, content):
    """가짜 STT 전사 전체의 순번·원본 키·내용 해시를 독립 기준으로 검사한다."""
    grouped = defaultdict(list)
    keys = set()
    problems = []
    pattern = re.compile(rf"live-{re.escape(run)}-(\d{{6}})")
    expected_hash = hashlib.sha256(content.encode()).hexdigest() if content is not None else None
    for line in open(path, encoding="utf-8"):
        purpose, key, number, digest = line.rstrip("\n").split("\t")
        match = pattern.fullmatch(purpose)
        if not match:
            raise SystemExit("전사 상세의 RUN_ID가 다릅니다")
        seq = int(match.group(1))
        grouped[seq].append(int(number))
        recording = ((meetings.get(seq) or {}).get("done") or {}).get("recordingSessionId")
        if recording is not None and key != f"{recording}:{number}":
            problems.append(f"seq={seq} 녹음 ID·전사 순번과 원본 키 불일치")
        if key in keys:
            problems.append(f"seq={seq} 원본 키 중복")
        keys.add(key)
        if expected_hash is not None and digest.lower() != expected_hash:
            problems.append(f"seq={seq} 전사 내용 불일치")
    for seq in meetings:
        numbers = grouped[seq]
        # 현재 가짜 STT의 확정 전사 순번은 0부터 시작한다.
        if sorted(numbers) != list(range(expected)):
            problems.append(f"seq={seq} 순번 누락·중복 또는 개수 불일치({len(numbers)}/{expected})")
    if set(grouped) - set(meetings):
        problems.append("요청 기록이 없는 회의의 전사가 있습니다")
    print(f"\n전사 상세 검증: {'FAIL' if problems else 'PASS'} (키·순번" + ("·내용" if content is not None else "") + ")")
    for problem in problems[:30]:
        print("  " + problem)
    return not problems

def parse_marks(values):
    marks = {}
    for value in values:
        name, _, text = value.partition("=")
        if name not in MARK_NAMES:
            raise SystemExit(f"--mark 이름은 {', '.join(MARK_NAMES)} 중 하나여야 합니다: {name}")
        marks[name] = parse_time(text)
    return marks


def parse_time(text):
    # switch.sh가 출력한 epoch 밀리초, 또는 HH:MM:SS(.mmm) / YYYY-MM-DDTHH:MM:SS(.mmm) (로컬 시간)
    if re.fullmatch(r"\d{13}", text):
        return int(text)
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S", "%H:%M:%S.%f", "%H:%M:%S"):
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        if fmt.startswith("%H"):
            parsed = datetime.combine(datetime.now().date(), parsed.time())
        return parsed.timestamp() * 1000
    raise SystemExit(f"시각 형식은 epoch 밀리초, HH:MM:SS(.mmm), YYYY-MM-DDTHH:MM:SS(.mmm) 중 하나여야 합니다: {text}")


def phase_of(started_at, marks):
    # 첫 단계 전은 전환 전, 마지막 단계 이후는 전환 후, 그 사이는 전환 중이다.
    if not marks:
        return "전체"
    if started_at < min(marks.values()):
        return "1.전환 전"
    if started_at >= max(marks.values()):
        return "3.전환 후"
    return "2.전환 중"


def clock(ms):
    return datetime.fromtimestamp(ms / 1000).strftime("%H:%M:%S.%f")[:-3]


def percentile(values, ratio):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(ratio * (len(ordered) - 1))))]


def print_latency(attempts, marks, title):
    if not attempts:
        return
    groups = defaultdict(list)
    for entry in attempts:
        groups[(phase_of(entry["startedAt"], marks), entry["op"])].append(entry)
    print(f"\n## {title}")
    print(f"{'구간':<10}{'작업':<22}{'요청':>6}{'실패':>6}{'p50(ms)':>9}{'p95(ms)':>9}{'최대(ms)':>9}  상태 코드")
    for (phase, op), entries in sorted(groups.items()):
        times = [e["ms"] for e in entries]
        failed = sum(1 for e in entries if not e["ok"])
        codes = Counter(e["status"] for e in entries)
        code_text = ", ".join(f"{code}:{count}" for code, count in sorted(codes.items()))
        print(f"{phase:<10}{op:<22}{len(entries):>6}{failed:>6}{percentile(times, .5):>9}"
              f"{percentile(times, .95):>9}{max(times):>9}  {code_text}")


def main():
    parser = argparse.ArgumentParser(description="DB 이전 테스트 결과 검증")
    parser.add_argument("--run", required=True, help="write-load.js, live-load.js에 준 RUN_ID")
    parser.add_argument("--ops", required=True, action="append", help="k6 요청 기록 파일 (여러 번 줄 수 있음)")
    parser.add_argument("--db", help="collect.sh의 meetings-<RUN_ID>.tsv (REST 쓰기)")
    parser.add_argument("--live", help="collect.sh의 live-<RUN_ID>.tsv (실시간 회의)")
    parser.add_argument("--mark", action="append", default=[], help=f"전환 시각. {', '.join(MARK_NAMES)}")
    parser.add_argument("--expected-transcripts", type=int, help="가짜 STT의 회의당 예상 전사 수. 기준 회의가 없을 때도 검증 가능")
    parser.add_argument("--segments", help="collect.sh의 segments-<RUN_ID>.tsv")
    parser.add_argument("--expected-content", help="가짜 STT의 고정 문장. 원문 대신 해시를 비교한다")
    args = parser.parse_args()

    rest, live = load_entries(args.ops, args.run)
    if not rest and not live:
        raise SystemExit("요청 기록이 없습니다. --run 값과 --ops 파일을 확인하세요")
    marks = parse_marks(args.mark)

    print(f"# 검증 결과: RUN_ID={args.run}")
    if marks:
        ordered = sorted(marks.items(), key=lambda kv: kv[1])
        start = ordered[0][1]
        print("전환 단계: " + ", ".join(f"{name} {clock(t)} (+{int(t - start)}ms)" for name, t in ordered))

    last, attempts = rest_last(rest)
    passed = True
    if last:
        if not args.db:
            raise SystemExit("REST 기록이 있습니다. --db meetings-<RUN_ID>.tsv를 주세요")
        rows = load_db(args.db, args.run)
        print_rest(last, attempts, rows, marks)
        verdicts, _, duplicates, unknown = judge_rest(last, rows)
        passed = passed and not duplicates and not unknown and all(verdict == "정상" or count == 0 for (_, verdict), count in verdicts.items())
    if live:
        if not args.live:
            raise SystemExit("실시간 회의 기록이 있습니다. --live live-<RUN_ID>.tsv를 주세요")
        passed = print_live(group_live(live), load_live_db(args.live, args.run), marks, live, args.expected_transcripts) and passed
    if args.segments:
        if args.expected_transcripts is None or args.expected_transcripts < 1 or not live:
            raise SystemExit("--segments 검증에는 실시간 기록과 양수 --expected-transcripts가 필요합니다")
        passed = check_segments(args.segments, args.run, group_live(live), args.expected_transcripts, args.expected_content) and passed
    print("\n최종 판정: " + ("PASS" if passed else "FAIL"))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
