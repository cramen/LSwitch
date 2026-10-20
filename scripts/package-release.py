#!/usr/bin/env python3
"""Собирает отдельную Universal alpha-поставку, не меняя рабочую .build/LSwitch.app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    match = re.fullmatch(r'(\d+\.\d+\.\d+)-alpha\.([1-9]\d*)', args.version)
    if not match:
        parser.error('Этот рецепт предназначен только для явно обозначенных alpha-версий')
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    if output('git', 'status', '--porcelain'):
        raise RuntimeError('Сначала закоммитьте изменения: release должен соответствовать точному commit')
    revision = output('git', 'rev-parse', 'HEAD')
    destination = Path(args.output).resolve()
    destination.relative_to(root / 'dist')
    if destination.exists():
        raise RuntimeError('Путь выпуска уже существует; выберите новый output')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.release-', dir=destination.parent) as temporary:
        staging = Path(temporary)
        payload = staging / 'payload'
        app = payload / 'LSwitch.app'
        executable = app / 'Contents/MacOS/LSwitch'
        executable.parent.mkdir(parents=True)
        resources = app / 'Contents/Resources'
        resources.mkdir()
        info = plistlib.loads((root / 'packaging/Info.plist').read_bytes())
        info.update(CFBundleShortVersionString=match[1], CFBundleVersion=match[2],
                    LSwitchPrereleaseVersion=args.version, LSwitchSourceRevision=revision)
        plist = app / 'Contents/Info.plist'
        plist.write_bytes(plistlib.dumps(info))
        binaries = []
        resource_sources = []
        for architecture in ('arm64', 'x86_64'):
            command = ['swift', 'build', '-c', 'release', '--arch', architecture,
                       '--scratch-path', str(root / '.build/distribution' / architecture)]
            run(*command, '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist',
                '-Xlinker', str(plist))
            binary_path = Path(output(*command, '--show-bin-path'))
            binaries.append(str(binary_path / 'lswitch'))
            resource_sources.append(binary_path / 'LSwitch_LSwitchCore.bundle')
        inventories = [{str(path.relative_to(bundle)): digest(path) for path in bundle.rglob('*') if path.is_file()}
                       for bundle in resource_sources]
        if inventories[0] != inventories[1]:
            raise RuntimeError('Ресурсы двух архитектур различаются')
        run('lipo', '-create', *binaries, '-output', str(executable))
        shutil.copytree(resource_sources[0], resources / resource_sources[0].name)
        for name in ('LICENSE', 'NOTICE.md'):
            shutil.copy2(root / name, payload / name)
            shutil.copy2(root / name, resources / name)
        shutil.copy2(root / 'packaging/ALPHA-README.txt', payload / 'README.txt')
        run('codesign', '--force', '--sign', '-', '--identifier', 'ru.cramen.lswitch',
            '--options', 'runtime', '--timestamp=none', str(app))
        run('codesign', '--verify', '--deep', '--strict', str(app))
        architectures = output('lipo', '-archs', str(executable)).split()
        if set(architectures) != {'arm64', 'x86_64'}:
            raise RuntimeError('Universal binary не содержит обе архитектуры')
        artifacts = staging / 'artifacts'
        artifacts.mkdir()
        name = f'LSwitch-{args.version}-macOS-universal'
        archive = artifacts / f'{name}.zip'
        image = artifacts / f'{name}.dmg'
        run('ditto', '-c', '-k', '--sequesterRsrc', str(payload), str(archive))
        (payload / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-volname', f'LSwitch {args.version}', '-srcfolder', str(payload),
            '-format', 'UDZO', '-ov', str(image))
        manifest = dict(version=args.version, sourceCommit=revision, architectures=architectures,
                        minimumMacOS='13.0', configuration='release', signing='ad-hoc', notarized=False,
                        executableSHA256=digest(executable), swiftVersion=output('swift', '--version'))
        (artifacts / 'build-info.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        checksums = ''.join(f'{digest(path)}  {path.name}\n' for path in sorted(artifacts.iterdir()))
        (artifacts / 'SHA256SUMS.txt').write_text(checksums)
        shutil.move(str(artifacts), destination)
    print(f'Готово: {destination}')


if __name__ == '__main__':
    main()
