#!/usr/bin/env bash
set -euo pipefail

# Packages this helper repo into a clean source archive suitable for publishing.
# Excludes: cloned ijkplayer sources, build outputs, and cached deps.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
NAME="${NAME:-ijkplayer-16kb-helper}"
FORCE="${FORCE:-0}"
NO_GIT="${NO_GIT:-0}"

usage() {
  cat <<'EOF'
Usage:
  bash ./scripts/package.sh

Environment overrides:
  OUT_DIR=dist        Output directory (default: ./dist)
  NAME=...            Archive base name
  FORCE=1             Overwrite existing archive
  NO_GIT=1            Don't include git short SHA in filename

Outputs:
  dist/<name>-<timestamp>-<gitsha>.tar.gz
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$OUT_DIR"

ts="$(date +%Y%m%d-%H%M%S)"
sha="nogit"
if [[ "$NO_GIT" != "1" ]] && command -v git >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  fi
fi

archive="$OUT_DIR/${NAME}-${ts}-${sha}.tar.gz"
if [[ -f "$archive" && "$FORCE" != "1" ]]; then
  echo "ERROR: archive exists: $archive (set FORCE=1 to overwrite)" >&2
  exit 1
fi

# Create archive from repo root, including only required paths.
# Note: tar --exclude patterns are applied to paths in the archive.
(
  cd "$REPO_ROOT"
  tar -czf "$archive" \
    --exclude="./.git" \
    --exclude="./.android-sdk" \
    --exclude="./dist" \
    --exclude="./work" \
    --exclude="./ijkplayer" \
    --exclude="./android-16kb/out" \
    --exclude="./android-16kb/.deps" \
    --exclude="./scripts/android-env.sh" \
    ./.github \
    ./android-16kb \
    ./docker \
    ./patches \
    ./scripts \
    ./.gitignore \
    ./README.md \
    ./docker-compose.yml
)

echo "OK: Created $archive"

# Optionally also create a zip (useful for GitHub Releases) if the `zip` tool exists.
if command -v zip >/dev/null 2>&1; then
  zip_archive="$OUT_DIR/${NAME}-${ts}-${sha}.zip"
  if [[ -f "$zip_archive" && "$FORCE" != "1" ]]; then
    echo "WARN: zip exists (skipping): $zip_archive" >&2
    exit 0
  fi
  rm -f "$zip_archive" || true
  (
    cd "$REPO_ROOT"
    zip -r -q "$zip_archive" \
      .github android-16kb docker patches scripts .gitignore README.md docker-compose.yml \
      -x ".git/*" ".android-sdk/*" "dist/*" "work/*" "ijkplayer/*" "android-16kb/out/*" "android-16kb/.deps/*" "scripts/android-env.sh"
  )
  echo "OK: Created $zip_archive"
fi
