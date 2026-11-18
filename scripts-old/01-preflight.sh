#!/usr/bin/env bash

set -Eeuo pipefail

# Load common AWS and validation functions.
source "$(dirname "$0")/common.sh"

echo "========================================"
echo "RR-DEMO INFRASTRUCTURE PREFLIGHT"
echo "========================================"

# Validate required configuration.
for v in SOURCE_INSTANCE_ID LAUNCH_TEMPLATE_ID ASG_NAME TARGET_GROUP_ARN; do
    require_value "$v"
done

# --------------------------------------------------
# 1. Validate source instance
# --------------------------------------------------

echo
echo "=== Source Instance ==="

"${AWS[@]}" ec2 describe-instances \
    --instance-ids "$SOURCE_INSTANCE_ID" \
    --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,AMI:ImageId,AZ:Placement.AvailabilityZone,Subnet:SubnetId}' \
    --output table

# Confirm source instance is healthy in the target group.
assert_source_healthy_target "$SOURCE_INSTANCE_ID" "$TARGET_GROUP_ARN"

# --------------------------------------------------
# 2. Validate Auto Scaling Group
# --------------------------------------------------

echo
echo "=== Auto Scaling Group ==="

asg="$(get_asg_json "$ASG_NAME")"

asg_count="$(jq '.AutoScalingGroups | length' <<< "$asg")"

if [[ "$asg_count" != "1" ]]; then
    echo "ERROR: ASG not found or multiple results returned: $ASG_NAME" >&2
    exit 1
fi

# Verify ASG uses the expected Launch Template.
asg_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg")"

if [[ "$asg_lt_id" != "$LAUNCH_TEMPLATE_ID" ]]; then
    echo "ERROR: ASG Launch Template mismatch." >&2
    echo "Expected: $LAUNCH_TEMPLATE_ID" >&2
    echo "Actual:   $asg_lt_id" >&2
    exit 1
fi

# Ensure source instance is not already an ASG member.
member_count="$(
    jq --arg id "$SOURCE_INSTANCE_ID" \
       '[.AutoScalingGroups[0].Instances[]? | select(.InstanceId == $id)] | length' \
       <<< "$asg"
)"

if [[ "$member_count" != "0" ]]; then
    echo "ERROR: AMI source instance is already an ASG member. Refusing to continue." >&2
    exit 1
fi

# Display ASG configuration.
jq '
    .AutoScalingGroups[0] |
    {
        Name: .AutoScalingGroupName,
        Min: .MinSize,
        Desired: .DesiredCapacity,
        Max: .MaxSize,
        HealthCheckType: .HealthCheckType,
        HealthCheckGracePeriod: .HealthCheckGracePeriod,
        LaunchTemplate: .LaunchTemplate,
        Instances: .Instances
    }
' <<< "$asg"

# --------------------------------------------------
# 3. Validate Launch Template
# --------------------------------------------------

echo
echo "=== Launch Template Latest Version ==="

"${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions '$Latest' \
    --query 'LaunchTemplateVersions[].{Version:VersionNumber,AMI:LaunchTemplateData.ImageId,Type:LaunchTemplateData.InstanceType}' \
    --output table

# --------------------------------------------------
# 4. Validate target group
# --------------------------------------------------

echo
echo "=== Target Group Health ==="

"${AWS[@]}" elbv2 describe-target-health \
    --target-group-arn "$TARGET_GROUP_ARN" \
    --query 'TargetHealthDescriptions[].{InstanceId:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
    --output table

# --------------------------------------------------
# 5. Check active Instance Refresh
# --------------------------------------------------

echo
echo "=== Instance Refresh Status ==="

refreshes="$(
    "${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" \
        --max-records 20 \
        --output json
)"

active_count="$(
    jq '
        [
            .InstanceRefreshes[]? |
            select(
                .Status == "Pending" or
                .Status == "InProgress" or
                .Status == "Cancelling" or
                .Status == "RollbackInProgress"
            )
        ] | length
    ' <<< "$refreshes"
)"

if [[ "$active_count" != "0" ]]; then
    echo "ERROR: An Instance Refresh is already active for $ASG_NAME." >&2

    jq '
        .InstanceRefreshes[]? |
        select(
            .Status == "Pending" or
            .Status == "InProgress" or
            .Status == "Cancelling" or
            .Status == "RollbackInProgress"
        ) |
        {
            InstanceRefreshId: .InstanceRefreshId,
            Status: .Status,
            PercentageComplete: .PercentageComplete
        }
    ' <<< "$refreshes"

    exit 1
fi

echo "No active Instance Refresh found."

# --------------------------------------------------
# 6. Final result
# --------------------------------------------------

echo
echo "========================================"
echo "PREFLIGHT SUCCESSFUL"
echo "========================================"

echo "AWS account and region validated."
echo "Source instance validation passed."
echo "ASG validation passed."
echo "Launch Template validation passed."
echo "Target group health check completed."
echo "No active Instance Refresh detected."

echo
echo "Ready for the next infrastructure stage."
