#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
require_value LAUNCH_TEMPLATE_ID
AMI_ID="${AMI_ID:-}"
[[ -n "$AMI_ID" ]] || [[ ! -f "${ROOT_DIR}/artifacts/latest-ami-id.txt" ]] || AMI_ID="$(cat "${ROOT_DIR}/artifacts/latest-ami-id.txt")"
[[ -n "$AMI_ID" ]] || { echo "Set AMI_ID or create an AMI first" >&2; exit 1; }
state="$("${AWS[@]}" ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].State' --output text)"
[[ "$state" == "available" ]] || { echo "AMI state is $state, expected available" >&2; exit 1; }
src="$("${AWS[@]}" ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions '$Latest' --query 'LaunchTemplateVersions[0].VersionNumber' --output text)"
mkdir -p "${ROOT_DIR}/artifacts"
data="${ROOT_DIR}/artifacts/lt-data.json"
"${AWS[@]}" ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions "$src" --query 'LaunchTemplateVersions[0].LaunchTemplateData' --output json > "$data"
jq --arg image "$AMI_ID" '.ImageId=$image' "$data" > "${data}.tmp"
mv "${data}.tmp" "$data"
echo "New LT version will inherit source version $src and change only ImageId to $AMI_ID"
jq '{ImageId,InstanceType,KeyName,SecurityGroupIds,IamInstanceProfile,BlockDeviceMappings,UserData}' "$data"
confirm_apply || exit 0
new="$("${AWS[@]}" ec2 create-launch-template-version --launch-template-id "$LAUNCH_TEMPLATE_ID" --source-version "$src" --version-description "${APP_NAME} AMI ${AMI_ID}" --launch-template-data "file://${data}" --query 'LaunchTemplateVersion.VersionNumber' --output text)"
printf '%s\n' "$src" > "${ROOT_DIR}/artifacts/previous-lt-version.txt"
printf '%s\n' "$new" > "${ROOT_DIR}/artifacts/latest-lt-version.txt"
printf '%s\n' "$AMI_ID" > "${ROOT_DIR}/artifacts/latest-ami-id.txt"
echo "Created LT version $new (source $src)"
