#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HELPER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_IJKPLAYER_GIT_URL="https://github.com/bilibili/ijkplayer.git"
DEFAULT_IJKPLAYER_GIT_REF="k0.8.8"

usage() {
  cat <<'EOF'
Standalone ijkplayer 16KB-page-size helper.

What it does:
  1) Clones ijkplayer into ./ijkplayer
  2) Applies patches to enable 16KB linker flags for ijkplayer/ijksdl
  3) Selects ABIs + codec preset (lite / lite+hevc / default)
  4) Builds OpenSSL+FFmpeg (https/tls enabled) + ijkplayer
  5) Verifies 16KB ELF alignment + HTTPS/TLS symbols

Usage:
  ./scripts/run.sh
  ./scripts/run.sh --non-interactive --abis arm64-v8a,x86_64 --preset default
  ./scripts/setup-unix.sh   # Linux/macOS: install deps + Android SDK/NDK (optional helper)

Options:
  --non-interactive         No prompts; requires --abis and --preset (or env vars)
  --abis <csv>              e.g. arm64-v8a,x86_64,armeabi-v7a,x86
  --preset <lite|lite-hevc|default>
  --clean                   Remove previous outputs before building
  --no-openssl              Build without HTTPS/TLS support in FFmpeg

Environment:
  IJKPLAYER_GIT_URL         ijkplayer repo URL (default: https://github.com/bilibili/ijkplayer.git)
  IJKPLAYER_GIT_REF         git ref/tag/commit (default: k0.8.8)

  IJKPLAYER_DIR             Where ijkplayer is cloned (default: <helper>/ijkplayer)
  IJK_OUT_DIR               Build outputs directory (default: <helper>/android-16kb/out)
  IJK_DEPS_DIR              Deps/build directory for OpenSSL (default: <helper>/android-16kb/.deps)

  (Most users should keep defaults; override only if you need custom paths or a fork/ref.)

  ANDROID_NDK or ANDROID_NDK_HOME
                            Path to Android NDK r26+ (Docker image sets ANDROID_NDK automatically)

Outputs:
  android-16kb/out/<abi>/*.so
EOF
}

fail() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

is_wsl() {
  [[ -r /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease
}

is_windows_mount_path() {
  local p="$1"
  [[ "$p" == /mnt/* ]]
}

prompt() {
  local msg="$1"
  local default_value="${2:-}"
  local input=""
  if [[ -n "$default_value" ]]; then
    read -r -p "$msg [$default_value]: " input || true
    echo "${input:-$default_value}"
  else
    read -r -p "$msg: " input || true
    echo "$input"
  fi
}

maybe_source_android_env() {
  # If user ran ./scripts/setup-unix.sh, it generates this file.
  local env_file="$SCRIPT_DIR/android-env.sh"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
  fi
}

ndk_is_set() {
  [[ -n "${ANDROID_NDK:-}" || -n "${ANDROID_NDK_HOME:-}" ]]
}

ensure_ndk_configured() {
  local non_interactive="$1"

  if ndk_is_set; then
    return 0
  fi

  local os
  os="$(uname -s)"
  if [[ "$os" == "Linux" || "$os" == "Darwin" ]]; then
    if [[ "$non_interactive" == "1" ]]; then
      fail "ANDROID_NDK is not set. Set ANDROID_NDK (or ANDROID_NDK_HOME), or run: bash ./scripts/setup-unix.sh"
    fi

    echo ""
    echo "Android NDK is not configured. Choose one:"
    echo "  1) Download/install Android SDK+NDK now (recommended)"
    echo "  2) I will export ANDROID_NDK manually and retry"
    local choice
    choice="$(prompt "Choice" "1")"
    case "$choice" in
      1)
        bash "$SCRIPT_DIR/setup-unix.sh"
        maybe_source_android_env
        ndk_is_set || fail "ANDROID_NDK still not set. Please export it and re-run." 
        ;;
      2)
        fail "Set ANDROID_NDK (or ANDROID_NDK_HOME) and re-run ./scripts/run.sh"
        ;;
      *) fail "Invalid choice";;
    esac
  else
    fail "ANDROID_NDK is not set. On Windows, use Docker or WSL2."
  fi
}

ijkplayer_dir() {
  # Default clone location: <helper>/ijkplayer
  echo "${IJKPLAYER_DIR:-$HELPER_DIR/ijkplayer}"
}

legacy_ijkplayer_dir() {
  echo "$HELPER_DIR/work/ijkplayer"
}

sanitize_branch_name() {
  local name="$1"
  name="${name//[^A-Za-z0-9._-]/-}"
  echo "$name"
}

clone_or_update_ijkplayer() {
  local url="$1"
  local ref="$2"
  local dst
  dst="$(ijkplayer_dir)"
  local legacy
  legacy="$(legacy_ijkplayer_dir)"

  # Migrate older layout (<helper>/work/ijkplayer) to the new default (<helper>/ijkplayer).
  if [[ ! -d "$dst/.git" && -d "$legacy/.git" ]]; then
    echo "[*] Migrating legacy clone: $legacy -> $dst"
    mkdir -p "$(dirname "$dst")"
    if mv "$legacy" "$dst" 2>/dev/null; then
      rmdir "$HELPER_DIR/work" >/dev/null 2>&1 || true
    else
      echo "[!] WARN: Could not migrate legacy clone (permission denied?). Using legacy path: $legacy" >&2
      dst="$legacy"
      export IJKPLAYER_DIR="$dst"
    fi
  fi

  if [[ -d "$dst/.git" ]]; then
    echo "[*] Updating ijkplayer: $dst"
    if ! (cd "$dst" && git fetch --tags --force); then
      echo "[!] WARN: git fetch failed; using existing ijkplayer checkout." >&2
    fi
  else
    echo "[*] Cloning ijkplayer: $url -> $dst"
    git clone "$url" "$dst"
  fi

  local branch
  branch="$(sanitize_branch_name "ijk-16kb-${ref}")"

  echo "[*] Switching to: $ref (branch: $branch)"
  if (cd "$dst" && git show-ref --verify --quiet "refs/heads/$branch"); then
    (cd "$dst" && git switch "$branch") || fail "Failed to switch to branch: $branch"
    return 0
  fi

  (cd "$dst" && git switch -c "$branch" "$ref") || fail "Failed to create branch: $branch"
}

apply_patches() {
  local dst
  dst="$(ijkplayer_dir)"
  [[ -d "$dst/.git" ]] || fail "ijkplayer repo not found at $dst"
  need_cmd perl

  echo "[*] Enabling 16KB linker flags in ijkplayer/ijksdl (idempotent)"

  # Recover from any previous run that may have modified these files.
  (cd "$dst" && git restore -- \
    ijkmedia/ijksdl/Android.mk \
    ijkmedia/ijkplayer/Android.mk \
    ijkmedia/ijkj4a/Android.mk \
    ijkmedia/ijksdl/ijksdl_egl.c \
    ijkmedia/ijkplayer/ff_ffplay.c \
    ijkmedia/ijkplayer/android/pipeline/ffpipeline_android.c \
    >/dev/null 2>&1 || true)

  local files_for_16k=(
    "$dst/ijkmedia/ijksdl/Android.mk"
    "$dst/ijkmedia/ijkplayer/Android.mk"
  )

  local files_for_c99_fix=(
    "$dst/ijkmedia/ijksdl/Android.mk"
    "$dst/ijkmedia/ijkplayer/Android.mk"
    "$dst/ijkmedia/ijkj4a/Android.mk"
  )

  for f in "${files_for_c99_fix[@]}"; do
    [[ -f "$f" ]] || fail "Expected makefile not found: $f"

    # ndk-build applies LOCAL_CFLAGS to both C and C++ compilation.
    # ijkplayer builds a C++ TU (ijkstl.cpp) inside the ijkplayer module, so keeping
    # -std=c99 in LOCAL_CFLAGS breaks with: "invalid argument '-std=c99' not allowed with 'C++'".
    # Use LOCAL_CONLYFLAGS so it only affects C sources.
    if grep -qE '^[[:space:]]*LOCAL_CFLAGS[[:space:]]*\+=[[:space:]]*-std=c99[[:space:]]*$' "$f"; then
      perl -i -pe 's/^([ \t]*)LOCAL_CFLAGS([ \t]*)\+=[ \t]*-std=c99[ \t]*$/${1}LOCAL_CONLYFLAGS${2}+= -std=c99/m' "$f"
    fi
  done

  local snippet
  snippet=$'\nifeq ($(IJK_16K_PAGE_SIZE),1)\nLOCAL_LDFLAGS += -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384\nendif\n'
  export IJK_16K_SNIPPET="$snippet"

  for f in "${files_for_16k[@]}"; do
    [[ -f "$f" ]] || fail "Expected makefile not found: $f"

    if grep -q "IJK_16K_PAGE_SIZE" "$f"; then
      continue
    fi

    # Insert the snippet immediately after the first LOCAL_LDLIBS line.
    perl -0777 -i -pe 'BEGIN{$s=$ENV{"IJK_16K_SNIPPET"}} $c=0; $c += s/(^LOCAL_LDLIBS[^\n]*\n)/$1.$s."\n"/me; END{ exit 3 if !$c }' "$f" || {
      fail "Failed to patch $f (LOCAL_LDLIBS line not found?)"
    }
  done

  echo "[*] Applying NDK r26+ compatibility fixes (idempotent)"

  local ffplay_c="$dst/ijkmedia/ijkplayer/ff_ffplay.c"
  if [[ -f "$ffplay_c" ]]; then
    # Upstream defines isnan() in terms of isnanf(), but modern NDK headers may not expose isnanf()
    # in C mode, which breaks compilation under clang with C99+.
    if grep -q "isnanf((float)(x))" "$ffplay_c"; then
      perl -i -pe 's/^#define\s+isnan\(x\)\s+\(isnan\(\(double\)\(x\)\)\s+\|\|\s+isnanf\(\(float\)\(x\)\)\)\s*[ \t]*$/#define isnan(x) __builtin_isnan((x))/m' "$ffplay_c"
    fi
    # Guard against a bad prior edit that accidentally concatenated the next #endif onto the same line.
    if grep -q "__builtin_isnan((x))#endif" "$ffplay_c"; then
      perl -0777 -i -pe 's/#define\s+isnan\(x\)\s+__builtin_isnan\(\(x\)\)#endif/#define isnan(x) __builtin_isnan((x))\n#endif/g' "$ffplay_c"
    fi
  else
    echo "[!] WARN: expected file not found (skipping): $ffplay_c" >&2
  fi

  local pipeline_c="$dst/ijkmedia/ijkplayer/android/pipeline/ffpipeline_android.c"
  if [[ -f "$pipeline_c" ]]; then
    # clang rejects initializing an int with NULL (void*).
    if grep -qE '^[[:space:]]*int[[:space:]]+ret[[:space:]]*=[[:space:]]*NULL[[:space:]]*;' "$pipeline_c"; then
      perl -i -pe 's/^([ \t]*int[ \t]+ret[ \t]*=)[ \t]*NULL([ \t]*;)/$1 0$2/m' "$pipeline_c"
    fi
  else
    echo "[!] WARN: expected file not found (skipping): $pipeline_c" >&2
  fi

  local egl_c="$dst/ijkmedia/ijksdl/ijksdl_egl.c"
  if [[ -f "$egl_c" ]]; then
    # Modern clang in C99+ mode treats missing prototypes as errors.
    # ijksdl_egl.c calls ANativeWindow_* APIs but doesn't include <android/native_window.h>.
    if ! grep -q "<android/native_window.h>" "$egl_c"; then
      perl -i -pe 's@(#include\s+<stdbool\.h>\s*\n)@$1#ifdef __ANDROID__\n#include <android/native_window.h>\n#endif\n@ms' "$egl_c"
    fi
  else
    echo "[!] WARN: expected file not found (skipping): $egl_c" >&2
  fi
}

set_codec_preset() {
  local preset="$1"
  local dst
  dst="$(ijkplayer_dir)"
  local module_sh="$dst/config/module.sh"

  [[ -d "$dst/config" ]] || fail "Expected ijkplayer config dir: $dst/config"

  local module
  case "$preset" in
    lite) module="module-lite.sh";;
    lite-hevc) module="module-lite-hevc.sh";;
    default) module="module-default.sh";;
    *) fail "Unknown preset: $preset";;
  esac

  [[ -f "$dst/config/$module" ]] || fail "Missing module config in ijkplayer: $dst/config/$module"

  echo "[*] Selecting codec preset: $preset ($module)"

  # ijkplayer upstream may have config/module.sh as a symlink (often pointing to module-lite.sh).
  # Writing to it would overwrite the symlink target, corrupting module scripts.
  (cd "$dst" && git restore -- config/module-lite.sh config/module-lite-hevc.sh config/module-default.sh >/dev/null 2>&1 || true)

  rm -f "$module_sh"
  cp -f "$dst/config/$module" "$module_sh"
}

choose_abis_interactive() {
  cat >&2 <<'EOF'
Select ABIs:
  1) Single ABI
  2) All 32-bit (armeabi-v7a,x86)
  3) All 64-bit (arm64-v8a,x86_64)
  4) All ABIs (arm64-v8a,armeabi-v7a,x86,x86_64)
EOF
  local choice
  choice="$(prompt "Choice" "4")"
  case "$choice" in
    1)
      cat >&2 <<'EOF'
Single ABI:
  1) arm64-v8a
  2) armeabi-v7a
  3) x86
  4) x86_64
EOF
      local abi_choice
      abi_choice="$(prompt "ABI" "1")"
      case "$abi_choice" in
        1) echo "arm64-v8a";;
        2) echo "armeabi-v7a";;
        3) echo "x86";;
        4) echo "x86_64";;
        *) fail "Invalid ABI choice";;
      esac
      ;;
    2) echo "armeabi-v7a,x86";;
    3) echo "arm64-v8a,x86_64";;
    4) echo "arm64-v8a,armeabi-v7a,x86,x86_64";;
    *) fail "Invalid choice";;
  esac
}

choose_preset_interactive() {
  cat >&2 <<'EOF'
Select codec preset:
  1) lite       (smallest)
  2) lite-hevc  (lite + HEVC)
  3) default    (largest)
EOF
  local choice
  choice="$(prompt "Choice" "1")"
  case "$choice" in
    1) echo "lite";;
    2) echo "lite-hevc";;
    3) echo "default";;
    *) fail "Invalid choice";;
  esac
}

main() {
  local non_interactive=0
  local abis="${IJK_ABIS:-}"
  local preset="${IJK_CODEC_PRESET:-}"
  local clean=0
  local no_openssl=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --non-interactive) non_interactive=1; shift;;
      --abis) abis="$2"; shift 2;;
      --preset) preset="$2"; shift 2;;
      --clean) clean=1; shift;;
      --no-openssl) no_openssl=1; shift;;
      *) fail "Unknown arg: $1";;
    esac
  done

  need_cmd git

  maybe_source_android_env
  ensure_ndk_configured "$non_interactive"

  local url="${IJKPLAYER_GIT_URL:-$DEFAULT_IJKPLAYER_GIT_URL}"
  local ref="${IJKPLAYER_GIT_REF:-$DEFAULT_IJKPLAYER_GIT_REF}"

  if [[ "$non_interactive" == 0 ]]; then
    abis="${abis:-$(choose_abis_interactive)}"
    preset="${preset:-$(choose_preset_interactive)}"
  else
    [[ -n "$abis" ]] || fail "--abis (or IJK_ABIS) is required in --non-interactive mode"
    [[ -n "$preset" ]] || fail "--preset (or IJK_CODEC_PRESET) is required in --non-interactive mode"
  fi

  clone_or_update_ijkplayer "$url" "$ref"
  apply_patches
  set_codec_preset "$preset"

  export IJKPLAYER_ROOT="$(ijkplayer_dir)"

  local build_args=("--abis" "$abis")
  if [[ "$clean" == 1 ]]; then build_args+=("--clean"); fi
  if [[ "$no_openssl" == 1 ]]; then build_args+=("--no-openssl"); fi

  echo "[*] Building (abis=$abis preset=$preset openssl=$((1-no_openssl)))"
  (cd "$HELPER_DIR" && bash ./android-16kb/build.sh "${build_args[@]}")

  echo "[*] Success. Artifacts in: ${IJK_OUT_DIR:-$HELPER_DIR/android-16kb/out}"
}

main "$@"
