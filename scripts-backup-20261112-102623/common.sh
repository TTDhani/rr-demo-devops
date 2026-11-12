#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${ROOT_DIR}/config/poc.env}"
[[ -f "$CONFIG_FILE" ]] || { echo "Copy config/poc.env.example to config/poc.env" >&2; exit 1; }
APPLY_OVERRIDE="${APPLY:-}"
source "$CONFIG_FILE"
if [[ -n "$APPLY_OVERRIDE" ]]; then export APPLY="$APPLY_OVERRIDE"; fi
: "${AWS_REGION:?AWS_REGION required}"
: "${EXPECTED_ACCOUNT_ID:?EXPECTED_ACCOUNT_ID required}"
: "${APP_NAME:?APP_NAME required}"
command -v aws >/dev/null || { echo "aws CLI required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
AWS=(aws --region "$AWS_REGION" --no-cli-pager)
[[ -z "${AWS_PROFILE:-}" ]] || AWS+=(--profile "$AWS_PROFILE")
ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || { echo "Wrong AWS account: expected $EXPECTED_ACCOUNT_ID, got $ACCOUNT_ID" >&2; exit 1; }
echo "Verified AWS account ${ACCOUNT_ID}, region ${AWS_REGION}"
require_value() {
  local n="$1" v="${!1:-}"
  [[ -n "$v" && "$v" != REPLACE_* ]] || { echo "Set $n in $CONFIG_FILE" >&2; exit 1; }
}
confirm_apply() {
  [[ "${APPLY:-false}" == "true" ]] || { echo "DRY RUN: no AWS changes. Set APPLY=true after review."; return 1; }
}
timestamp() { date -u +%Y%m%dT%H%M%SZ; }
