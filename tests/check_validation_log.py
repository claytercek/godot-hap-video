#!/usr/bin/env python3
"""Validate rendered HAP smoke logs, allowing only exact intentional errors."""
import argparse
from pathlib import Path
import re
import sys

VIDEO_MARKER = "SMOKE: Hap fixture opened, played, sought, cleared, and rejected synchronous/asynchronous invalid replacements"
AUDIO_MARKER = "AUDIO_SMOKE: mono16, stereo16BE, stereo24BE captured from both players; seek/loop content, controls, unsupported audio, and teardown passed"
PROBES_46 = {
    f"ERROR: Attempt to get non-existent interface function: '{name}'."
    for name in ("variant_get_type_by_name", "classdb_construct_object3",
                 "classdb_register_extension_class6")
}
INTENTIONAL = {
    "video": {
        "error(hap_video_stream_playback): empty path",
        "error(hap_player): failed to open stream: ",
    },
    "audio": {"error(hap_video_stream_playback): Failed to decode invalid Hap frame"},
}


def check_log(text, scene, driver, audio_driver=None):
    errors = []
    allowed_seen = set()
    is_46 = re.search(r"^Godot Engine v4\.6\.", text, re.M) is not None
    for line in text.splitlines():
        if is_46 and line in PROBES_46:
            continue
        if line in INTENTIONAL[scene]:
            if line in allowed_seen:
                errors.append(f"Repeated intentional error: {line}")
            allowed_seen.add(line)
            continue
        if re.search(r"(^|\s)(ERROR:|SCRIPT ERROR:|USER ERROR:|error(?:\([^)]*\))?:|panic:)", line, re.I):
            errors.append(line)
        elif re.search(r"undefined symbol|error loading extension|failed to load.*(?:gdextension|libhap_video|hap_video\.dll)|leaked at exit|memory address .* leaked|ObjectDB instances leaked|Segmentation fault", line, re.I):
            errors.append(line)
    marker = AUDIO_MARKER if scene == "audio" else VIDEO_MARKER
    if marker not in text.splitlines():
        errors.append(f"Missing exact success marker: {marker}")
    banner = {"default": r"(?:Metal|Vulkan)", "vulkan": "Vulkan",
              "d3d12": r"(?:D3D12|Direct3D 12)"}[driver]
    if not re.search(rf"^{banner} .* - Forward\+ - Using Device.*$", text, re.M):
        errors.append(f"No {driver} Forward+ RenderingDevice in engine output")
    if scene == "audio":
        actual_drivers = re.findall(r"^AUDIO_SMOKE_DRIVER: ([^\r\n]+)$", text, re.M)
        if len(actual_drivers) != 1 or actual_drivers[0].lower() == "dummy":
            errors.append("PCM capture requires one exact real audio driver marker")
        if audio_driver and actual_drivers != [audio_driver]:
            errors.append(f"Missing exact requested audio driver marker: AUDIO_SMOKE_DRIVER: {audio_driver}")
        if re.search(r"(?:AudioDriverDummy|audio driver.*Dummy|Dummy.*audio driver)", text, re.I):
            errors.append("PCM capture requires a real audio driver")
        if re.search(r"(?:audio|pulseaudio|alsa|driver).*?(?:falling back|fallback|fell back)|(?:falling back|fallback|fell back).*?(?:audio|driver)", text, re.I):
            errors.append("Audio driver fallback is not allowed")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--scene", choices=("video", "audio"), required=True)
    parser.add_argument("--driver", choices=("default", "vulkan", "d3d12"), required=True)
    parser.add_argument("--audio-driver", help="Require this exact actual PCM driver")
    args = parser.parse_args()
    errors = check_log(args.log.read_text(encoding="utf-8", errors="replace"), args.scene, args.driver, args.audio_driver)
    for error in errors:
        print(error, file=sys.stderr)
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
