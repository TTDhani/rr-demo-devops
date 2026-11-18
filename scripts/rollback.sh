#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

for v in ASG_NAME LAUNCH_TEMPLATE_ID TARGET_GROUP_ARN; do require_value "$v"; done
validate_refresh_settings
ARTIFACT_DIR="$(artifact_dir)"

ROLLBACK_VERSION="${PREVIOUS_ASG_LT_VERSION:-}"
if [[ -z "$ROLLBACK_VERSION" && -f "$ARTIFACT_DIR/previous-asg-lt-version.txt" ]]; then
    ROLLBACK_VERSION="$(tr -d '[:space:]' < "$ARTIFACT_DIR/previous-asg-lt-version.txt")"
fi
[[ "$ROLLBACK_VERSION" =~ ^[0-9]+$ ]] || { echo "ERROR: Previous ASG LT version is missing or invalid." >&2; exit 1; }

assert_no_active_refresh
lt_json="$("${AWS[@]}" ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions "$ROLLBACK_VERSION" --output json)"
lt_id="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateId // empty' <<< "$lt_json")"
rollback_ami="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' <<< "$lt_json")"
[[ "$lt_id" == "$LAUNCH_TEMPLATE_ID" && "$rollback_ami" == ami-* ]] || { echo "ERROR: Rollback LT version is invalid." >&2; exit 1; }
ami_state="$("${AWS[@]}" ec2 describe-images --image-ids "$rollback_ami" --query 'Images[0].State' --output text)"
[[ "$ami_state" == available ]] || { echo "ERROR: Rollback AMI is not available: $rollback_ami ($ami_state)" >&2; exit 1; }

asg_json="$(get_asg_json "$ASG_NAME")"
[[ "$(jq '.AutoScalingGroups | length' <<< "$asg_json")" == 1 ]] || { echo "ERROR: ASG not found or ambiguous." >&2; exit 1; }
current_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
[[ "$current_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || { echo "ERROR: ASG Launch Template mismatch." >&2; exit 1; }
current_version="$(resolve_asg_version "$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")")"
[[ "$current_version" != "$ROLLBACK_VERSION" ]] || { echo "ASG already uses rollback version $ROLLBACK_VERSION; nothing to change."; exit 0; }

echo "Rollback plan: ASG=$ASG_NAME current-version=$current_version rollback-version=$ROLLBACK_VERSION AMI=$rollback_ami"
if [[ "$APPLY" != true ]]; then
    echo "DRY RUN: no AWS changes made. Set APPLY=true to execute rollback."
    exit 0
fi

printf '%s\n' "$current_version" > "$ARTIFACT_DIR/pre-rollback-asg-lt-version.txt"
"${AWS[@]}" autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${ROLLBACK_VERSION}" \
    --health-check-type ELB \
    --health-check-grace-period "$ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS"

updated="$(get_asg_json "$ASG_NAME")"
[[ "$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$updated")" == "$ROLLBACK_VERSION" ]] || { echo "ERROR: Rollback ASG version verification failed." >&2; exit 1; }

desired_file="$ARTIFACT_DIR/rollback-desired-configuration.json"
prefs_file="$ARTIFACT_DIR/rollback-refresh-preferences.json"
jq -n --arg id "$LAUNCH_TEMPLATE_ID" --arg version "$ROLLBACK_VERSION" '{LaunchTemplate:{LaunchTemplateId:$id,Version:$version}}' > "$desired_file"
jq -n --argjson min "$MIN_HEALTHY_PERCENTAGE" --argjson max "$MAX_HEALTHY_PERCENTAGE" --argjson warm "$INSTANCE_WARMUP_SECONDS" --argjson skip "$SKIP_MATCHING" --argjson rollback "$AUTO_ROLLBACK" \
    '{MinHealthyPercentage:$min,MaxHealthyPercentage:$max,InstanceWarmup:$warm,SkipMatching:$skip,AutoRollback:$rollback}' > "$prefs_file"
start_refresh "$ROLLBACK_VERSION" "$desired_file" "$prefs_file"
verify_asg_instances "$ROLLBACK_VERSION" "$rollback_ami"
echo "Rollback completed successfully: ASG=$ASG_NAME LT_VERSION=$ROLLBACK_VERSION AMI=$rollback_ami"
