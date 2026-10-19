"""실제 AWS/DB 대신 CLI 대역으로 대상 검증과 승격 실패 경계를 검사한다."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rehearsal_reset', HERE / 'reset.py')
reset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reset)

# 명령을 실행하지 않고 SSM 입출력만 흉내 낸다. 테스트는 임시 디렉터리에 로그를 만든다.
FAKE_AWS = r'''#!/usr/bin/env python3
import sys,json,os,pathlib
args=sys.argv[1:];root=pathlib.Path(os.environ['FAKE_STATE']);scenario=os.environ.get('SCENARIO','ok')
def option(name):return args[args.index(name)+1]
if 'sts' in args:
 print('000000000000' if scenario=='wrong_account' else '062270568040');sys.exit()
if 'ec2' in args:
 print('10.0.1.147' if option('--instance-ids')=='i-00b1191f61901d977' else '10.0.1.143');sys.exit()
if 'send-command' in args:
 entry={'instance':option('--instance-ids'),'script':json.loads(option('--parameters'))['commands'][0]}
 with (root/'commands.jsonl').open('a') as f:f.write(json.dumps(entry)+'\n')
 cid=str(len((root/'commands.jsonl').read_text().splitlines()));(root/cid).write_text(json.dumps(entry));print(cid);sys.exit()
e=json.loads((root/option('--command-id')).read_text());s=e['script'];target=e['instance']=='i-0ebad3417d7a43bda'
promote=target and 'STOP REPLICA' in s
failed=promote and scenario=='ambiguous_promotion'
query=option('--query')
if query=='Status':print('Failed' if failed else 'Success');sys.exit()
if failed:print('synthetic failure');sys.exit()
at='AT=1760840000000\n'
if 'SELECT @@server_id' in s:
 out=('4' if scenario=='wrong_identity' and target else '6' if target else '1')+'\n'
elif 'SHOW REPLICA STATUS' in s:
 out='SRO=1\nMAX_CONN=64\nIO=Yes\nSQL=Yes\nLAG=0\nSRC=10.0.1.147\n'
elif "SELECT CONCAT('RO='" in s:out='RO=0 SRO=0\nMAX_CONN=64\n'
elif "SELECT CONCAT('SRV='" in s:
 parked=os.environ.get('PARKED')=='1'
 out='SRV=10:10.0.1.147:ONLINE\nTARGET=10.0.1.143:'+('OFFLINE_HARD' if parked else 'ONLINE')+'\n'
 if not parked:out+='SRV=20:10.0.1.143:ONLINE\n'
elif "SELECT CONCAT('RULES='" in s:out='RULES=0\nBAD_USER=0\nTARGET_CONN=0\nREAD_TX=true\nOLD_TIMEOUT=30000\n'
elif promote:
 out='WAIT=-1\nNOT_PROMOTED=1\n' if scenario=='replication_timeout' else 'WAIT=0\nPROMOTED=1\n'+at
elif 'SHOW BINARY LOG STATUS' in s:out='DRAIN_TRX=0\nFILE=binlog.000005\nPOS='+('bad' if scenario=='invalid_coordinates' else '12345')+'\n'+at
elif "SELECT CONCAT('GATE='" in s:out='GATE=20\nPARKED=10.0.1.143:OFFLINE_HARD\nTARGET_RUNTIME=0\n'+at
elif "SELECT CONCAT('TARGET='" in s:out='TARGET=10.0.1.143:ONLINE\n'+at
else:out='OK\nIN_USE=0\n'+at
print(out,end='')
'''


class SwitchTests(unittest.TestCase):
    def run_switch(self, arguments, scenario='ok', parked=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / 'aws'
            cli.write_text(FAKE_AWS)
            cli.chmod(0o700)
            env = {**os.environ, 'PATH': str(root)+os.pathsep+os.environ['PATH'],
                   'FAKE_STATE': str(root), 'SCENARIO': scenario, 'PARKED': '1' if parked else '0'}
            result = subprocess.run(['bash', str(HERE/'switch.sh'), *arguments], cwd=root,
                                    env=env, text=True, capture_output=True, timeout=30)
            log = root/'commands.jsonl'
            commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, commands

    def test_preflight_is_read_only_and_accepts_parked_replica(self):
        result, commands = self.run_switch(['--preflight'], parked=True)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        for command in commands:
            self.assertNotIn('SET PERSIST', command['script'])
            self.assertNotIn('UPDATE mysql_servers', command['script'])
            self.assertNotIn('STOP REPLICA', command['script'])

    def test_wrong_account_never_submits_remote_command(self):
        result, commands = self.run_switch(['--mode', 'no-wait', '--yes'], 'wrong_account')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(commands)

    def test_wrong_mysql_identity_never_mutates(self):
        result, commands = self.run_switch(['--mode', 'no-wait', '--yes'], 'wrong_identity')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('SET PERSIST' in c['script'] for c in commands))

    def test_all_modes_complete_with_confirmed_promotion(self):
        for mode in ['no-wait', 'proxysql-wait', 'hostgroup-wait']:
            with self.subTest(mode=mode):
                result, commands = self.run_switch(['--mode', mode, '--yes'])
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertTrue(any('STOP REPLICA' in c['script'] for c in commands))
                if mode != 'hostgroup-wait':
                    inserts = [c['script'] for c in commands if 'INSERT INTO mysql_servers' in c['script']]
                    self.assertTrue(any('max_connections' in s and ", 20, 'target-rehearsal" in s for s in inserts))
                self.assertFalse(any('ap-northeast-2' in c['script'] for c in commands))

    def test_invalid_coordinates_never_attempt_promotion(self):
        result, commands = self.run_switch(['--mode', 'no-wait', '--yes'], 'invalid_coordinates')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('STOP REPLICA' in c['script'] for c in commands))

    def test_uncertain_promotion_never_reopens_original(self):
        for mode in ['no-wait', 'hostgroup-wait']:
            with self.subTest(mode=mode):
                result, commands = self.run_switch(['--mode', mode, '--yes'], 'ambiguous_promotion')
                self.assertNotEqual(result.returncode, 0)
                source = [c['script'] for c in commands if c['instance']=='i-00b1191f61901d977']
                self.assertFalse(any('super_read_only = OFF' in s or 'super_read_only=OFF' in s for s in source))

    def test_confirmed_replication_timeout_reopens_original(self):
        result, commands = self.run_switch(['--mode', 'no-wait', '--yes'], 'replication_timeout')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(c['instance']=='i-00b1191f61901d977' and 'super_read_only = OFF' in c['script'] for c in commands))


class ResetTests(unittest.TestCase):
    def test_monitor_failure_restores_super_read_only(self):
        # 계정 생성이 실패해도 대상의 쓰기 보호를 복구해야 한다.
        calls = []
        def remote(role, body, label, private=False):
            if role == 'SOURCE':
                return json.dumps([['caching_sha2_password', ('$A$005$'+'a'*85).encode().hex(), '']])
            compile(body, 'monitor-prepare', 'exec')
            def sql(query):
                calls.append(query)
                if query.startswith('SELECT'): return '6\t1\t1'
                if query.startswith('SET SESSION'): raise RuntimeError('synthetic create failure')
            exec(body, {'sql':sql})
        with patch.object(reset, 'remote', side_effect=remote):
            with self.assertRaisesRegex(RuntimeError, 'synthetic create failure'):
                reset.prepare_monitor()
        self.assertEqual(calls[-1], 'SET GLOBAL super_read_only=ON;')
        self.assertFalse(any('read_only=OFF' in q and 'super_read_only' not in q for q in calls))

    def test_foreign_account_rejected_before_remote(self):
        with patch.object(reset, 'aws', return_value={'Account':'wrong'}), patch.object(reset, 'remote') as remote:
            with self.assertRaises(RuntimeError):
                reset.preflight()
            remote.assert_not_called()

    def test_replica_status_retains_column_names(self):
        namespace = {}
        exec(reset.MYSQL.replace('__CONTAINER__', 'mysql'), namespace)
        output = 'Source_Host\tReplica_IO_Running\tReplica_SQL_Running\n10.0.1.147\tYes\tYes\n'
        with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0, output, '')):
            self.assertEqual(namespace['status']()['Replica_SQL_Running'], 'Yes')

    def test_failed_seed_restores_original_app_route(self):
        calls = []
        def remote(role, body, label, private=False):
            calls.append((role, body, label))
            if label == 'read app credential':
                return json.dumps([['caching_sha2_password', 'safehash'.encode().hex()]])
            if label == 'rebuild target':
                raise RuntimeError('synthetic restore failure')
            return ''
        with patch.object(reset, 'remote', side_effect=remote), patch.object(reset, 'app') as app:
            with self.assertRaisesRegex(RuntimeError, 'synthetic restore failure'):
                reset.reset(True)
            self.assertIn('resume BE', [c.args[1] for c in app.call_args_list])
            self.assertNotIn('enable standby', [c.args[1] for c in app.call_args_list])
        body = next(body for role, body, label in calls if label=='rebuild target')
        # 32자 제한 회귀를 막고 원격 Python 문법도 검사한다.
        import re
        self.assertEqual(len(re.search("SOURCE_PASSWORD='([^']+)'", body)[1]), 32)
        compile(reset.MYSQL.replace('__CONTAINER__','mysql')+'\n'+body, 'remote-reset', 'exec')


if __name__ == '__main__':
    unittest.main()
