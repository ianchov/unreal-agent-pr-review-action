#!/usr/bin/env bash
# Installs pinned unreal-agent-runner and nono releases for the runner architecture (amd64 or arm64).
# Each download is checked against its pinned SHA-256.
# Renovate keeps each tool's release tag and asset SHA-256 current (see renovate.json).
set -euo pipefail

arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64 | arm64) ;;
  *) echo "::error::Unsupported runner architecture: $arch"; exit 1 ;;
esac

# tool tag arch repo asset sha256
# The asset is downloaded from https://github.com/<repo>/releases/download/<tag>/. In the asset
# name, {version} stands for the tag without its leading "v".
tools_table="
unreal-agent v0.3.1 amd64 unreallabsai/unreal-agent unreal-agent_{version}_linux_amd64.tar.gz fd6e15236cc6f126ea3ddf2fc85c4be05bc5e8e4967977a89720bf95e22b304b
unreal-agent v0.3.1 arm64 unreallabsai/unreal-agent unreal-agent_{version}_linux_arm64.tar.gz b01b096d0543277b2d58d8928da7a7df32b7dcb546a86335de2d04c81eea507b
nono v0.79.0 amd64 nolabs-ai/nono nono-cli_{version}_amd64.deb 33b7e4f2315226bfc8ffeafc8113d444c2f71a9b98ec44c54fe3800b96938a07
nono v0.79.0 arm64 nolabs-ai/nono nono-cli_{version}_arm64.deb 50036f6ec1e9c8374a05c52d4b7b81339fa63e4866e2d3db3adf7fe11d458c37
"

# download TOOL: download TOOL's release asset for $arch to $RUNNER_TEMP, verify it, print its path.
download() {
  local tag repo asset sum file
  read -r _ tag _ repo asset sum < <(awk -v n="$1" -v a="$arch" '$1 == n && $3 == a' <<<"$tools_table")
  asset="${asset//\{version\}/${tag#v}}"
  file="$RUNNER_TEMP/$asset"
  curl -fsSLo "$file" "https://github.com/$repo/releases/download/$tag/$asset"
  echo "${sum}  $file" | sha256sum --check --strict - >&2
  echo "$file"
}

tgz="$(download unreal-agent)"
mkdir -p "$RUNNER_TEMP/unreal-agent-bin"
tar -xzf "$tgz" -C "$RUNNER_TEMP/unreal-agent-bin" unreal-agent-runner

deb="$(download nono)"
sudo apt-get install -y --no-install-recommends "$deb"
