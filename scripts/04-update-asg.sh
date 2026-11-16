
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value TARGET_GROUP_ARN

ARTIFACT_DIR="$(artifact_dir)"

# --------------------------------------------------
# 1. GET NEW LT VERSION AND AMI
# --------------------------------------------------

version="${NEW_LT_VERSION:-}"

if [[ -z "$version" && -f "${ARTIFACT_DIR}/latest-lt-version.txt" ]]; then
    version="$(tr -d '[:space:]' < "${ARTIFACT_DIR}/latest-lt-version.txt")"
fi

AMI_ID="${AMI_ID:-}"

if [[ -z "$AMI_ID" && -f "${ARTIFACT_DIR}/latest-ami-id.txt" ]]; then
    AMI_ID="$(tr -d '[:space:]' < "${ARTIFACT_DIR}/latest-ami-id.txt")"
fi

[[ "$version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: A valid numeric NEW_LT_VERSION is required." >&2
    exit 1
}

[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || {
    echo "ERROR: Current rollout AMI_ID is missing." >&2
    exit 1
}

# --------------------------------------------------
# 2. VERIFY NEW LAUNCH TEMPLATE VERSION
# --------------------------------------------------

echo "========================================"
echo "VALIDATING NEW LAUNCH TEMPLATE VERSION"
echo "========================================"

new_lt_json="$(
    "${AWS[@]}" ec2 describe-launch-template-versions \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --versions "$version" \
        --output json
)"

new_lt_count="$(jq '.LaunchTemplateVersions | length' <<< "$new_lt_json")"

[[ "$new_lt_count" == "1" ]] || {
    echo "ERROR: Launch Template version $version was not found." >&2
    exit 1
}

new_lt_id="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateId // empty' <<< "$new_lt_json")"
new_ami="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' <<< "$new_lt_json")"
new_description="$(jq -r '.LaunchTemplateVersions[0].VersionDescription // empty' <<< "$new_lt_json")"

[[ "$new_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: Launch Template ID mismatch." >&2
    exit 1
}

[[ "$new_ami" == "$AMI_ID" ]] || {
    echo "ERROR: Launch Template AMI does not match the current rollout." >&2
    echo "Expected AMI: $AMI_ID" >&2
    echo "Actual AMI:   $new_ami" >&2
    exit 1
}

# Verify AMI is available.
ami_state="$(
    "${AWS[@]}" ec2 describe-images \
        --image-ids "$AMI_ID" \
        --query 'Images[0].State' \
        --output text
)"

[[ "$ami_state" == "available" ]] || {
    echo "ERROR: AMI $AMI_ID is not available: $ami_state" >&2
    exit 1
}

# --------------------------------------------------
# 3. VERIFY LAUNCH TEMPLATE DEFAULT VERSION
# --------------------------------------------------

default_version="$(
    "${AWS[@]}" ec2 describe-launch-templates \
        --launch-template-ids "$LAUNCH_TEMPLATE_ID" \
        --query 'LaunchTemplates[0].DefaultVersionNumber' \
        --output text
)"

[[ "$default_version" == "$version" ]] || {
    echo "ERROR: Launch Template default version does not match new version." >&2
    echo "Expected default: $version" >&2
    echo "Actual default:   $default_version" >&2
    echo "Run scripts/03-create-lt-version.sh successfully first." >&2
    exit 1
}

# --------------------------------------------------
# 4. READ CURRENT ASG CONFIGURATION
# --------------------------------------------------

asg_json="$(
    "${AWS[@]}" autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --output json
)"

asg_count="$(jq '.AutoScalingGroups | length' <<< "$asg_json")"

[[ "$asg_count" == "1" ]] || {
    echo "ERROR: Expected exactly one ASG named $ASG_NAME." >&2
    exit 1
}

current_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
configured_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"

[[ "$current_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG is using a different Launch Template." >&2
    echo "Expected: $LAUNCH_TEMPLATE_ID" >&2
    echo "Actual:   $current_lt_id" >&2
    exit 1
}

# Resolve symbolic current ASG version to numeric.
if [[ "$configured_version" == '$Default' || "$configured_version" == '$Latest' ]]; then
    current_version="$(
        "${AWS[@]}" ec2 describe-launch-template-versions \
            --launch-template-id "$LAUNCH_TEMPLATE_ID" \
            --versions "$configured_version" \
            --query 'LaunchTemplateVersions[0].VersionNumber' \
            --output text
    )"
else
    current_version="$configured_version"
fi

[[ "$current_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Could not resolve current ASG LT version." >&2
    exit 1
}

# Confirm Target Group is attached to ASG.
attached="$(
    jq --arg tg "$TARGET_GROUP_ARN" \
        '[.AutoScalingGroups[0].TargetGroupARNs[]? | select(. == $tg)] | length' \
        <<< "$asg_json"
)"

[[ "$attached" == "1" ]] || {
    echo "ERROR: Target Group is not attached to ASG $ASG_NAME." >&2
    exit 1
}

# Do not update ASG during an active Instance Refresh.
refresh_json="$(
    "${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" \
        --max-records 20 \
        --output json
)"

active_refresh_count="$(
    jq '[
        .InstanceRefreshes[]? |
        select(
            .Status == "Pending" or
            .Status == "InProgress" or
            .Status == "Cancelling" or
            .Status == "RollbackInProgress"
        )
    ] | length' <<< "$refresh_json"
)"

[[ "$active_refresh_count" == "0" ]] || {
    echo "ERROR: An Instance Refresh is already active. Refusing to update ASG." >&2
    jq '
        .InstanceRefreshes[]? |
        select(
            .Status == "Pending" or
            .Status == "InProgress" or
            .Status == "Cancelling" or
            .Status == "RollbackInProgress"
        ) |
        {
            InstanceRefreshId,
            Status,
            PercentageComplete
        }
    ' <<< "$refresh_json"
    exit 1
}

# --------------------------------------------------
# 5. SHOW UPDATE PLAN
# --------------------------------------------------

echo
echo "========================================"
echo "ASG UPDATE PLAN"
echo "========================================"
echo "ASG name                  : $ASG_NAME"
echo "Launch Template ID        : $LAUNCH_TEMPLATE_ID"
echo "Current ASG version       : $current_version"
echo "New Launch Template       : $version"
echo "Launch Template default   : $default_version"
echo "New AMI                   : $new_ami"
echo "AMI state                 : $ami_state"
echo "Version description       : $new_description"
echo "Health check type         : ELB"
echo "Health check grace period : 300 seconds"
echo "Target Group              : $TARGET_GROUP_ARN"
echo
echo "This updates future launches only."
echo "Existing ASG instances will not be replaced by this command."

confirm_apply || exit 0

# --------------------------------------------------
# 6. SAVE PREVIOUS VERSION FOR ROLLBACK
# --------------------------------------------------

printf '%s\n' "$current_version" \
    > "${ARTIFACT_DIR}/previous-asg-lt-version.txt"

# --------------------------------------------------
# 7. UPDATE ASG TO EXACT NUMERIC VERSION
# --------------------------------------------------

echo
echo "Updating ASG to Launch Template version $version..."

"${AWS[@]}" autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${version}" \
    --health-check-type ELB \
    --health-check-grace-period 300

# --------------------------------------------------
# 8. VERIFY ASG CONFIGURATION
# --------------------------------------------------

updated_json="$(
    "${AWS[@]}" autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --output json
)"

actual_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$updated_json")"
actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$updated_json")"
actual_health_type="$(jq -r '.AutoScalingGroups[0].HealthCheckType // empty' <<< "$updated_json")"
actual_grace="$(jq -r '.AutoScalingGroups[0].HealthCheckGracePeriod // empty' <<< "$updated_json")"

[[ "$actual_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template ID verification failed." >&2
    exit 1
}

[[ "$actual_version" == "$version" ]] || {
    echo "ERROR: ASG Launch Template version verification failed." >&2
    echo "Expected: $version" >&2
    echo "Actual:   $actual_version" >&2
    exit 1
}

[[ "$actual_health_type" == "ELB" ]] || {
    echo "ERROR: ASG ELB health check verification failed." >&2
    exit 1
}

[[ "$actual_grace" == "300" ]] || {
    echo "ERROR: ASG health check grace period verification failed." >&2
    exit 1
}

# Verify that the ASG is configured with the same version
# that contains the exact AMI from this rollout.
actual_version_ami="$(
    "${AWS[@]}" ec2 describe-launch-template-versions \
        --launch-template-id "$actual_lt_id" \
        --versions "$actual_version" \
        --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' \
        --output text
)"

[[ "$actual_version_ami" == "$AMI_ID" ]] || {
    echo "ERROR: ASG version does not resolve to the expected AMI." >&2
    echo "Expected: $AMI_ID" >&2
    echo "Actual:   $actual_version_ami" >&2
    exit 1
}

# --------------------------------------------------
# 9. SAVE ROLLOUT METADATA
# --------------------------------------------------

cat > "${ARTIFACT_DIR}/asg-rollout-metadata.txt" <<EOF
ASG_NAME=${ASG_NAME}
LAUNCH_TEMPLATE_ID=${LAUNCH_TEMPLATE_ID}
PREVIOUS_ASG_LT_VERSION=${current_version}
NEW_ASG_LT_VERSION=${actual_version}
AMI_ID=${AMI_ID}
DEFAULT_LT_VERSION=${default_version}
TARGET_GROUP_ARN=${TARGET_GROUP_ARN}
EOF

# --------------------------------------------------
# 10. FINAL RESULT
# --------------------------------------------------

echo
echo "========================================"
echo "ASG UPDATE VERIFIED SUCCESSFULLY"
echo "========================================"
echo "ASG                  : $ASG_NAME"
echo "Launch Template      : $actual_lt_id"
echo "Previous version     : $current_version"
echo "New ASG version      : $actual_version"
echo "Launch Template AMI  : $actual_version_ami"
echo "Default LT version   : $default_version"
echo "Health check type    : $actual_health_type"
echo "Health grace period  : $actual_grace seconds"
echo
echo "ASG is configured to launch instances from the new AMI."
echo "Next step: scripts/05-start-instance-refresh.sh"
