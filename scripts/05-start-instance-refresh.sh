
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID

: "${MIN_HEALTHY_PERCENTAGE:=90}"
: "${MAX_HEALTHY_PERCENTAGE:=200}"
: "${INSTANCE_WARMUP_SECONDS:=300}"
: "${SKIP_MATCHING:=true}"
: "${AUTO_ROLLBACK:=true}"

# Validate numeric settings.
for value in "$MIN_HEALTHY_PERCENTAGE" "$MAX_HEALTHY_PERCENTAGE" "$INSTANCE_WARMUP_SECONDS"; do
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "ERROR: Invalid numeric refresh preference: $value" >&2
        exit 1
    }
done

(( MIN_HEALTHY_PERCENTAGE >= 0 && MIN_HEALTHY_PERCENTAGE <= 100 )) || {
    echo "ERROR: MIN_HEALTHY_PERCENTAGE must be between 0 and 100." >&2
    exit 1
}

(( MAX_HEALTHY_PERCENTAGE >= 100 && MAX_HEALTHY_PERCENTAGE <= 200 )) || {
    echo "ERROR: MAX_HEALTHY_PERCENTAGE must be between 100 and 200." >&2
    exit 1
}

(( MAX_HEALTHY_PERCENTAGE >= MIN_HEALTHY_PERCENTAGE )) || {
    echo "ERROR: MAX_HEALTHY_PERCENTAGE must be >= MIN_HEALTHY_PERCENTAGE." >&2
    exit 1
}

[[ "$SKIP_MATCHING" == "true" || "$SKIP_MATCHING" == "false" ]] || {
    echo "ERROR: SKIP_MATCHING must be true or false." >&2
    exit 1
}

[[ "$AUTO_ROLLBACK" == "true" || "$AUTO_ROLLBACK" == "false" ]] || {
    echo "ERROR: AUTO_ROLLBACK must be true or false." >&2
    exit 1
}

# Confirm the ASG is using the intended LT version.
expected_version="${NEW_LT_VERSION:-}"

if [[ -z "$expected_version" && -f "${ROOT_DIR}/artifacts/latest-lt-version.txt" ]]; then
    expected_version="$(cat "${ROOT_DIR}/artifacts/latest-lt-version.txt")"
fi

[[ "$expected_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: New numeric LT version not found." >&2
    exit 1
}

asg_json="$("${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --output json)"

asg_count="$(jq '.AutoScalingGroups | length' <<< "$asg_json")"

[[ "$asg_count" == "1" ]] || {
    echo "ERROR: ASG not found or result is ambiguous." >&2
    exit 1
}

actual_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId' <<< "$asg_json")"
actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version' <<< "$asg_json")"
health_type="$(jq -r '.AutoScalingGroups[0].HealthCheckType' <<< "$asg_json")"

[[ "$actual_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template ID mismatch." >&2
    exit 1
}

[[ "$actual_version" == "$expected_version" ]] || {
    echo "ERROR: ASG version $actual_version does not match expected version $expected_version." >&2
    exit 1
}

[[ "$health_type" == "ELB" ]] || {
    echo "ERROR: ASG health check type is $health_type; expected ELB." >&2
    exit 1
}

# Refuse to start a second active refresh.
active_refreshes="$("${AWS[@]}" autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --query "length(InstanceRefreshes[?Status=='Pending' || Status=='InProgress' || Status=='Cancelling' || Status=='RollbackInProgress'])" \
    --output text)"

[[ "$active_refreshes" == "0" ]] || {
    echo "ERROR: An Instance Refresh is already active for $ASG_NAME." >&2
    exit 1
}

prefs="$(jq -n \
    --argjson min "$MIN_HEALTHY_PERCENTAGE" \
    --argjson max "$MAX_HEALTHY_PERCENTAGE" \
    --argjson warm "$INSTANCE_WARMUP_SECONDS" \
    --argjson skip "$SKIP_MATCHING" \
    --argjson rollback "$AUTO_ROLLBACK" \
    '{
        MinHealthyPercentage: $min,
        MaxHealthyPercentage: $max,
        InstanceWarmup: $warm,
        SkipMatching: $skip,
        AutoRollback: $rollback
    }')"

echo "========================================"
echo "INSTANCE REFRESH PLAN"
echo "========================================"
echo "ASG:                   $ASG_NAME"
echo "Launch Template:       $LAUNCH_TEMPLATE_ID"
echo "LT version:            $expected_version"
echo "Health check:          $health_type"
echo
echo "$prefs" | jq .
echo
echo "WARNING: This operation replaces ASG instances."

confirm_apply || exit 0

refresh_id="$("${AWS[@]}" autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" \
    --preferences "$prefs" \
    --query InstanceRefreshId \
    --output text)"

[[ -n "$refresh_id" && "$refresh_id" != "None" ]] || {
    echo "ERROR: AWS did not return an Instance Refresh ID." >&2
    exit 1
}

mkdir -p "${ROOT_DIR}/artifacts"

printf '%s\n' "$refresh_id" > "${ROOT_DIR}/artifacts/latest-refresh-id.txt"
printf '%s\n' "$expected_version" > "${ROOT_DIR}/artifacts/refresh-lt-version.txt"

echo "========================================"
echo "INSTANCE REFRESH STARTED"
echo "========================================"
echo "Refresh ID: $refresh_id"
echo "ASG:        $ASG_NAME"
echo "LT version: $expected_version"
