# copilot-podman.sh

A Podman-based wrapper that runs GitHub Copilot CLI inside a container sandbox. It builds a minimal image, mounts your workspace, persists Copilot auth in a named volume, and enforces container security hardening.

## Requirements

- [Podman](https://podman.io/) installed and accessible in your `PATH`
- A GitHub account with Copilot access

## Usage

```bash
./copilot-podman.sh [WORKSPACE_DIR]
```

`WORKSPACE_DIR` defaults to the current directory (`$PWD`).

**Example:**

```bash
./copilot-podman.sh ~/my-project
```

The script will:
1. Build the container image (once, reused on subsequent runs)
2. Create a named Podman volume for Copilot auth/config (persisted across runs)
3. Drop all Linux capabilities and prevent privilege escalation
4. Mount your workspace at `/workspace` inside the container
5. Drop you into an interactive shell

### First-time authentication

Inside the container, authenticate with GitHub:

```bash
copilot /login
```

This uses the device flow. On subsequent runs, auth is preserved via the named volume.

Alternatively, pass a token via environment variable (see below).

### Using Amazon Bedrock

The image includes `copilot-bedrock.sh` as the `copilot-bedrock` command on `PATH`.
Inside the container, set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
`AWS_SESSION_TOKEN`, then run:

```bash
copilot-bedrock
```

Arguments are forwarded to Copilot. Optional environment variables include
`AWS_REGION` (default: `eu-west-1`), `BEDROCK_MODEL` (default:
`global.moonshotai.kimi-k3`), and `BEDROCK_TOKEN_TTL` (default: `3600` seconds).
The launcher uses AWS credentials instead of GitHub authentication.

### Using LiteLLM

The image includes `copilot-litellm.sh` as the `copilot-litellm` command on
`PATH`. It connects to a LiteLLM proxy published on the host at port 4000
(reached via `host.containers.internal`). Inside the container, run:

```bash
copilot-litellm
```

Arguments are forwarded to Copilot. Optional environment variables include
`LITELLM_BASE_URL` (default: `http://host.containers.internal:4000`; `/v1` is
appended if missing), `LITELLM_MODEL` (default: first model from `/v1/models`),
`LITELLM_WIRE_API` (`completions` or `responses`; default: `completions`), and
`LITELLM_API_KEY` (only needed if the proxy requires authentication).

If LiteLLM returns `UnsupportedParamsError` (e.g. Bedrock Claude models rejecting
`presence_penalty` or `temperature`), enable `drop_params` in the LiteLLM config:

```yaml
litellm_settings:
  drop_params: true
```

If you already have a cached image, rebuild it from this repository before
starting the wrapper:

```bash
podman build -t "${COPILOT_PODMAN_IMAGE:-copilot-cli-sandbox:latest}" .
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `COPILOT_PODMAN_IMAGE` | `copilot-cli-sandbox:latest` | Container image name/tag to use or build |
| `COPILOT_PODMAN_VOLUME` | `copilot-home` | Named Podman volume for persisting Copilot auth |
| `COPILOT_NODE_IMAGE` | `node:22-slim` | Base image used when building the sandbox image |
| `COPILOT_SHELL` | `bash` | Shell to launch inside the container |
| `COPILOT_NO_NET` | `0` | Set to `1` to disable networking (`--network=none`) |
| `COPILOT_READONLY` | `0` | Set to `1` to make the container root filesystem read-only |
| `COPILOT_WORKSPACE_RO` | `0` | Set to `1` to mount the workspace as read-only |
| `COPILOT_GITHUB_TOKEN` | _(unset)_ | GitHub token passed into the container for auth |
| `GH_TOKEN` | _(unset)_ | Alternative GitHub token (used if `COPILOT_GITHUB_TOKEN` is unset) |
| `GITHUB_TOKEN` | _(unset)_ | Alternative GitHub token (used if `GH_TOKEN` is also unset) |

## Examples

**Run with networking disabled:**

```bash
COPILOT_NO_NET=1 ./copilot-podman.sh
```

**Run with a read-only container filesystem:**

```bash
COPILOT_READONLY=1 ./copilot-podman.sh
```

**Mount workspace as read-only (protect your files):**

```bash
COPILOT_WORKSPACE_RO=1 ./copilot-podman.sh ~/my-project
```

**Pass a GitHub token directly:**

```bash
GH_TOKEN=ghp_xxx ./copilot-podman.sh
```

**Use a custom base image:**

```bash
COPILOT_NODE_IMAGE=node:20-slim ./copilot-podman.sh
```

## Security

The container runs with:

- `--cap-drop=ALL` — all Linux capabilities dropped
- `--security-opt=no-new-privileges` — prevents privilege escalation
- Optional `--read-only` root filesystem with tmpfs mounts for `/tmp`, `/run`, and `/var/tmp`
- Optional `--network=none` to fully isolate the container from the network

## How it Works

1. **Image**: On first run, a `Dockerfile` is generated in a temp directory and built as `copilot-cli-sandbox:latest`. Subsequent runs reuse the cached image.
2. **Auth volume**: A Podman named volume (`copilot-home`) is mounted at `/root` to persist Copilot credentials between sessions.
3. **Workspace**: Your target directory is bind-mounted at `/workspace` (read-write by default).
