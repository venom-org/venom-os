#!/usr/bin/env python3
"""`venom-os up` and `venom-os login` against a real venomx.

usage: up.py <venom-os> <venomx>

Every case runs in one temp root under /tmp (short enough for the socket
path) with its own HOME and XDG dirs, so the user's real config, runtime
directory and any running venomx are never touched. Every process this test
starts is killed in `finally`, and the test fails if one is left behind.
`login install` only writes into the temp XDG config home; this test never
runs `systemctl` (only `systemd-analyze --user verify`, when installed).
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

REPO = Path(__file__).resolve().parent.parent
VENOM_OS = str(Path(sys.argv[1]).resolve())
VENOMX = str((REPO / sys.argv[2]).resolve())
TIMEOUT = 15
ROOT = Path(tempfile.mkdtemp(prefix='vos-', dir='/tmp'))
results = []


def ok(name):
    results.append(name)
    print(f'ok {name}', flush=True)


def until(fn, what, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{what} did not become true')


def ours():
    """Live PIDs whose environment names ROOT (venom-os, venomx, shells)."""
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            environ = (entry / 'environ').read_bytes()
            state = (entry / 'stat').read_text().rsplit(')', 1)[1].split()[0]
        except OSError:
            continue
        if state != 'Z' and str(ROOT).encode() in environ:
            found.append(int(entry.name))
    return found


def venomx_pids():
    """Every live venomx of ours: supervised or on-demand (which re-execs
    /proc/self/exe, so match the executable, not argv[0])."""
    out = []
    for pid in ours():
        try:
            exe = os.readlink(f'/proc/{pid}/exe')
        except OSError:
            continue
        if exe == VENOMX:
            out.append(pid)
    return out


def serve_pids():
    out = []
    for pid in ours():
        try:
            argv = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        except OSError:
            continue
        if argv[0] == VENOMX.encode() and b'serve' in argv:
            out.append(pid)
    return out


for d in ('run', 'cfg/venomx', 'state', 'data', 'etc', 'work'):
    (ROOT / d).mkdir(parents=True, mode=0o700)
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith('VENOMX_') and not k.endswith('_TOKEN') and not k.startswith('XDG_')}
ENV.update(HOME=str(ROOT), XDG_RUNTIME_DIR=str(ROOT / 'run'), XDG_CONFIG_HOME=str(ROOT / 'cfg'),
           XDG_STATE_HOME=str(ROOT / 'state'), XDG_DATA_HOME=str(ROOT / 'data'), XDG_CONFIG_DIRS=str(ROOT / 'etc'),
           SHELL='/bin/sh', ENV='', TERM='xterm-256color')
SOCKET = ROOT / 'run' / 'venom' / 'venomx.sock'
STATUS = ROOT / 'run' / 'venom' / 'venom-os.status.json'
VOS_SOCKET = ROOT / 'run' / 'venom' / 'venom-os.sock'
INSTALLED = ROOT / 'data' / 'venom' / 'venom-os' / 'xdg' / 'venomx' / 'defaults.zon'
# The clients see the same XDG_CONFIG_DIRS as the supervised daemon.
CLIENT = dict(ENV, XDG_CONFIG_DIRS=f'{INSTALLED.parent.parent}:{ROOT / "etc"}')
OWNER = dict(CLIENT, VENOMX_TOKEN='@owner')


def vx(*args, env=OWNER, code=0):
    r = subprocess.run([VENOMX, *args, '--json'], stdin=subprocess.DEVNULL, env=env, cwd=ROOT / 'work',
                       capture_output=True, text=True, timeout=TIMEOUT)
    assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
    return json.loads(r.stdout.splitlines()[-1]) if r.stdout else None


def vos(*args, env=ENV, code=0):
    r = subprocess.run([VENOM_OS, *args, '--json'], stdin=subprocess.DEVNULL, env=env, cwd=ROOT / 'work',
                       capture_output=True, text=True, timeout=TIMEOUT)
    assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
    return json.loads(r.stdout)


VOS_OWNER = dict(ENV, VENOM_OS_TOKEN='@owner')


def bundle_checks():
    return {c['id']: c for c in vos('doctor')['checks']}


def ping():
    r = subprocess.run([VENOMX, 'ping', '--json'], stdin=subprocess.DEVNULL, env=CLIENT, capture_output=True, timeout=TIMEOUT)
    return r.returncode == 0


def status():
    try:
        return {w['name']: w for w in json.loads(STATUS.read_text())['workers']}
    except (OSError, ValueError, KeyError):
        return None


def pty_run(argv, env):
    """Run argv with stdin/stdout on a fresh PTY (venomx new needs one)."""
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env, cwd=ROOT / 'work',
                         start_new_session=True)
    os.close(slave)
    try:
        code = p.wait(timeout=TIMEOUT)
        return code, p.stderr.read().decode()
    finally:
        if p.poll() is None:
            p.kill()
        os.close(master)


def main():
    # Packager path: `defaults` prints the shipped file and installs it under --dir.
    shipped = subprocess.run([VENOM_OS, 'defaults'], capture_output=True, text=True, timeout=TIMEOUT, env=ENV)
    assert shipped.returncode == 0 and '.interactive_start = false' in shipped.stdout, shipped
    pkg = subprocess.run([VENOM_OS, 'defaults', f'--dir={ROOT / "pkg"}'], capture_output=True, text=True,
                         timeout=TIMEOUT, env=ENV)
    assert pkg.returncode == 0 and (ROOT / 'pkg' / 'venomx' / 'defaults.zon').read_text() == shipped.stdout, pkg
    assert subprocess.run([VENOM_OS, 'defaults', '--dir=rel'], capture_output=True, env=ENV).returncode == 2
    assert subprocess.run([VENOM_OS, 'up', '--bogus'], capture_output=True, env=ENV).returncode == 2
    ok('venom-os defaults prints and installs the shipped file; bad usage exits 2')

    login_session(shipped.stdout)

    # The user's own config: one key that the defaults also set.
    (ROOT / 'cfg' / 'venomx' / 'config.zon').write_text('.{ .status = .{ .position = .bottom } }\n')

    up = subprocess.Popen([VENOM_OS, 'up', f'--venomx={VENOMX}'], stdin=subprocess.DEVNULL, env=ENV,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    until(lambda: up.poll() is not None or (SOCKET.exists() and ping()), 'supervised venomx answers ping')
    assert up.poll() is None, up.communicate()
    assert INSTALLED.read_text() == shipped.stdout
    [first] = until(serve_pids, 'one venomx serve')
    w = until(lambda: (status() or {}).get('venomx'), 'status file names venomx')
    assert w['state'] == 'running', w

    checks = {c['id']: c for c in vx('doctor', env=CLIENT)['checks']}
    assert checks['daemon.lifetime']['message'].startswith('persistent'), checks['daemon.lifetime']
    assert checks['daemon.origin']['message'] == 'origin serve (serve --origin)', checks['daemon.origin']
    assert checks['config.valid']['status'] == 'ok', checks['config.valid']
    assert checks['daemon.interactive_start']['message'] == 'active false; persisted false', checks['daemon.interactive_start']
    got = vx('config', 'get', '--key', 'daemon.interactive_start', env=CLIENT)
    assert got['content'] == 'false' and got['source'] == 'defaults', got
    got = vx('config', 'get', '--key', 'recovery.enabled', env=CLIENT)
    assert got['content'] == 'true' and got['source'] == 'defaults', got
    got = vx('config', 'get', '--key', 'status', env=CLIENT)
    sources = {s['key']: s['source'] for s in got['sources']}
    assert sources['status.priority'] == 'defaults' and '"venom.agents"' in got['content'], got
    # User config overrides a default.
    assert sources['status.position'] == 'user' and '.position = .bottom' in got['content'], got
    tables = {t['name']: t for t in vx('keys', 'list', env=CLIENT)['tables']}
    assert tables['venom-os']['layer'] == 'defaults' and tables['venom-os']['prefix'] == 'g', tables
    assert vx('config', 'check', env=CLIENT)['valid'] is True
    ok('under venom-os up, doctor reports persistent/serve, values come from defaults, user config wins')

    # venom-os ships its float presets and a popup binding.
    got = vx('config', 'get', '--key', 'floats.presets', env=CLIENT)
    assert got['source'] == 'defaults', got
    sources = {s['key']: s['source'] for s in got['sources']}
    assert sources['floats.presets."venom-os.launcher"'] == 'defaults', got
    assert sources['floats.presets."venom-os.settings"'] == 'defaults', got
    assert '.@"venom-os.launcher" = .{ .width = "50%", .height = "40%", .anchor = .top,' in got['content'], got
    assert '.y = 2,' in got['content'] and '.title = "venom-os settings"' in got['content'], got
    print('keys:', json.dumps(tables['venom-os']), flush=True)
    ok('the venom-os float presets and popup binding come from defaults')

    # venom-os's own agent-contract surface reports the supervised venomx.
    st = vos('status')
    assert st == {'mode': 'up', 'defaults': str(INSTALLED), 'venomx': {'state': 'running', 'pid': first, 'restarts': 0}}, st
    checks = bundle_checks()
    assert checks['venomx.supervised']['status'] == 'ok' and f'pid {first}' in checks['venomx.supervised']['message'], checks
    assert checks['venomx.answers']['status'] == 'ok' and str(SOCKET) in checks['venomx.answers']['message'], checks
    assert checks['defaults.installed']['status'] == 'ok' and str(INSTALLED) in checks['defaults.installed']['message'], checks
    assert checks['config.valid']['status'] == 'ok', checks
    ok('venom-os status and doctor --json report the supervised venomx, that it answers, and the installed defaults')

    # A human typing `venomx new` gets a session on the supervised daemon,
    # and the last shell exiting leaves the daemon running.
    code, err = pty_run([VENOMX, 'new', '-d', '--name', 'work', '--', '/bin/sh', '-c', 'sleep 1'], CLIENT)
    assert code == 0, (code, err)
    sessions = vx('session', 'list')['sessions']
    assert [s['name'] for s in sessions] == ['work'], sessions
    until(lambda: vx('session', 'list')['sessions'] == [], 'session removed after its shell exits')
    assert ping() and serve_pids() == [first], 'the persistent daemon must outlive its last session'
    ok('venomx new attaches to the supervised daemon; exiting the last shell keeps the daemon')

    # Crash: the supervisor restarts venomx, which comes back persistent.
    os.kill(first, signal.SIGKILL)
    until(lambda: (p := serve_pids()) and p != [first] and ping(), 'venomx restarted')
    w = until(lambda: (s := status()) and s['venomx']['restarts'] >= 1 and s['venomx']['state'] == 'running' and s['venomx'],
              'status records the restart')
    checks = {c['id']: c for c in vx('doctor', env=CLIENT)['checks']}
    assert checks['daemon.lifetime']['message'].startswith('persistent'), checks
    st = vos('status')['venomx']
    assert st['restarts'] >= 1 and st['pid'] != first, st
    ok('the supervisor restarts venomx after a crash')

    # Disabling a service is persisted for the next up; the running one stays.
    assert vos('service', 'disable', '--name=venomx', code=4)['error']['code'].startswith('denied.')
    assert vos('service', 'disable', '--name=venomx', env=VOS_OWNER) == {'name': 'venomx', 'enabled': False, 'changed': True}
    assert vos('service', 'list') == {'services': [{'name': 'venomx', 'enabled': False}]}
    assert ping() and len(serve_pids()) == 1
    ok('service disable is persisted and leaves the running venomx alone')

    # Graceful stop: SIGTERM to venom-os stops venomx and removes the status file.
    up.send_signal(signal.SIGTERM)
    assert up.wait(timeout=TIMEOUT) == 0, up.communicate()
    until(lambda: not serve_pids(), 'venomx stopped with venom-os')
    assert not STATUS.exists()
    ok('SIGTERM stops venom-os and its venomx; the status file is removed')

    # The next up skips the disabled venomx; enabling it again is persisted.
    up = subprocess.Popen([VENOM_OS, 'up', f'--venomx={VENOMX}'], stdin=subprocess.DEVNULL, env=ENV,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    until(lambda: up.poll() is not None or (VOS_SOCKET.exists() and status() is not None), 'venom-os up serves')
    assert up.poll() is None, up.communicate()
    assert vos('status') == {'mode': 'up', 'defaults': str(INSTALLED)}
    checks = bundle_checks()
    assert checks['venomx.supervised']['status'] == 'ok' and 'disabled' in checks['venomx.supervised']['message'], checks
    assert 'venomx.answers' not in checks and not serve_pids(), checks
    assert vos('service', 'enable', '--name=venomx', env=VOS_OWNER)['changed'] is True
    up.send_signal(signal.SIGTERM)
    assert up.wait(timeout=TIMEOUT) == 0, up.communicate()
    assert not VOS_SOCKET.exists() and not STATUS.exists()
    ok('up skips a disabled venomx; service enable is persisted')
    print(f'ok venom-os up: {len(results)} cases', flush=True)


def login_session(shipped):
    """Run up at login, and give login sessions venom-os's XDG_CONFIG_DIRS."""
    unit = ROOT / 'cfg' / 'systemd' / 'user' / 'venom-os.service'
    wants = ROOT / 'cfg' / 'systemd' / 'user' / 'default.target.wants' / 'venom-os.service'
    envd = ROOT / 'cfg' / 'environment.d' / '50-venom-os.conf'
    ours_dir = str(INSTALLED.parent.parent)
    got = vos('login', 'install', f'--venomx={VENOMX}')
    assert got == {'unit': str(unit), 'wants': str(wants), 'env': str(envd), 'defaults': str(INSTALLED),
                   'config_dirs': ours_dir, 'next': 'systemctl --user daemon-reload && systemctl --user start venom-os.service'}, got
    text = unit.read_text()
    assert f'\nExecStart="{VENOM_OS}" up "--venomx={VENOMX}"\n' in text and '\nWantedBy=default.target\n' in text, text
    assert os.readlink(wants) == str(unit)
    assert INSTALLED.read_text() == shipped
    # A second install rewrites the same files.
    assert vos('login', 'install', f'--venomx={VENOMX}') == got
    if shutil.which('systemd-analyze'):
        v = subprocess.run(['systemd-analyze', '--user', 'verify', str(unit)], stdin=subprocess.DEVNULL, env=ENV,
                           capture_output=True, text=True, timeout=60)
        assert v.returncode == 0 and 'venom-os.service' not in v.stdout + v.stderr, v
        ok('systemd-analyze --user verify accepts the generated unit')
    ok('login install writes the unit, its default.target.wants link and environment.d under XDG_CONFIG_HOME')

    # environment.d and `eval "$(venom-os env)"` give the same list; env is idempotent.
    [line] = [x for x in envd.read_text().splitlines() if x.startswith('XDG_CONFIG_DIRS=')]
    session = line.split('=', 1)[1].replace('${XDG_CONFIG_DIRS:-/etc/xdg}', str(ROOT / 'etc'))
    assert session == f'{ours_dir}:{ROOT / "etc"}', session
    sh = subprocess.run(['/bin/sh', '-c', 'eval "$("$0" env)"; eval "$("$0" env)"; printf %s "$XDG_CONFIG_DIRS"', VENOM_OS],
                        stdin=subprocess.DEVNULL, env=ENV, capture_output=True, text=True, timeout=TIMEOUT)
    assert sh.returncode == 0 and sh.stdout == session, sh
    assert vos('env')['config_dirs'] == ours_dir
    ok('environment.d and venom-os env put venom-os first in XDG_CONFIG_DIRS, once')

    # A fresh terminal of that session, with the daemon stopped,
    # fails unavailable.not_running instead of starting an on-demand daemon.
    login_env = dict(ENV, XDG_CONFIG_DIRS=session)
    code, err = pty_run([VENOMX, 'new', '-d', '--name', 'stray', '--', '/bin/sh', '-c', 'sleep 30'], login_env)
    assert code == 6 and 'interactive_start' in err, (code, err)
    assert not venomx_pids()
    ok('venomx in a login-session terminal with the daemon stopped fails not_running and starts nothing')

    # Without venom-os's XDG_CONFIG_DIRS the same command starts an on-demand
    # daemon; `up` then refuses to fight it for the socket.
    code, err = pty_run([VENOMX, 'new', '-d', '--name', 'stray', '--', '/bin/sh', '-c', 'sleep 30'], ENV)
    assert code == 0, (code, err)
    stray = until(venomx_pids, 'an on-demand venomx')
    failed = vos('up', f'--venomx={VENOMX}', code=5)
    assert failed['error']['code'] == 'conflict.venomx_running', failed
    for pid in stray:
        os.kill(pid, signal.SIGKILL)
    until(lambda: not venomx_pids(), 'the on-demand venomx is gone')
    ok('without it venomx starts on demand, and venom-os up refuses (5) to supervise a second venomx')

    # uninstall removes exactly what install wrote; foreign files are left alone.
    got = vos('login', 'uninstall')
    assert got == {'removed': [str(wants), str(unit), str(envd)], 'next': 'systemctl --user stop venom-os.service'}, got
    assert not unit.exists() and not envd.exists() and not os.path.lexists(wants)
    assert vos('login', 'uninstall')['removed'] == []
    unit.write_text('[Service]\nExecStart=/bin/true\n')
    assert vos('login', 'install', code=5)['error']['code'] == 'conflict.not_ours'
    assert vos('login', 'uninstall', code=5)['error']['code'] == 'conflict.not_ours'
    assert unit.read_text() == '[Service]\nExecStart=/bin/true\n' and not envd.exists()
    unit.unlink()
    ok('login uninstall removes only the files login install wrote')


import traceback
failed = False
try:
    if not Path(VENOMX).is_file():
        raise SystemExit(f'venomx binary not found at {VENOMX}: run `zig build` in ../venomx or pass -Dvenomx=<path>')
    main()
except BaseException:
    traceback.print_exc()
    failed = True
finally:
    stray = ours()
    for pid in stray:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    subprocess.run(['rm', '-rf', str(ROOT)], check=False)
    if stray:
        print('stray processes killed:', stray, file=sys.stderr)
    if failed or stray:
        sys.exit(1)
