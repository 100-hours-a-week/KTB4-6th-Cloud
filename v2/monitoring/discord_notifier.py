"""허용한 CloudWatch Alarm 상태 변경을 Discord로 전달한다. 웹훅 값은 기록하지 않는다."""
import hashlib
import json
import os
import re
import time
from datetime import datetime, timedelta, timezone
from urllib import error, parse, request


class DeliveryError(RuntimeError):
    """URL, 토큰, Discord 응답 본문을 포함하지 않는 전송 오류."""


def notification(event, settings):
    """직접 호출형 CloudWatch 이벤트만 받고, 최초 OK 전환은 알림에서 제외한다."""
    alarms = json.loads(settings['ALARM_METRICS'])
    arn = event.get('alarmArn')
    if (event.get('source') != 'aws.cloudwatch' or arn not in alarms
            or event.get('accountId') != settings['EXPECTED_ACCOUNT_ID']
            or event.get('region') != settings['AWS_REGION']):
        raise ValueError('허용하지 않은 Alarm 이벤트')
    data = event['alarmData']
    if data['alarmName'] != arn.split(':alarm:', 1)[1]:
        raise ValueError('Alarm 이름과 ARN 불일치')
    state = data['state']['value']
    previous = data.get('previousState', {}).get('value')
    if state not in ('ALARM', 'OK'):
        return None
    if state == 'OK' and previous != 'ALARM':
        return None
    stamp = datetime.fromisoformat(data['state']['timestamp'].replace('Z', '+00:00'))
    if stamp.tzinfo is None:
        raise ValueError('Alarm 시각에 시간대가 없음')
    metric = alarms[arn]
    if metric not in ('Errors', 'AsyncEventsDropped'):
        raise ValueError('지원하지 않는 Alarm 지표')
    identifier = hashlib.sha256(f'{arn}|{state}|{stamp.isoformat()}'.encode()).hexdigest()[:16]
    env = settings['ENVIRONMENT']
    if state == 'ALARM':
        title = '로그 전달 실패' if metric == 'Errors' else '로그 배치 폐기 발생'
        description = ('전송 실패가 발생했습니다. 내부 전송 및 함수 재시도 상태를 확인하세요.'
                       if metric == 'Errors' else
                       '폐기된 로그 배치가 있습니다. 지표 수치는 로그 줄 수가 아닙니다. '
                       'CloudWatch 원본에서 누락 구간을 확인하고 수동 재전송하세요.')
        color = 0xF1C40F if metric == 'Errors' else 0xE74C3C
    else:
        title = '추가 전송 오류 미감지' if metric == 'Errors' else '추가 로그 배치 폐기 미감지'
        description = ('최근 평가 구간에 추가 오류·폐기가 감지되지 않았습니다. '
                       '로그가 발생하지 않아도 OK가 될 수 있습니다. '
                       '실제 전달 정상화나 이전 누락분 복구 완료를 뜻하지 않습니다.')
        color = 0x3498DB
    region = settings['AWS_REGION']
    name = data['alarmName']
    alarm_url = (f'https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}'
                 '#alarmsV2:alarm/' + parse.quote(name, safe=''))
    function_url = (f'https://{region}.console.aws.amazon.com/lambda/home?region={region}'
                    '#/functions/' + parse.quote(settings['LOG_FORWARDER_FUNCTION'], safe=''))
    # SetAlarmState 검증도 실제 장애 알림과 구분되도록 명시한 테스트 이유를 표시한다.
    is_test = event.get('test') is True or str(data['state'].get('reason', '')).startswith('[TEST]')
    test_prefix = '[TEST] ' if is_test else ''
    payload = {
        # Alarm 이유에 @everyone 등이 들어가도 멘션하지 않는다.
        'allowed_mentions': {'parse': []},
        'embeds': [{
            'title': f'{test_prefix}[{env}] {title}', 'description': description,
            'color': color, 'timestamp': stamp.astimezone(timezone.utc).isoformat(),
            'fields': [
                {'name': 'Alarm', 'value': name},
                {'name': '상태', 'value': f'{previous or "UNKNOWN"} → {state}', 'inline': True},
                {'name': '지표', 'value': metric, 'inline': True},
                {'name': '발생 시각(KST)', 'value': stamp.astimezone(timezone(timedelta(hours=9))).strftime('%Y-%m-%d %H:%M:%S')},
                {'name': '판정 이유', 'value': str(data['state'].get('reason') or '이유 없음')[:900]},
                {'name': '확인 경로', 'value': f'[CloudWatch Alarm]({alarm_url}) · [전달 Lambda]({function_url}) · [Grafana]({settings["GRAFANA_URL"]})'},
            ],
            # 같은 ID가 재도착하면 같은 상태 변경의 재전송임을 식별할 수 있다.
            'footer': {'text': '알림 ID: ' + identifier},
        }],
    }
    return {'id': identifier, 'alarm': name, 'state': state, 'payload': payload}


def webhook_url(value):
    """웹훅 목적지를 제한하고 메시지 생성 확인 응답(wait=true)을 요청한다."""
    try:
        url = parse.urlsplit(value.strip())
        valid = (url.scheme == 'https' and url.hostname == 'discord.com'
                 and url.port in (None, 443) and not url.username and not url.password
                 and not url.fragment
                 and re.fullmatch(r'/api(?:/v[0-9]+)?/webhooks/[0-9]+/[A-Za-z0-9._-]+/?', url.path))
    except ValueError:
        valid = False
    if not valid:
        raise DeliveryError('Discord 웹훅 URL 형식이 잘못되었습니다')
    query = [(key, val) for key, val in parse.parse_qsl(url.query) if key != 'wait']
    query.append(('wait', 'true'))
    return parse.urlunsplit((url.scheme, url.netloc, url.path, parse.urlencode(query), ''))


class NoRedirect(request.HTTPRedirectHandler):
    # 웹훅 URL을 다른 호스트로 따라 보내지 않는다.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def send(payload, url, context=None):
    """429와 일시 오류만 제한적으로 재시도하며 실패를 Lambda 호출자에게 반환한다."""
    destination = webhook_url(url)
    opener = request.build_opener(NoRedirect())
    body = json.dumps(payload, ensure_ascii=False).encode()
    for attempt in range(3):
        retry_delay = 2 ** attempt
        req = request.Request(destination, data=body, method='POST', headers={
            'Content-Type': 'application/json', 'User-Agent': 'MeetyMonitoring/1.0'})
        try:
            with opener.open(req, timeout=5) as response:
                result = json.loads(response.read(65536))
                message_id = result.get('id')
                if response.status != 200 or not isinstance(message_id, str) or not message_id.isdigit():
                    raise DeliveryError('Discord 메시지 생성 확인 실패')
                return message_id
        except error.HTTPError as exc:
            code = exc.code
            if code == 429:
                # Retry-After는 초 단위다. 응답 본문이나 URL은 로그에 남기지 않는다.
                try:
                    detail = json.loads(exc.read(4096))
                    retry_delay = max(0.1, float(detail.get('retry_after', exc.headers.get('Retry-After', 1))))
                except (ValueError, TypeError):
                    retry_delay = 1
            exc.close()
            if code != 429 and code not in (500, 502, 503, 504):
                raise DeliveryError(f'Discord HTTP {code}; 웹훅 설정을 확인하세요') from None
        except (error.URLError, TimeoutError, OSError):
            # 원래 예외에는 목적지 URL이 포함될 수 있어 출력하지 않는다.
            pass
        except (ValueError, TypeError, KeyError):
            raise DeliveryError('Discord 응답을 해석할 수 없습니다') from None
        if attempt == 2:
            raise DeliveryError('Discord 전송 재시도 소진') from None
        remaining = context.get_remaining_time_in_millis() / 1000 if context else 45
        if retry_delay > 10 or retry_delay + 6 >= remaining:
            raise DeliveryError('Discord 재시도 대기 필요; Lambda 비동기 재시도로 넘깁니다') from None
        time.sleep(retry_delay)
    raise DeliveryError('Discord 전송 실패')


def handler(event, context):
    item = notification(event, os.environ)
    if item is None:
        return {'status': 'ignored'}
    # AWS Python 런타임에 포함된 SDK를 사용한다. 파라미터는 매 호출 읽어 교체를 즉시 반영한다.
    try:
        import boto3
        from botocore.config import Config
        client = boto3.client('ssm', config=Config(connect_timeout=2, read_timeout=3, retries={'max_attempts': 2}))
        parameter = client.get_parameter(Name=os.environ['WEBHOOK_PARAMETER'], WithDecryption=True)['Parameter']
        if parameter['Type'] != 'SecureString':
            raise ValueError('SecureString 아님')
        secret = parameter['Value']
    except Exception:
        raise DeliveryError('웹훅 SecureString 조회 실패; IAM·파라미터 설정을 확인하세요') from None
    message_id = send(item['payload'], secret, context)
    result = {'notification_id': item['id'], 'alarm': item['alarm'],
              'state': item['state'], 'discord_message_id': message_id}
    print(json.dumps(result))
    return result
