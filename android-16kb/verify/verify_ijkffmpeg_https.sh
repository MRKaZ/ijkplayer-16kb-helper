#!/usr/bin/env bash
set -euo pipefail

# Verify that libijkffmpeg.so was built with HTTPS support.
#
# We check for FFmpeg's protocol symbols in the resulting shared library:
#   - ff_https_protocol
#
# Some ijkplayer FFmpeg forks expose https without exporting a standalone
# ff_tls_protocol symbol. In that case, we accept https as enabled if OpenSSL
# symbols are present (i.e. libijkffmpeg.so was linked against OpenSSL).
#
# Usage:
#   ./verify_ijkffmpeg_https.sh <path-to-out-dir-or-libijkffmpeg.so> [--ndk <ndk-path>]

fail() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Verify ijkplayer's bundled FFmpeg (libijkffmpeg.so) has HTTPS/TLS enabled.

Usage:
  verify_ijkffmpeg_https.sh <path> [--ndk <ndk-path>]

Where <path> can be:
  - a directory (recursively scans for libijkffmpeg.so)
  - a single libijkffmpeg.so

Exit codes:
  0 = all good
  1 = missing https/tls symbols
  2 = no libijkffmpeg.so found
EOF
}

ndk_path() {
  if [[ -n "${ANDROID_NDK:-}" ]]; then echo "$ANDROID_NDK"; return; fi
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then echo "$ANDROID_NDK_HOME"; return; fi
  echo ""
}

host_tag() {
  local u
  u="$(uname -s)"
  case "$u" in
    Linux) echo "linux-x86_64";;
    Darwin)
      if [[ "$(uname -m)" == "arm64" ]]; then echo "darwin-arm64"; else echo "darwin-x86_64"; fi
      ;;
    *) echo "";;
  esac
}

resolve_readelf() {
  local ndk="${1:-}"

  if command -v llvm-readelf >/dev/null 2>&1; then
    echo "llvm-readelf"; return
  fi
  if command -v readelf >/dev/null 2>&1; then
    echo "readelf"; return
  fi

  if [[ -z "$ndk" ]]; then
    ndk="$(ndk_path)"
  fi
  if [[ -n "$ndk" ]]; then
    local host bin
    host="$(host_tag)"
    if [[ -n "$host" ]]; then
      bin="$ndk/toolchains/llvm/prebuilt/$host/bin/llvm-readelf"
      if [[ -x "$bin" ]]; then
        echo "$bin"; return
      fi
    fi
  fi

  fail "No readelf/llvm-readelf found. Install binutils or set ANDROID_NDK and use NDK's llvm-readelf."
}

find_libs() {
  local p="$1"
  if [[ -f "$p" ]]; then
    local base
    base="$(basename "$p")"
    if [[ "$base" == "libijkffmpeg.so" ]]; then
      echo "$p"
    fi
    return
  fi

  if [[ -d "$p" ]]; then
    find "$p" -type f -name 'libijkffmpeg.so' -print
    return
  fi

  fail "Path not found: $p"
}

require_symbol() {
  local readelf="$1"
  local so="$2"
  local sym="$3"

  # -Ws prints .dynsym and .symtab (if present).
  # NOTE: Don't use `grep -q` here because this script runs with `set -o pipefail`.
  # If grep exits early, `llvm-readelf` can receive SIGPIPE and the pipeline becomes
  # non-zero even though the symbol exists, causing false failures.
  if "$readelf" -Ws "$so" 2>/dev/null | grep -F "$sym" >/dev/null; then
    return 0
  fi
  return 1
}

has_any_symbol() {
  local readelf="$1"
  local so="$2"
  shift 2
  local sym
  for sym in "$@"; do
    if require_symbol "$readelf" "$so" "$sym"; then
      return 0
    fi
  done
  return 1
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  local path="$1"; shift
  local ndk=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --ndk) ndk="$2"; shift 2;;
      *) fail "Unknown arg: $1";;
    esac
  done

  local readelf
  readelf="$(resolve_readelf "$ndk")"

  mapfile -t libs < <(find_libs "$path" | sort -u)
  if [[ ${#libs[@]} -eq 0 ]]; then
    echo "No libijkffmpeg.so found under: $path"
    exit 2
  fi

  local bad=0
  for so in "${libs[@]}"; do
    if ! require_symbol "$readelf" "$so" "ff_https_protocol"; then
      echo "FAIL: missing ff_https_protocol in: $so" >&2
      bad=1
      continue
    fi

    if require_symbol "$readelf" "$so" "ff_tls_protocol"; then
      continue
    fi

    # Fallback: OpenSSL-linked builds usually have these symbols.
    if has_any_symbol "$readelf" "$so" "OPENSSL_init_ssl" "SSL_connect" "SSL_CTX_new" "SSL_CTX_new_ex"; then
      echo "WARN: ff_tls_protocol not found, but OpenSSL symbols exist (treating as OK): $so" >&2
      continue
    fi

    echo "FAIL: missing ff_tls_protocol (and no OpenSSL symbols found) in: $so" >&2
    bad=1
  done

  if [[ "$bad" -ne 0 ]]; then
    exit 1
  fi

  echo "OK: HTTPS/TLS enabled in ${#libs[@]} libijkffmpeg.so file(s)"
}

main "$@"
