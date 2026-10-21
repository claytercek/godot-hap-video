#!/usr/bin/env python3
"""Check every manifest library and required notice in a staged HAP addon."""
import argparse
import configparser
import json
from pathlib import Path, PurePosixPath
import sys

NOTICES = {"README.md", "LICENSE.md", "licenses/LICENSE-snappy.txt",
           "licenses/AUTHORS-snappy.txt", "licenses/LICENSE-minimp4.txt",
           "licenses/LICENSE-gdzig.txt"}


def validate(directory):
    manifest = configparser.ConfigParser(interpolation=None, strict=True)
    manifest.optionxform = str
    manifest_path = directory / "hap_video.gdextension"
    with manifest_path.open(encoding="utf-8") as source:
        manifest.read_file(source)
    libraries = manifest["libraries"]
    if not libraries:
        raise ValueError("Manifest has no libraries")
    required = NOTICES | {"hap_video.gdextension"}
    for encoded in libraries.values():
        filename = json.loads(encoded)
        if not isinstance(filename, str) or not filename or "\\" in filename:
            raise ValueError(f"Invalid library path: {filename!r}")
        path = PurePosixPath(filename)
        if path.is_absolute() or ".." in path.parts or ":" in filename:
            raise ValueError(f"Unsafe library path: {filename}")
        required.add(filename)
    for filename in required:
        path = directory / filename
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Missing, empty or symlinked package file: {filename}")
    actual = {p.relative_to(directory).as_posix() for p in directory.rglob("*") if p.is_file()}
    if actual != required:
        raise ValueError(f"Unexpected package files: {sorted(actual - required)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        validate(args.directory)
    except (ValueError, KeyError, OSError, configparser.Error) as error:
        print(f"PACKAGE_FAIL: {error}", file=sys.stderr)
        return 1
    print("PACKAGE_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
