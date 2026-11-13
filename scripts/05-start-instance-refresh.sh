
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID

: "${MIN_HEALTHY_PERCENTAGE:=90}"
: "${MAX_HEALTHY_PERCENTAGE:=190}"
: "${INSTANCE_WARMUP_SECONDS:=300}"
: "${SKIP_MATCHING:=true}"
: "${AUTO_ROLLBACK:=true}"

for value in "$MIN_HEALTHY_PERCENTAGE" "$MAX_HEALTHY_PERCENTAGE" "$INSTANCE_WARMUP_SECONDS"; do
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "ERROR: Invalid numeric refresh preference: $value" >&2
        exit 1
    }
done

(( MIN_HEALTHY_PERCENTAGE <= 100 )) || {
    echo "ERROR: MIN_HEALTHY_PERCENTAGE must be <= 100." >&2
    exit 1
}

(( MAX_HEALTHY_PERCENTAGE >= 100 && MAX_HEALTHY_PERCENTAGE <= 200 )) || {
    echo "ERROR: MAX_HEALTHY_PERCENTAGE must be between 100 and 200." >&2
    exit 1
}

(( MAX_HEALTHY_PERCENTAGE >= MIN_HEALTHY_PERCENTAGE )) || {
    echo "ERROR: Maximum must be >= minimum." >&2
    exit 1
}

(( MAX_HEALTHY_PERCENTAGE - MIN_HEALTHY_PERCENTAGE <= 100 )) || {
    echo "ERROR: AWS requires MAX - MIN to be <= 100." >&2
    exit 1
}

[[ "$SKIP_MATCHING" == true || "$SKIP_MATCHING" == false ]] || {
    echo "ERROR: SKIP_MATCHING must be true or false." >&2
    exit 1
}

[[ "$AUTO_ROLLBACK" == true || "$AUTO_ROLLBACK" == false ]] || {
    echo "ERROR: AUTO_ROLLBACK must be true or false." >&2
    exit 1
}

expected_version="${NEW_LT_VERSION:-}"

if [[ -z "$expected_version" && -f "$ROOT_DIR/artifacts/latest-lt-version.txt" ]]; then
    expected_version="$(cat "$ROOT_DIR/artifacts/latest-lt-version.txt")"
fi

[[ "$expected_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: A numeric NEW_LT_VERSION is required." >&2
    exit 1
}

lt_json="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$expected_version" \
    --output json)"

lt_id="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateId // empty' <<< "$lt_json")"
expected_ami="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' <<< "$lt_json")"

[[ "$lt_id" == "$LAUNCH_TEMPLATE_ID" && -n "$expected_ami" ]] || {
    echo "ERROR: Launch Template version or AMI is invalid." >&2
    exit 1
}

ami_state="$("${AWS[@]}" ec2 describe-images \
    --image-ids "$expected_ami" \
    --query 'Images[0].State' \
    --output text)"

[[ "$ami_state" == available ]] || {
    echo "ERROR: AMI $expected_ami is not available: $ami_state" >&2
    exit 1
}

asg_json="$(get_asg_json "$ASG_NAME")"

[[ "$(jq '.AutoScalingGroups | length' <<< "$asg_json")" == 1 ]] || {
    echo "ERROR: ASG not found or ambiguous." >&2
    exit 1
}

actual_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"
health_type="$(jq -r '.AutoScalingGroups[0].HealthCheckType // empty' <<< "$asg_json")"

[[ "$actual_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template mismatch." >&2
    exit 1
}

[[ "$actual_version" == "$expected_version" ]] || {
    echo "ERROR: ASG version $actual_version != expected $expected_version." >&2
    exit 1
}

[[ "$health_type" == ELB ]] || {
    echo "ERROR: ASG health check must be ELB." >&2
    exit 1
}

active_count="$("${AWS[@]}" autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --query "length(InstanceRefreshes[?Status=='Pending' || Status=='InProgress' || Status=='Cancelling' || Status=='RollbackInProgress'])" \
    --output text)"

[[ "$active_count" == 0 ]] || {
    echo "ERROR: An Instance Refresh is already active. Do not start another." >&2
    exit 1
}

mkdir -p "$ROOT_DIR/artifacts"
desired_file="$ROOT_DIR/artifacts/desired-configuration.json"

jq -n \
    --arg id "$LAUNCH_TEMPLATE_ID" \
    --arg version "$expected_version" \
    '{LaunchTemplate:{LaunchTemplateId:$id,Version:$version}}' \
    > "$desired_file"

prefs="$(jq -n \
    --argjson min "$MIN_HEALTHY_PERCENTAGE" \
    --argjson max "$MAX_HEALTHY_PERCENTAGE" \
    --argjson warm "$INSTANCE_WARMUP_SECONDS" \
    --argjson skip "$SKIP_MATCHING" \
    --argjson rollback "$AUTO_ROLLBACK" \
    '{
        MinHealthyPercentage:$min,
        MaxHealthyPercentage:$max,
        InstanceWarmup:$warm,
        SkipMatching:$skip,
        AutoRollback:$rollback
    }')"

echo "ASG: $ASG_NAME"
echo "LT: $LAUNCH_TEMPLATE_ID"
echo "LT version: $expected_version"
echo "AMI: $expected_ami"
echo "Refresh preferences:"
jq . <<< "$prefs"
echo "This operation replaces ASG instances."

confirm_apply || exit 0

refresh_id="$("${AWS[@]}" autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" \
    --desired-configuration "file://$desired_file" \
    --preferences "$prefs" \
    --query InstanceRefreshId \
    --output text)"

[[ -n "$refresh_id" && "$refresh_id" != None ]] || {
    echo "ERROR: AWS did not return a refresh ID." >&2
    exit 1
}

printf '%s\n' "$refresh_id" > "$ROOT_DIR/artifacts/latest-refresh-id.txt"
printf '%s\n' "$expected_version" > "$ROOT_DIR/artifacts/refresh-lt-version.txt"
printf '%s\n' "$expected_ami" > "$ROOT_DIR/artifacts/refresh-ami-id.txt"

echo "Instance Refresh started: $refresh_id"
