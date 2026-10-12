#!/usr/bin/env bash
# Installs pinned unreal-agent-runner and nono releases for the runner architecture (amd64 or arm64).
# Each download is checked against the SHA-256 in its release's SHA256SUMS / SHA256SUMS.txt.
set -euo pipefail

# Renovate updates these versions but not the SHA-256 sums below. Update the sums in the same PR.
# renovate: datasource=github-releases depName=unreallabsai/unreal-agent
UNREAL_AGENT_VERSION="0.3.1"
# renovate: datasource=github-releases depName=nolabs-ai/nono
NONO_VERSION="0.79.0"

arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64)
    agent_sha=fd6e15236cc6f126ea3ddf2fc85c4be05bc5e8e4967977a89720bf95e22b304b
    nono_sha=33b7e4f2315226bfc8ffeafc8113d444c2f71a9b98ec44c54fe3800b96938a07
    ;;
  arm64)
    agent_sha=b01b096d0543277b2d58d8928da7a7df32b7dcb546a86335de2d04c81eea507b
    nono_sha=50036f6ec1e9c8374a05c52d4b7b81339fa63e4866e2d3db3adf7fe11d458c37
    ;;
  *) echo "::error::Unsupported runner architecture: $arch"; exit 1 ;;
esac

tgz="$RUNNER_TEMP/unreal-agent_${UNREAL_AGENT_VERSION}_linux_${arch}.tar.gz"
curl -fsSLo "$tgz" "https://github.com/unreallabsai/unreal-agent/releases/download/v${UNREAL_AGENT_VERSION}/unreal-agent_${UNREAL_AGENT_VERSION}_linux_${arch}.tar.gz"
echo "${agent_sha}  $tgz" | sha256sum --check --strict -
mkdir -p "$RUNNER_TEMP/unreal-agent-bin"
tar -xzf "$tgz" -C "$RUNNER_TEMP/unreal-agent-bin" unreal-agent-runner

deb="$RUNNER_TEMP/nono-cli_${NONO_VERSION}_${arch}.deb"
curl -fsSLo "$deb" "https://github.com/nolabs-ai/nono/releases/download/v${NONO_VERSION}/nono-cli_${NONO_VERSION}_${arch}.deb"
echo "${nono_sha}  $deb" | sha256sum --check --strict -
sudo apt-get install -y --no-install-recommends "$deb"
