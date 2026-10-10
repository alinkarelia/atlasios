#!/usr/bin/env python3
"""Publish one accepted Atlas preview using only the Actions job token."""
import argparse
import collections
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = 'alinkarelia/atlasios'
TAG = 'v0.3.1-preview.4'
RELEASE_ID = 408669631
IPA_ARTIFACT = 'Atlas-unsigned-device-IPA-candidate'
EXPECTED_JOBS = {
    'Source project and Server',
    'Swift 6 core and native SDK',
    'Unsigned arm64 iPhone candidate',
    'Full UI tests (Xcode 16.4, iOS 18)',
    'Full UI tests (Xcode 26, iOS 26)',
    'All checks passed; visual review required',
}
ROOT = pathlib.Path(__file__).resolve().parents[2]
STAGING = ROOT / 'artifacts/publish'


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def sha256(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def api(method, path, body=None, allow_missing=False, upload=False):
    require(path == f'/repos/{REPOSITORY}' or path.startswith(f'/repos/{REPOSITORY}/'),
            'Unexpected GitHub API resource.')
    token = os.environ.get('GH_TOKEN', '')
    require(bool(token), 'The Actions job token is missing.')
    origin = 'https://uploads.github.com' if upload else 'https://api.github.com'
    headers = {
        'Authorization': f'Bearer {token}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    }
    if upload:
        headers['Content-Type'] = 'application/octet-stream'
        payload = body
    else:
        headers['Content-Type'] = 'application/json'
        payload = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(origin + path, data=payload, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if allow_missing and error.code == 404:
            return None
        # Keep credentials and redirected download URLs out of diagnostics.
        raise SystemExit(f'GitHub {method} resource failed with HTTP {error.code}.') from None
    except urllib.error.URLError:
        raise SystemExit(f'GitHub {method} resource could not be reached.') from None


def collection(path, key=None):
    rows = []
    for page in range(1, 101):
        separator = '&' if '?' in path else '?'
        result = api('GET', f'{path}{separator}per_page=100&page={page}')
        current = result[key] if key else result
        require(isinstance(current, list), 'Unexpected GitHub collection response.')
        rows.extend(current)
        if len(current) < 100:
            return rows
    raise SystemExit('GitHub collection is unexpectedly large.')


def verify_context():
    require(os.environ.get('GITHUB_REPOSITORY') == REPOSITORY, 'Wrong publication repository.')
    require(os.environ.get('GITHUB_REF') == 'refs/heads/main', 'Publication requires main.')
    require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'Publication requires manual dispatch.')
    require(os.environ.get('ATLAS_VISUAL_REVIEW', '').lower() == 'true', 'Actual screenshot acceptance is required.')
    raw_id = os.environ.get('ATLAS_SOURCE_RUN_ID', '')
    require(re.fullmatch(r'[1-9][0-9]{0,18}', raw_id) is not None, 'Source run ID must be a positive decimal integer.')
    run_id = int(raw_id)
    record = json.loads((ROOT / '.github/preview-verification.json').read_text())
    require(record.get('repository') == REPOSITORY and record.get('run_id') == run_id,
            'Review record does not identify this source run.')
    source_sha = record.get('source_sha', '')
    require(re.fullmatch(r'[0-9a-f]{40}', source_sha) is not None, 'Invalid reviewed source commit.')
    require(record.get('all_CI_checks') == 'success' and record.get('manual_current_screenshot_review') == 'passed',
            'Complete CI and actual manual screenshot review are required.')
    require(record.get('personally_signed') is False and record.get('physical_camera_LiDAR_tested') is False,
            'Unexpected signing or physical-hardware claim in the review record.')
    for key, major in (('runtime_iOS18', '18'), ('runtime_iOS26', '26')):
        runtime = record.get(key, {})
        require(str(runtime.get('iOS', '')).split('.')[0] == major,
                'Review record contains the wrong runtime generation.')
        require(runtime.get('tests', 0) >= 4 and runtime.get('passed') == runtime.get('tests')
                and runtime.get('failed') == 0 and runtime.get('skipped') == 0,
                'Review record must include all four passing UI tests without failures or skips.')
        require(runtime.get('manual_visual_review') == 'passed'
                and {'initial_3D', 'orbit_rotated', 'foreground_return', 'walk_forward'}
                <= set(runtime.get('reviewed', [])), 'Incomplete actual screenshot review.')
    repository = api('GET', f'/repos/{REPOSITORY}')
    require(repository.get('private') is False and repository.get('full_name') == REPOSITORY,
            'Publication requires the public source repository.')
    run = api('GET', f'/repos/{REPOSITORY}/actions/runs/{run_id}')
    require(run.get('status') == 'completed' and run.get('conclusion') == 'success'
            and run.get('path') == '.github/workflows/verify.yml'
            and run.get('head_branch') == 'main' and run.get('head_sha') == source_sha
            and run.get('event') in ('push', 'workflow_dispatch')
            and run.get('repository', {}).get('id') == repository.get('id')
            and run.get('head_repository', {}).get('full_name') == REPOSITORY,
            'Source run is not a successful same-repository main verification of the reviewed commit.')
    jobs = collection(f'/repos/{REPOSITORY}/actions/runs/{run_id}/jobs?filter=latest', 'jobs')
    require(collections.Counter(job.get('name') for job in jobs)
            == collections.Counter({name: 1 for name in EXPECTED_JOBS}),
            'Source run does not contain exactly the six required verification jobs.')
    require(all(job.get('status') == 'completed' and job.get('conclusion') == 'success'
                and job.get('run_id') == run_id and job.get('head_sha') == source_sha
                and job.get('head_branch') == 'main' for job in jobs),
            'A required job is unsuccessful, skipped, or belongs to another source commit.')
    recorded_jobs = {(job.get('id'), job.get('name'), job.get('conclusion')) for job in record.get('jobs', [])}
    require(recorded_jobs == {(job['id'], job['name'], job['conclusion']) for job in jobs},
            'Review record job identities differ from the completed verification run.')
    artifacts = collection(f'/repos/{REPOSITORY}/actions/runs/{run_id}/artifacts', 'artifacts')
    candidates = [artifact for artifact in artifacts if artifact.get('name') == IPA_ARTIFACT]
    require(len(candidates) == 1, 'Expected exactly one IPA candidate artifact.')
    artifact = candidates[0]
    require(artifact.get('expired') is False and artifact.get('id') == record.get('artifact_id')
            and artifact.get('digest') == record.get('artifact_digest')
            and artifact.get('workflow_run', {}).get('id') == run_id
            and artifact.get('workflow_run', {}).get('head_sha') == source_sha,
            'IPA artifact provenance or digest differs from the reviewed candidate.')
    for key, name in (('runtime_iOS18', 'runtime-ios18-screenshots-and-diagnostics'),
                      ('runtime_iOS26', 'runtime-ios26-screenshots-and-diagnostics')):
        runtime = record[key]
        matching = [artifact for artifact in artifacts if artifact.get('name') == name]
        require(len(matching) == 1 and matching[0].get('expired') is False
                and matching[0].get('id') == runtime.get('screenshots_artifact')
                and matching[0].get('digest') == 'sha256:' + runtime.get('screenshots_archive_sha256', ''),
                'Actual reviewed screenshots do not match this source run.')
    return run_id, source_sha, record


def validate_ipa(ipa, source_sha):
    require(ipa.is_file() and not ipa.is_symlink() and 0 < ipa.stat().st_size <= 512 * 1024 * 1024,
            'IPA must be a bounded regular file.')
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        require(0 < len(entries) <= 20000 and len(names) == len(set(names))
                and sum(entry.file_size for entry in entries) <= 1024 * 1024 * 1024,
                'IPA ZIP membership or expansion limit is invalid.')
        for entry in entries:
            path = pathlib.PurePosixPath(entry.filename)
            require(not path.is_absolute() and '\\' not in entry.filename
                    and all(part not in ('', '.', '..') for part in entry.filename.rstrip('/').split('/'))
                    and not stat.S_ISLNK(entry.external_attr >> 16) and not entry.flag_bits & 1
                    and entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                    'Unsafe IPA ZIP member.')
        require(archive.testzip() is None, 'IPA ZIP CRC validation failed.')
        app = 'Payload/Atlas.app/'
        require(all(name == 'Payload/' or name.startswith(app) for name in names),
                'IPA contains an unexpected app or file outside Payload.')
        require(not any('_CodeSignature' in pathlib.PurePosixPath(name).parts
                        or name.endswith('/embedded.mobileprovision') for name in names),
                'IPA includes signing resources or a provisioning profile.')
        info = plistlib.loads(archive.read(app + 'Info.plist'))
        identity = {'CFBundleIdentifier': 'com.atlasfield.app', 'CFBundleShortVersionString': '0.3.1',
                    'CFBundleVersion': '4', 'CFBundlePackageType': 'APPL',
                    'CFBundleSupportedPlatforms': ['iPhoneOS'], 'LSRequiresIPhoneOS': True}
        require(all(info.get(key) == value for key, value in identity.items())
                and info.get('MinimumOSVersion') in ('17.0', '17.0.0')
                and 1 in info.get('UIDeviceFamily', []), 'IPA identity or iPhone platform does not match.')
        executable = info.get('CFBundleExecutable')
        require(isinstance(executable, str) and executable not in ('', '.', '..')
                and pathlib.PurePosixPath(executable).name == executable and '\\' not in executable,
                'Invalid IPA executable name.')
        binary = archive.read(app + executable)
        require(len(binary) >= 32, 'Truncated Mach-O header.')
        magic, cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack_from('<IiiIIIII', binary)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C and kind == 2,
                'IPA must contain a thin arm64 MH_EXECUTE device application.')
        offset, end = 32, 32 + command_bytes
        require(end <= len(binary) and count <= command_bytes // 8, 'Invalid Mach-O command table.')
        build_count = 0
        for _ in range(count):
            require(offset + 8 <= end, 'Truncated Mach-O load command.')
            command, size = struct.unpack_from('<II', binary, offset)
            require(size >= 8 and size % 8 == 0 and offset + size <= end,
                    'Invalid Mach-O load-command bounds.')
            require(command != 0x1D, 'Expected the exact unsigned candidate without an executable signature.')
            if command == 0x32:
                require(size >= 24, 'Truncated LC_BUILD_VERSION.')
                platform, minimum, sdk, tools = struct.unpack_from('<IIII', binary, offset + 8)
                require(platform == 2 and minimum == 17 << 16 and size >= 24 + tools * 8,
                        'Mach-O does not target physical iOS 17 or newer as expected.')
                build_count += 1
            offset += size
        require(offset == end and build_count == 1, 'Missing or ambiguous physical-iOS build version.')
    return {'sha256': sha256(ipa), 'bytes': ipa.stat().st_size, 'source_sha': source_sha}


def git(source, *arguments):
    return subprocess.check_output(['git', '-C', str(source), *arguments])


def source_archive(source_sha, release_dir):
    source = ROOT / 'verified-source'
    require(git(source, 'rev-parse', 'HEAD').decode().strip() == source_sha,
            'Source archive checkout differs from the verified commit.')
    output = release_dir / 'atlas-source.zip'
    subprocess.run(['git', '-C', str(source), 'archive', '--format=zip', '--prefix=atlas-source/',
                    source_sha, '-o', str(output)], check=True)
    expected = {}
    for row in git(source, 'ls-tree', '-r', '-z', '--full-tree', source_sha).split(b'\0'):
        if not row:
            continue
        metadata, name = row.split(b'\t', 1)
        mode, kind, object_id = metadata.split()
        require(mode in (b'100644', b'100755') and kind == b'blob', 'Unexpected source tree member type.')
        expected['atlas-source/' + name.decode()] = object_id.decode()
    with zipfile.ZipFile(output) as archive:
        require(archive.comment.decode() == source_sha and archive.testzip() is None,
                'Source archive commit comment or CRC is invalid.')
        members = [item for item in archive.infolist() if not item.is_dir()]
        require(len(members) == len(expected) and {item.filename for item in members} == set(expected),
                'Source archive membership differs from the verified Git tree.')
        for member in members:
            require(archive.read(member) == git(source, 'cat-file', 'blob', expected[member.filename]),
                    'Source archive bytes differ from the verified Git tree.')
    return output


def validate_release(release, source_sha):
    require(release.get('id') == RELEASE_ID and release.get('tag_name') == TAG
            and release.get('target_commitish') == source_sha and release.get('prerelease') is True,
            'Existing release identity or target differs from the accepted candidate.')
    require(isinstance(release.get('draft'), bool), 'Invalid release publication state.')


def verify_tag(source_sha, create=False):
    path = f'/repos/{REPOSITORY}/git/ref/tags/{TAG}'
    reference = api('GET', path, allow_missing=True)
    if reference is None:
        require(create, 'Published release tag is missing.')
        api('POST', f'/repos/{REPOSITORY}/git/refs', {'ref': f'refs/tags/{TAG}', 'sha': source_sha})
        reference = api('GET', path)
    obj = reference.get('object', {})
    for _ in range(4):
        if obj.get('type') != 'tag':
            break
        obj = api('GET', f'/repos/{REPOSITORY}/git/tags/{obj["sha"]}').get('object', {})
    require(obj.get('type') == 'commit' and obj.get('sha') == source_sha,
            'Release tag does not identify the exact accepted source commit.')


def publish(source_sha, record):
    candidate = STAGING / 'candidate/Atlas-unsigned.ipa'
    files = [path for path in (STAGING / 'candidate').rglob('*') if path.is_file()]
    require(files == [candidate], 'Downloaded artifact contains unexpected files.')
    report = validate_ipa(candidate, source_sha)
    require(report['sha256'] == record.get('ipa_sha256') and report['bytes'] == record.get('ipa_bytes'),
            'Downloaded IPA bytes differ from the exact reviewed application.')
    release_dir = STAGING / 'release'
    release_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(candidate, release_dir / 'Atlas-unsigned.ipa')
    archive = source_archive(source_sha, release_dir)
    record['source_archive_sha256'] = sha256(archive)
    record['source_archive_prefix'] = 'atlas-source/'
    (release_dir / 'verification.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    for name in ('Atlas-unsigned.ipa', 'atlas-source.zip'):
        (release_dir / (name + '.sha256')).write_text(sha256(release_dir / name) + '  ' + name + '\n')
    names = {'Atlas-unsigned.ipa', 'Atlas-unsigned.ipa.sha256', 'atlas-source.zip',
             'atlas-source.zip.sha256', 'verification.json'}
    expected = {name: (release_dir / name).stat().st_size for name in names}
    digests = {name: 'sha256:' + sha256(release_dir / name) for name in names}
    release = api('GET', f'/repos/{REPOSITORY}/releases/{RELEASE_ID}')
    validate_release(release, source_sha)
    assets = collection(f'/repos/{REPOSITORY}/releases/{RELEASE_ID}/assets')
    require(len({asset['name'] for asset in assets}) == len(assets)
            and {asset['name'] for asset in assets} <= names, 'Existing release contains unexpected or duplicate assets.')
    for asset in assets:
        name = asset['name']
        require(asset.get('state') == 'uploaded' and asset.get('size') == expected[name]
                and asset.get('digest') == digests[name], 'Existing release asset digest does not match; no asset will be overwritten.')
    present = {asset['name'] for asset in assets}
    if release['draft'] is False:
        require(present == names, 'Published release is incomplete; it will not be changed.')
        verify_tag(source_sha)
        print('Matching complete prerelease already published; no changes needed.')
        return
    for name in sorted(names - present):
        api('POST', f'/repos/{REPOSITORY}/releases/{RELEASE_ID}/assets?name={urllib.parse.quote(name)}',
            (release_dir / name).read_bytes(), upload=True)
    assets = collection(f'/repos/{REPOSITORY}/releases/{RELEASE_ID}/assets')
    require(len(assets) == len(names) and {asset['name'] for asset in assets} == names,
            'Release is missing files; draft will remain unpublished.')
    require(all(asset.get('state') == 'uploaded' and asset.get('size') == expected[asset['name']]
                and asset.get('digest') == digests[asset['name']] for asset in assets),
            'Release asset digest verification failed; draft will remain unpublished.')
    # Recheck mutable release state immediately before the final publication.
    validate_release(api('GET', f'/repos/{REPOSITORY}/releases/{RELEASE_ID}'), source_sha)
    verify_tag(source_sha, create=True)
    notes = (ROOT / '.github/release-notes.md').read_text()
    published = api('PATCH', f'/repos/{REPOSITORY}/releases/{RELEASE_ID}',
                    {'draft': False, 'prerelease': True, 'body': notes,
                     'name': 'Atlas 0.3.1 (4) — предварительная версия', 'make_latest': 'false'})
    validate_release(published, source_sha)
    require(published.get('draft') is False, 'Release remains a draft.')
    verify_tag(source_sha)
    url = f'https://github.com/{REPOSITORY}/releases/tag/{TAG}'
    print('Published the complete reviewed prerelease: ' + url)
    summary_path = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary_path:
        with open(summary_path, 'a') as summary:
            summary.write(f'Published [Atlas 0.3.1 (4)]({url}) from `{source_sha}` after matching all five asset digests.\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=('prepare', 'publish'))
    args = parser.parse_args()
    run_id, source_sha, record = verify_context()
    if args.operation == 'prepare':
        STAGING.mkdir(parents=True, exist_ok=True)
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'source_run_id={run_id}\nsource_sha={source_sha}\n')
        print('Accepted source run, six successful jobs, exact IPA provenance, and both actual screenshot reviews verified.')
    else:
        publish(source_sha, record)


if __name__ == '__main__':
    main()
