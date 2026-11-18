#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${ROOT_DIR}/config/poc.env}"
[[ -f "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
APPLY_OVERRIDE="${APPLY:-}"
source "$CONFIG_FILE"
[[ -z "$APPLY_OVERRIDE" ]] || export APPLY="$APPLY_OVERRIDE"
: "${AWS_REGION:?AWS_REGION required}" "${EXPECTED_ACCOUNT_ID:?EXPECTED_ACCOUNT_ID required}" "${APP_NAME:?APP_NAME required}"
command -v aws >/dev/null || { echo "aws CLI required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
AWS=(aws --region "$AWS_REGION" --no-cli-pager)
[[ -z "${AWS_PROFILE:-}" ]] || AWS+=(--profile "$AWS_PROFILE")
ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || { echo "Wrong account: $ACCOUNT_ID" >&2; exit 1; }
echo "Verified account $ACCOUNT_ID, region $AWS_REGION"
require_value() {
  local n="$1" v="${!1:-}"
  [[ -n "$v" && "$v" != REPLACE_* ]] || { echo "Set $n in Jenkins POC config" >&2; exit 1; }
}
confirm_apply() {
  [[ "${APPLY:-false}" == "true" ]] || { echo "DRY RUN: no AWS changes. Set APPLY=true after approval."; return 1; }
}
timestamp() { date -u +%Y%m%dT%H%M%SZ; }
artifact_dir() { mkdir -p "$ROOT_DIR/artifacts"; printf '%s\n' "$ROOT_DIR/artifacts"; }
get_asg_json() {
  "${AWS[@]}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${1:?ASG required}" --output json
}
assert_source_healthy_target() {
  local id="$1" tg="$2" state target
  state="$("${AWS[@]}" ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)"
  [[ "$state" == running ]] || { echo "Source $id is not running: $state" >&2; return 1; }
  target="$("${AWS[@]}" elbv2 describe-target-health --target-group-arn "$tg" --targets "Id=$id" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
  [[ "$target" == healthy ]] || { echo "Source $id is not healthy in target group: $target" >&2; return 1; }
}
