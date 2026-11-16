
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value APP_BUILD_NUMBER
require_value APP_GIT_COMMIT

# --------------------------------------------------
# CONFIGURATION
# --------------------------------------------------

: "${LT_VERSION_DESCRIPTION_PREFIX:=rr-demo}"
ARTIFACT_DIR="$(artifact_dir)"

AMI_ID="${AMI_ID:-}"

if [[ -z "$AMI_ID" && -f "${ARTIFACT_DIR}/latest-ami-id.txt" ]]; then
    AMI_ID="$(tr -d '[:space:]' < "${ARTIFACT_DIR}/latest-ami-id.txt")"
fi

[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || {
    echo "ERROR: Current rollout AMI_ID is missing." >&2
    exit 1
}

[[ "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "ERROR: APP_BUILD_NUMBER must be numeric." >&2
    exit 1
}

[[ "$APP_GIT_COMMIT" =~ ^[a-fA-F0-9]{7,40}$ ]] || {
    echo "ERROR: APP_GIT_COMMIT must be a valid Git commit SHA." >&2
    exit 1
}

COMMIT_SHORT="${APP_GIT_COMMIT:0:7}"

# --------------------------------------------------
# 1. VERIFY THE NEW AMI
# --------------------------------------------------

echo "========================================"
echo "VALIDATING NEW AMI"
echo "========================================"

ami_json="$(
    "${AWS[@]}" ec2 describe-images \
        --image-ids "$AMI_ID" \
        --output json
)"

ami_count="$(jq '.Images | length' <<< "$ami_json")"

[[ "$ami_count" == "1" ]] || {
    echo "ERROR: AMI not found: $AMI_ID" >&2
    exit 1
}

ami_state="$(jq -r '.Images[0].State' <<< "$ami_json")"
ami_name="$(jq -r '.Images[0].Name // empty' <<< "$ami_json")"

[[ "$ami_state" == "available" ]] || {
    echo "ERROR: AMI is not available: $AMI_ID ($ami_state)" >&2
    exit 1
}

# Verify the AMI belongs to this application build.
ami_app="$(jq -r '[.Images[0].Tags[]? | select(.Key=="Application") | .Value][0] // empty' <<< "$ami_json")"
ami_build="$(jq -r '[.Images[0].Tags[]? | select(.Key=="AppBuildNumber") | .Value][0] // empty' <<< "$ami_json")"
ami_commit="$(jq -r '[.Images[0].Tags[]? | select(.Key=="GitCommit") | .Value][0] // empty' <<< "$ami_json")"

[[ "$ami_app" == "$APP_NAME" ]] || {
    echo "ERROR: AMI Application tag mismatch." >&2
    echo "Expected: $APP_NAME" >&2
    echo "Actual:   $ami_app" >&2
    exit 1
}

[[ "$ami_build" == "$APP_BUILD_NUMBER" ]] || {
    echo "ERROR: AMI AppBuildNumber tag mismatch." >&2
    echo "Expected: $APP_BUILD_NUMBER" >&2
    echo "Actual:   $ami_build" >&2
    exit 1
}

[[ "${ami_commit,,}" == "${APP_GIT_COMMIT,,}" ]] || {
    echo "ERROR: AMI GitCommit tag mismatch." >&2
    echo "Expected: $APP_GIT_COMMIT" >&2
    echo "Actual:   $ami_commit" >&2
    exit 1
}

echo "AMI ID       : $AMI_ID"
echo "AMI name     : $ami_name"
echo "AMI state    : $ami_state"
echo "Application  : $ami_app"
echo "Build number : $ami_build"
echo "Git commit   : $ami_commit"

# --------------------------------------------------
# 2. VALIDATE ASG AND LAUNCH TEMPLATE
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

asg_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
asg_configured_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"

[[ "$asg_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template mismatch." >&2
    echo "Expected: $LAUNCH_TEMPLATE_ID" >&2
    echo "Actual:   $asg_lt_id" >&2
    exit 1
}

# Do not create another version while a refresh is active.
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
    echo "ERROR: An Instance Refresh is already active." >&2
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
# 3. GET LATEST LAUNCH TEMPLATE VERSION
# --------------------------------------------------

echo
echo "Resolving latest Launch Template version..."

latest_version="$(
    "${AWS[@]}" ec2 describe-launch-template-versions \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --versions '$Latest' \
        --query 'LaunchTemplateVersions[0].VersionNumber' \
        --output text
)"

[[ "$latest_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Could not resolve latest numeric LT version." >&2
    exit 1
}

echo "ASG configured version : $asg_configured_version"
echo "Latest LT version      : $latest_version"

# Always inherit the latest version's settings.
# This prevents inheriting an old AMI from Default version 1
# or an older ASG configuration.

data="${ARTIFACT_DIR}/lt-data.json"

"${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$latest_version" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
    --output json > "$data"

[[ -s "$data" ]] || {
    echo "ERROR: Could not retrieve latest LT data." >&2
    exit 1
}

# Change only the AMI ID.
jq --arg image "$AMI_ID" \
    '.ImageId = $image' \
    "$data" > "${data}.tmp"

mv "${data}.tmp" "$data"

# --------------------------------------------------
# 4. PREVIEW NEW LAUNCH TEMPLATE VERSION
# --------------------------------------------------

VERSION_DESCRIPTION="${LT_VERSION_DESCRIPTION_PREFIX}-build-${APP_BUILD_NUMBER}-${COMMIT_SHORT}"

echo
echo "========================================"
echo "LAUNCH TEMPLATE VERSION PLAN"
echo "========================================"
echo "Application          : $APP_NAME"
echo "Build number         : $APP_BUILD_NUMBER"
echo "Git commit           : $APP_GIT_COMMIT"
echo "AMI name             : $ami_name"
echo "AMI ID               : $AMI_ID"
echo "Launch Template      : $LAUNCH_TEMPLATE_ID"
echo "Source LT version    : $latest_version"
echo "Version description  : $VERSION_DESCRIPTION"
echo
echo "Inherited settings with updated AMI:"
jq '{
    ImageId,
    InstanceType,
    KeyName,
    SecurityGroupIds,
    IamInstanceProfile,
    BlockDeviceMappings,
    UserData
}' "$data"

confirm_apply || exit 0

# --------------------------------------------------
# 5. CREATE NEW LAUNCH TEMPLATE VERSION
# --------------------------------------------------

echo
echo "Creating new Launch Template version..."

new_version="$(
    "${AWS[@]}" ec2 create-launch-template-version \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --source-version "$latest_version" \
        --version-description "$VERSION_DESCRIPTION" \
        --launch-template-data "file://${data}" \
        --query 'LaunchTemplateVersion.VersionNumber' \
        --output text
)"

[[ "$new_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: AWS did not return a valid new LT version." >&2
    exit 1
}

# --------------------------------------------------
# 6. VERIFY NEW VERSION AMI
# --------------------------------------------------

created_version_json="$(
    "${AWS[@]}" ec2 describe-launch-template-versions \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --versions "$new_version" \
        --output json
)"

created_ami="$(
    jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' \
        <<< "$created_version_json"
)"

[[ "$created_ami" == "$AMI_ID" ]] || {
    echo "ERROR: New LT version AMI does not match current rollout AMI." >&2
    echo "Expected: $AMI_ID" >&2
    echo "Actual:   $created_ami" >&2
    exit 1
}

# --------------------------------------------------
# 7. SET NEW VERSION AS DEFAULT
# --------------------------------------------------

echo
echo "Setting Launch Template default version to $new_version..."

"${AWS[@]}" ec2 modify-launch-template \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --default-version "$new_version" \
    --output json

actual_default="$(
    "${AWS[@]}" ec2 describe-launch-templates \
        --launch-template-ids "$LAUNCH_TEMPLATE_ID" \
        --query 'LaunchTemplates[0].DefaultVersionNumber' \
        --output text
)"

[[ "$actual_default" == "$new_version" ]] || {
    echo "ERROR: Default Launch Template version verification failed." >&2
    echo "Expected: $new_version" >&2
    echo "Actual:   $actual_default" >&2
    exit 1
}

# --------------------------------------------------
# 8. SAVE ARTIFACTS FOR NEXT STAGE
# --------------------------------------------------

printf '%s\n' "$latest_version" \
    > "${ARTIFACT_DIR}/previous-lt-version.txt"

printf '%s\n' "$new_version" \
    > "${ARTIFACT_DIR}/latest-lt-version.txt"

printf '%s\n' "$AMI_ID" \
    > "${ARTIFACT_DIR}/latest-ami-id.txt"

printf '%s\n' "$ami_name" \
    > "${ARTIFACT_DIR}/latest-ami-name.txt"

cat > "${ARTIFACT_DIR}/lt-rollout-metadata.txt" <<EOF
APP_NAME=${APP_NAME}
APP_BUILD_NUMBER=${APP_BUILD_NUMBER}
APP_GIT_COMMIT=${APP_GIT_COMMIT}
AMI_ID=${AMI_ID}
AMI_NAME=${ami_name}
LAUNCH_TEMPLATE_ID=${LAUNCH_TEMPLATE_ID}
PREVIOUS_LT_VERSION=${latest_version}
NEW_LT_VERSION=${new_version}
DEFAULT_LT_VERSION=${actual_default}
EOF

# --------------------------------------------------
# 9. FINAL RESULT
# --------------------------------------------------

echo
echo "========================================"
echo "LAUNCH TEMPLATE VERSION CREATED"
echo "========================================"
echo "AMI ID               : $AMI_ID"
echo "AMI name             : $ami_name"
echo "Previous LT version  : $latest_version"
echo "New LT version       : $new_version"
echo "Default LT version   : $actual_default"
echo
echo "Next step: execute scripts/04-update-asg.sh"
