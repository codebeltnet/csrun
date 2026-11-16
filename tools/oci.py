"""Verify, assemble and promote csrun OCI content without rebuilding it (stdlib only)."""
import argparse
import contextlib
import hashlib
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import tarfile
import tempfile
import weakref

INDEX = 'application/vnd.oci.image.index.v1+json'
SOURCE = 'https://github.com/codebeltnet/csrun'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def encoded(value):
    return json.dumps(value, separators=(',', ':'), sort_keys=True).encode()


class Archive:
    def __init__(self, path):
        self.path = Path(path)
        self.tar = tarfile.open(path)
        self._close = weakref.finalize(self, self.tar.close)
        self.members = {}
        for member in self.tar:
            if member.isdir():
                continue
            name = member.name.removeprefix('./')
            require(member.isfile() and name not in self.members, 'Unsafe or duplicate tar member')
            require(name in ('index.json', 'oci-layout') or name.startswith('blobs/sha256/'), 'Unexpected OCI member')
            self.members[name] = member
            if name.startswith('blobs/'):
                h = hashlib.sha256()
                with self.tar.extractfile(member) as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        h.update(chunk)
                require(name == 'blobs/sha256/' + h.hexdigest(), 'Corrupt OCI blob')
        require(self.read('oci-layout') == {'imageLayoutVersion': '1.0.0'}, 'Invalid OCI layout')
        self.index_bytes = self.tar.extractfile(self.members['index.json']).read()
        self.index = json.loads(self.index_bytes)
        # Buildx exports a layout index, which may wrap the actual image index.
        while len(self.index['manifests']) == 1 and self.index['manifests'][0]['mediaType'] == INDEX:
            descriptor = self.index['manifests'][0]
            self.blob(descriptor)  # Validate the wrapper descriptor before unwrapping.
            self.index_bytes = self.tar.extractfile(self.members['blobs/' + descriptor['digest'].replace(':', '/')]).read()
            self.index = json.loads(self.index_bytes)
        require(self.index.get('schemaVersion') == 2 and self.index.get('mediaType') == INDEX, 'Expected an OCI image index')

    def read(self, name):
        with self.tar.extractfile(self.members[name]) as stream:
            return json.load(stream)

    def blob(self, descriptor):
        name = 'blobs/' + descriptor['digest'].replace(':', '/')
        require(name in self.members and self.members[name].size == descriptor['size'], 'Missing or truncated OCI content')
        return self.read(name)

    @contextlib.contextmanager
    def layout(self):
        """Materialize verified files without restoring tar ownership or modes."""
        with tempfile.TemporaryDirectory() as temp:
            for name, member in self.members.items():
                target = Path(temp) / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with self.tar.extractfile(member) as source, target.open('wb') as output:
                    shutil.copyfileobj(source, output)
            yield temp

    def verify(self, args, platforms):
        runnable = [d for d in self.index['manifests'] if d.get('platform', {}).get('os') == 'linux']
        actual = [d['platform']['architecture'] for d in runnable]
        require(sorted(actual) == sorted(platforms), f'Unexpected platform inventory: {actual}')
        image_digests = {d['digest'] for d in runnable}
        for desc in self.index['manifests']:
            if desc in runnable:
                continue
            annotations = desc.get('annotations', {})
            require(desc.get('platform') == {'os': 'unknown', 'architecture': 'unknown'}
                    and annotations.get('vnd.docker.reference.type') == 'attestation-manifest'
                    and annotations.get('vnd.docker.reference.digest') in image_digests,
                    'Unexpected runtime or unattached attestation in image index')
        for desc in runnable:
            manifest = self.blob(desc)
            config = self.blob(manifest['config'])
            require(config['architecture'] == desc['platform']['architecture'] and config['os'] == 'linux', 'Config CPU mismatch')
            labels = config['config']['Labels']
            for key, value in {
                'org.opencontainers.image.source': getattr(args, 'source', SOURCE),
                'org.opencontainers.image.revision': args.revision,
                'org.opencontainers.image.version': args.version,
                'net.codebelt.csrun.engine.release': args.version,
                'net.codebelt.csrun.engine.sha256': args.engine,
            }.items():
                require(labels.get(key) == value, f'Identity mismatch: {key}')
            require(labels.get('net.codebelt.csrun.sdks') and labels.get('org.opencontainers.image.created'), 'Missing build identity')
            if getattr(args, 'sdks', None):
                require(labels['net.codebelt.csrun.sdks'].split(',') == args.sdks, 'OCI SDK identity differs from release inventory')
            for layer in manifest['layers']:
                name = 'blobs/' + layer['digest'].replace(':', '/')
                require(name in self.members and self.members[name].size == layer['size'], 'Missing image layer')
            predicates = set()
            for att in self.index['manifests']:
                if att.get('annotations', {}).get('vnd.docker.reference.digest') != desc['digest']:
                    continue
                for layer in self.blob(att)['layers']:
                    statement = self.blob(layer)
                    require(any(s.get('digest', {}).get('sha256') == desc['digest'][7:] for s in statement['subject']), 'Attestation subject mismatch')
                    predicate = statement['predicateType']
                    body = statement['predicate']
                    if predicate == 'https://spdx.dev/Document':
                        require(body.get('spdxVersion') and body.get('packages'), 'Empty SBOM')
                    if predicate.startswith('https://slsa.dev/provenance/'):
                        require(body.get('buildType') or body.get('buildDefinition'), 'Empty provenance')
                        parameters = body.get('buildDefinition', {}).get('externalParameters', {}).get('request', {}).get('args')
                        if parameters is None:
                            parameters = body.get('invocation', {}).get('parameters', {}).get('args', {})
                        for key, value in {
                            'build-arg:ENGINE_SHA256': args.engine,
                            'build-arg:ENGINE_VERSION': args.version,
                            'label:org.opencontainers.image.revision': args.revision,
                            'label:org.opencontainers.image.source': getattr(args, 'source', SOURCE),
                            'label:net.codebelt.csrun.sdks': labels['net.codebelt.csrun.sdks'],
                        }.items():
                            require(parameters.get(key) == value, 'Provenance build identity mismatch: ' + key)
                    predicates.add(predicate)
            require('https://spdx.dev/Document' in predicates and any(p.startswith('https://slsa.dev/provenance/') for p in predicates), 'SBOM or provenance missing')
        return runnable


def checksum(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def seal(path):
    Path(str(path) + '.sha256').write_text(checksum(path) + '  ' + Path(path).name + '\n')


def check_seal(path):
    require(Path(str(path) + '.sha256').read_text().split()[0] == checksum(path), 'Archive checksum mismatch')


def add_bytes(tar, name, data):
    import io
    info = tarfile.TarInfo(name)
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))


def check_skopeo():
    """Require native transport when the utility daemon cannot mount client files."""
    if shutil.which('skopeo'):
        return True
    # DOCKER_CONTEXT overrides DOCKER_HOST, just as it does in the Docker CLI.
    host = os.environ.get('DOCKER_HOST') if not os.environ.get('DOCKER_CONTEXT') else None
    if not host:
        host = subprocess.check_output(
            ['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], text=True).strip()
    require(host.startswith(('unix://', 'npipe://')),
            'Native Skopeo is required when the active Docker daemon uses SSH or TCP; '
            'the utility container cannot bind-mount client archives or credentials. '
            'Install skopeo locally or select a local Docker context.')
    return False


def skopeo(arguments, *, capture=False):
    """Use native Skopeo or a versioned utility container, including on Windows."""
    if check_skopeo():
        command = ['skopeo', *arguments]
    else:
        command = ['docker', 'run', '--rm', '--user', '0']
        converted = []
        for position, argument in enumerate(arguments):
            if argument.startswith(('oci-archive:', 'oci:')):
                transport, local_path = argument.split(':', 1)
                path = Path(local_path).resolve()
                mount = '/archive' + str(position)
                command.extend(['--volume', str(path.parent) + ':' + mount])
                argument = transport + ':' + mount + '/' + path.name
            converted.append(argument)
        auth = os.environ.get('REGISTRY_AUTH_FILE')
        if auth:
            command.extend(['--volume', str(Path(auth).resolve()) + ':/auth.json:ro', '--env', 'REGISTRY_AUTH_FILE=/auth.json'])
        command.extend(['quay.io/skopeo/stable:v1.20.0', *converted])
    if capture:
        return subprocess.check_output(command, stderr=subprocess.PIPE)
    subprocess.run(command, check=True)


def loaded_config(args, archive):
    """Check raw config bytes from Docker, whose image ID may be a manifest ID."""
    desc = next(d for d in archive.index['manifests'] if d.get('platform', {}).get('architecture') == args.platform)
    expected = archive.blob(desc)['config']['digest']
    command = ['docker']
    if args.context:
        command += ['--context', args.context]
    command += ['image', 'save', args.image]
    process = subprocess.Popen(command, stdout=subprocess.PIPE)
    found = False
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as saved:
            for member in saved:
                name = member.name.removeprefix('./')
                if name in ('blobs/' + expected.replace(':', '/'), expected[7:] + '.json'):
                    with saved.extractfile(member) as stream:
                        require('sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest() == expected, 'Loaded config bytes changed')
                    found = True
        require(process.wait() == 0 and found, 'Loaded config differs from exported OCI artifact')
        print(expected)
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.kill()
            process.wait()


def merge(args):
    archives = [Archive(p) for p in args.inputs]
    manifests = []
    for archive in archives:
        cpus = [d['platform']['architecture'] for d in archive.index['manifests'] if d.get('platform', {}).get('os') == 'linux']
        require(len(cpus) == 1, 'Expected one tested platform per input')
        archive.verify(args, cpus)
        check_seal(archive.path)
        manifests.extend(archive.index['manifests'])
    index = encoded({'schemaVersion': 2, 'mediaType': INDEX, 'manifests': manifests, 'annotations': {
        'org.opencontainers.image.version': args.version.removeprefix('v'), 'org.opencontainers.image.revision': args.revision}})
    digest = hashlib.sha256(index).hexdigest()
    layout = {'schemaVersion': 2, 'mediaType': INDEX, 'manifests': [{'mediaType': INDEX, 'digest': 'sha256:' + digest,
        'size': len(index), 'annotations': {'org.opencontainers.image.ref.name': args.version.removeprefix('v')}}]}
    with tarfile.open(args.archive, 'w') as output:
        seen = set()
        for archive in archives:
            for name, member in archive.members.items():
                if name.startswith('blobs/') and name not in seen:
                    with archive.tar.extractfile(member) as stream:
                        info = tarfile.TarInfo(name)
                        info.size = member.size
                        output.addfile(info, stream)
                    seen.add(name)
        add_bytes(output, 'blobs/sha256/' + digest, index)
        add_bytes(output, 'index.json', encoded(layout))
        add_bytes(output, 'oci-layout', encoded({'imageLayoutVersion': '1.0.0'}))
    Archive(args.archive).verify(args, [args.platform] if getattr(args, 'platform', None) else ['amd64', 'arm64'])
    seal(args.archive)
    print('Assembled sha256:' + digest)
    return 'sha256:' + digest


def registry_digest(tag):
    """Only an explicit registry missing-manifest response means absence."""
    try:
        raw = skopeo(['inspect', '--raw', 'docker://' + tag], capture=True)
    except subprocess.CalledProcessError as error:
        message = (error.stderr or b'').decode(errors='replace')
        if re.search(r'\b(?:manifest unknown|name unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN)\b', message):
            return None
        raise
    return 'sha256:' + hashlib.sha256(raw).hexdigest()


def preflight(args, *, require_versioned=False):
    check_seal(args.archive)
    archive = Archive(args.archive)
    archive.verify(args, [args.platform] if getattr(args, 'platform', None) else ['amd64', 'arm64'])
    require(re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', args.version or ''), 'Invalid engine release identity')
    require(args.tags and len({t.rsplit(':', 1)[0] for t in args.tags}) == 1, 'SDK aliases must target one repository')
    for tag in args.tags:
        require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', tag) and tag.rsplit(':', 1)[1] != 'latest', 'Invalid publishing destination')
    versioned = getattr(args, 'versioned_tags', None)
    legacy = getattr(args, 'legacy_convenience_only', False) and versioned == []
    require((versioned or legacy) and len(set(args.tags)) == len(args.tags) and len(set(versioned)) == len(versioned)
            and set(versioned) < set(args.tags), 'Both unique tag families are required')
    require(all(t.endswith('-' + args.version) for t in versioned), 'Versioned destination release mismatch')
    digest = 'sha256:' + hashlib.sha256(archive.index_bytes).hexdigest()
    if getattr(args, 'expected', None):
        require(args.expected == digest, 'Saved OCI index digest mismatch')
    for tag in versioned:
        existing = registry_digest(tag)
        require(existing == digest or (existing is None and not require_versioned),
                f'Release-versioned tag conflict: {tag}; expected {digest}, found {existing}; refusing overwrite')
    return archive, digest


def publish(args, *, family='all', before_convenience=None):
    archive, expected_digest = preflight(args, require_versioned=family == 'convenience')
    expected = {d['digest'] for d in archive.index['manifests']}
    digests = set()
    published = []
    convenience = [t for t in args.tags if t not in args.versioned_tags]
    destinations = ([] if family == 'convenience' else list(args.versioned_tags)) + ([] if family == 'versioned' else convenience)
    # Skopeo's archive transport restores tar ownership, which fails rootless.
    with archive.layout() as layout:
        for tag in destinations:
            if tag in convenience and tag == convenience[0] and before_convenience:
                before_convenience()
            # Recheck immediately before each write. Registry policy is still needed
            # to close the check/write race against external or concurrent writers.
            existing = registry_digest(tag) if tag in args.versioned_tags else None
            require(existing is None or existing == expected_digest, f'Release-versioned tag conflict: {tag}; refusing overwrite')
            if existing is None:
                skopeo(['copy', '--all', '--preserve-digests', 'oci:' + layout, 'docker://' + tag])
            raw = skopeo(['inspect', '--raw', 'docker://' + tag], capture=True)
            index = json.loads(raw)
            require({d['digest'] for d in index['manifests']} == expected, 'Registry platform/attestation identities changed')
            digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
            require(digest == expected_digest, 'Registry OCI index digest changed')
            digests.add(digest)
            with tempfile.TemporaryDirectory() as temp:
                downloaded = str(Path(temp) / 'registry.tar')
                skopeo(['copy', '--all', '--preserve-digests', 'docker://' + tag.rsplit(':', 1)[0] + '@' + digest, 'oci-archive:' + downloaded])
                Archive(downloaded).verify(args, [args.platform] if getattr(args, 'platform', None) else ['amd64', 'arm64'])
            print(tag + '@' + digest)
            published.append({'tag': tag, 'digest': digest})
    require(len(digests) == 1, 'SDK aliases resolved to different indexes')
    Path(str(args.archive) + '.published.json').write_bytes(encoded(published))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as stream:
            stream.write('\nPublished tags: ' + ', '.join(destinations) + '\n\nDigest: ' + next(iter(digests)) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['verify', 'merge', 'publish', 'preflight', 'config', 'loaded-config', 'check-skopeo'])
    parser.add_argument('archive', nargs='?')
    parser.add_argument('--version')
    parser.add_argument('--revision')
    parser.add_argument('--engine')
    parser.add_argument('--source', default=SOURCE)
    parser.add_argument('--platform', choices=['amd64', 'arm64'])
    parser.add_argument('--expected')
    parser.add_argument('--image')
    parser.add_argument('--context')
    parser.add_argument('--tags', nargs='+')
    parser.add_argument('--versioned-tags', nargs='+')
    parser.add_argument('inputs', nargs='*')
    args = parser.parse_intermixed_args()
    if args.command == 'check-skopeo':
        check_skopeo()
        return
    if not args.archive:
        parser.error('archive is required')
    if args.command == 'merge':
        merge(args)
    elif args.command == 'publish':
        publish(args)
    elif args.command == 'preflight':
        preflight(args)
    else:
        archive = Archive(args.archive)
        if args.command == 'loaded-config':
            loaded_config(args, archive)
        elif args.command == 'config':
            desc = next(d for d in archive.index['manifests'] if d.get('platform', {}).get('architecture') == args.platform)
            require(archive.blob(desc)['config']['digest'] == args.expected, 'Loaded config differs from tested archive')
        else:
            archive.verify(args, [args.platform] if args.platform else ['amd64', 'arm64'])
            seal(args.archive)


if __name__ == '__main__':
    main()
