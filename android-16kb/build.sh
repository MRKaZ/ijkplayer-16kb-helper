#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HELPER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional overrides (use only if you need outputs outside the repo).
# Examples:
#   export IJK_OUT_DIR="$HELPER_DIR/android-16kb/out"
#   export IJK_DEPS_DIR="$HELPER_DIR/android-16kb/.deps"
OUT_DIR_DEFAULT="$SCRIPT_DIR/out"
DEPS_DIR_DEFAULT="$SCRIPT_DIR/.deps"
OUT_DIR="${IJK_OUT_DIR:-$OUT_DIR_DEFAULT}"
DEPS_DIR="${IJK_DEPS_DIR:-$DEPS_DIR_DEFAULT}"

# Path to the ijkplayer source tree.
# The helper repo clones ijkplayer into: <helper>/ijkplayer
IJKPLAYER_ROOT="${IJKPLAYER_ROOT:-${HELPER_DIR}/ijkplayer}"
ROOT_DIR="$(cd "${IJKPLAYER_ROOT}" && pwd)"

DEFAULT_ABIS="arm64-v8a"
PAGE_SIZE_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

# TLS backend for FFmpeg HTTPS support
DEFAULT_WITH_OPENSSL=1
DEFAULT_OPENSSL_REF="openssl-3.0.13"
DEFAULT_OPENSSL_UPSTREAM="https://github.com/openssl/openssl.git"

usage() {
  cat <<'EOF'
Build ijkplayer + bundled FFmpeg with 16KB-page-size-compatible ELF segment alignment.

Usage:
  ./android-16kb/build.sh [--abis arm64-v8a,x86_64,armeabi-v7a] [--clean] [--no-openssl]

Environment:
  IJKPLAYER_ROOT        Path to ijkplayer source tree (default: ../ijkplayer)
  ANDROID_NDK or ANDROID_NDK_HOME
                        Must point to Android NDK r26+ (LLVM lld).
  IJK_OUT_DIR            Optional override for output folder (default: android-16kb/out)
  IJK_DEPS_DIR           Optional override for deps/build folder (default: android-16kb/.deps)

Outputs:
  <IJK_OUT_DIR>/<abi>/ or android-16kb/out/<abi>/   (final .so files)

Notes:
  - This 16KB flow intentionally uses modern NDK + clang.
  - Legacy scripts under android/contrib/tools use old standalone toolchain and are not used here.
  - HTTPS playback requires a TLS backend; by default this script builds OpenSSL and enables FFmpeg https/tls.
EOF
}

fail() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

sanitize_branch_name() {
  local name="$1"
  name="${name//[^A-Za-z0-9._-]/-}"
  echo "$name"
}

strip_crlf_inplace() {
  # Windows checkouts mounted into Linux containers/WSL may contain CRLF.
  # This breaks bash/sh with errors like $'\r': command not found.
  local f="$1"
  [[ -f "$f" ]] || return 0
  if command -v grep >/dev/null 2>&1; then
    if ! grep -q $'\r' "$f"; then
      return 0
    fi
  fi
  sed -i 's/\r$//' "$f" || true
}

normalize_repo_line_endings() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    return 0
  fi

  strip_crlf_inplace "$ROOT_DIR/init-android.sh"
  strip_crlf_inplace "$ROOT_DIR/init-config.sh"
  strip_crlf_inplace "$ROOT_DIR/init-android-libyuv.sh"
  strip_crlf_inplace "$ROOT_DIR/init-android-soundtouch.sh"

  if [[ -d "$ROOT_DIR/tools" ]]; then
    while IFS= read -r -d '' f; do
      strip_crlf_inplace "$f"
    done < <(find "$ROOT_DIR/tools" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null || true)
  fi

  if [[ -d "$ROOT_DIR/config" ]]; then
    while IFS= read -r -d '' f; do
      strip_crlf_inplace "$f"
    done < <(find "$ROOT_DIR/config" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null || true)
  fi

  if [[ -d "$ROOT_DIR/android/contrib/tools" ]]; then
    while IFS= read -r -d '' f; do
      strip_crlf_inplace "$f"
    done < <(find "$ROOT_DIR/android/contrib/tools" -type f -name '*.sh' -print0 2>/dev/null || true)
  fi

  strip_crlf_inplace "$ROOT_DIR/android/contrib/compile-ffmpeg.sh"
  strip_crlf_inplace "$ROOT_DIR/android/compile-ijk.sh"

  strip_crlf_inplace "$ROOT_DIR/ijkmedia/ijkplayer/version.sh"
}

ndk_path() {
  if [[ -n "${ANDROID_NDK:-}" ]]; then echo "$ANDROID_NDK"; return; fi
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then echo "$ANDROID_NDK_HOME"; return; fi
  fail "Set ANDROID_NDK (or ANDROID_NDK_HOME) to your NDK path"
}

host_tag() {
  local u
  u="$(uname -s)"
  case "$u" in
    Linux) echo "linux-x86_64";;
    Darwin)
      if [[ "$(uname -m)" == "arm64" ]]; then echo "darwin-arm64"; else echo "darwin-x86_64"; fi
      ;;
    CYGWIN*|MINGW*|MSYS*)
      fail "Native Windows bash environments are not supported here; use WSL2 or Docker"
      ;;
    *) fail "Unsupported host OS: $u";;
  esac
}

ndk_major() {
  local ndk="$1"
  local rev
  rev="$(grep -E '^Pkg\.Revision' "$ndk/source.properties" | cut -d= -f2 | tr -d ' ' || true)"
  [[ -n "$rev" ]] || fail "Cannot determine NDK version from $ndk/source.properties"
  echo "${rev%%.*}"
}

abi_to_ff_arch() {
  case "$1" in
    arm64-v8a) echo "arm64";;
    armeabi-v7a) echo "armv7a";;
    x86) echo "x86";;
    x86_64) echo "x86_64";;
    *) fail "Unsupported ABI: $1";;
  esac
}

abi_to_android_api() {
  case "$1" in
    arm64-v8a|x86_64|x86|armeabi-v7a) echo "21";;
    *) fail "Unsupported ABI: $1";;
  esac
}

abi_to_clang_triple() {
  local abi="$1"
  local api="$2"
  case "$abi" in
    arm64-v8a) echo "aarch64-linux-android${api}";;
    x86) echo "i686-linux-android${api}";;
    x86_64) echo "x86_64-linux-android${api}";;
    armeabi-v7a) echo "armv7a-linux-androideabi${api}";;
    *) fail "Unsupported ABI: $abi";;
  esac
}

ensure_init_done() {
  if [[ ! -d "${ROOT_DIR}/android/contrib/ffmpeg-arm64" ]]; then
    echo "[*] Running init-android.sh (clones FFmpeg fork + deps)"
    normalize_repo_line_endings
    local attempt=1
    local max_attempts=3
    while true; do
      if (cd "$ROOT_DIR" && bash ./init-android.sh); then
        break
      fi

      if [[ "$attempt" -ge "$max_attempts" ]]; then
        fail "init-android.sh failed after ${max_attempts} attempts (network issue?)"
      fi

      echo "[!] WARN: init-android.sh failed; cleaning partial ffmpeg clone and retrying... (${attempt}/${max_attempts})" >&2
      rm -rf "$ROOT_DIR/extra/ffmpeg" || true
      attempt=$((attempt + 1))
      sleep $((attempt * 2))
    done
  fi
}

ensure_openssl_src() {
  local ref="${OPENSSL_REF:-$DEFAULT_OPENSSL_REF}"
  local upstream="${OPENSSL_UPSTREAM:-$DEFAULT_OPENSSL_UPSTREAM}"
  local src_dir="$DEPS_DIR/src/openssl"
  local branch
  branch="$(sanitize_branch_name "openssl-${ref}")"

  mkdir -p "$(dirname "$src_dir")"

  if [[ -d "$src_dir/.git" ]]; then
    (cd "$src_dir" && git fetch --tags --force >/dev/null 2>&1 || true)
    if (cd "$src_dir" && git show-ref --verify --quiet "refs/heads/$branch"); then
      (cd "$src_dir" && git switch "$branch" >/dev/null 2>&1) || fail "Failed to switch OpenSSL branch: $branch"
      return 0
    fi
    (cd "$src_dir" && git switch -c "$branch" "$ref" >/dev/null 2>&1) || fail "Failed to switch OpenSSL ref: $ref"
    return 0
  fi

  echo "[*] Fetching OpenSSL source ($ref)"
  if git clone --depth 1 --branch "$ref" "$upstream" "$src_dir" >/dev/null 2>&1; then
    return 0
  fi

  git clone "$upstream" "$src_dir" >/dev/null 2>&1 || fail "Failed to clone OpenSSL from: $upstream"
  if (cd "$src_dir" && git switch -c "$branch" "$ref" >/dev/null 2>&1); then
    return 0
  fi
  (cd "$src_dir" && git show-ref --verify --quiet "refs/heads/$branch" && git switch "$branch" >/dev/null 2>&1) || fail "Failed to switch OpenSSL ref: $ref"
}

abi_to_openssl_target() {
  case "$1" in
    arm64-v8a) echo "android-arm64";;
    armeabi-v7a) echo "android-arm";;
    x86) echo "android-x86";;
    x86_64) echo "android-x86_64";;
    *) fail "Unsupported ABI for OpenSSL: $1";;
  esac
}

build_openssl_one() {
  local abi="$1"
  local ndk="$2"
  local host="$3"
  local api triple toolbin sysroot openssl_target openssl_src prefix

  api="$(abi_to_android_api "$abi")"
  triple="$(abi_to_clang_triple "$abi" "$api")"
  toolbin="$ndk/toolchains/llvm/prebuilt/$host/bin"
  sysroot="$ndk/toolchains/llvm/prebuilt/$host/sysroot"
  openssl_target="$(abi_to_openssl_target "$abi")"

  ensure_openssl_src
  openssl_src="$DEPS_DIR/src/openssl"
  prefix="$DEPS_DIR/build/openssl-${abi}/output"

  if [[ -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" ]]; then
    echo "[*] OpenSSL already built for $abi"
    return 0
  fi

  echo "[*] Building OpenSSL for $abi ($openssl_target)"
  mkdir -p "$prefix"

  pushd "$openssl_src" >/dev/null

  if [[ -f "Makefile" ]]; then
    make distclean >/dev/null 2>&1 || make clean >/dev/null 2>&1 || true
  fi

  export ANDROID_NDK_HOME="$ndk"
  export ANDROID_NDK_ROOT="$ndk"
  export PATH="$toolbin:$PATH"
  export CC="$toolbin/${triple}-clang"
  export AR="$toolbin/llvm-ar"
  export RANLIB="$toolbin/llvm-ranlib"
  export CFLAGS="--sysroot=${sysroot} -fPIC"
  export LDFLAGS="--sysroot=${sysroot}"

  ./Configure "$openssl_target" "-D__ANDROID_API__=${api}" no-shared no-tests \
    --prefix="$prefix" --libdir=lib >/dev/null

  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null
  make install_sw >/dev/null

  popd >/dev/null
}

build_ffmpeg_one() {
  local abi="$1"
  local ndk="$2"
  local host="$3"

  local ff_arch api triple toolbin sysroot ff_src prefix
  ff_arch="$(abi_to_ff_arch "$abi")"
  api="$(abi_to_android_api "$abi")"

  toolbin="$ndk/toolchains/llvm/prebuilt/$host/bin"
  [[ -d "$toolbin" ]] || fail "NDK toolchain bin not found: $toolbin"

  sysroot="$ndk/toolchains/llvm/prebuilt/$host/sysroot"
  [[ -d "$sysroot" ]] || fail "NDK sysroot not found: $sysroot"

  ff_src="$ROOT_DIR/android/contrib/ffmpeg-${ff_arch}"
  [[ -d "$ff_src" ]] || fail "FFmpeg source not found: $ff_src (did init run?)"

  prefix="$ROOT_DIR/android/contrib/build/ffmpeg-${ff_arch}/output"
  mkdir -p "$prefix"

  triple="$(abi_to_clang_triple "$abi" "$api")"

  echo "[*] Building FFmpeg for $abi (source=ffmpeg-${ff_arch})"

  load_ijk_module_config() {
    local module_path="$ROOT_DIR/config/module.sh"
    [[ -f "$module_path" ]] || fail "Missing config: $module_path"

    local first_line
    first_line="$(head -n 1 "$module_path" | tr -d '\r' || true)"
    if [[ "$first_line" =~ ^[A-Za-z0-9._-]+\.sh$ ]] && [[ -f "$ROOT_DIR/config/$first_line" ]]; then
      # shellcheck disable=SC1090
      source "$ROOT_DIR/config/$first_line"
    else
      # shellcheck disable=SC1090
      source "$module_path"
    fi
  }

  load_ijk_module_config

  local openssl_prefix=""
  if [[ "${WITH_OPENSSL:-$DEFAULT_WITH_OPENSSL}" == "1" ]]; then
    build_openssl_one "$abi" "$ndk" "$host"
    openssl_prefix="$DEPS_DIR/build/openssl-${abi}/output"
  fi

  pushd "$ff_src" >/dev/null

  need_cmd make
  need_cmd perl

  export CC="$toolbin/${triple}-clang"
  export CXX="$toolbin/${triple}-clang++"
  export AR="$toolbin/llvm-ar"
  export RANLIB="$toolbin/llvm-ranlib"
  export STRIP="$toolbin/llvm-strip"
  export NM="$toolbin/llvm-nm"

  local cfg=""
  cfg+=" --prefix=${prefix}"
  cfg+=" --enable-cross-compile --target-os=android"
  cfg+=" --enable-pic"
  cfg+=" --disable-programs --disable-doc"
  # Some ijkplayer module presets still include legacy FFmpeg flags like --disable-ffserver.
  # Newer FFmpeg dropped ffserver entirely, and configure will hard-fail on unknown options.
  local common_cfg_flags="${COMMON_FF_CFG_FLAGS:-}"
  common_cfg_flags="${common_cfg_flags//--disable-ffserver/}"
  cfg+=" ${common_cfg_flags}"

  if [[ -n "$openssl_prefix" ]]; then
    cfg+=" --enable-openssl"
    cfg+=" --enable-protocol=https --enable-protocol=tls"
  fi

  case "$abi" in
    arm64-v8a) cfg+=" --arch=aarch64 --disable-asm --disable-inline-asm";;
    armeabi-v7a) cfg+=" --arch=arm --cpu=cortex-a8 --enable-neon --enable-thumb --disable-asm --disable-inline-asm";;
    x86) cfg+=" --arch=x86 --cpu=i686 --disable-asm --disable-inline-asm";;
    x86_64) cfg+=" --arch=x86_64 --disable-asm --disable-inline-asm";;
  esac

  local extra_cflags="-O3 -fPIC -DANDROID -DNDEBUG --sysroot=${sysroot} \
    -Wno-error -Wno-error=int-conversion -Wno-error=format -Wno-error=incompatible-function-pointer-types \
    -Wno-int-conversion -Wno-format -Wno-incompatible-function-pointer-types"
  if [[ -n "$openssl_prefix" ]]; then
    extra_cflags+=" -DOPENSSL_API_COMPAT=0x10100000L"
    extra_cflags+=" -I${openssl_prefix}/include"
  fi

  local extra_ldflags="${PAGE_SIZE_FLAGS}"
  local extra_libs=""
  if [[ -n "$openssl_prefix" ]]; then
    extra_ldflags+=" -L${openssl_prefix}/lib"
    extra_libs="-lssl -lcrypto -ldl"
  fi

  local old_pkg_config_path="${PKG_CONFIG_PATH:-}"
  if [[ -n "$openssl_prefix" ]]; then
    export PKG_CONFIG_PATH="${openssl_prefix}/lib/pkgconfig${old_pkg_config_path:+:$old_pkg_config_path}"
  fi

  if [[ -f "config.h" ]]; then
    if make distclean >/dev/null 2>&1; then
      true
    else
      make clean >/dev/null 2>&1 || true
    fi
  fi

  echo "[*] ./configure (this can take a while)"
  # shellcheck disable=SC2086
  ./configure $cfg \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --nm="$NM" \
    --extra-cflags="$extra_cflags" \
    --extra-ldflags="$extra_ldflags" \
    ${extra_libs:+--extra-libs="$extra_libs"}

  echo "[*] make + make install"
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null
  make install

  if [[ -n "$openssl_prefix" ]]; then
    export PKG_CONFIG_PATH="$old_pkg_config_path"
  fi

  mkdir -p "${prefix}/include/libffmpeg"
  cp -f config.h "${prefix}/include/libffmpeg/config.h"

  echo "[*] Linking monolithic libijkffmpeg.so"
  local module_dirs=(compat libavcodec libavfilter libavformat libavutil libswresample libswscale)
  local c_objs=""
  for d in "${module_dirs[@]}"; do
    if ls "$d"/*.o >/dev/null 2>&1; then
      c_objs+=" $d/*.o"
    fi
    if ls "$d"/*/*.o >/dev/null 2>&1; then
      c_objs+=" $d/*/*.o"
    fi
  done

  # Link OpenSSL statically into libijkffmpeg.so to ensure https/tls is available at runtime.
  # shellcheck disable=SC2086
  "$CC" -shared --sysroot="$sysroot" -Wl,--no-undefined -Wl,-z,noexecstack ${PAGE_SIZE_FLAGS} \
    -Wl,-soname,libijkffmpeg.so \
    $c_objs \
    ${openssl_prefix:+-L"$openssl_prefix/lib" -lssl -lcrypto -ldl} \
    -lm -lz \
    -o "${prefix}/libijkffmpeg.so"

  popd >/dev/null
}

build_ijk_one() {
  local abi="$1"
  local ndk="$2"
  local out_dir="$3"

  [[ -x "$ndk/ndk-build" ]] || fail "ndk-build not found/executable at: $ndk/ndk-build"

  local app_mk="$SCRIPT_DIR/ndk/Application-${abi}.mk"
  [[ -f "$app_mk" ]] || fail "Missing NDK Application.mk override: $app_mk"

  local jni_dir="$ROOT_DIR/android/ijkplayer/ijkplayer-armv7a/src/main/jni"
  [[ -d "$jni_dir" ]] || fail "JNI dir not found: $jni_dir"

  echo "[*] ndk-build ijkplayer for $abi"

  local tmp_root tmp_project
  tmp_root="$(mktemp -d 2>/dev/null || mktemp -d -t ijk16k)"

  tmp_project="$tmp_root/android/ijkplayer/ijkplayer-armv7a/src/main"
  mkdir -p "$tmp_project"
  mkdir -p "$tmp_project/jni"

  cp -a "$jni_dir/." "$tmp_project/jni/"

  ln -s "$ROOT_DIR/android/contrib" "$tmp_root/android/contrib"
  ln -s "$ROOT_DIR/ijkmedia" "$tmp_root/ijkmedia"

  if [[ -f "$tmp_project/jni/ijkmedia" ]]; then
    rm -f "$tmp_project/jni/ijkmedia"
    ln -s "$tmp_root/ijkmedia" "$tmp_project/jni/ijkmedia"
  fi

  if [[ -f "$tmp_project/jni/ffmpeg" ]]; then
    rm -f "$tmp_project/jni/ffmpeg"
    ln -s "$ROOT_DIR/android/ijkplayer/ijkplayer-armv7a/src/main/jni/ffmpeg" "$tmp_project/jni/ffmpeg"
  fi

  mkdir -p "$tmp_project/jni/android-ndk-prof"
  cp -a "$ROOT_DIR/ijkprof/android-ndk-profiler-dummy/jni/." "$tmp_project/jni/android-ndk-prof/"

  "$ndk/ndk-build" \
    NDK_PROJECT_PATH="$tmp_project" \
    NDK_APPLICATION_MK="$app_mk" \
    IJK_16K_PAGE_SIZE=1 \
    -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

  mkdir -p "$out_dir/$abi"

  if [[ -d "$tmp_project/libs/$abi" ]]; then
    cp -f "$tmp_project/libs/$abi"/*.so "$out_dir/$abi/" || true
  fi

  rm -rf "$tmp_root" || true

  local ff_arch
  ff_arch="$(abi_to_ff_arch "$abi")"
  cp -f "$ROOT_DIR/android/contrib/build/ffmpeg-${ff_arch}/output/libijkffmpeg.so" "$out_dir/$abi/" || true
}

verify_out() {
  local ndk="$1"
  local out_dir="$2"

  echo "[*] Verifying ELF segment alignment (<= 16KB)"
  "$SCRIPT_DIR/verify/verify_elf_page_size.sh" "$out_dir" --ndk "$ndk" --max-align 0x4000

  if [[ "${WITH_OPENSSL:-$DEFAULT_WITH_OPENSSL}" == "1" ]]; then
    echo "[*] Verifying HTTPS/TLS protocols are enabled in libijkffmpeg.so"
    "$SCRIPT_DIR/verify/verify_ijkffmpeg_https.sh" "$out_dir" --ndk "$ndk"
  fi
}

main() {
  local abis="$DEFAULT_ABIS"
  local clean=0
  local with_openssl="$DEFAULT_WITH_OPENSSL"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --abis) abis="$2"; shift 2;;
      --clean) clean=1; shift;;
      --no-openssl) with_openssl=0; shift;;
      *) fail "Unknown arg: $1";;
    esac
  done

  need_cmd git
  need_cmd make
  need_cmd perl

  normalize_repo_line_endings

  local ndk host major
  ndk="$(ndk_path)"
  host="$(host_tag)"

  WITH_OPENSSL="$with_openssl"

  [[ -f "$ndk/source.properties" ]] || fail "Invalid NDK path: $ndk"
  major="$(ndk_major "$ndk")"
  if [[ "$major" -lt 26 ]]; then
    fail "NDK r26+ required for 16KB page size (found major=$major at $ndk)"
  fi

  local out_dir="$OUT_DIR"
  if [[ "$clean" == 1 ]]; then
    echo "[*] Cleaning outputs"
    rm -rf "$out_dir"
    rm -rf "$ROOT_DIR/android/contrib/build"/ffmpeg-*/output || true
    rm -rf "$DEPS_DIR/build" || true
  fi

  ensure_init_done

  IFS=',' read -r -a abi_list <<<"$abis"

  for abi in "${abi_list[@]}"; do
    build_ffmpeg_one "$abi" "$ndk" "$host"
    build_ijk_one "$abi" "$ndk" "$out_dir"
  done

  verify_out "$ndk" "$out_dir"

  echo "[*] Done. Outputs in: $out_dir"
}

main "$@"
