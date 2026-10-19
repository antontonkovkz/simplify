#!/usr/bin/env python3
"""Explicit public/personal builds; private definitions never live in the repo."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--variant', choices=['public', 'personal'], default='public')
    parser.add_argument('--definitions', type=Path)
    parser.add_argument('--simulator', action='store_true')
    parser.add_argument('--unsigned', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    definitions = {}
    if args.definitions:
        if args.definitions.resolve().is_relative_to(root):
            parser.error('Private definitions must be outside the project')
        definitions = json.loads(args.definitions.read_text())
    if args.variant == 'public' and definitions:
        parser.error('Public builds do not accept private definitions')
    if set(definitions) - {'BOOTSTRAP_SESSION'}:
        parser.error('Only BOOTSTRAP_SESSION is supported for personal builds')
    target = 'lib/main.dart' if args.variant == 'public' else 'lib/main_personal.dart'
    command = ['flutter', 'build', 'ios', '--target', target]
    command += ['--simulator', '--debug'] if args.simulator else ['--release']
    if args.unsigned and not args.simulator:
        command += ['--no-codesign']
    if args.definitions:
        command += ['--dart-define-from-file=' + str(args.definitions.resolve())]
    secrets = [str(v) for v in definitions.values() if v]
    if definitions.get('BOOTSTRAP_SESSION'):
        try:
            secrets.append(json.loads(definitions['BOOTSTRAP_SESSION'])['token'])
        except (ValueError, KeyError, TypeError):
            parser.error('Invalid bootstrap session JSON')
    secrets += [base64.b64encode(f'{k}={v}'.encode()).decode() for k, v in definitions.items()]
    process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1)
    for line in process.stdout:
        for secret in secrets:
            line = line.replace(secret, '[PRIVATE]')
        print(re.sub(r'--DartDefines=\S+', '--DartDefines=[PRIVATE]', line), end='', flush=True)
    return process.wait()


if __name__ == '__main__':
    raise SystemExit(main())
