#!/usr/bin/env bash
set -euo pipefail

# Verify that produced ELF shared libraries are compatible with 16KB page size.
#
# We enforce that the maximum p_align of any PT_LOAD segment is <= max-align.
# Default max-align is 0x4000 (16KB).
#
# Usage:
#   ./verify_elf_page_size.sh <path-to-out-dir-or-so> [--ndk <ndk-path>] [--max-align 0x4000]

fail() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Verify ELF PT_LOAD segment alignment (p_align).

Usage:
  verify_elf_page_size.sh <path> [--ndk <ndk-path>] [--max-align 0x4000]

Where <path> can be:
  - a directory (recursively scans for *.so)
  - a single .so

Exit codes:
  0 = all good
  1 = one or more files exceed max align
  2 = no .so found
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

find_sos() {
  local p="$1"
  if [[ -f "$p" ]]; then
    if [[ "$p" == *.so ]]; then
      echo "$p"
    fi
    return
  fi

  if [[ -d "$p" ]]; then
    find "$p" -type f -name '*.so' -print
    return
  fi

  fail "Path not found: $p"
}

max_load_align() {
  local readelf="$1"
  local so="$2"

  # Prefer -W (wide) when supported.
  local aligns
  if aligns="$($readelf -W -l "$so" 2>/dev/null | awk '$1=="LOAD"{print $NF}')"; then
    true
  else
    aligns="$($readelf -l "$so" 2>/dev/null | awk '$1=="LOAD"{print $NF}')" || return 1
  fi

  local max=0
  while IFS= read -r a; do
    a="${a#0x}"
    [[ -n "$a" ]] || continue
    # p_align is small; bash arithmetic is fine here.
    local v=$((16#$a))
    if (( v > max )); then
      max=$v
    fi
  done <<<"$aligns"

  echo "$max"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  local path="$1"; shift
  local ndk=""
  local max_align="0x4000"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --ndk) ndk="$2"; shift 2;;
      --max-align) max_align="$2"; shift 2;;
      *) fail "Unknown arg: $1";;
    esac
  done

  local readelf
  readelf="$(resolve_readelf "$ndk")"

  mapfile -t sos < <(find_sos "$path" | sort -u)
  if [[ ${#sos[@]} -eq 0 ]]; then
    echo "No .so found under: $path"
    exit 2
  fi

  local max_align_dec
  max_align_dec=$((max_align))

  local bad=0
  for so in "${sos[@]}"; do
    local a
    a="$(max_load_align "$readelf" "$so" || echo 0)"
    if [[ "$a" -gt "$max_align_dec" ]]; then
      echo "FAIL: max LOAD align 0x$(printf '%x' "$a") > $max_align in: $so" >&2
      bad=1
    fi
  done

  if [[ "$bad" -ne 0 ]]; then
    exit 1
  fi

  echo "OK: ${#sos[@]} file(s) have max LOAD align <= $max_align"
}

main "$@"
