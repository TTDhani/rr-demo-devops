#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
version="${PREVIOUS_ASG_LT_VERSION:-}"
[[ -n "$version" ]] || [[ ! -f "${ROOT_DIR}/artifacts/previous-asg-lt-version.txt" ]] || version="$(cat "${ROOT_DIR}/artifacts/previous-asg-lt-version.txt")"
[[ -n "$version" ]] || { echo "No previous ASG LT version recorded" >&2; exit 1; }
echo "Planned rollback: $ASG_NAME -> LT $LAUNCH_TEMPLATE_ID version $version"
echo "This updates future launches only. Review before running a separate recovery refresh."
confirm_apply || exit 0
"${AWS[@]}" autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${version}"
