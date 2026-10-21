#!/usr/bin/env python3
"""Run device tests with private definitions outside the project and redacted logs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--platform', choices=['simulator', 'ios'], default='simulator')
    parser.add_argument('--reactivate-device', help='Optional CoreDevice identifier for physical iOS')
    parser.add_argument('--suite', choices=['all', 'app', 'catalog', 'background', 'restore', 'format', 'local', 'playlists', 'volume_normalization', 'large_lists', 'playlist_editor', 'downloaded_tracks', 'group_play', 'queue_follow', 'catalog_cache'], default='all')
    parser.add_argument('--credentials', type=Path, help='Private JSON outside the project')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.credentials:
        if args.credentials.resolve().is_relative_to(root):
            parser.error('Keep private test definitions outside the project')
        definitions = json.loads(args.credentials.read_text())
    else:
        definitions = {
            'TEST_SERVER': os.environ.get('JELLYFIN_TEST_SERVER', ''),
            'TEST_USERNAME': os.environ.get('JELLYFIN_TEST_USER', ''),
            'TEST_PASSWORD': os.environ.get('JELLYFIN_TEST_PASSWORD', ''),
        }
    suites = ['app', 'restore', 'catalog', 'background', 'local', 'playlists', 'volume_normalization', 'large_lists', 'playlist_editor', 'downloaded_tracks', 'group_play', 'queue_follow', 'catalog_cache'] if args.suite == 'all' else [args.suite]
    if any(s in ['app', 'background'] for s in suites) and not all(definitions.values()):
        parser.error('Supply a private definitions file or JELLYFIN_TEST_SERVER, JELLYFIN_TEST_USER and JELLYFIN_TEST_PASSWORD')

    def redact(text):
        secret = definitions.get('TEST_PASSWORD')
        if secret:
            text = text.replace(secret, '[redacted]')
        text = re.sub(r'(api_key=)[^&\s\"\x27]+', r'\1[redacted]', text, flags=re.I)
        text = re.sub(r'(Token\s*=\s*\")[^\"]+', r'\1[redacted]', text, flags=re.I)
        return text

    def reactivate():
        time.sleep(10)
        device = args.reactivate_device or args.device
        command = (['xcrun', 'simctl', 'launch', device, 'online.tavhome.simplefy']
                   if args.platform == 'simulator' else
                   ['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device, 'online.tavhome.simplefy'])
        result = subprocess.run(command, capture_output=True, text=True)
        print(f'HOST: application reactivation exit={result.returncode}', flush=True)

    descriptor, filename = tempfile.mkstemp(prefix='simplefy-private-test-', suffix='.json')
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'w') as handle:
            json.dump(definitions, handle)
        for suite in suites:
            workers = []
            command = ['flutter', 'test', f"integration_test/{'local_library' if suite == 'local' else 'local_playlists' if suite == 'playlists' else suite}_test.dart", '-d', args.device,
                       f'--dart-define-from-file={filename}', '--reporter', 'expanded']
            process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in process.stdout:
                print(redact(line), end='', flush=True)
                if 'SIMPLEFY_BACKGROUND_' in line and '_BEGIN' in line:
                    worker = threading.Thread(target=reactivate, daemon=True)
                    worker.start()
                    workers.append(worker)
            result = process.wait()
            for worker in workers:
                worker.join()
            if result:
                return result
        return 0
    finally:
        os.unlink(filename)


if __name__ == '__main__':
    raise SystemExit(main())
