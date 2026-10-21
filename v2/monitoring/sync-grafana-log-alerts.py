#!/usr/bin/env python3
"""Staging BE 로그 알림을 동기화한다. 기본은 조회, --execute에서만 변경한다.

AWS CLI 로그인 후 실행하며 비밀번호/웹훅은 SSM에서 메모리로만 읽는다.
Grafana DB의 암호화된 contact point를 사용하고 Terraform state에는 넣지 않는다.
"""
import argparse
import base64
import json
import subprocess
from urllib import error, parse, request

BASE_URL = 'https://grafana-staging.meety.io.kr'
FOLDER = 'meety-staging-log-alerts'
GROUP = 'be-log-errors-1m'
RULE = 'meety-staging-be-errors'
CONTACT = 'meety-staging-discord-logs'
PREFIX = '/meety/staging/monitoring/'
# Spring Boot의 로그 레벨 위치를 검사한다. INFO 본문의 ERROR나 스택 줄은 세지 않는다.
ERROR_PATTERN = (r'^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.+Z-]+'
                 r'[[:space:]]+ERROR[[:space:]]+[0-9]+[[:space:]]+---[[:space:]]')
QUERY = ('sum(count_over_time({env="staging",service="be",source="cloudwatch",'
         'log_group="/ecs/meety-v2-staging/be"} |~ '
         + json.dumps(ERROR_PATTERN) + ' [5m])) or vector(0)')


class SyncError(RuntimeError):
    """민감한 HTTP 본문과 URL을 포함하지 않는 오류."""


class NoRedirect(request.HTTPRedirectHandler):
    # Basic 인증이나 웹훅 설정이 다른 호스트로 넘어가지 않게 한다.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SyncError('HTTP redirect 거부')


def aws(*args):
    result = subprocess.run(['aws', '--profile', 'meety-admin', '--region',
                             'ap-northeast-2', '--no-cli-pager', *args],
                            text=True, capture_output=True)
    if result.returncode:
        raise SyncError('AWS CLI 실패: 로그인 및 권한 확인 필요')
    return json.loads(result.stdout)


def secret(name):
    return aws('ssm', 'get-parameter', '--name', PREFIX + name,
               '--with-decryption')['Parameter']['Value']


class Grafana:
    def __init__(self):
        self.auth = 'Basic ' + base64.b64encode(
            ('admin:' + secret('GRAFANA_ADMIN_PASSWORD')).encode()).decode()
        self.opener = request.build_opener(NoRedirect())

    def api(self, path, method='GET', body=None, missing_ok=False):
        headers = {'Authorization': self.auth, 'Content-Type': 'application/json'}
        data = None if body is None else json.dumps(body).encode()
        req = request.Request(BASE_URL + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except error.HTTPError as exc:
            if exc.code == 404 and missing_ok:
                return None
            raise SyncError(f'Grafana {method} 실패 (HTTP {exc.code})') from None
        except (error.URLError, TimeoutError):
            raise SyncError('Grafana 연결 실패') from None


def rule():
    # instant count를 사용한다. 매 분 평가하며, 5분 창 안의 합계가 10줄 이상이면 발생한다.
    return {
        'uid': RULE, 'orgID': 1, 'folderUID': FOLDER, 'ruleGroup': GROUP,
        'title': '[staging] BE ERROR logs >= 10 in 5m', 'condition': 'C',
        'data': [
            {'refId': 'A', 'queryType': 'instant', 'relativeTimeRange': {'from': 300, 'to': 0},
             'datasourceUid': 'loki', 'model': {
                 'datasource': {'type': 'loki', 'uid': 'loki'}, 'expr': QUERY,
                 'queryType': 'instant', 'instant': True, 'range': False,
                 'editorMode': 'code', 'intervalMs': 1000, 'maxDataPoints': 43200, 'refId': 'A'}},
            {'refId': 'C', 'queryType': '', 'relativeTimeRange': {'from': 0, 'to': 0},
             'datasourceUid': '__expr__', 'model': {
                 'datasource': {'type': '__expr__', 'uid': '__expr__'},
                 'type': 'math', 'expression': '$A >= 10', 'refId': 'C'}}],
        # 로그 부재는 0으로 정상 처리하지만, Loki 조회 실패는 별도 DatasourceError가 된다.
        'noDataState': 'OK', 'execErrState': 'Error', 'for': '0s', 'isPaused': False,
        'labels': {'env': 'staging', 'service': 'be', 'severity': 'warning',
                   'managed_by': 'meety-log-alerts'},
        'annotations': {
            'summary': 'staging BE ERROR 로그 증가',
            'description': '최근 5분 ERROR 로그 {{ $values.A.Value }}줄 (기준 10줄). '
                           '실패 요청 수가 아닌 로그 줄 수이며 API/realtime 합계입니다. '
                           'Resolved는 5분 창의 값이 10 미만이라는 뜻입니다. '
                           'DatasourceError는 애플리케이션 오류와 별도로 Loki 조회를 확인하세요.'},
        # 기존 조직 전체 notification policy를 수정하지 않는다.
        'notification_settings': {'receiver': CONTACT,
                                  'group_by': ['grafana_folder', 'alertname'],
                                  'group_wait': '10s', 'group_interval': '1m',
                                  'repeat_interval': '4h'},
    }


def sync(grafana, execute=False):
    contacts = grafana.api('/api/v1/provisioning/contact-points')
    if any(c['name'] == CONTACT and c['uid'] != CONTACT for c in contacts):
        raise SyncError('같은 이름의 다른 contact point가 있어 중단')
    existing = grafana.api('/api/v1/provisioning/alert-rules/' + RULE, missing_ok=True)
    if existing and existing.get('labels', {}).get('managed_by') != 'meety-log-alerts':
        raise SyncError('관리 대상이 아닌 rule UID 충돌')
    group_path = '/api/v1/provisioning/folder/' + FOLDER + '/rule-groups/' + GROUP
    group = grafana.api(group_path, missing_ok=True)
    if group and any(r['uid'] != RULE for r in group['rules']):
        raise SyncError('전용 평가 그룹에 다른 규칙이 있어 중단')
    print(json.dumps({'mode': 'execute' if execute else 'read-only',
                      'rule_uid': RULE, 'contact_point': CONTACT,
                      'query': QUERY, 'threshold': '>= 10 lines / 5m',
                      'evaluation_seconds': 60, 'query_error': 'DatasourceError'}, ensure_ascii=False))
    if not execute:
        return
    webhook = secret('DISCORD_WEBHOOK_URL')
    parts = parse.urlsplit(webhook)
    if parts.scheme != 'https' or parts.netloc != 'discord.com' or not parts.path.startswith('/api/webhooks/'):
        raise SyncError('허용하지 않는 Discord 웹훅 목적지')
    contact = {'uid': CONTACT, 'name': CONTACT, 'type': 'discord',
               'disableResolveMessage': False, 'settings': {
                   'url': webhook, 'use_discord_username': True,
                   'title': '[{{ .Status }}] staging BE 로그 모니터링',
                   'message': '{{ range .Alerts }}{{ .Labels.alertname }}\n{{ .Annotations.summary }}\n'
                              '{{ .Annotations.description }}\n{{ .GeneratorURL }}\n{{ end }}'}}
    old_contact = next((c for c in contacts if c['uid'] == CONTACT), None)
    if old_contact and (old_contact['name'] != CONTACT or old_contact['type'] != 'discord'):
        raise SyncError('관리 대상이 아닌 contact point UID 충돌')
    path = '/api/v1/provisioning/contact-points'
    grafana.api(path + ('/' + CONTACT if old_contact else ''),
                'PUT' if old_contact else 'POST', contact)
    folder = grafana.api('/api/folders/' + FOLDER, missing_ok=True)
    if folder is None:
        grafana.api('/api/folders', 'POST', {'uid': FOLDER, 'title': 'Meety staging log alerts'})
    grafana.api(group_path, 'PUT', {'title': GROUP, 'folderUid': FOLDER,
                                   'interval': 60, 'rules': [rule()]})
    actual = grafana.api('/api/v1/provisioning/alert-rules/' + RULE)
    assert actual['execErrState'] == 'Error' and actual['notification_settings']['receiver'] == CONTACT
    print('PASS: 전용 규칙 및 Discord contact point 동기화 완료')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true', help='Grafana 설정 변경 (기본은 조회만)')
    args = parser.parse_args()
    try:
        sync(Grafana(), args.execute)
    except (SyncError, ValueError, KeyError, AssertionError) as exc:
        # 예외 원문/응답 본문에는 자격증명이 들어갈 수 있어 출력하지 않는다.
        raise SystemExit('실패: ' + (str(exc) if isinstance(exc, SyncError) else '예상하지 못한 응답 형식'))
