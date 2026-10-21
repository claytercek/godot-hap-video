#!/usr/bin/env python3
"""Smoke an already-built extension, never rebuild it. PCM needs real audio."""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

from check_validation_log import check_log

REPO = Path(__file__).resolve().parent.parent


def prepare_extension_discovery(project):
    """Register the installed project extension without an editor import/build."""
    extension = project / "hap_video.gdextension"
    if not extension.is_file():
        raise FileNotFoundError(f"Project extension manifest not found: {extension}")
    # Godot reads this newline-delimited resource list before loading scenes.
    # A fresh artifact checkout has no editor-generated .godot cache, so the
    # native classes would otherwise be unavailable. Use only this project's
    # manifest: never discover or copy a native library from another install.
    resource = "res://hap_video.gdextension"
    cache = project / ".godot" / "extension_list.cfg"
    existing = cache.read_text(encoding="utf-8") if cache.exists() else ""
    if resource in existing.splitlines():
        return
    cache.parent.mkdir(parents=True, exist_ok=True)
    separator = "\n" if existing and not existing.endswith("\n") else ""
    cache.write_text(existing + separator + resource + "\n", encoding="utf-8")


def command_for(godot, scene, driver, display_args, gdvm_version=None, audio_driver=None):
    prefix = [godot]
    if gdvm_version:
        prefix += ["run", "--force", gdvm_version, "--"]
    command = prefix + ["--path", str(REPO / "project"),
                        f"res://{'audio_smoke' if scene == 'audio' else 'smoke'}.tscn",
                        "--rendering-method", "forward_plus", "--verbose"]
    if scene == "video":
        command += ["--audio-driver", "Dummy", "--max-fps", "60"]
    elif audio_driver:
        command += ["--audio-driver", audio_driver]
    # Do not cap PCM smoke's frame rate: its capture windows require the normal
    # engine cadence. In particular never select Dummy for PCM capture.
    if driver != "default":
        command += ["--rendering-driver", driver]
    return command + display_args


def run_scene(command, log, scene, driver, timeout, audio_driver=None):
    log.parent.mkdir(parents=True, exist_ok=True)
    print("SMOKE_COMMAND", command, flush=True)
    with log.open("w", encoding="utf-8") as output:
        # setup-godot's Windows executable alias has no .exe suffix.
        process = subprocess.Popen(command, executable=command[0], stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=os.name != "nt")
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)], check=False)
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            print(f"SMOKE_TIMEOUT after {timeout}s", file=sys.stderr)
            status = 1
    text = log.read_text(encoding="utf-8", errors="replace")
    print(text, end="", flush=True)
    errors = check_log(text, scene, driver, audio_driver)
    for error in errors:
        print(f"SMOKE_FAIL: {error}", file=sys.stderr)
    return 0 if status == 0 and not errors else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_PATH") or "godot")
    parser.add_argument("--gdvm-version", help="Use --godot gdvm to launch this managed version")
    parser.add_argument("--driver", choices=("default", "vulkan", "d3d12"), required=True)
    parser.add_argument("--audio", action="store_true", help="Also run PCM scene with real audio")
    parser.add_argument("--audio-driver", help="Require this real driver for PCM; omitted uses Godot's native default")
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("display_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    godot = shutil.which(args.godot, mode=os.F_OK)
    if not godot:
        parser.error(f"Godot executable not found: {args.godot}")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.audio_driver and (not args.audio or args.audio_driver.lower() == "dummy"):
        parser.error("--audio-driver requires --audio and a real audio driver")
    display_args = args.display_args
    if display_args[:1] == ["--"]:
        display_args = display_args[1:]
    # Limit pass-through to display setup; prevent headless/Compatibility or
    # Dummy audio from weakening the scene assertions.
    if display_args not in ([], ["--display-driver", "x11"]):
        parser.error("Only --display-driver x11 is supported after --")
    prepare_extension_discovery(REPO / "project")
    for scene in (["video", "audio"] if args.audio else ["video"]):
        command = command_for(godot, scene, args.driver, display_args, args.gdvm_version, args.audio_driver)
        if run_scene(command, args.log_dir / f"{scene}-smoke.log", scene, args.driver, args.timeout, args.audio_driver):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
