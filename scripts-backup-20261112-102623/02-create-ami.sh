#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
require_value SOURCE_INSTANCE_ID
: "${AMI_NAME_PREFIX:=rr-demo-autoscale}" "${NO_REBOOT:=false}" "${AMI_WAIT_TIMEOUT_SECONDS:=3600}"
if [[ -n "${ASG_NAME:-}" && "$ASG_NAME" != REPLACE_* ]]; then
  member="$("${AWS[@]}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query "AutoScalingGroups[].Instances[?InstanceId=='${SOURCE_INSTANCE_ID}'].InstanceId | [0]" --output text)"
  [[ "$member" == "None" || -z "$member" ]] || { echo "Source is an ASG member; use a dedicated image-builder." >&2; exit 1; }
fi
state="$("${AWS[@]}" ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)"
[[ "$state" == "running" ]] || { echo "Source must be running (state=$state)" >&2; exit 1; }
name="${AMI_NAME_PREFIX}-${APP_NAME}-$(timestamp)"
args=(ec2 create-image --instance-id "$SOURCE_INSTANCE_ID" --name "$name" --description "Jenkins POC image for ${APP_NAME}")
[[ "$NO_REBOOT" == "true" ]] && args+=(--no-reboot)
printf 'Planned: aws'; printf ' %q' "${args[@]}"; echo
confirm_apply || exit 0
ami_id="$("${AWS[@]}" "${args[@]}" --query ImageId --output text)"
[[ -n "$ami_id" && "$ami_id" != "None" ]] || { echo "No AMI ID returned" >&2; exit 1; }
mkdir -p "${ROOT_DIR}/artifacts"
printf '%s\n' "$ami_id" > "${ROOT_DIR}/artifacts/latest-ami-id.txt"
deadline=$((SECONDS + AMI_WAIT_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  image_state="$("${AWS[@]}" ec2 describe-images --image-ids "$ami_id" --query 'Images[0].State' --output text 2>/dev/null || true)"
  echo "AMI ${ami_id}: ${image_state:-pending}"
  [[ "$image_state" == "available" ]] && exit 0
  [[ "$image_state" == "failed" ]] && exit 1
  sleep 20
done
echo "Timed out waiting for AMI" >&2
exit 1
