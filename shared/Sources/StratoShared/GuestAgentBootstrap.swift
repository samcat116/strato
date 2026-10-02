import Foundation

/// First-boot installation only. Updating this pin affects new VMs, never software
/// already installed in a tenant's OS. The release manifest selects the native arch.
public enum GuestAgentBootstrap {
    public static let defaultRelease = "v0.1.2"

    public static func installScript(release: String = defaultRelease) -> String {
        // The selector is platform-authored, but refuse shell metacharacters even
        // when a persisted metadata document came from an untrusted peer.
        guard !release.isEmpty,
            release.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || [45, 46, 95].contains(byte)
            })
        else { return "#!/bin/sh\necho 'Invalid Strato guest-agent release selector' >&2\nexit 1\n" }
        return """
            #!/bin/sh
            # STRATO GUEST AGENT OPT-IN: installs an exec-capable ROOT daemon.
            # Inspect this script in /var/lib/cloud/instance/user-data.txt.
            # Requires Linux, cloud-init, Python 3, systemd and HTTPS egress.
            # No automatic updates: the selected release is installed at first boot only.
            set -eu
            command -v cloud-init >/dev/null || { echo 'Strato guest agent requires cloud-init' >&2; exit 1; }
            command -v systemctl >/dev/null || { echo 'Strato guest agent requires systemd' >&2; exit 1; }
            python3 - '\(release)' <<'STRATO_GUEST_AGENT_PY'
            import hashlib, json, os, platform, re, shutil, subprocess, sys, tarfile, tempfile, urllib.request
            release = sys.argv[1]
            arch = {'x86_64': 'x86_64', 'aarch64': 'aarch64', 'arm64': 'aarch64'}.get(platform.machine())
            if platform.system() != 'Linux' or arch is None:
                raise SystemExit('Unsupported Strato guest-agent OS/architecture: ' + platform.machine())
            base = 'https://github.com/samcat116/strato/releases/'
            manifest_url = base + ('latest/download/' if release == 'latest' else 'download/' + release + '/') + 'guest-agent-manifest.json'
            def download(url, target, limit):
                if not url.startswith('https://'):
                    raise ValueError('Guest-agent downloads require HTTPS')
                with urllib.request.urlopen(url, timeout=60) as response, open(target, 'wb') as output:
                    total = 0
                    while True:
                        chunk = response.read(65536)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > limit:
                            raise ValueError('Guest-agent download exceeded size limit')
                        output.write(chunk)
            with tempfile.TemporaryDirectory(prefix='strato-guest-agent-') as work:
                manifest_path = os.path.join(work, 'manifest.json')
                download(manifest_url, manifest_path, 1048576)
                with open(manifest_path) as source:
                    manifest = json.load(source)
                if manifest.get('schemaVersion') != 1:
                    raise ValueError('Unsupported guest-agent manifest schema')
                if release != 'latest' and manifest.get('version') != release:
                    raise ValueError('Guest-agent manifest does not match selected release')
                assets = [a for a in manifest['assets'] if a['arch'] == arch]
                if len(assets) != 1:
                    raise ValueError('Manifest must contain exactly one native guest-agent artifact')
                asset = assets[0]
                expected_name = 'strato-guest-agent-' + arch + '.tar.gz'
                expected_url = base + 'download/' + manifest['version'] + '/' + expected_name
                if asset['asset'] != expected_name or asset['url'] != expected_url:
                    raise ValueError('Manifest artifact does not belong to the selected guest-agent release')
                if not re.fullmatch('[a-fA-F0-9]{64}', asset['sha256']):
                    raise ValueError('Invalid guest-agent SHA-256')
                archive = os.path.join(work, 'agent.tar.gz')
                download(asset['url'], archive, 134217728)
                with open(archive, 'rb') as source:
                    digest = hashlib.file_digest(source, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(source.read()).hexdigest()
                if digest.lower() != asset['sha256'].lower():
                    raise ValueError('Strato guest-agent SHA-256 verification failed')
                # Extract only the two expected regular files, never archive paths or links.
                files = [('guestAgentBinaryPath', 'strato-guest-agent', '/usr/local/bin/strato-guest-agent', 0o755),
                         ('systemdUnitPath', 'strato-guest-agent.service', '/etc/systemd/system/strato-guest-agent.service', 0o644)]
                with tarfile.open(archive, 'r:gz') as bundle:
                    staged = []
                    try:
                        for key, name, target, mode in files:
                            if asset.get(key) != name:
                                raise ValueError('Unsupported guest-agent archive layout')
                            members = [m for m in bundle.getmembers() if m.name == name]
                            if len(members) != 1 or not members[0].isfile() or members[0].size > 67108864:
                                raise ValueError('Guest-agent archive member must be a bounded regular file')
                            os.makedirs(os.path.dirname(target), exist_ok=True)
                            fd, stage = tempfile.mkstemp(prefix='.strato-guest-agent-', dir=os.path.dirname(target))
                            staged.append((stage, target))
                            with os.fdopen(fd, 'wb') as output, bundle.extractfile(members[0]) as source:
                                shutil.copyfileobj(source, output)
                                output.flush()
                                os.fsync(output.fileno())
                            os.chmod(stage, mode)
                        for stage, target in staged:
                            os.replace(stage, target)
                    finally:
                        for stage, target in staged:
                            if os.path.exists(stage):
                                os.unlink(stage)
                subprocess.run(['systemctl', 'daemon-reload'], check=True)
                subprocess.run(['systemctl', 'enable', '--now', 'strato-guest-agent.service'], check=True)
                print('Installed Strato guest agent ' + manifest['version'] + ' (' + arch + '); root exec daemon enabled')
            STRATO_GUEST_AGENT_PY
            """ + "\n"
    }
}
