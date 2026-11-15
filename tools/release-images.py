"""Release artifact lifecycle. No image build commands belong in this file."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.request
from types import SimpleNamespace
import oci


def gh(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint]))


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def identity(meta):
    return SimpleNamespace(version=meta['EngineVersion'], revision=meta['SourceCommit'], engine=meta['EngineSha256'], sdks=meta['SdkVersions'])


def assemble(variant):
    root = Path('inputs')
    metadata = [json.loads(p.read_text(encoding='utf-8-sig')) for p in root.glob('*/csrun-image.json')]
    oci.require(len(metadata) == 2, 'Both native verification records required')
    first = dict(metadata[0])
    for meta in metadata:
        oci.require(meta['NativeVerified'] is True and all(meta[k] == first[k] for k in ('SdkVersions', 'EngineVersion', 'EngineSha256', 'SourceCommit', 'Tags')), 'Native verification identity mismatch')
    oci.require({m['Platforms'][0] for m in metadata} == {'linux/amd64', 'linux/arm64'}, 'Both native CPUs required')
    oci.require(first['SourceCommit'] == os.environ['GITHUB_SHA'] and first['EngineVersion'] == os.environ['GITHUB_REF_NAME'], 'Release source mismatch')
    Path('out').mkdir(exist_ok=True)
    archives = sorted(str(p) for p in root.glob('*/*.tar'))
    oci.require(len(archives) == 2, 'Exactly two native OCI inputs required')
    for archive_path in archives:
        cpu = 'arm64' if archive_path.endswith('.arm64.tar') else 'amd64'
        record = next(m for m in metadata if m['Platforms'] == ['linux/' + cpu])
        saved = oci.Archive(archive_path)
        runnable = saved.verify(identity(first), [cpu])[0]
        oci.require(saved.blob(runnable)['config']['digest'] == record['ConfigDigest'], 'Native test record does not identify the assembled image config')
    args = identity(first)
    args.inputs = archives
    args.archive = 'out/image.tar'
    first['OciIndexDigest'] = oci.merge(args)
    first['Verification'] = metadata
    first['ReleaseRunId'] = os.environ['GITHUB_RUN_ID']
    first['ReleaseRunAttempt'] = os.environ['GITHUB_RUN_ATTEMPT']
    first['Variant'] = variant
    write('out/release.json', first)
    summary(first)


def split(variant):
    Path('assets').mkdir(exist_ok=True)
    pieces = []
    with open('out/image.tar', 'rb') as source:
        number = 0
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            path = Path(f'assets/csrun-{variant}.oci.part{number:03}')
            size = 0
            with path.open('wb') as target:
                while block:
                    target.write(block)
                    size += len(block)
                    if size >= 1024 ** 3:
                        break
                    block = source.read(1024 * 1024)
            pieces.append({'name': path.name, 'sha256': oci.checksum(path), 'size': path.stat().st_size})
            number += 1
    meta = json.loads(Path('out/release.json').read_text())
    meta['Pieces'] = pieces
    meta['ArchiveSha256'] = oci.checksum('out/image.tar')
    write(f'assets/csrun-{variant}.json', meta)


def resolve():
    repo = os.environ['GITHUB_REPOSITORY']
    oci.require(repo == 'codebeltnet/csrun', 'Production deployment is restricted to codebeltnet/csrun')
    tag = os.environ['RELEASE_TAG']
    oci.require(re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', tag), 'Unexpected release tag')
    event = os.environ['GITHUB_EVENT_NAME']
    if event == 'workflow_dispatch':
        oci.require(os.environ['GITHUB_REF'] == 'refs/heads/main', 'Recovery must be dispatched from main')
    else:
        data = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        oci.require(event == 'release' and data['action'] == 'published' and data['release']['tag_name'] == tag, 'Unexpected release event')
    release = gh(f'repos/{repo}/releases/tags/{tag}')
    latest = gh(f'repos/{repo}/releases/latest')
    oci.require(not release['draft'] and not release['prerelease'] and release['published_at'] and latest['id'] == release['id'], 'Requested release must be the latest published stable release')
    if event == 'release':
        oci.require(data['release']['id'] == release['id'], 'Release ID changed')
    # Follow annotated tags through GitHub's commit endpoint.
    commit = gh(f'repos/{repo}/commits/{tag}')['sha']
    comparison = gh(f'repos/{repo}/compare/{commit}...main')
    oci.require(comparison['status'] in ('ahead', 'identical'), 'Release source is not in main history')
    assets = {a['name']: a for a in release['assets']}
    asset = assets['csrun.ps1']
    Path('resolved').mkdir(exist_ok=True)
    engine = Path('resolved/csrun.ps1')
    # The one and only moving engine download. All subsequent jobs consume identity.json.
    urllib.request.urlretrieve('https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1', engine)
    digest = oci.checksum(engine)
    oci.require(asset.get('digest') == 'sha256:' + digest and asset['size'] == engine.stat().st_size, 'Latest script checksum or release identity changed')
    write('resolved/identity.json', {'tag': tag, 'releaseId': release['id'], 'sha': commit, 'engine': digest, 'assets': assets})
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write('sha=' + commit + '\n')


def download(asset, destination):
    oci.require(asset.get('digest', '').startswith('sha256:'), 'Release asset has no authoritative digest')
    urllib.request.urlretrieve(asset['browser_download_url'], destination)
    oci.require('sha256:' + oci.checksum(destination) == asset['digest'] and Path(destination).stat().st_size == asset['size'], 'Release asset checksum mismatch')


def restore(variant, versions=None):
    resolved = json.loads(Path('resolved/identity.json').read_text())
    Path('out').mkdir(exist_ok=True)
    download(resolved['assets'][f'csrun-{variant}.json'], 'out/release.json')
    meta = json.loads(Path('out/release.json').read_text())
    oci.require(meta['EngineVersion'] == resolved['tag'] and meta['SourceCommit'] == resolved['sha'] and meta['EngineSha256'] == resolved['engine'] and meta['Variant'] == variant, 'Artifact does not represent the resolved latest engine and release')
    run = gh(f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{meta['ReleaseRunId']}")
    oci.require(run['event'] == 'push' and run['path'] == '.github/workflows/release.yml' and run['head_sha'] == resolved['sha'] and run['head_branch'] == resolved['tag'] and run['run_attempt'] == int(meta['ReleaseRunAttempt']) and run['conclusion'] == 'success', 'Authoritative tag release run did not succeed')
    if versions is not None:
        oci.require(meta['SdkVersions'] == versions, 'Requested exact SDK versions differ from the saved release; never rebuild on recovery')
    records = meta['Verification']
    oci.require(len(records) == 2 and {r['Platforms'][0] for r in records} == {'linux/amd64', 'linux/arm64'}, 'Both native verifications required')
    for record in records:
        oci.require(record['NativeVerified'] is True and all(record[k] == meta[k] for k in ('SdkVersions', 'EngineSha256', 'EngineVersion', 'SourceCommit', 'Tags')), 'Native result identity mismatch')
    # Recompute aliases using the same module as the manual interface, without external resolution.
    command = "Import-Module $env:CSRUN_MODULE -Force; $p = BuildAndPublish -SdkVersion ($env:SDK_VERSIONS.Split(',')) -WhatIf -PassThru; $p.Tags | ConvertTo-Json -Compress"
    output = subprocess.check_output(['pwsh', '-NoProfile', '-Command', command], env={**os.environ, 'SDK_VERSIONS': ','.join(meta['SdkVersions']), 'CSRUN_MODULE': str(Path(__file__).resolve().parent.parent / 'BuildAndPublish.psm1')}, text=True)
    tags = json.loads(output.strip().splitlines()[-1])
    oci.require(tags == meta['Tags'], 'Publishing aliases differ from version contract')
    with open('out/image.tar', 'wb') as archive:
        for part in meta['Pieces']:
            oci.require(re.fullmatch(r'csrun-' + re.escape(variant) + r'\.oci\.part\d{3}', part['name']), 'Invalid piece identity')
            download(resolved['assets'][part['name']], 'out/part')
            oci.require(oci.checksum('out/part') == part['sha256'] and Path('out/part').stat().st_size == part['size'], 'Piece differs from verified release record')
            with open('out/part', 'rb') as stream:
                shutil.copyfileobj(stream, archive)
            Path('out/part').unlink()
    oci.require(oci.checksum('out/image.tar') == meta['ArchiveSha256'], 'Reassembled archive checksum mismatch')
    oci.Archive('out/image.tar').verify(identity(meta), ['amd64', 'arm64'])
    oci.seal('out/image.tar')
    summary(meta)


def summary(meta):
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a') as stream:
            stream.write(f"\nSDK image {meta['SdkVersions']}: [GitHub Release {meta['EngineVersion']}](https://github.com/codebeltnet/csrun/releases/tag/{meta['EngineVersion']}) at {meta['SourceCommit']}\n\ncsrun SHA256: {meta['EngineSha256']}\n\n")
            stream.write(f"SDK aliases: {', '.join(meta['Tags'])}\n\nVerified OCI index: {meta.get('OciIndexDigest', 'platform build')}\n\n")
            for item in meta.get('Verification', [meta]):
                stream.write(f"- {item['Platforms']}: native runtime suite passed; SDK inventory {item['SdkVersions']}; image size {item['SizeBytes']} bytes\n")
                if item.get('OciArchiveBytes'):
                    stream.write(f"  OCI archive: {item['OciArchiveBytes']} bytes (compressed layers, manifests and attestations).\n")


def publish():
    resolved = json.loads(Path('resolved/identity.json').read_text())
    latest = gh(f"repos/{os.environ['GITHUB_REPOSITORY']}/releases/latest")
    oci.require(latest['id'] == resolved['releaseId'] and latest['tag_name'] == resolved['tag'] and not latest['draft'], 'Latest release changed after verification; refusing stale SDK alias promotion')
    meta = json.loads(Path('out/release.json').read_text())
    args = identity(meta)
    args.archive = 'out/image.tar'
    args.tags = meta['Tags']
    oci.publish(args)


if __name__ == '__main__':
    command = sys.argv[1]
    if command in ('assemble', 'split', 'restore'):
        globals()[command](sys.argv[2])
    else:
        globals()[command]()
