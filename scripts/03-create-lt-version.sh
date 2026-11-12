
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID

AMI_ID="${AMI_ID:-}"

if [[ -z "$AMI_ID" && -f "${ROOT_DIR}/artifacts/latest-ami-id.txt" ]]; then
    AMI_ID="$(cat "${ROOT_DIR}/artifacts/latest-ami-id.txt")"
fi

[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || {
    echo "ERROR: AMI_ID is missing. Create an AMI first." >&2
    exit 1
}

# Validate the AMI.
ami_state="$("${AWS[@]}" ec2 describe-images \
    --image-ids "$AMI_ID" \
    --query 'Images[0].State' \
    --output text)"

[[ "$ami_state" == "available" ]] || {
    echo "ERROR: AMI $AMI_ID is not available. State: $ami_state" >&2
    exit 1
}

# Read the ASG's currently configured Launch Template.
asg_json="$("${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --output json)"

asg_count="$(jq '.AutoScalingGroups | length' <<< "$asg_json")"

[[ "$asg_count" == "1" ]] || {
    echo "ERROR: Expected exactly one ASG named $ASG_NAME; found $asg_count." >&2
    exit 1
}

asg_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
source_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"

[[ "$asg_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template mismatch."
    echo "Expected: $LAUNCH_TEMPLATE_ID"
    echo "Actual:   $asg_lt_id"
    exit 1
}

# Require a concrete numeric version to avoid inheriting a moving alias.
[[ "$source_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: ASG Launch Template version is not numeric: $source_version" >&2
    echo "Resolve the ASG version to a numeric version before continuing." >&2
    exit 1
}

# Retrieve the exact version currently used by the ASG.
mkdir -p "${ROOT_DIR}/artifacts"

data="${ROOT_DIR}/artifacts/lt-data.json"

"${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$source_version" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
    --output json > "$data"

[[ -s "$data" ]] || {
    echo "ERROR: Could not retrieve Launch Template data." >&2
    exit 1
}

# Change only ImageId.
jq --arg image "$AMI_ID" '.ImageId = $image' "$data" > "${data}.tmp"
mv "${data}.tmp" "$data"

echo "========================================"
echo "LAUNCH TEMPLATE VERSION PLAN"
echo "========================================"
echo "ASG:                 $ASG_NAME"
echo "Launch Template:     $LAUNCH_TEMPLATE_ID"
echo "Source LT version:   $source_version"
echo "New AMI:             $AMI_ID"
echo
echo "Inherited Launch Template settings:"
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

new_version="$("${AWS[@]}" ec2 create-launch-template-version \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --source-version "$source_version" \
    --version-description "${APP_NAME} AMI ${AMI_ID}" \
    --launch-template-data "file://${data}" \
    --query 'LaunchTemplateVersion.VersionNumber' \
    --output text)"

[[ "$new_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: AWS did not return a valid new LT version." >&2
    exit 1
}

# Save artifacts for subsequent pipeline stages.
printf '%s\n' "$source_version" > "${ROOT_DIR}/artifacts/previous-lt-version.txt"
printf '%s\n' "$new_version" > "${ROOT_DIR}/artifacts/latest-lt-version.txt"
printf '%s\n' "$AMI_ID" > "${ROOT_DIR}/artifacts/latest-ami-id.txt"

echo "========================================"
echo "LAUNCH TEMPLATE VERSION CREATED"
echo "========================================"
echo "Previous/source version: $source_version"
echo "New version:             $new_version"
echo "AMI:                     $AMI_ID"
