
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value TARGET_GROUP_ARN
require_value VPC_ZONE_IDENTIFIER

: "${MIN_SIZE:=1}"
: "${DESIRED_CAPACITY:=1}"
: "${MAX_SIZE:=2}"
: "${HEALTH_CHECK_TYPE:=ELB}"
: "${HEALTH_CHECK_GRACE_PERIOD:=300}"

exists="$("${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'length(AutoScalingGroups)' \
    --output text)"

if [[ "$exists" == "1" ]]; then
    echo "ASG exists; refusing to overwrite it."
    exit 0
fi

echo "Planned create ASG $ASG_NAME with LT $LAUNCH_TEMPLATE_ID:1, subnets $VPC_ZONE_IDENTIFIER and capacity $MIN_SIZE/$DESIRED_CAPACITY/$MAX_SIZE"

confirm_apply || exit 0

"${AWS[@]}" autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=1" \
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
