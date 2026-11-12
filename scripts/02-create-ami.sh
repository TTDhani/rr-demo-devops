#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
for v in SOURCE_INSTANCE_ID TARGET_GROUP_ARN ASG_NAME; do require_value "$v"; done
: "${AMI_NAME_PREFIX:=rr-demo-autoscale}" "${NO_REBOOT:=true}" "${AMI_WAIT_TIMEOUT_SECONDS:=3600}"
[[ "$NO_REBOOT" == true ]] || { echo "NO_REBOOT must be true for live source" >&2; exit 1; }
asg="$(get_asg_json "$ASG_NAME")"
member="$(jq --arg id "$SOURCE_INSTANCE_ID" '[.AutoScalingGroups[0].Instances[]? | select(.InstanceId==$id)]|length' <<<"$asg")"
[[ "$member" == 0 ]] || { echo "Source is an ASG member" >&2; exit 1; }
assert_source_healthy_target "$SOURCE_INSTANCE_ID" "$TARGET_GROUP_ARN"
name="${AMI_NAME_PREFIX}-${APP_NAME}-$(timestamp)"
args=(ec2 create-image --instance-id "$SOURCE_INSTANCE_ID" --name "$name" --description "Automated ${APP_NAME} image from ${SOURCE_INSTANCE_ID}" --no-reboot)
printf 'Planned: aws'; printf ' %q' "${args[@]}"; echo
confirm_apply || exit 0
ami="$("${AWS[@]}" "${args[@]}" --query ImageId --output text)"
[[ -n "$ami" && "$ami" != None ]] || { echo "No AMI ID returned" >&2; exit 1; }
a="$(artifact_dir)"; printf '%s\n' "$ami" > "$a/latest-ami-id.txt"
deadline=$((SECONDS+AMI_WAIT_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  state="$("${AWS[@]}" ec2 describe-images --image-ids "$ami" --query 'Images[0].State' --output text 2>/dev/null || true)"
  echo "AMI $ami: ${state:-pending}"
  [[ "$state" == available ]] && exit 0
  [[ "$state" == failed ]] && { echo "AMI creation failed" >&2; exit 1; }
  sleep 20
done
echo "Timed out waiting for AMI $ami" >&2; exit 1
