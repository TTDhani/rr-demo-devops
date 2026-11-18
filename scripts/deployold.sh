#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

for v in SOURCE_INSTANCE_ID LAUNCH_TEMPLATE_ID ASG_NAME TARGET_GROUP_ARN APP_BUILD_NUMBER APP_GIT_COMMIT; do require_value "$v"; done
validate_refresh_settings
[[ "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "ERROR: APP_BUILD_NUMBER must be numeric." >&2; exit 1; }
[[ "$APP_GIT_COMMIT" =~ ^[a-fA-F0-9]{7,40}$ ]] || { echo "ERROR: APP_GIT_COMMIT must be a valid commit SHA." >&2; exit 1; }

ARTIFACT_DIR="$(artifact_dir)"
COMMIT_SHORT="${APP_GIT_COMMIT:0:7}"
BUILD_TS="$(date -u +%Y%m%dT%H%M%SZ)"
AMI_NAME="${AMI_NAME_PREFIX}-${APP_NAME}-build-${APP_BUILD_NUMBER}-${COMMIT_SHORT}-${BUILD_TS}"

# Preflight: source instance, ASG, LT, target group and refresh state.
source_json="$("${AWS[@]}" ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --output json)"
source_state="$(jq -r '.Reservations[0].Instances[0].State.Name // empty' <<< "$source_json")"
[[ "$source_state" == running ]] || { echo "ERROR: Source instance is not running: $source_state" >&2; exit 1; }
source_target="$("${AWS[@]}" elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --targets "Id=$SOURCE_INSTANCE_ID" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
[[ "$source_target" == healthy ]] || { echo "ERROR: Source instance is not healthy in target group: $source_target" >&2; exit 1; }

asg_json="$(get_asg_json "$ASG_NAME")"
[[ "$(jq '.AutoScalingGroups | length' <<< "$asg_json")" == 1 ]] || { echo "ERROR: ASG not found or ambiguous: $ASG_NAME" >&2; exit 1; }
asg_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
[[ "$asg_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || { echo "ERROR: ASG is not using expected Launch Template $LAUNCH_TEMPLATE_ID." >&2; exit 1; }
member_count="$(jq --arg id "$SOURCE_INSTANCE_ID" '[.AutoScalingGroups[0].Instances[]? | select(.InstanceId==$id)] | length' <<< "$asg_json")"
[[ "$member_count" == 0 ]] || { echo "ERROR: Source instance is already an ASG member." >&2; exit 1; }
attached="$(jq --arg tg "$TARGET_GROUP_ARN" '[.AutoScalingGroups[0].TargetGroupARNs[]? | select(.==$tg)] | length' <<< "$asg_json")"
[[ "$attached" == 1 ]] || { echo "ERROR: Target Group is not attached to ASG." >&2; exit 1; }
assert_no_active_refresh

current_configured="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"
PREVIOUS_ASG_VERSION="$(resolve_asg_version "$current_configured")"
[[ "$PREVIOUS_ASG_VERSION" =~ ^[0-9]+$ ]] || { echo "ERROR: Could not resolve current ASG LT version." >&2; exit 1; }

latest_version="$("${AWS[@]}" ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions '$Latest' --query 'LaunchTemplateVersions[0].VersionNumber' --output text)"
[[ "$latest_version" =~ ^[0-9]+$ ]] || { echo "ERROR: Could not resolve latest LT version." >&2; exit 1; }

# Print a compact plan. No AWS resources are changed unless APPLY=true.
echo "Deployment plan: app=$APP_NAME build=$APP_BUILD_NUMBER source=$SOURCE_INSTANCE_ID ASG=$ASG_NAME LT=$LAUNCH_TEMPLATE_ID current-version=$PREVIOUS_ASG_VERSION latest-version=$latest_version AMI=$AMI_NAME"
if [[ "$APPLY" != true ]]; then
    echo "DRY RUN: validation passed; no AWS changes made. Set APPLY=true to execute."
    exit 0
fi

# Create and tag AMI.
tags_file="$ARTIFACT_DIR/ami-tag-specifications.json"
jq -n --arg name "$AMI_NAME" --arg app "$APP_NAME" --arg source "$SOURCE_INSTANCE_ID" --arg build "$APP_BUILD_NUMBER" --arg commit "$APP_GIT_COMMIT" \
    '[{ResourceType:"image",Tags:[{Key:"Name",Value:$name},{Key:"Application",Value:$app},{Key:"SourceInstance",Value:$source},{Key:"AppBuildNumber",Value:$build},{Key:"GitCommit",Value:$commit},{Key:"ManagedBy",Value:"Jenkins"}]},{ResourceType:"snapshot",Tags:[{Key:"Name",Value:$name},{Key:"Application",Value:$app},{Key:"AppBuildNumber",Value:$build},{Key:"GitCommit",Value:$commit},{Key:"ManagedBy",Value:"Jenkins"}]}]' > "$tags_file"
ami_args=(ec2 create-image --instance-id "$SOURCE_INSTANCE_ID" --name "$AMI_NAME" --description "${APP_NAME} build ${APP_BUILD_NUMBER} commit ${APP_GIT_COMMIT}" --tag-specifications "file://$tags_file")
[[ "$NO_REBOOT" == true ]] && ami_args+=(--no-reboot)
AMI_ID="$("${AWS[@]}" "${ami_args[@]}" --query ImageId --output text)"
[[ "$AMI_ID" == ami-* ]] || { echo "ERROR: Invalid AMI ID returned: $AMI_ID" >&2; exit 1; }
printf '%s\n' "$AMI_ID" > "$ARTIFACT_DIR/latest-ami-id.txt"
printf '%s\n' "$AMI_NAME" > "$ARTIFACT_DIR/latest-ami-name.txt"
echo "AMI creation started: $AMI_ID"
"${AWS[@]}" ec2 wait image-available --image-ids "$AMI_ID"

ami_json="$("${AWS[@]}" ec2 describe-images --image-ids "$AMI_ID" --output json)"
[[ "$(jq -r '.Images[0].State' <<< "$ami_json")" == available ]] || { echo "ERROR: AMI is not available." >&2; exit 1; }
[[ "$(jq -r '[.Images[0].Tags[]? | select(.Key==\"Application\") | .Value][0] // empty' <<< "$ami_json")" == "$APP_NAME" ]] || { echo "ERROR: AMI application tag mismatch." >&2; exit 1; }

# Inherit latest LT data and change only ImageId.
lt_data="$ARTIFACT_DIR/launch-template-data.json"
"${AWS[@]}" ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions "$latest_version" --query 'LaunchTemplateVersions[0].LaunchTemplateData' --output json > "$lt_data"
jq --arg image "$AMI_ID" '.ImageId=$image' "$lt_data" > "${lt_data}.tmp" && mv "${lt_data}.tmp" "$lt_data"

NEW_LT_VERSION="$("${AWS[@]}" ec2 create-launch-template-version --launch-template-id "$LAUNCH_TEMPLATE_ID" --source-version "$latest_version" --version-description "${LT_VERSION_DESCRIPTION_PREFIX}-build-${APP_BUILD_NUMBER}-${COMMIT_SHORT}" --launch-template-data "file://$lt_data" --query 'LaunchTemplateVersion.VersionNumber' --output text)"
[[ "$NEW_LT_VERSION" =~ ^[0-9]+$ ]] || { echo "ERROR: Invalid LT version returned: $NEW_LT_VERSION" >&2; exit 1; }
new_lt_ami="$("${AWS[@]}" ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions "$NEW_LT_VERSION" --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' --output text)"
[[ "$new_lt_ami" == "$AMI_ID" ]] || { echo "ERROR: New LT version AMI mismatch." >&2; exit 1; }

# Persist rollback version before changing ASG.
printf '%s\n' "$PREVIOUS_ASG_VERSION" > "$ARTIFACT_DIR/previous-asg-lt-version.txt"
printf '%s\n' "$NEW_LT_VERSION" > "$ARTIFACT_DIR/latest-lt-version.txt"
printf '%s\n' "$AMI_ID" > "$ARTIFACT_DIR/refresh-ami-id.txt"
printf '%s\n' "$NEW_LT_VERSION" > "$ARTIFACT_DIR/refresh-lt-version.txt"

"${AWS[@]}" autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${NEW_LT_VERSION}" \
    --health-check-type ELB \
    --health-check-grace-period "$ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS"

updated_asg="$(get_asg_json "$ASG_NAME")"
updated_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$updated_asg")"
[[ "$updated_version" == "$NEW_LT_VERSION" ]] || { echo "ERROR: ASG LT version update verification failed." >&2; exit 1; }

# Start AWS-managed Instance Refresh using the exact numeric LT version.
desired_file="$ARTIFACT_DIR/desired-configuration.json"
prefs_file="$ARTIFACT_DIR/refresh-preferences.json"
jq -n --arg id "$LAUNCH_TEMPLATE_ID" --arg version "$NEW_LT_VERSION" '{LaunchTemplate:{LaunchTemplateId:$id,Version:$version}}' > "$desired_file"
jq -n --argjson min "$MIN_HEALTHY_PERCENTAGE" --argjson max "$MAX_HEALTHY_PERCENTAGE" --argjson warm "$INSTANCE_WARMUP_SECONDS" --argjson skip "$SKIP_MATCHING" --argjson rollback "$AUTO_ROLLBACK" \
    '{MinHealthyPercentage:$min,MaxHealthyPercentage:$max,InstanceWarmup:$warm,SkipMatching:$skip,AutoRollback:$rollback}' > "$prefs_file"
start_refresh "$NEW_LT_VERSION" "$desired_file" "$prefs_file"
verify_asg_instances "$NEW_LT_VERSION" "$AMI_ID"

cat > "$ARTIFACT_DIR/deployment-metadata.txt" <<META
APP_NAME=$APP_NAME
APP_BUILD_NUMBER=$APP_BUILD_NUMBER
APP_GIT_COMMIT=$APP_GIT_COMMIT
AMI_ID=$AMI_ID
AMI_NAME=$AMI_NAME
LAUNCH_TEMPLATE_ID=$LAUNCH_TEMPLATE_ID
PREVIOUS_ASG_LT_VERSION=$PREVIOUS_ASG_VERSION
NEW_ASG_LT_VERSION=$NEW_LT_VERSION
META

echo "Deployment completed successfully: ASG=$ASG_NAME LT_VERSION=$NEW_LT_VERSION AMI=$AMI_ID"
