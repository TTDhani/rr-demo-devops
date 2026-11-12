#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
version="${NEW_LT_VERSION:-}"
[[ -n "$version" ]] || [[ ! -f "${ROOT_DIR}/artifacts/latest-lt-version.txt" ]] || version="$(cat "${ROOT_DIR}/artifacts/latest-lt-version.txt")"
[[ -n "$version" ]] || { echo "No new LT version available" >&2; exit 1; }
current="$("${AWS[@]}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].LaunchTemplate.Version' --output text)"
[[ -n "$current" && "$current" != "None" ]] || { echo "ASG not found or not using an LT; inspect before proceeding" >&2; exit 1; }
mkdir -p "${ROOT_DIR}/artifacts"
printf '%s\n' "$current" > "${ROOT_DIR}/artifacts/previous-asg-lt-version.txt"
echo "Planned: update $ASG_NAME to LT $LAUNCH_TEMPLATE_ID version $version (previous ASG version $current)"
echo "This changes future launches only; it does not replace running instances."
confirm_apply || exit 0
"${AWS[@]}" autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${version}"
