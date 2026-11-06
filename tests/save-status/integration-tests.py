"""Run the actual PowerShell helper and Lua handler against isolated fake services."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = next(p for p in Path(__file__).resolve().parents if (p / 'packages/v0.5.7').is_dir())
SOURCE = REPO / 'packages/v0.5.7/source/payload'
PWSH = os.environ.get('TIBIASP_TEST_PWSH') or shutil.which('pwsh')
assert PWSH, 'Set TIBIASP_TEST_PWSH or put pwsh on PATH'
TEXLUA = os.environ.get('TIBIASP_TEST_TEXLUA') or shutil.which('texlua')
assert TEXLUA, 'texlua is required for isolated integration tests'

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys, subprocess
from pathlib import Path
root = Path(os.environ['TIBIASP_TEST_ROOT'])
path = root/'docker-state.json'
state = json.loads(path.read_text())
args = sys.argv[1:]
with (root/'docker-calls.jsonl').open('a') as trace: trace.write(json.dumps(args)+'\n')
def persist(): path.write_text(json.dumps(state))
def target(cid):
 for name in ['server','database']:
  if cid == state[name]['Id']: return state[name]
 raise RuntimeError('Unknown fixture container')
def tick():
 if state['server']['State']['Status'] != 'running': return
 result = subprocess.run([os.environ['TIBIASP_TEST_TEXLUA'],str(root/'tick.lua')],cwd=root/'silnik-8.60/server',capture_output=True,text=True)
 if result.returncode: raise RuntimeError(result.stdout+result.stderr)
 if (root/'game-exited').exists():
  state['server']['State'].update(Status='exited',Running=False,Restarting=False)
  persist()
if args[0]=='info': print('fixture-1.0')
elif args[0]=='ps':
 service = next(x.split('=',2)[-1] for x in args if x.startswith('label=com.docker.compose.service='))
 print(state[service]['Id'])
elif args[0]=='inspect':
 tick()
 item=target(args[-1])
 fmt=args[args.index('--format')+1]
 assert fmt == '{{json .State}}{{println}}{{json .HostConfig.RestartPolicy}}{{println}}{{.Id}}', fmt
 print(json.dumps(item['State']))
 print(json.dumps(item['HostConfig']['RestartPolicy']))
 print(item['Id'])
elif args[0]=='start':
 item=target(args[-1]); assert item is state['database'], 'Only existing database may be started directly'
 item['State'].update(Status='running',Running=True,Restarting=False)
 item['State']['Health']={'Status':'healthy'};persist();print(item['Id'])
elif args[0]=='update':
 item=target(args[-1]); policy=args[1].split('=',1)[1]
 name,_,retries=policy.partition(':')
 item['HostConfig']['RestartPolicy']={'Name':name,'MaximumRetryCount':int(retries or 0)}
 persist();print(item['Id'])
elif args[0]=='compose':
 assert state['database']['State']['Health']['Status']=='healthy'
 assert args[-1]=='server' and 'up' in args and '--no-deps' in args and '--no-build' in args and '--pull' in args and 'never' in args
 assert args.count('-f')==2, 'Startup must use restart:no override'
 override=Path(args[[i for i,x in enumerate(args) if x=='-f'][-1]+1])
 assert 'restart: "no"' in override.read_text()
 state['server']['State'].update(Status='running',Running=True,Restarting=False)
 state['server']['HostConfig']['RestartPolicy']={'Name':'no','MaximumRetryCount':0}
 (root/'game-exited').unlink(missing_ok=True);persist()
else: raise RuntimeError('Forbidden unexpected Docker operation: '+repr(args))
'''

def container(cid, policy='no'):
    return {'Id':cid, 'State':{'Status':'exited','Running':False,'Restarting':False,'ExitCode':0,'OOMKilled':False},'HostConfig':{'RestartPolicy':{'Name':policy,'MaximumRetryCount':0}}}

with tempfile.TemporaryDirectory(prefix='Tibia SERWER integration ') as temporary:
    root = Path(temporary)
    data = root / 'silnik-8.60/server/data'
    data.mkdir(parents=True)
    (data.parent / 'compose.yaml').write_text('name: tibiasp-real860\nservices: {}\n')
    shutil.copy2(SOURCE / 'TIBIA_REAL860.ps1', root / 'TIBIA_REAL860.ps1')
    shutil.copy2(SOURCE / 'silnik-8.60/server/data/globalevents/scripts/tibiasp_launcher_commands.lua', root / 'handler.lua')
    # The marker represents the stub's persistent save, not a real MariaDB write.
    (root / 'tick.lua').write_text(r'''
local root=os.getenv('TIBIASP_TEST_ROOT')
saveServer=function()
 if os.getenv('TIBIASP_TEST_SAVE_ERROR')=='1' then error('simulated engine error') end
 local f=assert(io.open(root..'/save-markers','a'));assert(f:write('saved\n'));assert(f:close());return true
end
GAME_STATE_SHUTDOWN=1
Game={setGameState=function(value)
 assert(value==GAME_STATE_SHUTDOWN)
 local f=assert(io.open(root..'/game-exited','w'));assert(f:write('exited'));assert(f:close());return true
end}
assert(loadfile(root..'/handler.lua'))()
assert(onThink(1000)==true)
''')
    binary = root / 'bin'; binary.mkdir()
    executable = binary / 'docker.exe'; executable.write_text(FAKE_DOCKER); executable.chmod(0o755)
    state = {'server':container('a'*64,'unless-stopped'), 'database':container('b'*64)}
    (root/'docker-state.json').write_text(json.dumps(state))
    environment = dict(os.environ, PATH=str(binary)+os.pathsep+os.environ['PATH'], LOCALAPPDATA=str(root/'local'), TIBIASP_TEST_ROOT=str(root), TIBIASP_TEST_TEXLUA=TEXLUA)
    index = 0
    def action(name, success=True, save_error=False):
        global index
        index += 1
        operation_id=f'{index:032x}'
        result_file=root/f'result-{index}.json'
        env=dict(environment, TIBIASP_TEST_SAVE_ERROR='1' if save_error else '0')
        result=subprocess.run([PWSH,'-NoLogo','-NoProfile','-File',str(root/'TIBIA_REAL860.ps1'),'-Action',name,'-OperationId',operation_id,'-ResultFile',str(result_file)],env=env,text=True,capture_output=True,timeout=30)
        assert result_file.is_file(), result.stdout+result.stderr
        record=json.loads(result_file.read_text())
        assert record['operationId']==operation_id and record['action']==name
        assert record['success'] is success and (result.returncode==0) is success, result.stdout+result.stderr+repr(record)
        return record
    action('start')
    current=json.loads((root/'docker-state.json').read_text())
    assert current['database']['State']['Health']['Status']=='healthy'
    assert current['server']['HostConfig']['RestartPolicy']['Name']=='unless-stopped'
    assert action('save')['saveConfirmed'] is True
    failure=action('save',False,True)
    assert failure['saveConfirmed'] is False and 'SAVE_FAILED' in failure['message']
    stopped=action('safestop')
    assert stopped['saveConfirmed'] and stopped['stopConfirmed']
    current=json.loads((root/'docker-state.json').read_text())
    assert current['server']['State']['Status']=='exited'
    assert current['server']['HostConfig']['RestartPolicy']['Name']=='no'
    assert current['database']['State']['Status']=='running'
    action('start')
    current=json.loads((root/'docker-state.json').read_text())
    assert current['server']['HostConfig']['RestartPolicy']['Name']=='unless-stopped'
    action('save')
    trace=[json.loads(x) for x in (root/'docker-calls.jsonl').read_text().splitlines()]
    assert not any(x[0] in ['stop','kill','rm','volume','system'] for x in trace)
    assert not any('playerbot-setup' in x for x in trace)
    assert (root/'save-markers').read_text().splitlines().count('saved')==3
    print('PASS: 6 real-helper/Lua integration actions; startup, save, engine error, shutdown, restart, save')
    print('PASS: matching results, existing healthy database retained, original restart policy recovered, no provisioning')
