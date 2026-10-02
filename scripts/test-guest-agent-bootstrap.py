"""Execute the generated installer with disposable files and fake HTTPS/systemd.

No production paths, network, credentials, or services are touched.
"""
import hashlib
import io
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
from unittest.mock import patch

script = pathlib.Path(sys.argv[1]).read_text()
python_code = script.split("<<'STRATO_GUEST_AGENT_PY'\n", 1)[1].split("\nSTRATO_GUEST_AGENT_PY", 1)[0]
base = 'https://github.com/samcat116/strato/releases/'
for mode in ['x86_64', 'aarch64', 'latest', 'checksum', 'unsupported', 'download', 'version', 'layout', 'interrupt', 'service']:
    with tempfile.TemporaryDirectory() as directory:
        arch = 'aarch64' if mode == 'aarch64' else 'x86_64'
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
            for name, payload in [('strato-guest-agent', b'fixture binary'), ('strato-guest-agent.service', b'fixture unit')]:
                member = tarfile.TarInfo(name)
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
        artifact = buffer.getvalue()
        name = 'strato-guest-agent-' + arch + '.tar.gz'
        manifest = {'schemaVersion': 1, 'version': 'v0.1.2', 'assets': [{
            'arch': arch, 'asset': name, 'url': base + 'download/v0.1.2/' + name,
            'sha256': '0' * 64 if mode == 'checksum' else hashlib.sha256(artifact).hexdigest(),
            'guestAgentBinaryPath': 'strato-guest-agent',
            'systemdUnitPath': 'wrong.service' if mode == 'layout' else 'strato-guest-agent.service'}]}
        if mode == 'version':
            manifest['version'] = 'v0.1.1'
        calls, urls = [], []
        def fetch(url, timeout):
            urls.append(url)
            if mode == 'download':
                raise OSError('fixture interrupted download')
            return io.BytesIO(json.dumps(manifest).encode() if url.endswith('.json') else artifact)
        def service(args, check):
            calls.append(args)
            if mode == 'service':
                raise subprocess.CalledProcessError(1, args)
        original_fsync = os.fsync
        def fsync(fd):
            if mode == 'interrupt':
                raise KeyboardInterrupt('fixture interrupted before publish')
            original_fsync(fd)
        code = python_code.replace("'/usr/local/bin/strato-guest-agent'", repr(directory + '/bin/strato-guest-agent')).replace(
            "'/etc/systemd/system/strato-guest-agent.service'", repr(directory + '/units/strato-guest-agent.service'))
        failed = False
        with patch('platform.system', return_value='Linux'), patch('platform.machine', return_value='riscv64' if mode == 'unsupported' else arch), \
             patch('urllib.request.urlopen', side_effect=fetch), patch('subprocess.run', side_effect=service), \
             patch('os.fsync', side_effect=fsync), patch('sys.argv', ['installer', 'latest' if mode == 'latest' else 'v0.1.2']):
            try:
                exec(compile(code, 'generated-installer', 'exec'), {})
            except (Exception, SystemExit, KeyboardInterrupt):
                failed = True
        expected_success = mode in ['x86_64', 'aarch64', 'latest']
        assert failed != expected_success, mode
        files = [p for p in pathlib.Path(directory).rglob('*') if p.is_file()]
        assert not any(p.name.startswith('.strato') for p in files), (mode, files)
        if expected_success:
            assert pathlib.Path(directory + '/bin/strato-guest-agent').read_bytes() == b'fixture binary'
            assert calls[-1] == ['systemctl', 'enable', '--now', 'strato-guest-agent.service']
            assert urls[0] == base + ('latest/download/' if mode == 'latest' else 'download/v0.1.2/') + 'guest-agent-manifest.json'
        elif mode != 'service':
            assert files == [], (mode, files)
            assert calls == [], mode
        print('PASS ' + mode)
# A guest without cloud-init must not reach any download or installation code.
result = subprocess.run(['/bin/sh', sys.argv[1]], env={'PATH': '/nonexistent'}, capture_output=True)
assert result.returncode != 0 and b'requires cloud-init' in result.stderr
print('PASS missing cloud-init')
