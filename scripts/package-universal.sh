#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-universal.sh --version <tag> [--dist-root <dir>] [--output-dir <dir>]

Requires staged binaries from:
  <dist-root>/arm64/bin/
  <dist-root>/x86_64/bin/

Outputs:
  <output-dir>/xcode-mcp-proxy_<tag>_darwin_universal.tar.gz
  <output-dir>/SHA256SUMS.txt
EOF
}

version=""
dist_root="dist"
output_dir="release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$version" ]]; then
  echo "--version is required." >&2
  usage
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi
if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi

arm_bin="$dist_base/arm64/bin"
x86_bin="$dist_base/x86_64/bin"
binaries=(
  "xcode-mcp-proxy"
  "xcode-mcp-proxy-server"
  "xcode-mcp-proxy-install"
)

for path in "$arm_bin" "$x86_bin"; do
  if [[ ! -d "$path" ]]; then
    echo "Missing staged directory: $path" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$output_base"

for bin in "${binaries[@]}"; do
  arm_src="$arm_bin/$bin"
  x86_src="$x86_bin/$bin"
  if [[ ! -f "$arm_src" || ! -f "$x86_src" ]]; then
    echo "Missing binary for lipo merge: $bin" >&2
    exit 1
  fi
  lipo -create "$arm_src" "$x86_src" -output "$tmp_dir/bin/$bin"
  chmod +x "$tmp_dir/bin/$bin"
done

archive_name="xcode-mcp-proxy_${version}_darwin_universal.tar.gz"
archive_path="$output_base/$archive_name"
tar -C "$tmp_dir" -czf "$archive_path" bin

(
  cd "$output_base"
  shasum -a 256 "$archive_name" > SHA256SUMS.txt
)

echo "Created release package: $archive_path"
echo "Created checksum file: $output_base/SHA256SUMS.txt"
