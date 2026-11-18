#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value TARGET_GROUP_ARN

: "${ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS:=600}"

[[ "$ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS" =~ ^[0-9]+$ ]] || {
    echo "ERROR: ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS must be numeric." >&2
    exit 1
}

ARTIFACT_DIR="$(artifact_dir)"

version="${NEW_LT_VERSION:-}"
if [[ -z "$version" && -f "$ARTIFACT_DIR/latest-lt-version.txt" ]]; then
    version="$(tr -d '[:space:]' < "$ARTIFACT_DIR/latest-lt-version.txt")"
fi

AMI_ID="${AMI_ID:-}"
if [[ -z "$AMI_ID" && -f "$ARTIFACT_DIR/latest-ami-id.txt" ]]; then
    AMI_ID="$(tr -d '[:space:]' < "$ARTIFACT_DIR/latest-ami-id.txt")"
fi

[[ "$version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: A numeric NEW_LT_VERSION is required." >&2
    exit 1
}
[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || {
    echo "ERROR: AMI_ID is missing." >&2
    exit 1
}

echo "=== Validating Launch Template version ==="

lt_json="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$version" \
    --output json)"

lt_id="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateId // empty' <<< "$lt_json")"
lt_ami="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' <<< "$lt_json")"

[[ "$lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: Launch Template ID mismatch." >&2
    exit 1
}
[[ "$lt_ami" == "$AMI_ID" ]] || {
    echo "ERROR: LT version AMI mismatch. Expected $AMI_ID, got $lt_ami." >&2
    exit 1
}

ami_state="$("${AWS[@]}" ec2 describe-images \
    --image-ids "$AMI_ID" \
    --query 'Images[0].State' \
    --output text)"

[[ "$ami_state" == "available" ]] || {
    echo "ERROR: AMI $AMI_ID is not available: $ami_state" >&2
    exit 1
}

default_version="$("${AWS[@]}" ec2 describe-launch-templates \
    --launch-template-ids "$LAUNCH_TEMPLATE_ID" \
    --query 'LaunchTemplates[0].DefaultVersionNumber' \
    --output text)"

[[ "$default_version" == "$version" ]] || {
    echo "ERROR: LT default version is $default_version, expected $version." >&2
    exit 1
}

echo "=== Validating Auto Scaling Group ==="

asg_json="$(get_asg_json "$ASG_NAME")"

[[ "$(jq '.AutoScalingGroups | length' <<< "$asg_json")" == "1" ]] || {
    echo "ERROR: ASG not found or ambiguous." >&2
    exit 1
}

current_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
configured_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"

[[ "$current_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG is using a different Launch Template." >&2
    exit 1
}

if [[ "$configured_version" == '$Default' || "$configured_version" == '$Latest' ]]; then
    current_version="$("${AWS[@]}" ec2 describe-launch-template-versions \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --versions "$configured_version" \
        --query 'LaunchTemplateVersions[0].VersionNumber' \
        --output text)"
else
    current_version="$configured_version"
fi

[[ "$current_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Could not resolve the current ASG LT version." >&2
    exit 1
}

attached="$(jq --arg tg "$TARGET_GROUP_ARN" \
    '[.AutoScalingGroups[0].TargetGroupARNs[]? | select(. == $tg)] | length' \
    <<< "$asg_json")"

[[ "$attached" == "1" ]] || {
    echo "ERROR: Target Group is not attached to this ASG." >&2
    exit 1
}

active_count="$("${AWS[@]}" autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --query "length(InstanceRefreshes[?Status=='Pending' || Status=='InProgress' || Status=='Cancelling' || Status=='RollbackInProgress'])" \
    --output text)"

[[ "$active_count" == "0" ]] || {
    echo "ERROR: An Instance Refresh is already active. Refusing ASG update." >&2
    exit 1
}

echo
echo "=============== ASG UPDATE PLAN ==============="
echo "ASG                         : $ASG_NAME"
echo "Launch Template             : $LAUNCH_TEMPLATE_ID"
echo "Previous LT version         : $current_version"
echo "New LT version              : $version"
echo "AMI                         : $AMI_ID"
echo "Health check type           : ELB"
echo "Health check grace period   : ${ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS}s"
echo "Target Group                : $TARGET_GROUP_ARN"
echo "================================================"

echo "This changes future launches. Existing instances are not replaced by this command."

confirm_apply || exit 0

printf '%s\n' "$current_version" > "$ARTIFACT_DIR/previous-asg-lt-version.txt"

"${AWS[@]}" autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${version}" \
    --health-check-type ELB \
    --health-check-grace-period "$ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS"

updated="$(get_asg_json "$ASG_NAME")"

actual_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$updated")"
actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$updated")"
actual_health_type="$(jq -r '.AutoScalingGroups[0].HealthCheckType // empty' <<< "$updated")"
actual_grace="$(jq -r '.AutoScalingGroups[0].HealthCheckGracePeriod // empty' <<< "$updated")"

[[ "$actual_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG LT ID verification failed." >&2
    exit 1
}
[[ "$actual_version" == "$version" ]] || {
    echo "ERROR: ASG LT version verification failed." >&2
    exit 1
}
[[ "$actual_health_type" == "ELB" ]] || {
    echo "ERROR: ASG health-check type is not ELB." >&2
    exit 1
}
[[ "$actual_grace" == "$ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS" ]] || {
    echo "ERROR: ASG health-check grace period verification failed." >&2
    exit 1
}

actual_ami="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$actual_lt_id" \
    --versions "$actual_version" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' \
    --output text)"

[[ "$actual_ami" == "$AMI_ID" ]] || {
    echo "ERROR: ASG LT version does not resolve to the expected AMI." >&2
    exit 1
}

cat > "$ARTIFACT_DIR/asg-rollout-metadata.txt" <<EOF
ASG_NAME=${ASG_NAME}
LAUNCH_TEMPLATE_ID=${LAUNCH_TEMPLATE_ID}
PREVIOUS_ASG_LT_VERSION=${current_version}
NEW_ASG_LT_VERSION=${actual_version}
AMI_ID=${AMI_ID}
TARGET_GROUP_ARN=${TARGET_GROUP_ARN}
HEALTH_CHECK_TYPE=${actual_health_type}
HEALTH_CHECK_GRACE_PERIOD=${actual_grace}
EOF

echo
echo "SUCCESS: ASG configuration updated and verified."
echo "Previous LT version : $current_version"
echo "Current LT version  : $actual_version"
echo "AMI                 : $actual_ami"
echo "Health grace period : $actual_grace seconds"
echo "Next: scripts/05-start-instance-refresh.sh"
