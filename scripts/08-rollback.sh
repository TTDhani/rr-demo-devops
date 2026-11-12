
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID

# Previous version can be supplied explicitly or restored from artifacts.
version="${PREVIOUS_ASG_LT_VERSION:-}"

if [[ -z "$version" && -f "${ROOT_DIR}/artifacts/previous-asg-lt-version.txt" ]]; then
    version="$(cat "${ROOT_DIR}/artifacts/previous-asg-lt-version.txt")"
fi

[[ "$version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: A valid previous numeric LT version is required." >&2
    exit 1
}

# Verify the previous LT version exists.
"${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$version" \
    --query 'LaunchTemplateVersions[0].VersionNumber' \
    --output text >/dev/null

asg_json="$(get_asg_json "$ASG_NAME")"

current_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"

[[ "$current_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template ID mismatch." >&2
    exit 1
}

echo "========================================"
echo "ROLLBACK PLAN"
echo "========================================"
echo "ASG:                 $ASG_NAME"
echo "Launch Template:     $LAUNCH_TEMPLATE_ID"
echo "Rollback version:    $version"
echo "Auto rollback:       false"
echo
echo "This changes the ASG configuration and starts a recovery refresh."
echo "Existing instances may be replaced."

confirm_apply || exit 0

# Point the ASG to the previous version.
"${AWS[@]}" autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${version}"

# Verify the ASG configuration before recovery refresh.
updated="$(get_asg_json "$ASG_NAME")"

actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version' <<< "$updated")"

[[ "$actual_version" == "$version" ]] || {
    echo "ERROR: ASG rollback version verification failed." >&2
    exit 1
}

# Do not start a second refresh if one is already active.
active_refreshes="$("${AWS[@]}" autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --query "length(InstanceRefreshes[?Status=='Pending' || Status=='InProgress' || Status=='Cancelling' || Status=='RollbackInProgress'])" \
    --output text)"

[[ "$active_refreshes" == "0" ]] || {
    echo "ERROR: An Instance Refresh is already active. Resolve it before rollback." >&2
    exit 1
}

prefs="$(jq -n \
    --argjson min "${MIN_HEALTHY_PERCENTAGE:-90}" \
    --argjson max "${MAX_HEALTHY_PERCENTAGE:-200}" \
    --argjson warm "${INSTANCE_WARMUP_SECONDS:-300}" \
    '{
        MinHealthyPercentage: $min,
        MaxHealthyPercentage: $max,
        InstanceWarmup: $warm,
        SkipMatching: false,
        AutoRollback: false
    }')"

refresh_id="$("${AWS[@]}" autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" \
    --preferences "$prefs" \
    --query InstanceRefreshId \
    --output text)"

[[ -n "$refresh_id" && "$refresh_id" != "None" ]] || {
    echo "ERROR: AWS did not return a rollback refresh ID." >&2
    exit 1
}

artifact_dir >/dev/null
printf '%s\n' "$refresh_id" > "${ROOT_DIR}/artifacts/rollback-refresh-id.txt"

echo "========================================"
echo "ROLLBACK REFRESH STARTED"
echo "========================================"
echo "ASG:          $ASG_NAME"
echo "LT version:   $version"
echo "Refresh ID:   $refresh_id"
echo
echo "Monitor and verify the recovery refresh before declaring success."
