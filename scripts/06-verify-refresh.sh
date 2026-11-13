
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value TARGET_GROUP_ARN

: "${REFRESH_TIMEOUT_SECONDS:=7200}"
: "${REFRESH_POLL_INTERVAL_SECONDS:=30}"
: "${TARGET_HEALTH_TIMEOUT_SECONDS:=600}"

id="${REFRESH_ID:-}"
if [[ -z "$id" && -f "$ROOT_DIR/artifacts/latest-refresh-id.txt" ]]; then
    id="$(cat "$ROOT_DIR/artifacts/latest-refresh-id.txt")"
fi

[[ -n "$id" ]] || {
    echo "ERROR: REFRESH_ID is required." >&2
    exit 1
}

expected_version="${NEW_LT_VERSION:-}"
if [[ -z "$expected_version" && -f "$ROOT_DIR/artifacts/refresh-lt-version.txt" ]]; then
    expected_version="$(cat "$ROOT_DIR/artifacts/refresh-lt-version.txt")"
fi

expected_ami="${AMI_ID:-}"
if [[ -z "$expected_ami" && -f "$ROOT_DIR/artifacts/refresh-ami-id.txt" ]]; then
    expected_ami="$(cat "$ROOT_DIR/artifacts/refresh-ami-id.txt")"
fi
if [[ -z "$expected_ami" && -f "$ROOT_DIR/artifacts/latest-ami-id.txt" ]]; then
    expected_ami="$(cat "$ROOT_DIR/artifacts/latest-ami-id.txt")"
fi

[[ "$expected_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Expected numeric LT version is missing." >&2
    exit 1
}
[[ -n "$expected_ami" ]] || {
    echo "ERROR: Expected AMI ID is missing." >&2
    exit 1
}

echo "Monitoring refresh: $id"
echo "ASG: $ASG_NAME | LT: $LAUNCH_TEMPLATE_ID | Version: $expected_version | AMI: $expected_ami"

deadline=$((SECONDS + REFRESH_TIMEOUT_SECONDS))

while true; do
    obj="$("${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" \
        --instance-refresh-ids "$id" \
        --query 'InstanceRefreshes[0]' \
        --output json)"

    status="$(jq -r '.Status // "Unknown"' <<< "$obj")"
    progress="$(jq -r '.PercentageComplete // 0' <<< "$obj")"
    reason="$(jq -r '.StatusReason // "No reason supplied"' <<< "$obj")"

    echo "Status=$status Progress=${progress}% Reason=$reason"

    case "$status" in
        Successful) break ;;
        Failed|Cancelled|RollbackFailed|RollbackSuccessful)
            echo "ERROR: Refresh ended with status $status" >&2
            jq . <<< "$obj"
            "${AWS[@]}" autoscaling describe-scaling-activities \
                --auto-scaling-group-name "$ASG_NAME" \
                --max-records 20 \
                --output table || true
            exit 1
            ;;
        Pending|InProgress|Cancelling|RollbackInProgress) ;;
        *)
            echo "ERROR: Unexpected refresh status: $status" >&2
            jq . <<< "$obj"
            exit 1
            ;;
    esac

    if (( SECONDS >= deadline )); then
        echo "ERROR: Monitoring timeout reached. AWS refresh is NOT cancelled." >&2
        "${AWS[@]}" autoscaling describe-scaling-activities \
            --auto-scaling-group-name "$ASG_NAME" \
            --max-records 20 \
            --output table || true
        exit 2
    fi

    sleep "$REFRESH_POLL_INTERVAL_SECONDS"
done

echo "AWS reports refresh Successful. Verifying ASG..."

asg_json="$(get_asg_json "$ASG_NAME")"
actual_lt="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"
instances="$(jq '.AutoScalingGroups[0].Instances // []' <<< "$asg_json")"
desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<< "$asg_json")"

[[ "$actual_lt" == "$LAUNCH_TEMPLATE_ID" && "$actual_version" == "$expected_version" ]] || {
    echo "ERROR: ASG is not configured with the expected LT version." >&2
    exit 1
}

count="$(jq 'length' <<< "$instances")"
(( count >= desired && count > 0 )) || {
    echo "ERROR: ASG instance count $count is below desired capacity $desired." >&2
    exit 1
}

bad="$(jq --arg v "$expected_version" \
    '[.[] | select(.LifecycleState != "InService" or .HealthStatus != "Healthy" or (.LaunchTemplate.Version|tostring) != $v)] | length' \
    <<< "$instances")"

[[ "$bad" == 0 ]] || {
    echo "ERROR: One or more ASG instances are not healthy on LT version $expected_version." >&2
    jq '.[] | {InstanceId,LifecycleState,HealthStatus,LaunchTemplate}' <<< "$instances"
    exit 1
}

instance_ids="$(jq -r '.[].InstanceId' <<< "$instances")"

while IFS= read -r iid; do
    [[ -n "$iid" ]] || continue
    actual_ami="$("${AWS[@]}" ec2 describe-instances \
        --instance-ids "$iid" \
        --query 'Reservations[0].Instances[0].ImageId' \
        --output text)"
    echo "Instance $iid AMI=$actual_ami"
    [[ "$actual_ami" == "$expected_ami" ]] || {
        echo "ERROR: Instance $iid is running AMI $actual_ami, expected $expected_ami." >&2
        exit 1
    }
done <<< "$instance_ids"

echo "Waiting for target-group health..."
health_deadline=$((SECONDS + TARGET_HEALTH_TIMEOUT_SECONDS))

while true; do
    target_json="$("${AWS[@]}" elbv2 describe-target-health \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --output json)"

    all_healthy=true
    while IFS= read -r iid; do
        [[ -n "$iid" ]] || continue
        state="$(jq -r --arg id "$iid" \
            '[.TargetHealthDescriptions[] | select(.Target.Id==$id) | .TargetHealth.State][0] // "not-registered"' \
            <<< "$target_json")"
        echo "Target $iid: $state"
        [[ "$state" == healthy ]] || all_healthy=false
    done <<< "$instance_ids"

    [[ "$all_healthy" == true ]] && break

    if (( SECONDS >= health_deadline )); then
        echo "ERROR: Target group did not become healthy before timeout." >&2
        jq '.TargetHealthDescriptions[] | {Target,TargetHealth}' <<< "$target_json"
        exit 1
    fi

    sleep 15
done

echo "================================================"
echo "INSTANCE REFRESH VERIFICATION PASSED"
echo "ASG: $ASG_NAME"
echo "LT version: $expected_version"
echo "AMI: $expected_ami"
echo "All ASG instances are InService and Healthy."
echo "All target-group instances are healthy."
echo "================================================"
