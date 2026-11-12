
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value TARGET_GROUP_ARN

version="${NEW_LT_VERSION:-}"

if [[ -z "$version" && -f "${ROOT_DIR}/artifacts/latest-lt-version.txt" ]]; then
    version="$(cat "${ROOT_DIR}/artifacts/latest-lt-version.txt")"
fi

[[ "$version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: A valid numeric new LT version is required." >&2
    exit 1
}

# Verify the requested new Launch Template version exists.
new_lt_json="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$version" \
    --output json)"

new_lt_id="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateId // empty' <<< "$new_lt_json")"
new_ami="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' <<< "$new_lt_json")"

[[ "$new_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: Requested Launch Template version does not exist." >&2
    exit 1
}

[[ -n "$new_ami" && "$new_ami" != "None" ]] || {
    echo "ERROR: New Launch Template version has no AMI configured." >&2
    exit 1
}

# Read current ASG configuration.
asg_json="$("${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --output json)"

asg_count="$(jq '.AutoScalingGroups | length' <<< "$asg_json")"

[[ "$asg_count" == "1" ]] || {
    echo "ERROR: Expected exactly one ASG named $ASG_NAME." >&2
    exit 1
}

current_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
configured_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"

[[ "$current_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG is using a different Launch Template." >&2
    exit 1
}

# Resolve symbolic ASG versions to numeric versions.
if [[ "$configured_version" == '$Default' || "$configured_version" == '$Latest' ]]; then
    echo "ASG uses symbolic Launch Template version: $configured_version"

    current_version="$("${AWS[@]}" ec2 describe-launch-template-versions \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --versions "$configured_version" \
        --query 'LaunchTemplateVersions[0].VersionNumber' \
        --output text)"
else
    current_version="$configured_version"
fi

[[ "$current_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Could not resolve current ASG LT version: $configured_version" >&2
    exit 1
}

# Confirm the target group is attached to this ASG.
attached="$(
    jq --arg tg "$TARGET_GROUP_ARN" \
       '[.AutoScalingGroups[0].TargetGroupARNs[]? | select(. == $tg)] | length' \
       <<< "$asg_json"
)"

[[ "$attached" == "1" ]] || {
    echo "ERROR: Target group is not attached to ASG $ASG_NAME." >&2
    exit 1
}

# Confirm the new AMI is available.
ami_state="$("${AWS[@]}" ec2 describe-images \
    --image-ids "$new_ami" \
    --query 'Images[0].State' \
    --output text)"

[[ "$ami_state" == "available" ]] || {
    echo "ERROR: New AMI $new_ami is not available: $ami_state" >&2
    exit 1
}

mkdir -p "${ROOT_DIR}/artifacts"

echo "========================================"
echo "ASG UPDATE PLAN"
echo "========================================"
echo "ASG:                      $ASG_NAME"
echo "Launch Template:          $LAUNCH_TEMPLATE_ID"
echo "Configured ASG version:   $configured_version"
echo "Resolved previous version: $current_version"
echo "New LT version:           $version"
echo "New AMI:                  $new_ami"
echo "Health check type:        ELB"
echo "Health check grace:       300 seconds"
echo "Target group:             $TARGET_GROUP_ARN"
echo
echo "This changes future launches. Existing instances are not replaced here."

confirm_apply || exit 0

# Preserve the previous numeric version for rollback.
printf '%s\n' "$current_version" \
    > "${ROOT_DIR}/artifacts/previous-asg-lt-version.txt"

# Update ASG to the new numeric Launch Template version.
"${AWS[@]}" autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${version}" \
    --health-check-type ELB \
    --health-check-grace-period 300

# Verify ASG configuration.
updated="$("${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --output json)"

actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version' <<< "$updated")"
actual_health_type="$(jq -r '.AutoScalingGroups[0].HealthCheckType' <<< "$updated")"
actual_grace="$(jq -r '.AutoScalingGroups[0].HealthCheckGracePeriod' <<< "$updated")"

[[ "$actual_version" == "$version" ]] || {
    echo "ERROR: ASG Launch Template version verification failed." >&2
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

echo "========================================"
echo "ASG UPDATE VERIFIED"
echo "========================================"
echo "ASG:               $ASG_NAME"
echo "Launch Template:   $LAUNCH_TEMPLATE_ID"
echo "Previous version:  $current_version"
echo "New version:       $actual_version"
echo "AMI:               $new_ami"
echo "Health check:      $actual_health_type"
echo "Grace period:      $actual_grace seconds"
