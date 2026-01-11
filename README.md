Standalone build helper for producing **16KB page-size compatible** ijkplayer Android `.so` libraries.

> **Download:** Pre-built artifacts for `default` and `lite-hevc` presets (all ABIs) are available for download via the **Actions** tab.
> 
## Overview

This toolchain acts as a standalone build environment designed to modernize `ijkplayer` for current Android standards. It orchestrates the complete lifecycle—from cloning upstream sources to generating production-ready binaries.

**Key Operations:**
1.  **Dependency Compilation:** Builds OpenSSL and FFmpeg from source, ensuring full HTTPS/TLS protocol support.
2.  **16KB Compliance:** Automatically injects linker flags into `ijkplayer` and `ijksdl` build scripts to ensure `PT_LOAD` segments align to 16KB boundaries (required for Android 15+).
3.  **Automated Verification:** Post-build scripts inspect the ELF headers of every generated `.so` file to strictly enforce alignment (<= 0x4000) and verify symbol presence.

> **Build Context:**
> The helper uses a dedicated git branch within the cloned repo to maintain a clean workspace. By default, it targets upstream ref `k0.8.8`.

**Output:**
Artifacts are organized by ABI in `android-16kb/out/<abi>/*.so`.

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
- `IJKPLAYER_GIT_REF=k0.8.8` (as documented in compiling guide.)

***Note: Most users should keep these defaults. Override only if you need a fork or a specific ref.***

## Troubleshooting

- **HTTPS Protocol Not Found:** Ensure you do not pass `--no-openssl`.
- **Windows Users:** Use Docker (recommended) or WSL2.
- **WSL2 Performance:** Building from `/mnt/c/...` (Windows-mounted) paths can be slower or flaky due to filesystem semantics.
  - **Recommendation:** Clone this helper repo inside WSL (e.g., `~/ijkplayer-16kb-helper`).
  - If you must run from `/mnt/c`, only set `IJKPLAYER_DIR`, `IJK_OUT_DIR`, or `IJK_DEPS_DIR` when necessary.

## GitHub Actions CI

This repository is equipped with a default CI workflow to automate the compilation and verification process.

**Default Configuration**
Unless configured via `workflow_dispatch` inputs, the automated run uses the following production-ready defaults:

* **Codec Preset:** `default`
* **Target ABIs:** `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`
* **SSL Support:** Enabled (OpenSSL included for HTTPS compatibility)
* **Verification:** Strict 16KB `PT_LOAD` alignment check on all outputs

**Customization**
To compile with a different configuration (e.g., specific ABIs or `lite` preset):
1.  **Fork** this repository.
2.  Adjust the `--abis` and `--preset` arguments within `.github/workflows/build.yml`.
3.  Navigate to the **Actions** tab to manually trigger the workflow.

**Artifacts**
Upon successful completion, the compiled `.so` libraries are packaged and uploaded as a workflow artifact named `android-16kb-out`.

## Acknowledgments

This project is a build toolchain designed to facilitate the compilation of [ijkplayer](https://github.com/bilibili/ijkplayer).

We strictly respect the intellectual property and hard work of the original authors. The core player logic, FFmpeg integration, and architecture belong entirely to the **Bilibili** team and the open-source community.

- **ijkplayer**: [https://github.com/bilibili/ijkplayer](https://github.com/bilibili/ijkplayer)
- **FFmpeg**: [https://ffmpeg.org](https://ffmpeg.org)
- **OpenSSL**: [https://www.openssl.org](https://www.openssl.org)

## License

This project (the build scripts and helper tools) is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

### Third-Party Notices

The artifacts produced by this tool include code from the following projects, which are subject to their own licenses:

* **ijkplayer / FFmpeg**: Licensed under LGPLv2.1 (default) or GPL (if configured). Users are responsible for complying with these licenses when distributing the generated `.so` files.
* **OpenSSL**: Licensed under the Apache License 2.0.
