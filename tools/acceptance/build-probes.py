#!/usr/bin/env python3
"""Упаковать один готовый executable в два probe-бандла, не запуская приложения."""

import argparse
import hashlib
import json
import plistlib
import shutil
import struct
import subprocess
import uuid
import zlib
from datetime import datetime, timezone
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SANDBOX_ENTITLEMENTS = {"com.apple.security.app-sandbox": True}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result


def sections(data):
    """Хэши секций thin Mach-O: codesign меняет подпись и load commands, но не код."""
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Требуется native thin 64-bit Mach-O после make build")
    count = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    result = {}
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("Повреждены Mach-O load commands")
        if command == 0x19:  # LC_SEGMENT_64
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + section_count * 80 > size:
                raise ValueError("Повреждены Mach-O sections")
            for index in range(section_count):
                entry = offset + 72 + index * 80
                name, segment = struct.unpack_from("<16s16s", data, entry)
                name = name.rstrip(b"\0").decode("ascii")
                segment = segment.rstrip(b"\0").decode("ascii")
                length, position = struct.unpack_from("<QI", data, entry + 40)
                flags = struct.unpack_from("<I", data, entry + 64)[0]
                key = segment + "," + name
                if key == "__TEXT,__info_plist":
                    raise ValueError("Используйте make build: embedded Info.plist из make app переносит identity")
                # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL не имеют bytes в файле.
                if flags & 0xFF in (1, 12, 18):
                    result[key] = {"size": length, "zeroFill": True}
                else:
                    if position + length > len(data):
                        raise ValueError("Секция выходит за границы Mach-O")
                    result[key] = {"size": length, "sha256": digest(data[position:position + length])}
        offset += size
    if "__TEXT,__text" not in result:
        raise ValueError("Не найдена исполняемая секция __TEXT,__text")
    return result


def png_fixture():
    def chunk(kind, payload):
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

    # Два ряда RGBA, фильтр None; размер 2 x 2 проверяется принимающей стороной.
    pixels = b"\0" + bytes([255, 0, 0, 255, 0, 255, 0, 255])
    pixels += b"\0" + bytes([0, 0, 255, 255, 255, 255, 255, 255])
    header = struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


def prepare_fixtures(destination):
    destination.mkdir()
    marker = "LSWITCH_ACCEPTANCE_" + uuid.uuid4().hex + "\nghbdtn\n"
    files = {
        "LSwitchAcceptance.txt": marker.encode("utf-8"),
        "original.txt": b"LSwitch clipboard fixture\n",
        "formatted.rtf": b"{\\rtf1\\ansi{\\fonttbl{\\f0 Helvetica;}}\\f0\\b LSwitch\\b0  clipboard fixture\\par}",
        "pixels.png": png_fixture(),
        "file-one.txt": "Первый тестовый файл LSwitch.\n".encode("utf-8"),
        "file-two.txt": "Второй тестовый файл LSwitch.\n".encode("utf-8")
    }
    for name, data in files.items():
        (destination / name).write_bytes(data)
    return {name: {"bytes": len(data), "sha256": digest(data)} for name, data in files.items()}


def copy_bundle(mode, args, source, expected_sections, fixtures, evidence):
    identifier = "ru.cramen.lswitch.probe." + mode
    app = args.output / ("LSwitchProbe-" + mode + ".app")
    contents = app / "Contents"
    executable = contents / "MacOS" / "LSwitchProbe"
    executable.parent.mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    shutil.copyfile(source, executable)
    executable.chmod(0o755)
    shutil.copytree(fixtures, resources / "Fixtures")
    shutil.copytree(args.resources, resources / "LSwitch_LSwitchCore.bundle")
    info = {
        "CFBundleIdentifier": identifier,
        "CFBundleName": "LSwitch Probe " + mode,
        "CFBundleExecutable": "LSwitchProbe",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "0.1",
        "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    before = digest(executable.read_bytes())
    if before != digest(source.read_bytes()):
        raise RuntimeError("Копия executable не совпадает с сохранённым исходником")
    command = ["/usr/bin/codesign", "--force", "--sign", args.identity, "--identifier", identifier]
    if mode == "sandbox":
        command += ["--entitlements", str(evidence / "sandbox.entitlements.plist")]
    run(command + [str(app)])
    run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(app)])
    signed = executable.read_bytes()
    if sections(signed) != expected_sections:
        raise RuntimeError("Подписание изменило содержимое Mach-O sections")
    details = run(["/usr/bin/codesign", "-d", "--verbose=4", "-r-", str(app)])
    (evidence / (mode + ".codesign.txt")).write_bytes(details.stdout + details.stderr)
    entitlements = run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)]).stdout
    parsed = plistlib.loads(entitlements) if entitlements.strip() else {}
    if parsed != (SANDBOX_ENTITLEMENTS if mode == "sandbox" else {}):
        raise RuntimeError("Подпись содержит неожиданные entitlements")
    (evidence / (mode + ".entitlements.plist")).write_bytes(plistlib.dumps(parsed))
    return {
        "path": str(app), "bundleID": identifier, "sourceSHA256": before,
        "signedExecutableSHA256": digest(signed), "sectionsMatchSource": True,
        "entitlements": parsed, "signatureVerifiedStrict": True
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=REPOSITORY / ".build/debug/lswitch")
    parser.add_argument("--resources", type=Path, default=REPOSITORY / ".build/debug/LSwitch_LSwitchCore.bundle")
    parser.add_argument("--output", type=Path, required=True, help="Новый каталог; существующий не перезаписывается")
    parser.add_argument("--identity", default="LSwitch Dev")
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.resources = args.resources.resolve(strict=True)
    args.output = args.output.resolve()
    source_bytes = args.binary.read_bytes()
    expected_sections = sections(source_bytes)
    args.output.mkdir(parents=True, exist_ok=False)
    evidence = args.output / "evidence"
    evidence.mkdir()
    source = evidence / "source-executable"
    source.write_bytes(source_bytes)
    source.chmod(0o600)
    (evidence / "sandbox.entitlements.plist").write_bytes(plistlib.dumps(SANDBOX_ENTITLEMENTS))
    fixture_path = args.output / "fixtures"
    fixture_hashes = prepare_fixtures(fixture_path)
    report = {
        "createdAt": datetime.now(timezone.utc).isoformat(), "sourcePath": str(args.binary),
        "sourceSHA256": digest(source_bytes), "sourceSections": expected_sections,
        "fixtures": fixture_hashes, "signingIdentity": args.identity,
        "launched": False, "requestedPermissions": False, "bundles": {}
    }
    for mode in ("normal", "sandbox"):
        report["bundles"][mode] = copy_bundle(mode, args, source, expected_sections, fixture_path, evidence)
    (args.output / "manifest.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"manifest": str(args.output / "manifest.json"), "sourceSHA256": report["sourceSHA256"],
                      "signedBundles": list(report["bundles"]), "launched": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
