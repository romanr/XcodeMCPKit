#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-universal.sh [--dist-root <dir>] [--output-dir <dir>]

Requires staged binaries from:
  <dist-root>/arm64/bin/
  <dist-root>/x86_64/bin/

Outputs:
  <output-dir>/xcode-mcp-proxy.tar.gz
  <output-dir>/xcode-mcp-proxy-darwin-arm64.tar.gz
  <output-dir>/xcode-mcp-proxy-darwin-x86_64.tar.gz
  <output-dir>/SHA256SUMS.txt
EOF
}

dist_root="dist"
output_dir="release"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
for path in "$arm_bin" "$x86_bin"; do
  if [[ ! -d "$path" ]]; then
    echo "Missing staged directory: $path" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$output_base"

universal_archive="$output_base/xcode-mcp-proxy.tar.gz"
arm_archive="$output_base/xcode-mcp-proxy-darwin-arm64.tar.gz"
x86_archive="$output_base/xcode-mcp-proxy-darwin-x86_64.tar.gz"
find "$output_base" -maxdepth 1 -type f -name 'xcode-mcp-proxy*.tar.gz' -delete
rm -f "$output_base/SHA256SUMS.txt"

products=(
  "xcode-mcp-proxy"
  "xcode-mcp-proxy-server"
  "xcode-mcp-proxy-install"
)

for product in "${products[@]}"; do
  arm_product="$arm_bin/$product"
  x86_product="$x86_bin/$product"
  if [[ ! -f "$arm_product" ]]; then
    echo "Missing staged binary: $arm_product" >&2
    exit 1
  fi
  if [[ ! -f "$x86_product" ]]; then
    echo "Missing staged binary: $x86_product" >&2
    exit 1
  fi
done

mkdir -p "$tmp_dir/universal/bin"
for product in "${products[@]}"; do
  target="$tmp_dir/universal/bin/$product"
  lipo -create -output "$target" "$arm_bin/$product" "$x86_bin/$product"
  chmod +x "$target"
  if command -v codesign >/dev/null 2>&1; then
    codesign --remove-signature "$target" >/dev/null 2>&1 || true
  fi
done

cp -R "$tmp_dir/universal/bin" "$tmp_dir/bin"
tar -C "$tmp_dir" -czf "$universal_archive" bin
rm -rf "$tmp_dir/bin"

cp -R "$arm_bin" "$tmp_dir/bin"
tar -C "$tmp_dir" -czf "$arm_archive" bin
rm -rf "$tmp_dir/bin"

cp -R "$x86_bin" "$tmp_dir/bin"
tar -C "$tmp_dir" -czf "$x86_archive" bin
rm -rf "$tmp_dir/bin"

(
  cd "$output_base"
  shasum -a 256 \
    xcode-mcp-proxy.tar.gz \
    xcode-mcp-proxy-darwin-arm64.tar.gz \
    xcode-mcp-proxy-darwin-x86_64.tar.gz > SHA256SUMS.txt
)

echo "Created release package: $universal_archive"
echo "Created release package: $arm_archive"
echo "Created release package: $x86_archive"
echo "Created checksum file: $output_base/SHA256SUMS.txt"
