"""k6 회의·SSE 시나리오를 조율한다. 테스트 대상 서버가 아닌 부하 발생기에서 실행한다.

준비된 참여자 번호와 검증 성공 여부만 보관한다. 계정·토큰·전사 본문은 받지 않는다.
서버 재시작 시 모든 상태가 사라지며, 실행마다 UUID로 상태를 분리한다.
"""

import argparse
import json
import re
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Coordinator(ThreadingHTTPServer):
    # 다수 참여자의 준비 알림이 동시에 들어오는 구간을 수용한다.
    request_queue_size = 1024
    daemon_threads = True

    def __init__(self, address):
        super().__init__(address, Handler)
        self.runs = {}
        self.lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    # 대상 앱 쿠키가 localhost로 전달되지 않도록 k6 요청에도 별도 헤더만 지정한다.
    def log_message(self, *_):
        pass

    def reply(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def body(self):
        length = int(self.headers.get('Content-Length', '0'))
        if not 0 < length <= 65536:
            raise ValueError('Invalid request size')
        return json.loads(self.rfile.read(length))

    def do_POST(self):
        self.handle_request('POST')

    def do_GET(self):
        self.handle_request('GET')

    def do_DELETE(self):
        self.handle_request('DELETE')

    def handle_request(self, method):
        try:
            body = self.body() if method == 'POST' else None
            with self.server.lock:
                if method == 'POST' and self.path == '/runs':
                    teams = body['teams']
                    if not isinstance(teams, list) or not 1 <= len(teams) <= 1000:
                        raise ValueError('Invalid teams')
                    states = {}
                    for team in teams:
                        if type(team['id']) is not int or team['id'] <= 0 or str(team['id']) in states:
                            raise ValueError('Invalid or duplicate team ID')
                        if type(team['members']) is not int or not 1 <= team['members'] <= 1000:
                            raise ValueError('Invalid member count')
                        states[str(team['id'])] = {'members': team['members'], 'ready': [], 'results': {}}
                    run_id = str(uuid.uuid4())
                    self.server.runs[run_id] = states
                    return self.reply(200, {'runId': run_id})
                match = re.fullmatch(r'/runs/([a-f0-9-]+)(?:/teams/([0-9]+))?', self.path)
                if not match or match[1] not in self.server.runs:
                    return self.reply(404, {'error': 'Unknown run'})
                if method == 'DELETE' and match[2] is None:
                    del self.server.runs[match[1]]
                    return self.reply(200, {'deleted': True})
                state = self.server.runs[match[1]].get(match[2])
                if state is None:
                    return self.reply(404, {'error': 'Unknown team'})
                if method == 'POST':
                    if set(body) == {'ready'}:
                        member = body['ready']
                    elif set(body) == {'member', 'ok'} and type(body['ok']) is bool:
                        member = body['member']
                    else:
                        raise ValueError('Invalid state update')
                    if type(member) is not int or not 0 <= member < state['members']:
                        raise ValueError('Invalid member index')
                    if 'ready' in body and member not in state['ready']:
                        state['ready'].append(member)
                    if 'ok' in body:
                        state['results'][str(member)] = body['ok']
                elif method != 'GET':
                    return self.reply(405, {'error': 'Unsupported method'})
                self.reply(200, state)
        except (KeyError, ValueError, TypeError, json.JSONDecodeError):
            self.reply(400, {'error': 'Invalid request'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8787)
    args = parser.parse_args()
    # 외부 접근을 열지 않는다. k6와 같은 부하 발생기에서만 사용한다.
    with Coordinator(('127.0.0.1', args.port)) as server:
        print(f'Coordinator listening on http://127.0.0.1:{args.port}', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
