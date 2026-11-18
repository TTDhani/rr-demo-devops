
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --------------------------------------------------
# Validate configuration
# --------------------------------------------------

for v in SOURCE_INSTANCE_ID LAUNCH_TEMPLATE_ID ASG_NAME TARGET_GROUP_ARN APP_BUILD_NUMBER APP_GIT_COMMIT; do
    require_value "$v"
done

validate_refresh_settings

[[ "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Invalid application build number." >&2
    exit 1
}

[[ "$APP_GIT_COMMIT" =~ ^[a-fA-F0-9]{40}$ ]] || {
    echo "ERROR: Invalid Git commit." >&2
    exit 1
}

ARTIFACT_DIR="$(artifact_dir)"
AMI_NAME="${AMI_NAME_PREFIX}-${APP_BUILD_NUMBER}"

# --------------------------------------------------
# Validate source instance and ASG
# --------------------------------------------------

source_state="$("${AWS[@]}" ec2 describe-instances \
    --instance-ids "$SOURCE_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)"

[[ "$source_state" == running ]] || {
    echo "ERROR: Source instance is not running." >&2
    exit 1
}

source_target="$("${AWS[@]}" elbv2 describe-target-health \
    --target-group-arn "$TARGET_GROUP_ARN" \
    --targets "Id=$SOURCE_INSTANCE_ID" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text)"

[[ "$source_target" == healthy ]] || {
    echo "ERROR: Source instance is not healthy." >&2
    exit 1
}

asg_json="$(get_asg_json "$ASG_NAME")"

[[ "$(jq '.AutoScalingGroups | length' <<< "$asg_json")" == 1 ]] || {
    echo "ERROR: ASG not found or ambiguous." >&2
    exit 1
}

asg_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"

[[ "$asg_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template mismatch." >&2
    exit 1
}

member_count="$(jq --arg id "$SOURCE_INSTANCE_ID" \
    '[.AutoScalingGroups[0].Instances[]? | select(.InstanceId==$id)] | length' \
    <<< "$asg_json")"

[[ "$member_count" == 0 ]] || {
    echo "ERROR: Source instance is already an ASG member." >&2
    exit 1
}

attached="$(jq --arg tg "$TARGET_GROUP_ARN" \
    '[.AutoScalingGroups[0].TargetGroupARNs[]? | select(.==$tg)] | length' \
    <<< "$asg_json")"

[[ "$attached" == 1 ]] || {
    echo "ERROR: Target Group is not attached to ASG." >&2
    exit 1
}

assert_no_active_refresh

CURRENT_ASG_VERSION="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"

LATEST_LT_VERSION="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions '$Latest' \
    --query 'LaunchTemplateVersions[0].VersionNumber' \
    --output text)"

[[ "$LATEST_LT_VERSION" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Could not determine latest Launch Template version." >&2
    exit 1
}

echo "Preflight passed: build #${APP_BUILD_NUMBER}, ASG ${ASG_NAME}, latest LT version ${LATEST_LT_VERSION}."

if [[ "$APPLY" != true ]]; then
    echo "DRY RUN: no AWS changes made."
    exit 0
fi

# --------------------------------------------------
# Create or reuse AMI
# --------------------------------------------------

existing_amis="$("${AWS[@]}" ec2 describe-images \
    --owners self \
    --filters "Name=name,Values=${AMI_NAME}" \
    --output json)"

ami_count="$(jq '.Images | length' <<< "$existing_amis")"

if [[ "$ami_count" -gt 1 ]]; then
    echo "ERROR: Multiple AMIs found with name ${AMI_NAME}." >&2
    exit 1
fi

if [[ "$ami_count" == 1 ]]; then
    AMI_ID="$(jq -r '.Images[0].ImageId' <<< "$existing_amis")"

    existing_build="$(jq -r '[.Images[0].Tags[]? | select(.Key=="AppBuildNumber") | .Value][0] // empty' <<< "$existing_amis")"
    existing_commit="$(jq -r '[.Images[0].Tags[]? | select(.Key=="GitCommit") | .Value][0] // empty' <<< "$existing_amis")"
    existing_source="$(jq -r '[.Images[0].Tags[]? | select(.Key=="SourceInstance") | .Value][0] // empty' <<< "$existing_amis")"

    [[ "$existing_build" == "$APP_BUILD_NUMBER" &&
       "$existing_commit" == "$APP_GIT_COMMIT" &&
       "$existing_source" == "$SOURCE_INSTANCE_ID" ]] || {
        echo "ERROR: Existing AMI metadata does not match this build." >&2
        exit 1
    }

    echo "Reusing AMI: ${AMI_ID}"
else
    tags_file="$ARTIFACT_DIR/ami-tag-specifications.json"

    jq -n \
        --arg name "$AMI_NAME" \
        --arg app "$APP_NAME" \
        --arg source "$SOURCE_INSTANCE_ID" \
        --arg build "$APP_BUILD_NUMBER" \
        --arg commit "$APP_GIT_COMMIT" \
        '[
          {ResourceType:"image",Tags:[
            {Key:"Name",Value:$name},
            {Key:"Application",Value:$app},
            {Key:"SourceInstance",Value:$source},
            {Key:"AppBuildNumber",Value:$build},
            {Key:"GitCommit",Value:$commit},
            {Key:"ManagedBy",Value:"Jenkins"}
          ]},
          {ResourceType:"snapshot",Tags:[
            {Key:"Name",Value:$name},
            {Key:"Application",Value:$app},
            {Key:"AppBuildNumber",Value:$build},
            {Key:"GitCommit",Value:$commit},
            {Key:"ManagedBy",Value:"Jenkins"}
          ]}
        ]' > "$tags_file"

    ami_args=(
        ec2 create-image
        --instance-id "$SOURCE_INSTANCE_ID"
        --name "$AMI_NAME"
        --description "${APP_NAME} build ${APP_BUILD_NUMBER}"
        --tag-specifications "file://$tags_file"
    )

    [[ "$NO_REBOOT" == true ]] && ami_args+=(--no-reboot)

    AMI_ID="$("${AWS[@]}" "${ami_args[@]}" \
        --query ImageId --output text)"

    [[ "$AMI_ID" == ami-* ]] || {
        echo "ERROR: AMI creation failed." >&2
        exit 1
    }
fi

echo "Waiting for AMI availability..."
"${AWS[@]}" ec2 wait image-available --image-ids "$AMI_ID"

ami_json="$("${AWS[@]}" ec2 describe-images \
    --image-ids "$AMI_ID" --output json)"

[[ "$(jq -r '.Images[0].State' <<< "$ami_json")" == available ]] || {
    echo "ERROR: AMI is not available." >&2
    exit 1
}

printf '%s\n' "$AMI_ID" > "$ARTIFACT_DIR/latest-ami-id.txt"
printf '%s\n' "$AMI_NAME" > "$ARTIFACT_DIR/latest-ami-name.txt"

# --------------------------------------------------
# Find or create Launch Template version
# --------------------------------------------------

all_versions="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --output json)"

NEW_LT_VERSION="$(jq -r --arg ami "$AMI_ID" \
    '[.LaunchTemplateVersions[]
      | select(.LaunchTemplateData.ImageId==$ami)
      | .VersionNumber] | max // empty' <<< "$all_versions")"

if [[ -n "$NEW_LT_VERSION" ]]; then
    echo "Reusing Launch Template version: ${NEW_LT_VERSION}"
else
    lt_data="$ARTIFACT_DIR/launch-template-data.json"

    "${AWS[@]}" ec2 describe-launch-template-versions \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --versions '$Latest' \
        --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
        --output json > "$lt_data"

    jq --arg image "$AMI_ID" \
        '.ImageId=$image' "$lt_data" > "${lt_data}.tmp"

    mv "${lt_data}.tmp" "$lt_data"

    NEW_LT_VERSION="$("${AWS[@]}" ec2 create-launch-template-version \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --source-version '$Latest' \
        --version-description "app-build-${APP_BUILD_NUMBER}" \
        --launch-template-data "file://$lt_data" \
        --query 'LaunchTemplateVersion.VersionNumber' \
        --output text)"
fi

[[ "$NEW_LT_VERSION" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Invalid Launch Template version." >&2
    exit 1
}

new_lt_ami="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$NEW_LT_VERSION" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' \
    --output text)"

[[ "$new_lt_ami" == "$AMI_ID" ]] || {
    echo "ERROR: Launch Template AMI mismatch." >&2
    exit 1
}

printf '%s\n' "$CURRENT_ASG_VERSION" > "$ARTIFACT_DIR/previous-asg-lt-version.txt"
printf '%s\n' "$NEW_LT_VERSION" > "$ARTIFACT_DIR/latest-lt-version.txt"
printf '%s\n' "$AMI_ID" > "$ARTIFACT_DIR/refresh-ami-id.txt"
printf '%s\n' "$NEW_LT_VERSION" > "$ARTIFACT_DIR/refresh-lt-version.txt"

# --------------------------------------------------
# Update ASG and refresh
# --------------------------------------------------

if [[ "$CURRENT_ASG_VERSION" == "$NEW_LT_VERSION" ]]; then
    echo "ASG already uses the required Launch Template version."
    verify_asg_instances "$NEW_LT_VERSION" "$AMI_ID"
else
    "${AWS[@]}" autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${NEW_LT_VERSION}" \
        --health-check-type ELB \
        --health-check-grace-period "$ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS"

    updated_asg="$(get_asg_json "$ASG_NAME")"
    updated_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$updated_asg")"

    [[ "$updated_version" == "$NEW_LT_VERSION" ]] || {
        echo "ERROR: ASG Launch Template update verification failed." >&2
        exit 1
    }

    desired_file="$ARTIFACT_DIR/desired-configuration.json"
    prefs_file="$ARTIFACT_DIR/refresh-preferences.json"

    jq -n --arg id "$LAUNCH_TEMPLATE_ID" --arg version "$NEW_LT_VERSION" \
        '{LaunchTemplate:{LaunchTemplateId:$id,Version:$version}}' > "$desired_file"

    jq -n \
        --argjson min "$MIN_HEALTHY_PERCENTAGE" \
        --argjson max "$MAX_HEALTHY_PERCENTAGE" \
        --argjson warm "$INSTANCE_WARMUP_SECONDS" \
        --argjson skip "$SKIP_MATCHING" \
        --argjson rollback "$AUTO_ROLLBACK" \
        '{
          MinHealthyPercentage:$min,
          MaxHealthyPercentage:$max,
          InstanceWarmup:$warm,
          SkipMatching:$skip,
          AutoRollback:$rollback
        }' > "$prefs_file"

    start_refresh "$NEW_LT_VERSION" "$desired_file" "$prefs_file"
    verify_asg_instances "$NEW_LT_VERSION" "$AMI_ID"
fi

# --------------------------------------------------
# Save deployment metadata
# --------------------------------------------------

cat > "$ARTIFACT_DIR/deployment-metadata.txt" <<META
APP_NAME=$APP_NAME
APP_BUILD_NUMBER=$APP_BUILD_NUMBER
APP_GIT_COMMIT=$APP_GIT_COMMIT
AMI_ID=$AMI_ID
AMI_NAME=$AMI_NAME
LAUNCH_TEMPLATE_ID=$LAUNCH_TEMPLATE_ID
PREVIOUS_ASG_LT_VERSION=$CURRENT_ASG_VERSION
NEW_ASG_LT_VERSION=$NEW_LT_VERSION
META

echo "SUCCESS: build #${APP_BUILD_NUMBER}, AMI ${AMI_ID}, LT version ${NEW_LT_VERSION}, ASG ${ASG_NAME}."
