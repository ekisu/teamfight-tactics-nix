#!/usr/bin/env python3
"""Run only supplied owned PE fixtures in a new prefix, with scoped cleanup."""
import os
from pathlib import Path
import resource
import selectors
import shutil
import subprocess
import sys
import time


def wait_display(read_fd, timeout=10):
    """Consume and close only our display pipe, with a bounded startup wait."""
    deadline = time.monotonic() + timeout
    data = bytearray()
    with os.fdopen(read_fd, 'rb', buffering=0) as stream, selectors.DefaultSelector() as selector:
        selector.register(stream, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise TimeoutError('owned Xvfb startup exceeded deadline')
            chunk = os.read(stream.fileno(), 64)
            if not chunk:
                raise RuntimeError('owned Xvfb closed its display pipe before startup')
            data.extend(chunk)
            if b'\n' in data:
                display = bytes(data).split(b'\n', 1)[0]
                if not display or len(display) > 10 or not display.isdigit():
                    raise RuntimeError('owned Xvfb returned an invalid display number')
                return ':' + display.decode('ascii')
            if len(data) > 10:
                raise RuntimeError('owned Xvfb display number exceeded its bound')


def cleanup(runtime, env, xvfb):
    """Try both prefix-scoped operations, and reap only our Xvfb process."""
    failed = False
    for action in ('-k', '-w'):
        try:
            process = subprocess.run([str(runtime / 'bin/wineserver'), action], env=env, timeout=30,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if process.returncode:
                print('OWNED cleanup=wineserver action=%s exit=%d' %
                      (action, process.returncode), file=sys.stderr, flush=True)
                failed = True
        except (OSError, subprocess.SubprocessError) as error:
            print('OWNED cleanup=wineserver action=%s error=%s' %
                  (action, error), file=sys.stderr, flush=True)
            failed = True
    if xvfb is not None:
        try:
            if xvfb.poll() is None:
                try:
                    xvfb.terminate()
                except ProcessLookupError:
                    pass
        except OSError as error:
            print('OWNED cleanup=Xvfb terminate_error=%s' % error, file=sys.stderr, flush=True)
            failed = True
        try:
            xvfb.wait(timeout=10)
        except subprocess.TimeoutExpired:
            failed = True
            print('OWNED cleanup=Xvfb timeout; killing only owned process',
                  file=sys.stderr, flush=True)
            try:
                xvfb.kill()
            except ProcessLookupError:
                pass
            except OSError as error:
                print('OWNED cleanup=Xvfb kill_error=%s' % error, file=sys.stderr, flush=True)
            try:
                xvfb.wait(timeout=10)
            except (OSError, subprocess.SubprocessError) as error:
                print('OWNED cleanup=Xvfb reap_error=%s' % error, file=sys.stderr, flush=True)
        except (OSError, subprocess.SubprocessError) as error:
            print('OWNED cleanup=Xvfb error=%s' % error, file=sys.stderr, flush=True)
            failed = True
    print('OWNED cleanup_result=%s' % ('FAIL' if failed else 'PASS'), flush=True)
    return failed


def main(arguments):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    inner = bool(arguments and arguments[0] == '--inner')
    arguments = arguments[1:] if inner else arguments
    if len(arguments) < 3:
        raise SystemExit('usage: run-owned-wine-tests.py RUNTIME NEW_SCRATCH FIXTURE...')
    runtime, scratch = (Path(p).resolve() for p in arguments[:2])
    fixtures = [Path(p).resolve() for p in arguments[2:]]
    prefix = scratch / 'prefix'
    if not scratch.is_dir() or prefix.exists() or prefix.is_symlink():
        raise SystemExit('fixture scratch must exist and contain no prefix')
    if any(p.parent != scratch or p.suffix != '.exe' or not p.is_file() for p in fixtures):
        raise SystemExit('only owned fixture executables directly under scratch are accepted')
    env = {k: v for k, v in os.environ.items()
           if not k.startswith('TFT_') and k not in
           ('WINEPREFIX', 'WINEARCH', 'WINELOADER', 'WINESERVER', 'WINEDLLPATH',
            'WINEDEBUG', 'WINEDLLOVERRIDES')}
    if not inner and shutil.which('steam-run'):
        return subprocess.call(['steam-run', sys.executable, str(Path(__file__).resolve()),
                                '--inner', *arguments], env=env)

    prefix.mkdir(mode=0o700)
    env.update(WINEPREFIX=str(prefix), WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=')
    env.pop('WAYLAND_DISPLAY', None)
    read_fd, write_fd = os.pipe()
    xvfb = None
    result = 0
    try:
        try:
            xvfb = subprocess.Popen(['Xvfb', '-displayfd', str(write_fd), '-nolisten', 'tcp',
                                     '-screen', '0', '1280x720x24'], pass_fds=[write_fd],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
        finally:
            os.close(write_fd)
        display_fd, read_fd = read_fd, None
        env['DISPLAY'] = wait_display(display_fd)
        subprocess.run([str(runtime / 'bin/wine'), 'wineboot', '-u'], env=env, check=True,
                       timeout=180, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for fixture in fixtures:
            process = subprocess.run([str(runtime / 'bin/wine'), str(fixture)], env=env,
                                     timeout=30, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True)
            print(process.stdout, end='', flush=True)
            print('OWNED fixture=%s exit=%d' % (fixture.name, process.returncode), flush=True)
            if process.returncode:
                result = 1
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print('OWNED runner_error=%s' % error, file=sys.stderr, flush=True)
        result = 1
    finally:
        if read_fd is not None:
            os.close(read_fd)
        if cleanup(runtime, env, xvfb):
            result = 1
    return result


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
