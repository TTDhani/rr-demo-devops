
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

for v in ASG_NAME LAUNCH_TEMPLATE_ID TARGET_GROUP_ARN VPC_ZONE_IDENTIFIER; do
    require_value "$v"
done

: "${MIN_SIZE:=1}"
: "${DESIRED_CAPACITY:=1}"
: "${MAX_SIZE:=2}"
: "${HEALTH_CHECK_TYPE:=ELB}"
: "${HEALTH_CHECK_GRACE_PERIOD:=600}"

asg_json="$(get_asg_json "$ASG_NAME")"
exists="$(jq '.AutoScalingGroups | length' <<< "$asg_json")"

if [[ "$exists" == 1 ]]; then
    existing_lt="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"

    [[ "$existing_lt" == "$LAUNCH_TEMPLATE_ID" ]] || {
        echo "ERROR: Existing ASG uses a different Launch Template." >&2
        exit 1
    }

    echo "ASG already exists and uses the expected Launch Template. Reusing it."
    exit 0
fi

LT_VERSION="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions '$Latest' \
    --query 'LaunchTemplateVersions[0].VersionNumber' \
    --output text)"

[[ "$LT_VERSION" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Could not determine Launch Template version." >&2
    exit 1
}

echo "Create ASG: ${ASG_NAME}, LT version ${LT_VERSION}."

if [[ "$APPLY" != true ]]; then
    echo "DRY RUN: no AWS changes made."
    exit 0
fi

"${AWS[@]}" autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${LT_VERSION}" \
    --min-size "$MIN_SIZE" \
    --desired-capacity "$DESIRED_CAPACITY" \
    --max-size "$MAX_SIZE" \
    --vpc-zone-identifier "$VPC_ZONE_IDENTIFIER" \
    --target-group-arns "$TARGET_GROUP_ARN" \
    --health-check-type "$HEALTH_CHECK_TYPE" \
    --health-check-grace-period "$HEALTH_CHECK_GRACE_PERIOD" \
    --tags \
        "Key=Name,Value=${APP_NAME}-asg,PropagateAtLaunch=true" \
        "Key=ManagedBy,Value=rr-demo-infra,PropagateAtLaunch=true"

echo "ASG created successfully: ${ASG_NAME}"
