
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID

version="${PREVIOUS_ASG_LT_VERSION:-}"

if [[ -z "$version" && -f "$ROOT_DIR/artifacts/previous-asg-lt-version.txt" ]]; then
    version="$(cat "$ROOT_DIR/artifacts/previous-asg-lt-version.txt")"
fi

[[ "$version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Set PREVIOUS_ASG_LT_VERSION to a numeric LT version." >&2
    exit 1
}

: "${MIN_HEALTHY_PERCENTAGE:=90}"
: "${MAX_HEALTHY_PERCENTAGE:=190}"
: "${INSTANCE_WARMUP_SECONDS:=300}"

for value in "$MIN_HEALTHY_PERCENTAGE" "$MAX_HEALTHY_PERCENTAGE" "$INSTANCE_WARMUP_SECONDS"; do
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "ERROR: Invalid numeric rollback preference: $value" >&2
        exit 1
    }
done

(( MIN_HEALTHY_PERCENTAGE <= 100 )) || {
    echo "ERROR: Minimum healthy percentage must be <= 100." >&2
    exit 1
}
(( MAX_HEALTHY_PERCENTAGE >= 100 && MAX_HEALTHY_PERCENTAGE <= 200 )) || {
    echo "ERROR: Maximum healthy percentage must be between 100 and 200." >&2
    exit 1
}
(( MAX_HEALTHY_PERCENTAGE >= MIN_HEALTHY_PERCENTAGE &&
   MAX_HEALTHY_PERCENTAGE - MIN_HEALTHY_PERCENTAGE <= 100 )) || {
    echo "ERROR: Invalid AWS healthy percentage range." >&2
    exit 1
}

active="$("${AWS[@]}" autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --query "length(InstanceRefreshes[?Status=='Pending' || Status=='InProgress' || Status=='Cancelling' || Status=='RollbackInProgress'])" \
    --output text)"

[[ "$active" == 0 ]] || {
    echo "ERROR: An Instance Refresh is active. No rollback changes have been made." >&2
    exit 1
}

lt_json="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$version" \
    --output json)"

rollback_ami="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' <<< "$lt_json")"

[[ -n "$rollback_ami" ]] || {
    echo "ERROR: Rollback LT version does not contain an AMI." >&2
    exit 1
}

ami_state="$("${AWS[@]}" ec2 describe-images \
    --image-ids "$rollback_ami" \
    --query 'Images[0].State' \
    --output text)"

[[ "$ami_state" == available ]] || {
    echo "ERROR: Rollback AMI $rollback_ami is not available: $ami_state" >&2
    exit 1
}

asg_json="$(get_asg_json "$ASG_NAME")"
current_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"

[[ "$current_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template ID mismatch." >&2
    exit 1
}

echo "ROLLBACK PLAN"
echo "ASG: $ASG_NAME"
echo "LT: $LAUNCH_TEMPLATE_ID"
echo "Rollback version: $version"
echo "Rollback AMI: $rollback_ami"
echo "Min healthy: $MIN_HEALTHY_PERCENTAGE"
echo "Max healthy: $MAX_HEALTHY_PERCENTAGE"
echo "Warmup: $INSTANCE_WARMUP_SECONDS"
echo
echo "This changes the ASG configuration and starts an instance refresh."

confirm_apply || exit 0

"${AWS[@]}" autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${version}"

updated="$(get_asg_json "$ASG_NAME")"
actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$updated")"

[[ "$actual_version" == "$version" ]] || {
    echo "ERROR: ASG rollback version verification failed." >&2
    exit 1
}

prefs="$(jq -n \
    --argjson min "$MIN_HEALTHY_PERCENTAGE" \
    --argjson max "$MAX_HEALTHY_PERCENTAGE" \
    --argjson warm "$INSTANCE_WARMUP_SECONDS" \
    '{
        MinHealthyPercentage:$min,
        MaxHealthyPercentage:$max,
        InstanceWarmup:$warm,
        SkipMatching:false,
        AutoRollback:false
    }')"

refresh_id="$("${AWS[@]}" autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" \
    --preferences "$prefs" \
    --query InstanceRefreshId \
    --output text)"

[[ -n "$refresh_id" && "$refresh_id" != None ]] || {
    echo "ERROR: AWS did not return a rollback refresh ID." >&2
    exit 1
}

mkdir -p "$ROOT_DIR/artifacts"
printf '%s\n' "$refresh_id" > "$ROOT_DIR/artifacts/rollback-refresh-id.txt"

echo "Rollback refresh started: $refresh_id"
echo "Rollback LT version: $version"
echo "Rollback AMI: $rollback_ami"
