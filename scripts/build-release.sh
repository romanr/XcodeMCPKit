#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --arch <arm64|x86_64> --version <tag> [--dist-root <dir>]

Builds release binaries and stages them under:
  <dist-root>/<arch>/bin/
EOF
}

arch=""
version=""
dist_root="dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      arch="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
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

if [[ -z "$arch" ]]; then
  echo "--arch is required." >&2
  usage
  exit 1
fi

if [[ -z "$version" ]]; then
  echo "--version is required." >&2
  usage
  exit 1
fi

case "$arch" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported arch: $arch (expected arm64 or x86_64)" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi

out_dir="$dist_base/$arch"
bin_out="$out_dir/bin"
products=(
  "xcode-mcp-proxy"
  "xcode-mcp-proxy-server"
  "xcode-mcp-proxy-install"
)

pushd "$repo_root" >/dev/null

for product in "${products[@]}"; do
  swift build -c release --arch "$arch" --product "$product"
done

bin_path="$(swift build -c release --arch "$arch" --show-bin-path)"
rm -rf "$out_dir"
mkdir -p "$bin_out"

for product in "${products[@]}"; do
  source_path="$bin_path/$product"
  if [[ ! -f "$source_path" ]]; then
    source_path="$(find "$repo_root/.build" -type f -path "*/release/$product" | head -n 1 || true)"
  fi
  if [[ -z "$source_path" || ! -f "$source_path" ]]; then
    echo "Failed to locate built binary: $product" >&2
    exit 1
  fi

  target_path="$bin_out/$product"
  cp "$source_path" "$target_path"
  chmod +x "$target_path"
  if command -v codesign >/dev/null 2>&1; then
    codesign --remove-signature "$target_path" >/dev/null 2>&1 || true
  fi
done

cat > "$out_dir/manifest.txt" <<EOF
version=$version
arch=$arch
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

popd >/dev/null

echo "Staged release binaries at: $out_dir"
