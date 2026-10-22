"""로그 오탐 방지와 기존 Grafana 규칙 보호를 검증한다. 외부 API는 호출하지 않는다."""
import importlib.util
from pathlib import Path
import re
import unittest
from unittest.mock import Mock

SPEC = importlib.util.spec_from_file_location(
    'grafana_log_alerts', Path(__file__).resolve().parents[1] / 'sync-grafana-log-alerts.py')
ALERTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ALERTS)


class LogAlertsTest(unittest.TestCase):
    def test_only_spring_error_level_lines_match(self):
        # Python과 RE2의 공통 구문을 사용하고 POSIX 공백 클래스만 치환한다.
        pattern = re.compile(ALERTS.ERROR_PATTERN.replace('[[:space:]]', r'\s'))
        prefix = '2026-10-21T01:02:03.456+09:00 '
        suffix = ' 1 --- [meety] [http-1] example.Logger : '
        self.assertIsNotNone(pattern.match(prefix + 'ERROR' + suffix + 'failure'))
        self.assertIsNone(pattern.match(prefix + 'INFO' + suffix + 'ERROR in message'))
        self.assertIsNone(pattern.match('java.lang.RuntimeException: ERROR'))
        self.assertIsNone(pattern.match('    at example.ERROR.run(App.java:10)'))

    def test_query_error_is_not_silenced_as_zero(self):
        # vector(0)는 빈 검색 결과만 보완한다. datasource 실패는 Error 상태로 보존한다.
        rule = ALERTS.rule()
        self.assertEqual(rule['execErrState'], 'Error')
        self.assertEqual(rule['noDataState'], 'OK')
        self.assertTrue(ALERTS.QUERY.endswith('or vector(0)'))
        self.assertEqual(rule['data'][1]['model']['expression'], '$A >= 10')

    def test_prod_rule_and_endpoints_are_isolated_from_staging(self):
        # prod 선택이 SSM·접속 URL·로그 그룹·알림 수신처에 모두 적용되어야 한다.
        config = ALERTS.environment('prod')
        rule = ALERTS.rule('prod')
        self.assertEqual(config['base_url'], 'https://grafana.meety.io.kr')
        self.assertEqual(config['prefix'], '/meety/prod/monitoring/')
        self.assertEqual(rule['labels']['env'], 'prod')
        self.assertEqual(rule['notification_settings']['receiver'], 'meety-prod-discord-logs')
        self.assertIn('/ecs/meety-v2-prod/be', rule['data'][0]['model']['expr'])
        self.assertNotIn('staging', str(rule))
        self.assertEqual(ALERTS.rule()['labels']['env'], 'staging')

    def test_connection_environment_mismatch_aborts_before_requests(self):
        # 인증 정보를 읽지 않고 객체만 만들어 환경 불일치가 API 호출 전에 차단되는지 검사한다.
        grafana = object.__new__(ALERTS.Grafana)
        grafana.env = 'staging'
        grafana.api = Mock()
        with self.assertRaises(ALERTS.SyncError):
            ALERTS.sync(grafana, execute=True, env='prod')
        grafana.api.assert_not_called()

    def test_unowned_rule_uid_collision_aborts_without_writes(self):
        grafana = Mock()
        grafana.api.side_effect = [[], {'labels': {}}]
        with self.assertRaises(ALERTS.SyncError):
            ALERTS.sync(grafana, execute=True)
        self.assertTrue(all(len(call.args) == 1 for call in grafana.api.call_args_list))

    def test_group_with_other_rule_aborts_without_writes(self):
        grafana = Mock()
        grafana.api.side_effect = [[], None, {'rules': [{'uid': 'someone-elses-rule'}]}]
        with self.assertRaises(ALERTS.SyncError):
            ALERTS.sync(grafana, execute=True)
        self.assertTrue(all(len(call.args) == 1 for call in grafana.api.call_args_list))


if __name__ == '__main__':
    unittest.main()
