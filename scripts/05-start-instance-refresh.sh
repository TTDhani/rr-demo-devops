#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
require_value ASG_NAME
: "${MIN_HEALTHY_PERCENTAGE:=90}" "${MAX_HEALTHY_PERCENTAGE:=200}" "${INSTANCE_WARMUP_SECONDS:=300}" "${SKIP_MATCHING:=true}" "${AUTO_ROLLBACK:=true}"
prefs="$(jq -n --argjson min "$MIN_HEALTHY_PERCENTAGE" --argjson max "$MAX_HEALTHY_PERCENTAGE" --argjson warm "$INSTANCE_WARMUP_SECONDS" --argjson skip "$SKIP_MATCHING" --argjson rollback "$AUTO_ROLLBACK" '{MinHealthyPercentage:$min,MaxHealthyPercentage:$max,InstanceWarmup:$warm,SkipMatching:$skip,AutoRollback:$rollback}')"
echo "WARNING: this replaces ASG instances."
echo "$prefs" | jq .
confirm_apply || exit 0
id="$("${AWS[@]}" autoscaling start-instance-refresh --auto-scaling-group-name "$ASG_NAME" --preferences "$prefs" --query InstanceRefreshId --output text)"
mkdir -p "${ROOT_DIR}/artifacts"
printf '%s\n' "$id" > "${ROOT_DIR}/artifacts/latest-refresh-id.txt"
echo "Started refresh $id"
