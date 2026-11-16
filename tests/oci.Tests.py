"""Fail-closed artifact tests; no Docker, credentials, network or third-party packages."""
import hashlib
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import shutil
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import oci
spec = importlib.util.spec_from_file_location('release_images', Path(__file__).resolve().parents[1] / 'tools/release-images.py')
release_images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_images)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.args = SimpleNamespace(version='v0.2.0', revision='a' * 40, engine='b' * 64, sdks=['11.0.100'])

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, cpu, *, missing=None, subject=None, engine=None, provenance_engine=None, source=oci.SOURCE):
        blobs = {}

        def blob(value, media='application/vnd.oci.image.manifest.v1+json'):
            data = oci.encoded(value)
            digest = hashlib.sha256(data).hexdigest()
            blobs['blobs/sha256/' + digest] = data
            return {'digest': 'sha256:' + digest, 'size': len(data), 'mediaType': media}

        config = blob({'architecture': cpu, 'os': 'linux', 'config': {'Labels': {
            'org.opencontainers.image.source': source,
            'org.opencontainers.image.version': self.args.version,
            'org.opencontainers.image.revision': self.args.revision,
            'org.opencontainers.image.created': '2026-11-15T12:00:00Z',
            'net.codebelt.csrun.engine.release': self.args.version,
            'net.codebelt.csrun.engine.sha256': engine or self.args.engine,
            'net.codebelt.csrun.sdks': ','.join(self.args.sdks)}}})
        image = blob({'config': config, 'layers': []})
        image['platform'] = {'os': 'linux', 'architecture': cpu}
        layers = []
        for predicate, body in [('https://spdx.dev/Document', {'spdxVersion': 'SPDX-2.3', 'packages': [{}]}),
                                ('https://slsa.dev/provenance/v0.2', {'buildType': 'https://mobyproject.org/buildkit@v1', 'invocation': {'parameters': {'args': {
                                    'build-arg:ENGINE_SHA256': provenance_engine or self.args.engine,
                                    'build-arg:ENGINE_VERSION': self.args.version,
                                    'label:org.opencontainers.image.revision': self.args.revision,
                                    'label:org.opencontainers.image.source': source,
                                    'label:net.codebelt.csrun.sdks': ','.join(self.args.sdks)}}}})]:
            if predicate == missing:
                continue
            subjects = [] if subject is False else [{'digest': {'sha256': subject or image['digest'][7:]}}]
            layers.append(blob({'predicateType': predicate, 'predicate': body, 'subject': subjects}))
        att = blob({'layers': layers})
        att['platform'] = {'os': 'unknown', 'architecture': 'unknown'}
        att['annotations'] = {'vnd.docker.reference.digest': image['digest'], 'vnd.docker.reference.type': 'attestation-manifest'}
        path = self.root / (cpu + '.tar')
        with tarfile.open(path, 'w') as tar:
            for name, data in blobs.items():
                oci.add_bytes(tar, name, data)
            oci.add_bytes(tar, 'index.json', oci.encoded({'schemaVersion': 2, 'mediaType': oci.INDEX, 'manifests': [image, att]}))
            oci.add_bytes(tar, 'oci-layout', oci.encoded({'imageLayoutVersion': '1.0.0'}))
        oci.seal(path)
        return path, image, config

    def test_native_archive_identity_and_attestations(self):
        path, image, config = self.fixture('amd64')
        self.assertEqual(oci.Archive(path).verify(self.args, ['amd64']), [image])

    def test_fork_source_identity_is_supported_without_ci(self):
        self.args.source = 'https://github.com/fork-owner/csrun'
        path, image, _ = self.fixture('amd64', source=self.args.source)
        self.assertEqual(oci.Archive(path).verify(self.args, ['amd64']), [image])

    def test_arm64_cannot_be_replaced_by_amd64(self):
        path, _, _ = self.fixture('amd64')
        with self.assertRaisesRegex(ValueError, 'platform inventory'):
            oci.Archive(path).verify(self.args, ['arm64'])

    def test_extra_untested_runtime_platform_is_rejected(self):
        path, _, _ = self.fixture('amd64')
        archive = oci.Archive(path)
        archive.index['manifests'].append({'platform': {'os': 'windows', 'architecture': 'amd64'}})
        with self.assertRaisesRegex(ValueError, 'Unexpected runtime'):
            archive.verify(self.args, ['amd64'])

    def test_missing_sbom_blocks_verification(self):
        path, _, _ = self.fixture('amd64', missing='https://spdx.dev/Document')
        with self.assertRaisesRegex(ValueError, 'SBOM or provenance missing'):
            oci.Archive(path).verify(self.args, ['amd64'])

    def test_wrong_attestation_subject_blocks_verification(self):
        path, _, _ = self.fixture('amd64', subject='c' * 64)
        with self.assertRaisesRegex(ValueError, 'subject mismatch'):
            oci.Archive(path).verify(self.args, ['amd64'])

    def test_empty_buildkit_subject_is_rejected(self):
        path, _, _ = self.fixture('amd64', subject=False)
        with self.assertRaisesRegex(ValueError, 'subject mismatch'):
            oci.Archive(path).verify(self.args, ['amd64'])

    def test_wrong_engine_blocks_verification(self):
        path, _, _ = self.fixture('amd64', engine='c' * 64)
        with self.assertRaisesRegex(ValueError, 'Identity mismatch'):
            oci.Archive(path).verify(self.args, ['amd64'])

    def test_provenance_for_a_different_engine_is_rejected(self):
        path, _, _ = self.fixture('amd64', provenance_engine='c' * 64)
        with self.assertRaisesRegex(ValueError, 'Provenance build identity mismatch'):
            oci.Archive(path).verify(self.args, ['amd64'])

    def test_sdk_labels_must_match_release_record(self):
        path, _, _ = self.fixture('amd64')
        self.args.sdks = ['10.0.404']
        with self.assertRaisesRegex(ValueError, 'SDK identity'):
            oci.Archive(path).verify(self.args, ['amd64'])

    def test_merge_preserves_tested_child_manifests_and_configs(self):
        amd, image1, config1 = self.fixture('amd64')
        arm, image2, config2 = self.fixture('arm64')
        self.args.archive = str(self.root / 'combined.tar')
        self.args.inputs = [str(amd), str(arm)]
        oci.merge(self.args)
        archive = oci.Archive(self.args.archive)
        images = archive.verify(self.args, ['amd64', 'arm64'])
        self.assertEqual([image1, image2], images)
        self.assertEqual([config1, config2], [archive.blob(d)['config'] for d in images])
        oci.check_seal(self.args.archive)

    def test_corrupted_transferred_archive_is_rejected(self):
        path, _, _ = self.fixture('amd64')
        with path.open('ab') as stream:
            stream.write(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            oci.check_seal(path)

    def test_corrupted_blob_is_rejected_even_if_archive_resealed(self):
        path, _, _ = self.fixture('amd64')
        data = path.read_bytes().replace(b'11.0.100', b'11.0.999')
        path.write_bytes(data)
        oci.seal(path)
        with self.assertRaisesRegex(ValueError, 'Corrupt OCI blob'):
            oci.Archive(path)

    def test_missing_native_platform_blocks_assembly(self):
        path, _, _ = self.fixture('amd64')
        self.args.archive = str(self.root / 'combined.tar')
        self.args.inputs = [str(path)]
        with self.assertRaisesRegex(ValueError, 'platform inventory'):
            oci.merge(self.args)

    def test_release_assembly_split_and_recovery_reuse_the_tested_bytes(self):
        convenience = ['docker.io/codebeltnet/csrun:11.0.100', 'docker.io/codebeltnet/csrun:11.0', 'docker.io/codebeltnet/csrun:11']
        versioned = [t + '-v0.2.0' for t in convenience]
        tags = convenience + versioned
        for cpu in ('amd64', 'arm64'):
            path, _, config = self.fixture(cpu)
            target = self.root / 'inputs' / cpu
            target.mkdir(parents=True)
            archive = target / ('image.' + cpu + '.tar')
            shutil.copyfile(path, archive)
            oci.seal(archive)
            (target / 'csrun-image.json').write_text(json.dumps({
                'NativeVerified': True, 'SdkVersions': ['11.0.100'], 'EngineVersion': self.args.version,
                'EngineSha256': self.args.engine, 'SourceCommit': self.args.revision, 'Tags': tags,
                'ConvenienceTags': convenience, 'VersionedTags': versioned,
                'Platforms': ['linux/' + cpu], 'ConfigDigest': config['digest'], 'SizeBytes': 1234}))
        with contextlib.chdir(self.root), patch.dict('os.environ', {
            'GITHUB_SHA': self.args.revision, 'GITHUB_REF_NAME': self.args.version,
            'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_REPOSITORY': 'codebeltnet/csrun'}):
            release_images.assemble('11')
            original = oci.checksum('out/image.tar')
            release_images.split('11')
            Path('resolved').mkdir()
            assets = {p.name: {'browser_download_url': p.resolve().as_uri(), 'size': p.stat().st_size,
                              'digest': 'sha256:' + oci.checksum(p)} for p in Path('assets').iterdir()}
            Path('resolved/identity.json').write_text(json.dumps({
                'tag': self.args.version, 'sha': self.args.revision, 'engine': self.args.engine, 'assets': assets}))
            run = {'event': 'push', 'path': '.github/workflows/release.yml', 'head_sha': self.args.revision,
                   'head_branch': self.args.version, 'run_attempt': 1, 'conclusion': 'success'}
            def get_run(endpoint):
                if endpoint == 'repos/codebeltnet/csrun/actions/runs/123/attempts/1':
                    return run
                if endpoint == 'repos/codebeltnet/csrun/actions/runs/123':
                    return {**run, 'run_attempt': 2, 'conclusion': 'failure'}
                self.fail('Unexpected GitHub endpoint: ' + endpoint)

            with patch.object(release_images, 'gh', side_effect=get_run):
                release_images.restore('11')
                for changes in ({'conclusion': 'failure'}, {'run_attempt': 2}, {'head_sha': 'c' * 40}, {'event': 'workflow_dispatch'}, {'path': '.github/workflows/other.yml'}, {'head_branch': 'main'}):
                    with self.subTest(changes=changes), patch.object(release_images, 'gh', return_value={**run, **changes}):
                        with self.assertRaisesRegex(ValueError, 'Authoritative tag release run'):
                            release_images.restore('11')
            self.assertEqual(original, oci.checksum('out/image.tar'))

    def test_latest_alias_is_rejected_before_any_registry_upload(self):
        amd, _, _ = self.fixture('amd64')
        arm, _, _ = self.fixture('arm64')
        self.args.archive = str(self.root / 'combined.tar')
        self.args.inputs = [str(amd), str(arm)]
        self.args.tags = ['docker.io/fork/csrun:11', 'docker.io/fork/csrun:latest']
        oci.merge(self.args)
        with patch.object(oci, 'skopeo') as transfer:
            with self.assertRaisesRegex(ValueError, 'Invalid publishing destination'):
                oci.publish(self.args)
            transfer.assert_not_called()

    def test_publish_uses_owner_independent_layout_and_preserves_verified_bytes(self):
        amd, _, _ = self.fixture('amd64')
        arm, _, _ = self.fixture('arm64')
        self.args.archive = str(self.root / 'combined.tar')
        self.args.inputs = [str(amd), str(arm)]
        self.args.tags = ['docker.io/fork/csrun:11.0.100', 'docker.io/fork/csrun:11']
        self.args.versioned_tags = ['docker.io/fork/csrun:11.0.100-v0.2.0', 'docker.io/fork/csrun:11-v0.2.0']
        self.args.tags += self.args.versioned_tags
        oci.merge(self.args)
        original = oci.checksum(self.args.archive)
        archive = oci.Archive(self.args.archive)
        layouts = []
        present = set()

        def transfer(arguments, *, capture=False):
            if arguments[0] == 'inspect':
                if arguments[-1] not in present:
                    raise subprocess.CalledProcessError(1, arguments, stderr=b'manifest unknown')
                return oci.encoded(archive.index)
            self.assertEqual(arguments[:3], ['copy', '--all', '--preserve-digests'])
            if arguments[3].startswith('docker://'):
                shutil.copyfile(self.args.archive, arguments[4].removeprefix('oci-archive:'))
                return
            self.assertTrue(arguments[3].startswith('oci:'))
            layout = Path(arguments[3].removeprefix('oci:'))
            layouts.append(layout)
            present.add(arguments[-1])
            self.assertEqual({p.relative_to(layout).as_posix() for p in layout.rglob('*') if p.is_file()}, set(archive.members))
            for name, member in archive.members.items():
                with archive.tar.extractfile(member) as source:
                    self.assertEqual((layout / name).read_bytes(), source.read())

        with patch.object(oci, 'skopeo', side_effect=transfer), patch.object(oci.tarfile.TarFile, 'chown', side_effect=PermissionError('ownership restoration forbidden')):
            oci.publish(self.args)
        archive.tar.close()
        self.assertEqual(len(layouts), 4)
        self.assertEqual(layouts[0], layouts[1])
        self.assertFalse(layouts[0].exists())
        self.assertEqual(original, oci.checksum(self.args.archive))
        self.assertEqual(len(json.loads(Path(self.args.archive + '.published.json').read_text())), 4)

    def test_publish_removes_temporary_layout_after_transfer_failure(self):
        path, _, _ = self.fixture('amd64')
        self.args.archive = str(path)
        self.args.platform = 'amd64'
        self.args.tags = ['docker.io/fork/csrun:11']
        self.args.versioned_tags = ['docker.io/fork/csrun:11-v0.2.0']
        self.args.tags += self.args.versioned_tags
        layouts = []

        def fail_transfer(arguments):
            layouts.append(Path(arguments[3].removeprefix('oci:')))
            self.assertTrue(layouts[-1].is_dir())
            raise RuntimeError('transfer failed')

        with patch.object(oci, 'registry_digest', return_value=None), patch.object(oci, 'skopeo', side_effect=fail_transfer):
            with self.assertRaisesRegex(RuntimeError, 'transfer failed'):
                oci.publish(self.args)
        self.assertFalse(layouts[0].exists())
        self.assertFalse(Path(str(path) + '.published.json').exists())

    def publication(self):
        amd, _, _ = self.fixture('amd64')
        arm, _, _ = self.fixture('arm64')
        self.args.archive = str(self.root / 'combined.tar')
        self.args.inputs = [str(amd), str(arm)]
        self.args.tags = ['localhost:5000/fork/csrun:11.0.100', 'localhost:5000/fork/csrun:11']
        self.args.versioned_tags = ['localhost:5000/fork/csrun:11.0.100-v0.2.0', 'localhost:5000/fork/csrun:11-v0.2.0']
        self.args.tags += self.args.versioned_tags
        digest = oci.merge(self.args)
        archive = oci.Archive(self.args.archive)
        raw = archive.index_bytes
        archive.tar.close()
        return digest, raw

    def test_conflicting_historical_alias_blocks_all_writes(self):
        digest, _ = self.publication()
        for conflict in self.args.versioned_tags:
            with self.subTest(conflict=conflict), patch.object(oci, 'registry_digest', side_effect=lambda tag: 'sha256:' + 'c' * 64 if tag == conflict else digest), patch.object(oci, 'skopeo') as transfer:
                with self.assertRaisesRegex(ValueError, 'Release-versioned tag conflict.*refusing overwrite'):
                    oci.publish(self.args)
                transfer.assert_not_called()

    def test_absent_matching_and_partial_retry_publish_one_index(self):
        digest, raw = self.publication()
        present = {}
        writes = []
        fail = [True]

        def transfer(arguments, *, capture=False):
            if arguments[0] == 'inspect':
                tag = arguments[-1].removeprefix('docker://')
                if tag not in present:
                    raise subprocess.CalledProcessError(1, arguments, stderr=b'MANIFEST_UNKNOWN')
                return present[tag]
            if arguments[3].startswith('docker://'):
                shutil.copyfile(self.args.archive, arguments[4].removeprefix('oci-archive:'))
            else:
                tag = arguments[-1].removeprefix('docker://')
                if tag == self.args.versioned_tags[1] and fail[0]:
                    fail[0] = False
                    raise RuntimeError('interrupted publication')
                present[tag] = raw
                writes.append(tag)

        with patch.object(oci, 'skopeo', side_effect=transfer):
            with self.assertRaisesRegex(RuntimeError, 'interrupted publication'):
                oci.publish(self.args)
            self.assertEqual(writes, self.args.versioned_tags[:1])
            oci.publish(self.args)
            self.assertEqual(writes, self.args.versioned_tags + self.args.tags[:2])
            previous = list(writes)
            def stale():
                raise ValueError('refusing stale SDK alias promotion')
            with self.assertRaisesRegex(ValueError, 'refusing stale'):
                oci.publish(self.args, before_convenience=stale)
            self.assertEqual(writes, previous)
            oci.publish(self.args)
            self.assertEqual(writes.count(self.args.versioned_tags[0]), 1)
            self.assertEqual(writes.count(self.args.versioned_tags[1]), 1)
        records = json.loads(Path(self.args.archive + '.published.json').read_text())
        self.assertEqual({r['digest'] for r in records}, {digest})
        self.assertEqual({r['tag'] for r in records}, set(self.args.tags))

    def test_concurrent_conflict_on_recheck_never_overwrites(self):
        self.publication()
        with patch.object(oci, 'registry_digest', side_effect=[None, None, 'sha256:' + 'c' * 64]), patch.object(oci, 'skopeo') as transfer:
            with self.assertRaisesRegex(ValueError, 'refusing overwrite'):
                oci.publish(self.args)
            transfer.assert_not_called()

    def test_same_children_with_different_index_bytes_are_rejected(self):
        _, raw = self.publication()
        with patch.object(oci, 'registry_digest', return_value=None), patch.object(oci, 'skopeo', return_value=raw + b'\n'):
            with self.assertRaisesRegex(ValueError, 'OCI index digest changed'):
                oci.publish(self.args)

    def test_duplicate_or_missing_versioned_families_are_rejected(self):
        self.publication()
        for versioned in ([], self.args.versioned_tags * 2, ['localhost:5000/fork/csrun:11-v0.1.0']):
            with self.subTest(versioned=versioned), patch.object(oci, 'skopeo') as transfer:
                args = SimpleNamespace(**{**vars(self.args), 'versioned_tags': versioned})
                with self.assertRaises(ValueError):
                    oci.publish(args)
                transfer.assert_not_called()

    def test_convenience_phase_requires_all_versioned_aliases_to_exist(self):
        self.publication()
        with patch.object(oci, 'registry_digest', return_value=None), patch.object(oci, 'skopeo') as transfer:
            with self.assertRaisesRegex(ValueError, 'refusing overwrite'):
                oci.publish(self.args, family='convenience')
            transfer.assert_not_called()

    def test_historical_recovery_keeps_original_convenience_only_contract(self):
        _, raw = self.publication()
        self.args.tags = self.args.tags[:2]
        self.args.versioned_tags = []
        self.args.legacy_convenience_only = True
        writes = []
        def transfer(arguments, *, capture=False):
            if arguments[0] == 'inspect':
                return raw
            if arguments[3].startswith('docker://'):
                shutil.copyfile(self.args.archive, arguments[4].removeprefix('oci-archive:'))
            else:
                writes.append(arguments[-1].removeprefix('docker://'))
        with patch.object(oci, 'skopeo', side_effect=transfer):
            oci.publish(self.args)
        self.assertEqual(writes, self.args.tags)

    def test_all_six_aliases_share_exact_index_for_each_sdk_variant(self):
        for sdks, aliases in ((['10.0.404'], ['10.0.404', '10.0', '10']),
                              (['11.0.100'], ['11.0.100', '11.0', '11']),
                              (['10.0.404', '11.0.100'], ['10.0.404-11.0.100', '10.0-11.0', '10-11'])):
            with self.subTest(sdks=sdks):
                self.args.sdks = sdks
                digest, raw = self.publication()
                convenience = ['registry.example/fork/csrun:' + tag for tag in aliases]
                self.args.versioned_tags = [tag + '-v0.2.0' for tag in convenience]
                self.args.tags = convenience + self.args.versioned_tags
                def transfer(arguments, *, capture=False):
                    if arguments[0] == 'inspect':
                        return raw
                    if arguments[3].startswith('docker://'):
                        shutil.copyfile(self.args.archive, arguments[4].removeprefix('oci-archive:'))
                with patch.object(oci, 'registry_digest', return_value=None), patch.object(oci, 'skopeo', side_effect=transfer):
                    oci.publish(self.args)
                records = json.loads(Path(self.args.archive + '.published.json').read_text())
                self.assertEqual(len(records), 6)
                self.assertEqual({r['tag'] for r in records}, set(self.args.tags))
                self.assertEqual({r['digest'] for r in records}, {digest})


class PowerShellInvocationTests(unittest.TestCase):
    def test_publishing_contract_from_parent_script_matches_ci_invocation(self):
        script = Path(__file__).resolve().with_name('BuildAndPublish.Tests.ps1')
        result = subprocess.run(['pwsh', '-NoProfile', '-Command', '& $env:CSRUN_PUBLISHING_TESTS'],
                                env={**os.environ, 'CSRUN_PUBLISHING_TESTS': str(script)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('14 passed, 0 failed', result.stdout)


class SkopeoTransportTests(unittest.TestCase):
    def test_captured_registry_errors_keep_diagnostics_in_exception_text(self):
        for operation in (lambda: oci.registry_digest('registry/image:11'),
                          lambda: oci.skopeo(['inspect', '--raw', 'docker://registry/image:11'], capture=True)):
            for message in (b'unauthorized: login expired', b'denied: access forbidden', b'connection refused'):
                error = subprocess.CalledProcessError(23, ['skopeo', 'inspect'], output=b'', stderr=message)
                with self.subTest(message=message, operation=operation), patch.object(oci, 'check_skopeo', return_value=True), patch.object(oci.subprocess, 'check_output', side_effect=error):
                    with self.assertRaises(subprocess.CalledProcessError) as caught:
                        operation()
                    self.assertIn(message.decode(), str(caught.exception))
                    self.assertEqual(caught.exception.returncode, 23)
                    self.assertEqual(caught.exception.stderr, message)

    def test_registry_absence_is_distinct_from_auth_network_and_server_failures(self):
        for message in (b'manifest unknown', b'MANIFEST_UNKNOWN', b'name unknown'):
            with patch.object(oci, 'check_skopeo', return_value=True), patch.object(oci.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'inspect', stderr=message)):
                self.assertIsNone(oci.registry_digest('registry/image:11'))
        for message in (b'unauthorized', b'connection refused', b'500 Internal Server Error', b'404 proxy not found'):
            with patch.object(oci, 'skopeo', side_effect=subprocess.CalledProcessError(1, 'inspect', stderr=message)):
                with self.assertRaises(subprocess.CalledProcessError):
                    oci.registry_digest('registry/image:11')
    def test_local_container_mounts_oci_layout_directory(self):
        with patch.dict('os.environ', {'DOCKER_HOST': 'unix:///var/run/docker.sock'}, clear=True), patch.object(oci.shutil, 'which', return_value=None), patch.object(oci.subprocess, 'run') as execute:
            oci.skopeo(['copy', '--all', '--preserve-digests', 'oci:client-layout', 'docker://registry/image:11'])
            command = execute.call_args.args[0]
            self.assertIn('oci:/archive3/client-layout', command)
            self.assertIn(str(Path('client-layout').resolve().parent) + ':/archive3', command)

    def test_native_skopeo_does_not_need_a_local_docker_daemon(self):
        with patch.dict('os.environ', {'DOCKER_HOST': 'ssh://builder'}, clear=True), patch.object(oci.shutil, 'which', return_value='/usr/bin/skopeo'), patch.object(oci.subprocess, 'run') as execute, patch.object(oci.subprocess, 'check_output') as inspect:
            oci.skopeo(['copy', 'oci-archive:client.tar', 'docker://registry/image:11'])
            execute.assert_called_once_with(['skopeo', 'copy', 'oci-archive:client.tar', 'docker://registry/image:11'], check=True)
            inspect.assert_not_called()

    def test_remote_environment_host_is_rejected_before_container_launch(self):
        for host in ('ssh://builder', 'tcp://builder:2376', 'tcp://localhost:2375'):
            with self.subTest(host=host), patch.dict('os.environ', {'DOCKER_HOST': host}, clear=True), patch.object(oci.shutil, 'which', return_value=None), patch.object(oci.subprocess, 'run') as execute, patch.object(oci.subprocess, 'check_output') as inspect:
                with self.assertRaisesRegex(ValueError, 'Native Skopeo is required'):
                    oci.skopeo(['copy', 'oci-archive:client.tar', 'docker://registry/image:11'])
                execute.assert_not_called()
                inspect.assert_not_called()

    def test_remote_active_context_is_rejected(self):
        for environment in ({}, {'DOCKER_CONTEXT': 'remote', 'DOCKER_HOST': 'unix:///var/run/docker.sock'}):
            with self.subTest(environment=environment), patch.dict('os.environ', environment, clear=True), patch.object(oci.shutil, 'which', return_value=None), patch.object(oci.subprocess, 'check_output', return_value='ssh://builder\n'), patch.object(oci.subprocess, 'run') as execute:
                with self.assertRaisesRegex(ValueError, 'Native Skopeo is required'):
                    oci.skopeo(['inspect', '--raw', 'docker://registry/image:11'], capture=True)
                execute.assert_not_called()

    def test_local_context_overrides_remote_host_and_keeps_container_fallback(self):
        for host in ('unix:///var/run/docker.sock', 'npipe:////./pipe/docker_engine'):
            with self.subTest(host=host), patch.dict('os.environ', {'DOCKER_CONTEXT': 'local', 'DOCKER_HOST': 'ssh://builder'}, clear=True), patch.object(oci.shutil, 'which', return_value=None), patch.object(oci.subprocess, 'check_output', return_value=host), patch.object(oci.subprocess, 'run') as execute:
                oci.skopeo(['copy', 'oci-archive:client.tar', 'docker://registry/image:11'])
                command = execute.call_args.args[0]
                self.assertEqual(command[:3], ['docker', 'run', '--rm'])
                self.assertIn('oci-archive:/archive1/client.tar', command)


class DeploymentIdentityTests(unittest.TestCase):
    def test_saved_metadata_validates_both_families_using_explicit_release(self):
        convenience = ['docker.io/codebeltnet/csrun:11.0.100', 'docker.io/codebeltnet/csrun:11.0', 'docker.io/codebeltnet/csrun:11']
        versioned = ['docker.io/codebeltnet/csrun:11.0.100-v0.2.2', 'docker.io/codebeltnet/csrun:11.0-v0.2.2', 'docker.io/codebeltnet/csrun:11-v0.2.2']
        meta = {'EngineVersion': 'v0.2.2', 'SdkVersions': ['11.0.100'], 'ConvenienceTags': convenience, 'VersionedTags': versioned, 'Tags': convenience + versioned}
        release_images.validate_tags(meta)
        for key in ('Tags', 'ConvenienceTags', 'VersionedTags'):
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, 'aliases differ'):
                    release_images.validate_tags({**meta, key: ['docker.io/codebeltnet/csrun:11-v0.1.0']})
        legacy = {k: v for k, v in meta.items() if k not in ('ConvenienceTags', 'VersionedTags')}
        legacy['Tags'] = convenience
        release_images.validate_tags(legacy)
        self.assertNotIn('VersionedTags', legacy)

    def test_all_variants_preflight_before_any_publication(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.chdir(temp):
            def restore(variant):
                Path('out').mkdir()
                Path('out/release.json').write_text(json.dumps({'variant': variant}))
            def args(meta, path):
                return SimpleNamespace(variant=meta['variant'], legacy_convenience_only=False)
            events = []
            with patch.object(release_images, 'current_release'), patch.object(release_images, 'restore', side_effect=restore), patch.object(release_images, 'publication_args', side_effect=args), patch.object(oci, 'preflight', side_effect=lambda a: events.append(('preflight', a.variant))), patch.object(oci, 'publish', side_effect=lambda a, **kw: events.append((kw['family'], a.variant))):
                release_images.publish_all()
            self.assertEqual(events, [(phase, variant) for phase in ('preflight', 'versioned', 'convenience') for variant in ('10', '11', '10-11')])
            with patch.object(release_images, 'current_release'), patch.object(release_images, 'restore', side_effect=restore), patch.object(release_images, 'publication_args', side_effect=args), patch.object(oci, 'preflight', side_effect=[None, None, ValueError('conflict')]), patch.object(oci, 'publish') as publish:
                with self.assertRaisesRegex(ValueError, 'conflict'):
                    release_images.publish_all()
                publish.assert_not_called()

    def test_latest_changing_after_verification_blocks_promotion(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.chdir(temp):
            Path('resolved').mkdir()
            Path('resolved/identity.json').write_text(json.dumps({'releaseId': 1, 'tag': 'v0.2.0'}))
            with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'codebeltnet/csrun'}), patch.object(release_images, 'gh', return_value={'id': 2}), patch.object(oci, 'publish') as publish:
                with self.assertRaisesRegex(ValueError, 'refusing stale'):
                    release_images.publish()
                publish.assert_not_called()

    def test_recovery_from_a_feature_branch_is_rejected(self):
        with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'codebeltnet/csrun', 'RELEASE_TAG': 'v0.2.0', 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/feature'}):
            with self.assertRaisesRegex(ValueError, 'from main'):
                release_images.resolve()

    def test_unexpected_release_tag_is_rejected(self):
        with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'codebeltnet/csrun', 'RELEASE_TAG': 'latest'}):
            with self.assertRaisesRegex(ValueError, 'Unexpected release tag'):
                release_images.resolve()

    def test_draft_release_cannot_be_promoted(self):
        release = {'id': 1, 'draft': True, 'tag_name': 'v0.2.0'}
        with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'codebeltnet/csrun', 'RELEASE_TAG': 'v0.2.0', 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main'}), patch.object(release_images, 'gh', return_value=release):
            with self.assertRaisesRegex(ValueError, 'latest published stable release'):
                release_images.resolve()

    def test_old_published_release_cannot_overwrite_current_aliases(self):
        release = {'id': 1, 'draft': False, 'prerelease': False, 'published_at': '2026-11-15'}
        with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'codebeltnet/csrun', 'RELEASE_TAG': 'v0.2.0', 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main'}), patch.object(release_images, 'gh', side_effect=[release, {'id': 2}]):
            with self.assertRaisesRegex(ValueError, 'latest published stable release'):
                release_images.resolve()


if __name__ == '__main__':
    unittest.main()
