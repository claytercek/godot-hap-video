# Contributing

## CI validation

The shared Build workflow runs one macOS/Linux/Windows matrix entirely on
Ubuntu 24.04. Zig 0.17.0 cross-compiles six architecture targets in debug and
release flavors; `llvm-lipo-18` combines and verifies the macOS universal
libraries on Linux. No host Godot installation is needed for these builds.
The `hap-video-macos`, `hap-video-linux`, and `hap-video-windows` artifacts
remain the release-packaging inputs.

Runtime tests run only on Ubuntu 24.04 with Godot 4.7.2 and 4.6.3. They install
the Linux x86_64 release artifact and invoke `tests/run_smoke.py` directly;
do not use `zig build smoke` here, because it would rebuild the extension.
Xvfb and Mesa software Vulkan provide rendered Forward+ smoke. PCM capture
uses PulseAudio with a virtual 48,000 Hz stereo sink and requires the exact
`AUDIO_SMOKE_DRIVER: PulseAudio` marker, rejecting Dummy audio and driver
fallback. Native core tests and Python validation-helper tests run only in the
primary Godot 4.7.2 job.

CI no longer runs native macOS or Windows runtime tests. Cross-compilation
and Linux-only smoke do not establish foreign-platform loadability; validate
on the target OS when needed. Local macOS testing with `gdvm` remains supported:
follow the README's already-built-extension smoke command and omit
`--audio-driver` to use Godot's native default (CoreAudio on macOS).

## Writing release notes

Release notes come from [Changie](https://changie.dev/) fragments, not commit
messages. Install the standalone Changie v1.26.0 binary using its
[installation guide](https://changie.dev/guide/installation/), then run:

```bash
changie new
```

Commit the generated `.changes/unreleased/*.yaml` file with your PR. Describe
what changes for someone using the addon: new behavior, fixes, requirements,
and any steps needed to upgrade. Markdown and multiple paragraphs are supported.
Internal refactors, tests, and CI-only changes don't need a fragment. There's
no required fragment check in CI. Commit messages and rebase-and-merge remain
independent of release notes.

Choose `Fixed` or `Security` for a patch release; `Added`, `Changed`, or
`Deprecated` for a minor release. Put incompatible changes under `Breaking
Changes` or `Removed` and explain the migration. While the addon is pre-1.0,
these also bump the minor version; revisit that policy before releasing 1.0.
When several fragments are pending, the highest bump wins.

Preview pending release notes without modifying any files:

```bash
changie batch auto --dry-run --allow-no-changes=false
```

With no fragments, that command fails rather than producing an empty release.
Check that the generated changelog matches the committed version files with:

```bash
changie merge --dry-run | diff -u CHANGELOG.md -
```

## Publishing a release

Every push to `main` updates a single `release/changie` PR with the batched
notes and generated `CHANGELOG.md`. Review and merge that PR when ready to
release; GitHub's rebase-and-merge is supported. The Release workflow creates
the `vX.Y.Z` tag and GitHub release, then builds, validates, and attaches
the addon ZIP. With no pending fragments, no release PR is needed. The
history through `v0.3.0` is preserved in `.changes/v0.3.0.md`; subsequent
releases each have their own `.changes/v*.md` file.

Edit fragments in the originating PR rather than editing generated release-PR
files: the next update regenerates those files from `main`. Do not batch
fragments manually in feature PRs; batching is the release bot's job.

In **Settings > Actions > General > Workflow permissions**, enable **Allow
GitHub Actions to create and approve pull requests**. The workflow uses the
default `GITHUB_TOKEN`; no extra secret is needed. Workflows triggered by the
bot-created PR may require approval before running. No changelog or fragment
check is required.

To refresh the release PR, manually run **Release** on `main` with the default
inputs. Publication and PR refresh run independently, so a failed PR update
won't block a release's binary build. New tags point to the commit checked
out by the Release run. The imported `v0.3.0` baseline and existing tags are
skipped.

For a failed build, rerun the failed jobs or manually run **Release** with
`package-only` enabled and `release-tag` set to that existing release tag.
Every build and packaging checkout uses the tag, not the current `main`.
This mode skips release creation and PR refresh. Leave `release-tag` empty
to build the selected ref's SHA and upload the ZIP as a workflow artifact
without attaching it to a release. The tag input is ignored unless
`package-only` is enabled. If a tag exists without a GitHub release, create
the release for that tag using its `.changes/vX.Y.Z.md` notes before
running the build.
