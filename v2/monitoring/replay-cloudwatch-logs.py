#!/usr/bin/env python3
"""staging CloudWatch 로그 구간을 조회하고, 명시적으로 실행할 때만 Loki 전달 Lambda로 재전송한다."""
import argparse
import base64
from collections import defaultdict
from datetime import datetime, timezone
import gzip
import json
from pathlib import Path
import subprocess
import tempfile


def timestamp_ms(value):
    stamp = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if stamp.tzinfo is None:
        raise ValueError('시각에 Z 또는 +09:00 같은 시간대가 필요합니다')
    # 부동소수점 반올림으로 1ms 경계가 달라지지 않도록 정수로 계산한다.
    delta = stamp - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return delta.days * 86_400_000 + delta.seconds * 1000 + delta.microseconds // 1000


def subscription_payload(group, stream, events, owner):
    # 원본 event ID, 발생 시각과 메시지를 유지한다. 현재 시각으로 바꿔 보내지 않는다.
    data = {'owner': owner, 'logGroup': group, 'logStream': stream,
            'messageType': 'DATA_MESSAGE', 'subscriptionFilters': ['manual-replay'],
            'logEvents': [{'id': event['eventId'], 'timestamp': event['timestamp'],
                           'message': event['message']} for event in events]}
    packed = gzip.compress(json.dumps(data, ensure_ascii=False).encode(), mtime=0)
    return {'awslogs': {'data': base64.b64encode(packed).decode()}}


def batches(events, max_bytes=200_000):
    # 보수적으로 작은 배치로 나눈다. 과대 단일 이벤트는 잘라서 훼손하지 않고 중단한다.
    current, size = [], 0
    for event in events:
        event_size = len(json.dumps(event, ensure_ascii=False).encode())
        if event_size > max_bytes:
            raise ValueError('단일 이벤트가 재전송 배치 한도를 넘습니다')
        if current and (size + event_size > max_bytes or len(current) == 200):
            yield current
            current, size = [], 0
        current.append(event)
        size += event_size
    if current:
        yield current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', default='meety-admin')
    parser.add_argument('--log-group', required=True)
    parser.add_argument('--start', required=True, help='포함 시작 시각, 예: 2026-10-20T09:00:00+09:00')
    parser.add_argument('--end', required=True, help='미포함 종료 시각, 한 번에 최대 1시간')
    parser.add_argument('--filter-pattern', default='', help='테스트에서는 고유 합성 로그 마커로 한정')
    parser.add_argument('--execute', action='store_true', help='생략 시 건수만 조회하고 재전송하지 않음')
    args = parser.parse_args()
    start, end = timestamp_ms(args.start), timestamp_ms(args.end)
    if not 0 < end - start <= 3_600_000:
        parser.error('시작·종료 구간은 0초 초과, 1시간 이하여야 합니다')
    tf_dir = Path(__file__).resolve().parent.parent / 'terraform' / 'staging'
    config = json.loads(subprocess.check_output(
        ['terraform', '-chdir=' + str(tf_dir), 'output', '-json', 'loki_log_shipping'], text=True))
    # 환경이나 대상을 임의로 바꿔 prod에 재전송하는 실수를 막는다.
    if config['env'] != 'staging' or args.log_group not in config['allowed_log_groups']:
        parser.error('staging Terraform output에 등록된 로그 그룹만 사용할 수 있습니다')

    def aws(*command):
        result = subprocess.run(['aws', '--profile', args.profile, '--region', config['region'],
                                 '--no-cli-pager', '--output', 'json', *command],
                                capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    events, token = [], None
    while True:
        command = ['logs', 'filter-log-events', '--log-group-name', args.log_group,
                   '--start-time', str(start), '--end-time', str(end), '--no-paginate']
        if args.filter_pattern:
            command.extend(['--filter-pattern', args.filter_pattern])
        if token:
            command.extend(['--next-token', token])
        page = aws(*command)
        # 이 도구의 구간은 [start, end)로 고정해 이웃한 구간 재전송이 겹치지 않게 한다.
        events.extend(event for event in page.get('events', []) if start <= event['timestamp'] < end)
        next_token = page.get('nextToken')
        if not next_token or next_token == token:
            break
        token = next_token

    # 페이징 중 중복된 이벤트만 제거한다. 이전 재전송과의 중복까지 보장하는 기능은 아니다.
    unique = {event['eventId']: event for event in events}
    streams = defaultdict(list)
    for event in sorted(unique.values(), key=lambda event: (event['timestamp'], event['eventId'])):
        streams[event['logStreamName']].append(event)
    print(json.dumps({'mode': 'execute' if args.execute else 'dry-run', 'events': len(unique),
                      'streams': len(streams), 'start_ms': start, 'end_ms_exclusive': end}))
    if not args.execute or not unique:
        return
    owner = aws('sts', 'get-caller-identity')['Account']
    for stream, stream_events in streams.items():
        for batch in batches(stream_events):
            # 메시지는 메모리와 임시 파일에서만 다루고 표준 출력이나 Git에는 저장하지 않는다.
            with tempfile.TemporaryDirectory() as temp:
                payload_file = Path(temp) / 'payload.json'
                payload_file.write_text(json.dumps(subscription_payload(args.log_group, stream, batch, owner)))
                payload_file.chmod(0o600)
                result = aws('lambda', 'invoke', '--function-name', config['function_name'],
                             '--invocation-type', 'RequestResponse', '--payload', 'fileb://' + str(payload_file),
                             str(Path(temp) / 'response.json'))
            if result.get('FunctionError') or result['StatusCode'] != 200:
                raise RuntimeError('재전송 실패. 일부는 전송됐을 수 있으므로 CloudWatch의 Lambda 실행 로그를 확인하세요.')
            print('Lambda execution completed; events=' + str(len(batch)))
    print('재전송 호출 완료. 원본 시각으로 Loki에 반영됐는지 별도로 확인하세요.')


if __name__ == '__main__':
    main()
