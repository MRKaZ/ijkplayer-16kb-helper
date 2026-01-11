Standalone build helper for producing **16KB page-size compatible** ijkplayer Android `.so` libraries.

## What This Repo Does

1. Clones ijkplayer into `./ijkplayer`.
2. Applies a small patch so ijkplayer/ijksdl use 16KB-safe linker flags.
3. Builds OpenSSL + FFMPEG (ensuring `https://...` playback works).
4. Builds ijkplayer via `ndk-build`.
5. **Verifies:**
   - ELF `PT_LOAD` alignment is `<= 0x4000` (16KB).
   - FFMPEG has `https` + `tls` protocol support (symbols present).

> **Notes:**
>
> - Uses a dedicated git branch in the cloned ijkplayer repo for helper edits.
> - Defaults to the upstream ref `k0.8.8` unless overridden as ijkplayer compiling documentation.
> - Produces outputs per-ABI under `android-16kb/out/<abi>/`.

**Artifacts are written to**: `android-16kb/out/<abi>/*.so`

------

## Requirements

### Recommended: Docker

- Docker Desktop
- `docker compose`

### Local Linux/macOS

- Android NDK **r26+** (Recommended: `26.2.11394342`)
- Android SDK (cmdline-tools + platform-tools)
- `git`, `make`, `perl`, `patch`
- For x86/x86_64 builds: `nasm` (or `yasm`)

*This helper has been verified with Android SDK cmdline-tools + platform-tools and NDK **r26d** `26.2.11394342`.*

Environment Variables:

Set one of the following to your NDK path:

- `ANDROID_NDK=/path/to/android-ndk-r26...`
- `ANDROID_NDK_HOME=/path/to/android-ndk-r26...`

------

## Step-by-step (Docker)

### 1. Build the helper image

Bash

```
docker compose build
```

### 2. Run the interactive helper

Bash

```
docker compose run --rm ijk16k-helper
```

### 3. Follow the prompts

- ABI selection (single / 32-bit / 64-bit / all)
- Codec preset (lite / lite-hevc / default)

### Non-interactive Examples (Docker)

**arm64 + x86_64, lite preset:**

Bash

```
docker compose run --rm ijk16k-helper \
  bash -lc "bash ./scripts/run.sh --non-interactive --abis arm64-v8a,x86_64 --preset lite"
```

**All ABIs, lite-hevc preset:**

Bash

```
docker compose run --rm ijk16k-helper \
  bash -lc "bash ./scripts/run.sh --non-interactive --clean --abis arm64-v8a,armeabi-v7a,x86,x86_64 --preset lite-hevc"
```

------

## Step-by-step (Linux/macOS)

### 1. Install Dependencies

If you do not have the Android SDK/NDK set up, run:

Bash

```
bash ./scripts/setup-unix.sh
source ./scripts/android-env.sh
```

### 2. Configure NDK

If you already have an NDK installed, point to it:

Bash

```
export ANDROID_NDK=/path/to/android-ndk-r26...
```

### 3. Run Interactive Build

Bash

```
bash ./scripts/run.sh
```

------

## Command-line Arguments

Use `--help` to print all options:

Bash

```
bash ./scripts/run.sh --help
```

**Common Arguments:**

- `--non-interactive` (Requires `--abis` and `--preset`)
- `--abis <csv>` (e.g., `arm64-v8a,x86_64`)
- `--preset <lite|lite-hevc|default>`
- `--clean` (Remove previous outputs)
- `--no-openssl` (Build without HTTPS/TLS)

------

## Non-interactive Examples

### Local (Linux/macOS)

**Clean build, all ABIs, default preset:**

Bash

```
bash ./scripts/run.sh --non-interactive --clean \
  --abis arm64-v8a,armeabi-v7a,x86,x86_64 \
  --preset default
```

**Lite preset (smallest size):**

Bash

```
bash ./scripts/run.sh --non-interactive --abis arm64-v8a,x86_64 --preset lite
```

**Lite-HEVC preset:**

Bash

```
bash ./scripts/run.sh --non-interactive --abis arm64-v8a,armeabi-v7a,x86,x86_64 --preset lite-hevc
```

### Docker (CI-friendly)

**Clean build, all ABIs, default preset:**

Bash

```
docker compose run --rm ijk16k-helper \
  bash -lc "bash ./scripts/run.sh --non-interactive --clean --abis arm64-v8a,armeabi-v7a,x86,x86_64 --preset default"
```

**arm64 only, lite preset:**

Bash

```
docker compose run --rm ijk16k-helper \
  bash -lc "bash ./scripts/run.sh --non-interactive --abis arm64-v8a --preset lite"
```

**All ABIs, lite-hevc preset:**

Bash

```
docker compose run --rm ijk16k-helper \
  bash -lc "bash ./scripts/run.sh --non-interactive --clean --abis arm64-v8a,armeabi-v7a,x86,x86_64 --preset lite-hevc"
```

------

## Repo Selection (Choose ijkplayer Source)

**Defaults:**

- `IJKPLAYER_GIT_URL=https://github.com/bilibili/ijkplayer.git`
- `IJKPLAYER_GIT_REF=k0.8.8`

***Note: Most users should keep these defaults. Override only if you need a fork or a specific ref.***

Bash

```
export IJKPLAYER_GIT_URL=https://github.com/your-fork/ijkplayer.git
export IJKPLAYER_GIT_REF=your-branch-or-commit
```

------

## Troubleshooting

- **HTTPS Protocol Not Found:** Ensure you do not pass `--no-openssl`.
- **Windows Users:** Use Docker (recommended) or WSL2.
- **WSL2 Performance:** Building from `/mnt/c/...` (Windows-mounted) paths can be slower or flaky due to filesystem semantics.
  - **Recommendation:** Clone this helper repo inside WSL (e.g., `~/ijkplayer-16kb-helper`).
  - If you must run from `/mnt/c`, only set `IJKPLAYER_DIR`, `IJK_OUT_DIR`, or `IJK_DEPS_DIR` when necessary.
