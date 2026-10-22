"""AWS를 호출하지 않고 재전송의 원본 보존·페이징·실행 경계를 검증한다."""
import base64
import contextlib
import gzip
import importlib.util
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('replay', Path(__file__).resolve().parents[1] / 'replay-cloudwatch-logs.py')
REPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPLAY)


class ReplayTest(unittest.TestCase):
    def setUp(self):
        self.event = {'eventId': 'event-1', 'timestamp': 1792454400123,
                      'message': '합성 로그\n둘째 줄', 'logStreamName': 'test-stream'}
        self.config = {'env': 'staging', 'region': 'ap-northeast-2',
                       'allowed_log_groups': ['/test'], 'function_name': 'test-forwarder'}
        self.argv = ['replay', '--log-group', '/test', '--start', '2026-10-20T00:00:00Z',
                     '--end', '2026-10-20T00:01:00Z']

    def test_original_id_time_and_multiline_survive_encoding(self):
        payload = REPLAY.subscription_payload('/test', 'test-stream', [self.event], '123')
        decoded = json.loads(gzip.decompress(base64.b64decode(payload['awslogs']['data'])))
        self.assertEqual(decoded['logEvents'], [{'id': self.event['eventId'],
                         'timestamp': self.event['timestamp'], 'message': self.event['message']}])
        self.assertEqual(decoded['logStream'], 'test-stream')

    def test_batch_boundary_and_oversized_event(self):
        self.assertEqual([len(batch) for batch in REPLAY.batches([self.event] * 201)], [200, 1])
        with self.assertRaises(ValueError):
            list(REPLAY.batches([self.event], max_bytes=10))

    def test_timezone_is_required(self):
        self.assertEqual(REPLAY.timestamp_ms('2026-10-20T09:00:00+09:00'),
                         REPLAY.timestamp_ms('2026-10-20T00:00:00Z'))
        with self.assertRaises(ValueError):
            REPLAY.timestamp_ms('2026-10-20T00:00:00')
        self.assertEqual(REPLAY.timestamp_ms('2026-10-20T00:00:00.999Z'), 1792454400999)

    def test_end_boundary_is_excluded(self):
        end = REPLAY.timestamp_ms('2026-10-20T00:01:00Z')
        boundary = {**self.event, 'eventId': 'end-boundary', 'timestamp': end}
        with patch.object(sys, 'argv', self.argv), \
             patch.object(REPLAY.subprocess, 'check_output', return_value=json.dumps(self.config)), \
             patch.object(REPLAY.subprocess, 'run', return_value=SimpleNamespace(stdout=json.dumps({'events': [self.event, boundary]}))) as calls, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            REPLAY.main()
        self.assertEqual(json.loads(output.getvalue())['events'], 1)
        command = calls.call_args.args[0]
        self.assertEqual(command[command.index('--end-time') + 1], str(end))

    def test_single_millisecond_range_keeps_event_at_start(self):
        argv = ['replay', '--log-group', '/test', '--start', '2026-10-20T00:00:00.123Z',
                '--end', '2026-10-20T00:00:00.124Z']
        def api_result(command, **kwargs):
            start = int(command[command.index('--start-time') + 1])
            end = int(command[command.index('--end-time') + 1])
            events = [self.event] if start <= self.event['timestamp'] < end else []
            return SimpleNamespace(stdout=json.dumps({'events': events}))
        with patch.object(sys, 'argv', argv), \
             patch.object(REPLAY.subprocess, 'check_output', return_value=json.dumps(self.config)), \
             patch.object(REPLAY.subprocess, 'run', side_effect=api_result), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            REPLAY.main()
        self.assertEqual(json.loads(output.getvalue())['events'], 1)

    def test_dry_run_follows_empty_page_and_deduplicates_without_invoking(self):
        # CloudWatch는 이벤트가 비어 있어도 다음 페이지 토큰을 반환할 수 있다.
        pages = [{'events': [], 'nextToken': 'next'}, {'events': [self.event, self.event]}]
        with patch.object(sys, 'argv', self.argv), \
             patch.object(REPLAY.subprocess, 'check_output', return_value=json.dumps(self.config)), \
             patch.object(REPLAY.subprocess, 'run', side_effect=[SimpleNamespace(stdout=json.dumps(p)) for p in pages]) as calls, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            REPLAY.main()
        self.assertEqual(calls.call_count, 2)
        self.assertTrue(all('filter-log-events' in call.args[0] for call in calls.call_args_list))
        self.assertEqual(json.loads(output.getvalue())['events'], 1)
        self.assertNotIn(self.event['message'], output.getvalue())

    def test_rejects_environment_mismatch_before_reading_logs(self):
        self.config['env'] = 'prod'
        with patch.object(sys, 'argv', self.argv), \
             patch.object(REPLAY.subprocess, 'check_output', return_value=json.dumps(self.config)), \
             patch.object(REPLAY.subprocess, 'run') as calls, \
             contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            REPLAY.main()
        calls.assert_not_called()

    def test_prod_requires_explicit_environment_and_uses_prod_outputs(self):
        # 기본 staging을 유지하되 prod를 명시하면 prod output만 읽어 dry-run 한다.
        self.config['env'] = 'prod'
        with patch.object(sys, 'argv', self.argv + ['--env', 'prod']), \
             patch.object(REPLAY.subprocess, 'check_output', return_value=json.dumps(self.config)) as output_call, \
             patch.object(REPLAY.subprocess, 'run', return_value=SimpleNamespace(stdout=json.dumps({'events': []}))) as calls, \
             contextlib.redirect_stdout(io.StringIO()):
            REPLAY.main()
        self.assertTrue(output_call.call_args.args[0][1].endswith('/terraform/prod'))
        self.assertEqual(calls.call_count, 1)
        self.assertIn('filter-log-events', calls.call_args.args[0])

    def test_lambda_function_error_stops_replay(self):
        responses = [{'events': [self.event]}, {'Account': '123'},
                     {'StatusCode': 200, 'FunctionError': 'Unhandled'}]
        with patch.object(sys, 'argv', self.argv + ['--execute']), \
             patch.object(REPLAY.subprocess, 'check_output', return_value=json.dumps(self.config)), \
             patch.object(REPLAY.subprocess, 'run', side_effect=[SimpleNamespace(stdout=json.dumps(p)) for p in responses]), \
             contextlib.redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
            REPLAY.main()


if __name__ == '__main__':
    unittest.main()
