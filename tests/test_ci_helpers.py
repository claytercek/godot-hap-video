import json
from pathlib import Path
import shlex
import tempfile
import unittest
from unittest import mock

from check_packaged_addon import NOTICES, validate
from check_validation_log import AUDIO_MARKER, VIDEO_MARKER, PROBES_46, check_log
from run_smoke import command_for, main, prepare_extension_discovery, run_scene


class LogTests(unittest.TestCase):
    def log(self, scene="video", version="4.7.2"):
        marker = AUDIO_MARKER if scene == "audio" else VIDEO_MARKER
        audio = "AUDIO_SMOKE_DRIVER: CoreAudio\n" if scene == "audio" else ""
        return f"Godot Engine v{version}.stable\nMetal 4.0 - Forward+ - Using Device #0: Apple\n{audio}{marker}\n"

    def test_linux_vulkan_and_pulse_versions(self):
        for version in ("4.6.3", "4.7.2"):
            for scene in ("video", "audio"):
                with self.subTest(version=version, scene=scene):
                    log = self.log(scene, version).replace("Metal 4.0", "Vulkan 1.3").replace("CoreAudio", "PulseAudio")
                    if version == "4.6.3":
                        log += "\n".join(PROBES_46) + "\n"
                    self.assertEqual([], check_log(log, scene, "vulkan", "PulseAudio"))

    def test_exact_requested_audio_driver(self):
        log = self.log("audio").replace("CoreAudio", "PulseAudio")
        self.assertEqual([], check_log(log, "audio", "default", "PulseAudio"))
        for marker in ("", "prefix AUDIO_SMOKE_DRIVER: PulseAudio", "AUDIO_SMOKE_DRIVER: Dummy", "AUDIO_SMOKE_DRIVER: ALSA", "AUDIO_SMOKE_DRIVER: PulseAudio extra", "AUDIO_SMOKE_DRIVER: PulseAudio\nAUDIO_SMOKE_DRIVER: PulseAudio"):
            with self.subTest(marker=marker):
                self.assertTrue(check_log(log.replace("AUDIO_SMOKE_DRIVER: PulseAudio", marker), "audio", "default", "PulseAudio"))
        self.assertTrue(check_log(log.replace("PulseAudio", "Dummy"), "audio", "default"))
        self.assertTrue(check_log(log.replace("AUDIO_SMOKE_DRIVER: PulseAudio\n", ""), "audio", "default"))

    def test_audio_fallback_warnings_rejected(self):
        log = self.log("audio").replace("CoreAudio", "PulseAudio")
        for warning in ("WARNING: PulseAudio driver failed. Falling back to ALSA driver.", "WARNING: All audio drivers failed, falling back to the dummy driver.", "WARNING: Audio driver fallback to ALSA"):
            with self.subTest(warning=warning):
                self.assertTrue(check_log(log + warning, "audio", "default", "PulseAudio"))

    def test_exact_negative_test_allowances(self):
        log = self.log() + "error(hap_video_stream_playback): empty path\nerror(hap_player): failed to open stream: \n"
        self.assertEqual([], check_log(log, "video", "default"))
        self.assertTrue(check_log(log + "error(hap_video_stream_playback): empty path\n", "video", "default"))
        self.assertTrue(check_log(log + "error(hap_player): failed to open stream: unexpected.mov\n", "video", "default"))
        self.assertTrue(check_log(log, "audio", "default"))

    def test_audio_error_is_scene_specific(self):
        error = "error(hap_video_stream_playback): Failed to decode invalid Hap frame\n"
        self.assertEqual([], check_log(self.log("audio") + error, "audio", "default"))
        self.assertTrue(check_log(self.log() + error, "video", "default"))

    def test_probes_only_exact_and_only_46(self):
        probes = "\n".join(PROBES_46) + "\n"
        self.assertEqual([], check_log(self.log(version="4.6.3") + probes, "video", "default"))
        self.assertTrue(check_log(self.log() + probes, "video", "default"))
        self.assertTrue(check_log(self.log(version="4.6.3") + "ERROR: Attempt to get non-existent interface function: 'other'.\n", "video", "default"))

    def test_marker_device_and_errors(self):
        for bad in ("ERROR: unexpected", "SCRIPT ERROR: bad", "panic: bad", "ObjectDB instances leaked at exit", "undefined symbol: bad"):
            with self.subTest(bad=bad):
                self.assertTrue(check_log(self.log() + bad, "video", "default"))
        self.assertTrue(check_log(self.log().replace(VIDEO_MARKER, "prefix " + VIDEO_MARKER), "video", "default"))
        self.assertTrue(check_log(self.log().replace("Forward+", "Compatibility"), "video", "default"))
        self.assertTrue(check_log(self.log(), "video", "vulkan"))
        self.assertTrue(check_log(self.log("audio") + "Using audio driver Dummy\n", "audio", "default"))


class PulseConfigTests(unittest.TestCase):
    def test_ci_daemon_does_not_load_host_idle_suspend_policy(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/test.yml").read_text()
        # Join shell continuations before inspecting the actual startup command.
        commands = workflow.replace("\\\n", " ").splitlines()
        startup = next(shlex.split(line.strip()) for line in commands
                       if line.strip().startswith("pulseaudio --start "))
        # Keeping the daemon alive alone does not keep its sinks awake.
        self.assertIn("--exit-idle-time=-1", startup)
        self.assertIn("-n", startup, "default.pa can load module-suspend-on-idle")
        self.assertEqual(["--load=module-native-protocol-unix"],
                         [arg for arg in startup if arg.startswith("--load=")])
        self.assertFalse(any(arg == "-F" or arg.startswith("--file") for arg in startup))


class CaptureReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (Path(__file__).resolve().parents[1] / "project/audio_smoke.gd").read_text()

    def function(self, name):
        return self.source.split(f"func {name}(", 1)[1].split("\n\nfunc ", 1)[0]

    def test_readiness_precedes_candidate_and_discards_warmup(self):
        verify = self.function("_verify")
        install = verify.index("AudioServer.add_bus_effect(capture_bus, _capture)")
        readiness = verify.index('if not await _wait_capture_window("capture readiness", 5000):')
        candidate = verify.index('ClassDB.instantiate("HapVideoStream")')
        self.assertLess(install, readiness)
        self.assertLess(readiness, candidate)
        self.assertIn("return\n\t_capture.clear_buffer()", verify[readiness:candidate])
        self.assertLess(candidate, verify.index('await _silent("unplayed candidate")'))
        self.assertLess(verify.index('await _silent("unplayed candidate")'), verify.index("hap.play()"))

    def test_readiness_and_assertions_share_fresh_frame_wait_only(self):
        wait = self.function("_wait_capture_window")
        self.assertIn("timeout_msec: int = 1500", wait)
        self.assertIn("_capture.clear_buffer()", wait)
        self.assertIn("ceili(AudioServer.get_mix_rate() * CAPTURE_WINDOW_SECONDS)", wait)
        self.assertIn("Time.get_ticks_msec() + timeout_msec", wait)
        self.assertIn("while available < frames and Time.get_ticks_msec() < deadline:", wait)
        self.assertIn("if available < frames:", wait)
        self.assertIn("driver=%s mix_rate=%d", wait)
        stats = self.function("_stats")
        self.assertIn("await _wait_capture_window(label)", stats)
        self.assertIn("_capture.get_buffer(frames)", stats)
        self.assertIn("const CAPTURE_WINDOW_SECONDS := 0.12", self.source)


class RunnerTests(unittest.TestCase):
    def test_fresh_project_extension_discovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            manifest = project / "hap_video.gdextension"
            manifest.write_text("[configuration]\nentry_symbol = \"hap_video_init\"\n")
            prepare_extension_discovery(project)
            cache = project / ".godot" / "extension_list.cfg"
            self.assertEqual("res://hap_video.gdextension\n", cache.read_text())
            self.assertCountEqual([manifest, project / ".godot"], project.iterdir())

    def test_extension_discovery_preserves_other_entries_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / "hap_video.gdextension").touch()
            cache = project / ".godot" / "extension_list.cfg"
            cache.parent.mkdir()
            for existing in ("res://addons/other.gdextension", "res://addons/other.gdextension\n",
                             "res://hap_video.gdextension\nres://addons/other.gdextension\n"):
                with self.subTest(existing=existing):
                    cache.write_text(existing)
                    prepare_extension_discovery(project)
                    result = cache.read_text()
                    self.assertEqual(1, result.splitlines().count("res://hap_video.gdextension"))
                    self.assertIn("res://addons/other.gdextension", result.splitlines())
                    self.assertTrue(result.startswith(existing))
                    with mock.patch("run_smoke.Path.write_text") as write:
                        prepare_extension_discovery(project)
                        write.assert_not_called()
                    self.assertEqual(result, cache.read_text())

    def test_missing_project_manifest_does_not_use_other_extension(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / "other.gdextension").touch()
            with self.assertRaises(FileNotFoundError):
                prepare_extension_discovery(project)
            self.assertFalse((project / ".godot").exists())

    def test_runner_prepares_discovery_before_launch_without_touching_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / "project"
            (project / "lib").mkdir(parents=True)
            manifest = project / "hap_video.gdextension"
            manifest.write_bytes((Path(__file__).resolve().parents[1] / "project/hap_video.gdextension").read_bytes())
            library = project / "lib/libhap_video.so"
            library.write_bytes(b"downloaded artifact fixture")
            def launch(command, *args):
                self.assertEqual("res://hap_video.gdextension\n", (project / ".godot/extension_list.cfg").read_text())
                self.assertEqual(str(project), command[command.index("--path") + 1])
                self.assertEqual(b"downloaded artifact fixture", library.read_bytes())
                return 0
            with mock.patch("run_smoke.REPO", root), \
                 mock.patch("run_smoke.shutil.which", return_value="/godot"), \
                 mock.patch("run_smoke.sys.argv", ["run_smoke.py", "--driver", "vulkan", "--log-dir", str(root / "logs")]), \
                 mock.patch("run_smoke.run_scene", side_effect=launch) as run, \
                 mock.patch("run_smoke.subprocess.Popen") as process:
                self.assertEqual(0, main())
                run.assert_called_once()
                process.assert_not_called()
            self.assertEqual(b"downloaded artifact fixture", library.read_bytes())

    def test_audio_uses_real_driver_and_normal_cadence(self):
        command = command_for("godot", "audio", "default", [])
        self.assertIn("res://audio_smoke.tscn", command)
        self.assertNotIn("Dummy", command)
        self.assertNotIn("--audio-driver", command)
        self.assertNotIn("--max-fps", command)
        self.assertNotIn("zig", command)

    def test_explicit_pulse_only_applies_to_audio(self):
        audio = command_for("godot", "audio", "vulkan", [], audio_driver="PulseAudio")
        self.assertEqual(audio[audio.index("--audio-driver") + 1], "PulseAudio")
        self.assertNotIn("--max-fps", audio)
        video = command_for("godot", "video", "vulkan", [], audio_driver="PulseAudio")
        self.assertEqual(video[video.index("--audio-driver") + 1], "Dummy")
        self.assertEqual(video[video.index("--max-fps") + 1], "60")
        self.assertNotIn("PulseAudio", video)

    def test_runner_checks_requested_actual_audio_driver(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "audio.log"
            process = mock.Mock()
            process.wait.return_value = 0
            def launch(*args, **kwargs):
                kwargs["stdout"].write(LogTests().log("audio"))
                return process
            with mock.patch("run_smoke.subprocess.Popen", side_effect=launch):
                self.assertEqual(0, run_scene(["godot"], log, "audio", "default", 1))
                self.assertEqual(1, run_scene(["godot"], log, "audio", "default", 1, "PulseAudio"))

    def test_video_display_and_gdvm(self):
        command = command_for("gdvm", "video", "vulkan", ["--display-driver", "x11"], "4.6.3")
        self.assertEqual(command[:5], ["gdvm", "run", "--force", "4.6.3", "--"])
        self.assertIn("Dummy", command)
        self.assertIn("vulkan", command)

    def test_exit_status_and_timeout(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "smoke.log"
            process = mock.Mock(pid=123)
            def launch(*args, **kwargs):
                kwargs["stdout"].write(LogTests().log())
                return process
            with mock.patch("run_smoke.subprocess.Popen", side_effect=launch):
                process.wait.return_value = 0
                self.assertEqual(0, run_scene(["godot"], log, "video", "default", 1))
                process.wait.return_value = 3
                self.assertEqual(1, run_scene(["godot"], log, "video", "default", 1))
                import subprocess
                process.wait.side_effect = [subprocess.TimeoutExpired("godot", 1), 0]
                with mock.patch("run_smoke.os.killpg") as kill, mock.patch("run_smoke.subprocess.run") as taskkill:
                    self.assertEqual(1, run_scene(["godot"], log, "video", "default", 1))
                    self.assertTrue(kill.called or taskkill.called)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        source = Path(__file__).resolve().parents[1] / "addon/hap_video.gdextension"
        (self.root / "hap_video.gdextension").write_bytes(source.read_bytes())
        import configparser
        manifest = configparser.ConfigParser()
        manifest.read(source)
        self.libraries = [json.loads(value) for value in manifest["libraries"].values()]
        for filename in NOTICES | set(self.libraries):
            path = self.root / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")

    def test_complete_manifest(self):
        validate(self.root)

    def test_each_notice_and_library_required_nonempty(self):
        for filename in NOTICES | set(self.libraries):
            path = self.root / filename
            path.write_text("")
            with self.subTest(filename=filename), self.assertRaises(ValueError):
                validate(self.root)
            path.write_text("fixture")

    def test_unexpected_library_rejected(self):
        (self.root / "old.dll").write_text("stale")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_manifest_path_escape_rejected(self):
        path = self.root / "hap_video.gdextension"
        for bad in ("../outside.dll", "/tmp/outside.dll", "res://outside.dll", "C:\\outside.dll"):
            path.write_text("[libraries]\nwindows.debug = " + json.dumps(bad) + "\n")
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                validate(self.root)


if __name__ == "__main__":
    unittest.main()
