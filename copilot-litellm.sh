#!/usr/bin/env bash
set -euo pipefail

# Launch Copilot CLI against a LiteLLM proxy running on the container host.
# host.containers.internal resolves to the host from inside a Podman container.
BASE_URL="${LITELLM_BASE_URL:-http://host.containers.internal:4000}"
BASE_URL="${BASE_URL%/}"
[[ "$BASE_URL" == */v1 ]] || BASE_URL="${BASE_URL}/v1"

WIRE_API="${LITELLM_WIRE_API:-completions}"
MODEL="${LITELLM_MODEL:-}"

# Pick the first model advertised by LiteLLM when none is configured.
if [[ -z "$MODEL" ]]; then
  if ! models_json="$(curl -fsS --max-time 10 "${BASE_URL}/models")"; then
    echo "Unable to reach LiteLLM at ${BASE_URL}/models; set LITELLM_BASE_URL or LITELLM_MODEL" >&2
    exit 1
  fi
  MODEL="$(jq -r '.data[0].id // empty' <<<"$models_json")"
  if [[ -z "$MODEL" ]]; then
    echo "LiteLLM returned no models; set LITELLM_MODEL" >&2
    exit 1
  fi
  echo "Using LiteLLM model: ${MODEL} (override with LITELLM_MODEL)" >&2
fi

export COPILOT_PROVIDER_TYPE="openai"
export COPILOT_PROVIDER_BASE_URL="$BASE_URL"
export COPILOT_PROVIDER_WIRE_API="$WIRE_API"

if [[ -n "${LITELLM_API_KEY:-}" ]]; then
  export COPILOT_PROVIDER_API_KEY="$LITELLM_API_KEY"
fi

export COPILOT_PROVIDER_MODEL_ID="$MODEL"
export COPILOT_PROVIDER_WIRE_MODEL="$MODEL"
export COPILOT_MODEL="$MODEL"

# Prevent Copilot from contacting GitHub's servers
export COPILOT_OFFLINE=true

exec copilot "$@"
