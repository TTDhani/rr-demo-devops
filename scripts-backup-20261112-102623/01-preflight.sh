#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
require_value SOURCE_INSTANCE_ID
require_value LAUNCH_TEMPLATE_ID
require_value ASG_NAME
require_value TARGET_GROUP_ARN
echo "=== Source instance ==="
"${AWS[@]}" ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,AMI:ImageId,Subnet:SubnetId,AZ:Placement.AvailabilityZone}' --output table
echo "=== Launch Template ==="
"${AWS[@]}" ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions '$Latest' --query 'LaunchTemplateVersions[].{Version:VersionNumber,AMI:LaunchTemplateData.ImageId,Type:LaunchTemplateData.InstanceType}' --output table
echo "=== ASG ==="
"${AWS[@]}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,LT:LaunchTemplate,Instances:Instances[].{Id:InstanceId,Health:HealthStatus,State:LifecycleState}}' --output json
echo "=== Target health ==="
"${AWS[@]}" elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' --output table
