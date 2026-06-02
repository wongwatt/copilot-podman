#!/usr/bin/env bash
set -euo pipefail

# copilot-podman.sh
# A Podman-based wrapper to run GitHub Copilot CLI in a container "sandbox".
#
# Features:
# - Builds (or reuses) a small image with Copilot CLI
# - Mounts only the target workspace directory into /workspace
# - Persists Copilot auth/config in a named Podman volume
# - Drops Linux capabilities, prevents privilege escalation
# - Optional: disable networking (--network=none)
# - Optional: read-only container FS (workspace can still be rw or ro)

IMAGE="${COPILOT_PODMAN_IMAGE:-copilot-cli-sandbox:latest}"
VOL="${COPILOT_PODMAN_VOLUME:-copilot-home}"
WORKDIR="${1:-$PWD}"

# Options via env vars:
#   COPILOT_NO_NET=1        -> disable networking
#   COPILOT_READONLY=1      -> make container root filesystem read-only
#   COPILOT_WORKSPACE_RO=1  -> mount workspace as read-only
#   COPILOT_NODE_IMAGE=...  -> base image override (default: node:22-slim)
#   COPILOT_SHELL=bash      -> shell inside container

NO_NET="${COPILOT_NO_NET:-0}"
READONLY="${COPILOT_READONLY:-0}"
WORKSPACE_RO="${COPILOT_WORKSPACE_RO:-0}"
NODE_IMAGE="${COPILOT_NODE_IMAGE:-node:22-slim}"
SHELL_BIN="${COPILOT_SHELL:-bash}"

# Resolve absolute path
if command -v realpath >/dev/null 2>&1; then
  WORKDIR="$(realpath "$WORKDIR")"
else
  # macOS fallback if realpath isn't available
  WORKDIR="$(cd "$WORKDIR" && pwd -P)"
fi

if [[ ! -d "$WORKDIR" ]]; then
  echo "Error: workspace directory does not exist: $WORKDIR" >&2
  exit 1
fi

# Create auth volume if missing
if ! podman volume exists "$VOL" >/dev/null 2>&1; then
  podman volume create "$VOL" >/dev/null
fi

# Build image if missing
if ! podman image exists "$IMAGE" >/dev/null 2>&1; then
  echo "Building image: $IMAGE"
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT

  cat > "$TMPDIR/Dockerfile" <<EOF
FROM node:22-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @github/copilot

WORKDIR /workspace
CMD ["bash"]
EOF

  podman build -t "$IMAGE" "$TMPDIR" >/dev/null
  echo "Built."
fi

# Container security options
SEC_OPTS=(
  --cap-drop=ALL
  --security-opt=no-new-privileges
)

# Networking option
NET_OPTS=()
if [[ "$NO_NET" == "1" ]]; then
  NET_OPTS+=( --network=none )
fi

# Read-only root filesystem + tmpfs for writable paths
RO_OPTS=()
if [[ "$READONLY" == "1" ]]; then
  RO_OPTS+=( --read-only --tmpfs /tmp:rw,noexec,nosuid,size=256m )
  # If you run tools that need writable /var or /run, add tmpfs mounts:
  RO_OPTS+=( --tmpfs /run:rw,nosuid,size=64m --tmpfs /var/tmp:rw,nosuid,size=256m )
fi

# Workspace mount mode
WS_MODE="rw"
if [[ "$WORKSPACE_RO" == "1" ]]; then
  WS_MODE="ro"
fi

# Environment token pass-through (optional):
# GitHub Docs describe using COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN for auth. 【3-522ba4】
ENV_OPTS=()
if [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then
  ENV_OPTS+=( -e "COPILOT_GITHUB_TOKEN=${COPILOT_GITHUB_TOKEN}" )
elif [[ -n "${GH_TOKEN:-}" ]]; then
  ENV_OPTS+=( -e "GH_TOKEN=${GH_TOKEN}" )
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  ENV_OPTS+=( -e "GITHUB_TOKEN=${GITHUB_TOKEN}" )
fi

echo "==================================================="
echo " Podman Copilot Sandbox"
echo " Image:     $IMAGE"
echo " Workspace: $WORKDIR ($WS_MODE)"
echo " Auth vol:  $VOL (mounted at /root)"
if [[ "$NO_NET" == "1" ]]; then
  echo " Network:   disabled"
else
  echo " Network:   enabled"
fi
if [[ "$READONLY" == "1" ]]; then
  echo " Root FS:   read-only (tmpfs for /tmp, /run, /var/tmp)"
else
  echo " Root FS:   normal"
fi
echo "---------------------------------------------------"
echo " Inside container:"
echo "   - run: copilot"
echo "   - first time: /login (device flow), or pass GH_TOKEN/GITHUB_TOKEN"
echo "==================================================="

# Run
exec podman run --rm -it \
  "${SEC_OPTS[@]}" \
  ${NET_OPTS[@]+"${NET_OPTS[@]}"} \
  ${RO_OPTS[@]+"${RO_OPTS[@]}"} \
  ${ENV_OPTS[@]+"${ENV_OPTS[@]}"} \
  -v "${WORKDIR}:/workspace:${WS_MODE},z" \
  -v "${VOL}:/root:rw" \
  -w /workspace \
  "$IMAGE" \
  "$SHELL_BIN"
