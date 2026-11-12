#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
require_value ASG_NAME
id="${REFRESH_ID:-}"
[[ -n "$id" ]] || [[ ! -f "${ROOT_DIR}/artifacts/latest-refresh-id.txt" ]] || id="$(cat "${ROOT_DIR}/artifacts/latest-refresh-id.txt")"
[[ -n "$id" ]] || { echo "REFRESH_ID missing" >&2; exit 1; }
while true; do
  obj="$("${AWS[@]}" autoscaling describe-instance-refreshes --auto-scaling-group-name "$ASG_NAME" --instance-refresh-ids "$id" --query 'InstanceRefreshes[0]' --output json)"
  status="$(jq -r '.Status // "Unknown"' <<< "$obj")"
  pct="$(jq -r '.PercentageComplete // 0' <<< "$obj")"
  echo "Refresh $id: $status (${pct}%)"
  case "$status" in Successful) break ;; Failed|Cancelled|RollbackFailed) echo "$status" >&2; exit 1 ;; *) sleep 30 ;; esac
done
if [[ -n "${TARGET_GROUP_ARN:-}" && "$TARGET_GROUP_ARN" != REPLACE_* ]]; then
  "${AWS[@]}" elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' --output table
fi
"${AWS[@]}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[].Instances[].{Id:InstanceId,Health:HealthStatus,State:LifecycleState}' --output table
