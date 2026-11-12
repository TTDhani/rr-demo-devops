#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
require_value ASG_NAME; require_value LAUNCH_TEMPLATE_ID
: "${MIN_HEALTHY_PERCENTAGE:=90}" "${MAX_HEALTHY_PERCENTAGE:=200}" "${INSTANCE_WARMUP_SECONDS:=300}" "${AUTO_ROLLBACK:=true}"
version="${PREVIOUS_ASG_LT_VERSION:-}"
[[ -n "$version" ]] || [[ ! -f "$ROOT_DIR/artifacts/previous-asg-lt-version.txt" ]] || version="$(<"$ROOT_DIR/artifacts/previous-asg-lt-version.txt")"
[[ -n "$version" ]] || { echo "Previous ASG LT version not recorded" >&2; exit 1; }
asg="$(get_asg_json "$ASG_NAME")"
[[ "$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId' <<<"$asg")" == "$LAUNCH_TEMPLATE_ID" ]] || { echo "ASG LT ID mismatch" >&2; exit 1; }
echo "Planned rollback of $ASG_NAME to LT version $version, followed by recovery refresh."
confirm_apply || exit 0
"${AWS[@]}" autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --launch-template "LaunchTemplateId=$LAUNCH_TEMPLATE_ID,Version=$version"
prefs="$(jq -n --argjson min "$MIN_HEALTHY_PERCENTAGE" --argjson max "$MAX_HEALTHY_PERCENTAGE" --argjson warm "$INSTANCE_WARMUP_SECONDS" --argjson rollback "$AUTO_ROLLBACK" '{MinHealthyPercentage:$min,MaxHealthyPercentage:$max,InstanceWarmup:$warm,SkipMatching:false,AutoRollback:$rollback}')"
id="$("${AWS[@]}" autoscaling start-instance-refresh --auto-scaling-group-name "$ASG_NAME" --preferences "$prefs" --query InstanceRefreshId --output text)"
a="$(artifact_dir)"; printf '%s\n' "$id" > "$a/rollback-refresh-id.txt"
echo "Rollback LT version assigned; recovery refresh started: $id. Verify recovery health before declaring success."
