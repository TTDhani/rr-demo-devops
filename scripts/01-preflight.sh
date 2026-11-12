#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
for v in SOURCE_INSTANCE_ID LAUNCH_TEMPLATE_ID ASG_NAME TARGET_GROUP_ARN; do require_value "$v"; done
echo "=== Source instance ==="
"${AWS[@]}" ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,AMI:ImageId,Subnet:SubnetId,AZ:Placement.AvailabilityZone}' --output table
assert_source_healthy_target "$SOURCE_INSTANCE_ID" "$TARGET_GROUP_ARN"
asg="$(get_asg_json "$ASG_NAME")"
[[ "$(jq '.AutoScalingGroups|length' <<<"$asg")" == 1 ]] || { echo "ASG not found: $ASG_NAME" >&2; exit 1; }
[[ "$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<<"$asg")" == "$LAUNCH_TEMPLATE_ID" ]] || { echo "ASG Launch Template ID mismatch" >&2; exit 1; }
member="$(jq --arg id "$SOURCE_INSTANCE_ID" '[.AutoScalingGroups[0].Instances[]? | select(.InstanceId==$id)]|length' <<<"$asg")"
[[ "$member" == 0 ]] || { echo "AMI source is an ASG member; refusing" >&2; exit 1; }
echo "=== Launch Template latest ==="
"${AWS[@]}" ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions '$Latest' --query 'LaunchTemplateVersions[].{Version:VersionNumber,AMI:LaunchTemplateData.ImageId,Type:LaunchTemplateData.InstanceType}' --output table
echo "=== ASG ==="
jq '.AutoScalingGroups[0] | {Name:AutoScalingGroupName,Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,HealthCheckType:HealthCheckType,LaunchTemplate:LaunchTemplate,Instances:Instances}' <<<"$asg"
echo "=== Target health ==="
"${AWS[@]}" elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' --output table
refreshes="$("${AWS[@]}" autoscaling describe-instance-refreshes --auto-scaling-group-name "$ASG_NAME" --max-records 20 --output json)"
active="$(jq '[.InstanceRefreshes[]? | select(.Status=="Pending" or .Status=="InProgress" or .Status=="Cancelling" or .Status=="RollbackInProgress")]|length' <<<"$refreshes")"
[[ "$active" == 0 ]] || { echo "An Instance Refresh is already active" >&2; exit 1; }
echo "Preflight successful."
