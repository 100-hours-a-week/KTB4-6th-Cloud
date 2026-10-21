"""실제 Discord나 AWS를 호출하지 않고 알림 내용·비밀값 처리·실패 반환을 검증한다."""
import contextlib
from copy import deepcopy
import importlib.util
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, Mock, patch
from urllib import error

SPEC = importlib.util.spec_from_file_location('notifier', Path(__file__).resolve().parents[1] / 'discord_notifier.py')
NOTIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTIFIER)
ARN_PREFIX = 'arn:aws:cloudwatch:ap-northeast-2:111122223333:alarm:meety-v2-staging-loki-forwarder-'
WEBHOOK = 'https://discord.com/api/webhooks/123456/very-secret-test-token'


class NotifierTest(unittest.TestCase):
    def setUp(self):
        self.settings = {
            'ALARM_METRICS': json.dumps({ARN_PREFIX + metric: metric for metric in ('Errors', 'AsyncEventsDropped')}),
            'EXPECTED_ACCOUNT_ID': '111122223333', 'AWS_REGION': 'ap-northeast-2',
            'ENVIRONMENT': 'staging', 'WEBHOOK_PARAMETER': '/meety/staging/monitoring/DISCORD_WEBHOOK_URL',
            'LOG_FORWARDER_FUNCTION': 'meety-v2-staging-loki-forwarder',
            'GRAFANA_URL': 'https://grafana-staging.meety.io.kr/explore',
        }
        self.event = {
            'source': 'aws.cloudwatch', 'alarmArn': ARN_PREFIX + 'Errors',
            'accountId': '111122223333', 'region': 'ap-northeast-2',
            'alarmData': {
                'alarmName': 'meety-v2-staging-loki-forwarder-Errors',
                'state': {'value': 'ALARM', 'reason': '@everyone synthetic threshold',
                          'timestamp': '2026-10-20T13:00:00.000+0000'},
                'previousState': {'value': 'OK'},
            },
        }

    def response(self, data=None, status=200):
        result = MagicMock()
        result.__enter__.return_value = result
        result.status = status
        result.read.return_value = json.dumps(data if data is not None else {'id': '987654321'}).encode()
        return result

    def test_warning_has_kst_time_links_and_mentions_disabled(self):
        result = NOTIFIER.notification(self.event, self.settings)
        payload = result['payload']
        self.assertEqual(payload['allowed_mentions'], {'parse': []})
        embed = payload['embeds'][0]
        self.assertIn('[staging]', embed['title'])
        self.assertIn('2026-10-20 22:00:00', json.dumps(embed, ensure_ascii=False))
        self.assertIn('console.aws.amazon.com', json.dumps(embed))
        self.assertEqual(result['id'], NOTIFIER.notification(deepcopy(self.event), self.settings)['id'])

    def test_dropped_event_is_urgent_and_not_a_log_line_count(self):
        self.event['alarmArn'] = ARN_PREFIX + 'AsyncEventsDropped'
        self.event['alarmData']['alarmName'] = 'meety-v2-staging-loki-forwarder-AsyncEventsDropped'
        embed = NOTIFIER.notification(self.event, self.settings)['payload']['embeds'][0]
        self.assertEqual(embed['color'], 0xE74C3C)
        self.assertIn('로그 줄 수가 아닙니다', embed['description'])
        self.assertIn('수동 재전송', embed['description'])

    def test_ok_message_does_not_claim_delivery_or_backfill_completed(self):
        self.event['alarmData']['state']['value'] = 'OK'
        self.event['alarmData']['previousState']['value'] = 'ALARM'
        embed = NOTIFIER.notification(self.event, self.settings)['payload']['embeds'][0]
        self.assertIn('복구 완료를 뜻하지 않습니다', embed['description'])
        self.assertIn('로그가 발생하지 않아도 OK', embed['description'])

    def test_initial_ok_and_unknown_state_are_ignored(self):
        for value in ('OK', 'INSUFFICIENT_DATA'):
            with self.subTest(value=value):
                self.event['alarmData']['state']['value'] = value
                self.event['alarmData']['previousState']['value'] = 'INSUFFICIENT_DATA'
                self.assertIsNone(NOTIFIER.notification(self.event, self.settings))

    def test_rejects_unexpected_account_region_alarm_and_source(self):
        for key, value in [('accountId', '999999999999'), ('region', 'us-east-2'),
                           ('alarmArn', ARN_PREFIX + 'Unknown'), ('source', 'aws.sns')]:
            with self.subTest(key=key):
                event = {**self.event, key: value}
                with self.assertRaises(ValueError):
                    NOTIFIER.notification(event, self.settings)

    def test_rejects_name_mismatch_and_naive_timestamp(self):
        self.event['alarmData']['alarmName'] = 'another-alarm'
        with self.assertRaises(ValueError):
            NOTIFIER.notification(self.event, self.settings)
        self.event['alarmData']['alarmName'] = 'meety-v2-staging-loki-forwarder-Errors'
        self.event['alarmData']['state']['timestamp'] = '2026-10-20T13:00:00'
        with self.assertRaises(ValueError):
            NOTIFIER.notification(self.event, self.settings)

    def test_explicit_test_message_is_marked(self):
        self.event['test'] = True
        self.assertTrue(NOTIFIER.notification(self.event, self.settings)['payload']['embeds'][0]['title'].startswith('[TEST]'))

    def test_alarm_state_rehearsal_is_marked(self):
        self.event['alarmData']['state']['reason'] = '[TEST] Alarm action delivery rehearsal'
        self.assertTrue(NOTIFIER.notification(self.event, self.settings)['payload']['embeds'][0]['title'].startswith('[TEST]'))

    def test_webhook_destination_is_limited_and_wait_is_forced(self):
        self.assertEqual(NOTIFIER.webhook_url(WEBHOOK + '?wait=false'), WEBHOOK + '?wait=true')
        for url in ('http://discord.com/api/webhooks/123/secret',
                    'https://discord.com.attacker.test/api/webhooks/123/secret',
                    'https://attacker.test/api/webhooks/123/secret',
                    'https://user:secret@discord.com/api/webhooks/123/secret',
                    'https://discord.com/channels/123/secret'):
            with self.subTest(url=url), self.assertRaises(NOTIFIER.DeliveryError):
                NOTIFIER.webhook_url(url)

    def test_webhook_success_requires_confirmed_message_id(self):
        opener = Mock()
        opener.open.return_value = self.response()
        with patch.object(NOTIFIER.request, 'build_opener', return_value=opener):
            self.assertEqual(NOTIFIER.send({'allowed_mentions': {'parse': []}}, WEBHOOK), '987654321')
        req = opener.open.call_args.args[0]
        self.assertTrue(req.full_url.endswith('?wait=true'))
        self.assertEqual(opener.open.call_args.kwargs['timeout'], 5)

    def test_429_obeys_retry_after_then_succeeds(self):
        opener = Mock()
        limited = error.HTTPError(WEBHOOK, 429, 'limited', {}, io.BytesIO(b'{"retry_after": 0.25}'))
        opener.open.side_effect = [limited, self.response()]
        with patch.object(NOTIFIER.request, 'build_opener', return_value=opener), \
             patch.object(NOTIFIER.time, 'sleep') as sleep:
            self.assertEqual(NOTIFIER.send({}, WEBHOOK), '987654321')
        sleep.assert_called_once_with(0.25)

    def test_long_rate_limit_returns_failure_for_async_retry(self):
        opener = Mock()
        opener.open.side_effect = error.HTTPError(WEBHOOK, 429, 'limited', {}, io.BytesIO(b'{"retry_after": 60}'))
        with patch.object(NOTIFIER.request, 'build_opener', return_value=opener), \
             patch.object(NOTIFIER.time, 'sleep') as sleep, self.assertRaises(NOTIFIER.DeliveryError):
            NOTIFIER.send({}, WEBHOOK)
        sleep.assert_not_called()

    def test_transient_failure_is_bounded_and_does_not_expose_secret(self):
        opener = Mock()
        opener.open.side_effect = [error.HTTPError(WEBHOOK, 503, 'secret response', {}, io.BytesIO()) for _ in range(3)]
        with patch.object(NOTIFIER.request, 'build_opener', return_value=opener), \
             patch.object(NOTIFIER.time, 'sleep'), self.assertRaises(NOTIFIER.DeliveryError) as caught:
            NOTIFIER.send({}, WEBHOOK)
        self.assertEqual(opener.open.call_count, 3)
        self.assertNotIn('secret', str(caught.exception))

    def test_revoked_webhook_is_not_retried_inside_invocation(self):
        opener = Mock()
        opener.open.side_effect = error.HTTPError(WEBHOOK, 404, 'secret', {}, io.BytesIO())
        with patch.object(NOTIFIER.request, 'build_opener', return_value=opener), self.assertRaises(NOTIFIER.DeliveryError) as caught:
            NOTIFIER.send({}, WEBHOOK)
        self.assertEqual(opener.open.call_count, 1)
        self.assertNotIn('secret', str(caught.exception))

    def test_network_error_and_bad_response_do_not_expose_webhook(self):
        for result in (error.URLError(WEBHOOK), self.response({'content': WEBHOOK})):
            opener = Mock()
            if isinstance(result, Exception):
                opener.open.side_effect = result
            else:
                opener.open.return_value = result
            with self.subTest(result=type(result).__name__), \
                 patch.object(NOTIFIER.request, 'build_opener', return_value=opener), \
                 patch.object(NOTIFIER.time, 'sleep'), self.assertRaises(NOTIFIER.DeliveryError) as caught:
                NOTIFIER.send({}, WEBHOOK)
            self.assertNotIn('very-secret', str(caught.exception))

    def test_handler_reads_secure_parameter_and_logs_metadata_only(self):
        client = Mock()
        client.get_parameter.return_value = {'Parameter': {'Type': 'SecureString', 'Value': WEBHOOK}}
        modules = {'boto3': SimpleNamespace(client=Mock(return_value=client)),
                   'botocore': SimpleNamespace(), 'botocore.config': SimpleNamespace(Config=Mock())}
        with patch.dict(NOTIFIER.os.environ, self.settings, clear=True), patch.dict(sys.modules, modules), \
             patch.object(NOTIFIER, 'send', return_value='987654321') as send, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            result = NOTIFIER.handler(self.event, None)
        client.get_parameter.assert_called_once_with(Name=self.settings['WEBHOOK_PARAMETER'], WithDecryption=True)
        self.assertEqual(send.call_args.args[1], WEBHOOK)
        self.assertEqual(result['discord_message_id'], '987654321')
        self.assertNotIn(WEBHOOK, output.getvalue())

    def test_handler_parameter_failure_is_redacted_and_propagated(self):
        client = Mock()
        client.get_parameter.side_effect = RuntimeError(WEBHOOK)
        modules = {'boto3': SimpleNamespace(client=Mock(return_value=client)),
                   'botocore': SimpleNamespace(), 'botocore.config': SimpleNamespace(Config=Mock())}
        with patch.dict(NOTIFIER.os.environ, self.settings, clear=True), patch.dict(sys.modules, modules), \
             patch.object(NOTIFIER, 'send') as send, self.assertRaises(NOTIFIER.DeliveryError) as caught:
            NOTIFIER.handler(self.event, None)
        send.assert_not_called()
        self.assertNotIn(WEBHOOK, str(caught.exception))


if __name__ == '__main__':
    unittest.main()
