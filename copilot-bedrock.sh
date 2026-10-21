#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
MODEL="${BEDROCK_MODEL:-global.moonshotai.kimi-k3}"

# Use a shorter lifetime than the maximum 12 hours.
# The effective lifetime cannot exceed the underlying SSO credentials.
TOKEN_TTL="${BEDROCK_TOKEN_TTL:-3600}"

###############################################################################
# URL-encode a SigV4 query parameter.
#
# jq's @uri encoding produces the percent-encoding needed by SigV4 and avoids
# depending on Python, Perl, Node.js, or the AWS Bedrock token generator.
###############################################################################
uri_encode() {
  jq -nr --arg value "$1" '$value | @uri'
}

sha256_hex() {
  openssl dgst -sha256 | awk '{print $NF}'
}

hmac_sha256_hex() {
  local hex_key="$1"
  local data="$2"

  printf '%s' "$data" |
    openssl dgst -sha256 \
      -mac HMAC \
      -macopt "hexkey:${hex_key}" \
      -binary |
    od -An -vtx1 |
    tr -d ' \n'
}

###############################################################################
# Generate a short-term Bedrock bearer token using AWS credentials supplied
# via the AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN
# environment variables.
#
# COPILOT_PROVIDER_API_KEY_COMMAND expects the command to print only the
# credential to stdout. Therefore, diagnostics must go to stderr.
###############################################################################
generate_bedrock_token() {
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required" >&2
    exit 1
  }

  command -v openssl >/dev/null 2>&1 || {
    echo "openssl is required" >&2
    exit 1
  }

  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${AWS_SESSION_TOKEN:-}" ]]; then
    echo "AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN environment variables are required" >&2
    exit 1
  fi

  local access_key secret_key session_token
  access_key="$AWS_ACCESS_KEY_ID"
  secret_key="$AWS_SECRET_ACCESS_KEY"
  session_token="$AWS_SESSION_TOKEN"

  local service="bedrock"
  local host="bedrock.amazonaws.com"
  local endpoint="https://${host}/"
  local algorithm="AWS4-HMAC-SHA256"

  local amz_date date_stamp credential_scope
  amz_date="$(date -u '+%Y%m%dT%H%M%SZ')"
  date_stamp="${amz_date:0:8}"
  credential_scope="${date_stamp}/${REGION}/${service}/aws4_request"

  # Build the canonical query string in lexical order.
  local canonical_query
  canonical_query="$(
    printf '%s\n' \
      "Action=$(uri_encode "CallWithBearerToken")" \
      "X-Amz-Algorithm=$(uri_encode "$algorithm")" \
      "X-Amz-Credential=$(uri_encode "${access_key}/${credential_scope}")" \
      "X-Amz-Date=$(uri_encode "$amz_date")" \
      "X-Amz-Expires=$(uri_encode "$TOKEN_TTL")" \
      "X-Amz-SignedHeaders=$(uri_encode "host")"

    if [[ -n "$session_token" ]]; then
      printf '%s\n' \
        "X-Amz-Security-Token=$(uri_encode "$session_token")"
    fi
  )"

  canonical_query="$(printf '%s\n' "$canonical_query" | LC_ALL=C sort | paste -sd '&' -)"

  local empty_payload_hash
  empty_payload_hash="$(
    printf '' |
      openssl dgst -sha256 |
      awk '{print $NF}'
  )"

  local canonical_headers signed_headers canonical_request
  canonical_headers="host:${host}"
  signed_headers="host"

  canonical_request="$(
    printf 'POST\n/\n%s\n%s\n\n%s\n%s' \
      "$canonical_query" \
      "$canonical_headers" \
      "$signed_headers" \
      "$empty_payload_hash"
  )"

  local canonical_request_hash string_to_sign
  canonical_request_hash="$(
    printf '%s' "$canonical_request" |
      openssl dgst -sha256 |
      awk '{print $NF}'
  )"

  string_to_sign="$(
    printf '%s\n%s\n%s\n%s' \
      "$algorithm" \
      "$amz_date" \
      "$credential_scope" \
      "$canonical_request_hash"
  )"

  # SigV4 key derivation:
  #
  # kDate    = HMAC("AWS4" + secret, date)
  # kRegion  = HMAC(kDate, region)
  # kService = HMAC(kRegion, "bedrock")
  # kSigning = HMAC(kService, "aws4_request")
  local aws4_secret_hex k_date k_region k_service k_signing signature
  aws4_secret_hex="$(printf 'AWS4%s' "$secret_key" | od -An -vtx1 | tr -d ' \n')"

  k_date="$(hmac_sha256_hex "$aws4_secret_hex" "$date_stamp")"
  k_region="$(hmac_sha256_hex "$k_date" "$REGION")"
  k_service="$(hmac_sha256_hex "$k_region" "$service")"
  k_signing="$(hmac_sha256_hex "$k_service" "aws4_request")"
  signature="$(hmac_sha256_hex "$k_signing" "$string_to_sign")"

  local presigned_url token_payload token
  presigned_url="${endpoint}?${canonical_query}&X-Amz-Signature=${signature}"

  # AWS token construction:
  # 1. remove https://
  # 2. append &Version=1
  # 3. base64 encode
  # 4. prefix with bedrock-api-key-
  token_payload="${presigned_url#https://}&Version=1"

  token="$(
    printf '%s' "$token_payload" |
      base64 |
      tr -d '\r\n'
  )"

  printf 'bedrock-api-key-%s\n' "$token"
}

###############################################################################
# Credential-command mode
###############################################################################
if [[ "${1:-}" == "--bedrock-token" ]]; then
  generate_bedrock_token
  exit 0
fi

###############################################################################
# Normal launcher mode
###############################################################################

# Resolve this script to an absolute path so Copilot can invoke it reliably.
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$0")"

# Ensure AWS credentials are available via environment variables before
# Copilot starts (no interactive/browser-based SSO login in containers).
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${AWS_SESSION_TOKEN:-}" ]]; then
  echo "AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN environment variables are required" >&2
  exit 1
fi

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

export COPILOT_PROVIDER_TYPE="openai"
export COPILOT_PROVIDER_BASE_URL="https://bedrock-runtime.${REGION}.amazonaws.com/openai/v1"
export COPILOT_PROVIDER_WIRE_API="responses"

export COPILOT_PROVIDER_MODEL_ID="$MODEL"
export COPILOT_PROVIDER_WIRE_MODEL="$MODEL"
export COPILOT_MODEL="$MODEL"

# Copilot executes this whenever it needs a provider credential.
export COPILOT_PROVIDER_API_KEY_COMMAND="${SCRIPT_PATH} --bedrock-token"

# Prevent Copilot from contacting GitHub's servers
export COPILOT_OFFLINE=true

exec copilot "$@"
