
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value TARGET_GROUP_ARN

: "${REFRESH_TIMEOUT_SECONDS:=5400}"
: "${REFRESH_POLL_INTERVAL_SECONDS:=30}"
: "${TARGET_HEALTH_TIMEOUT_SECONDS:=900}"

id="${REFRESH_ID:-}"

if [[ -z "$id" && -f "${ROOT_DIR}/artifacts/latest-refresh-id.txt" ]]; then
    id="$(cat "${ROOT_DIR}/artifacts/latest-refresh-id.txt")"
fi

[[ -n "$id" ]] || {
    echo "ERROR: REFRESH_ID is missing." >&2
    exit 1
}

expected_version="${NEW_LT_VERSION:-}"

if [[ -z "$expected_version" && -f "${ROOT_DIR}/artifacts/refresh-lt-version.txt" ]]; then
    expected_version="$(cat "${ROOT_DIR}/artifacts/refresh-lt-version.txt")"
fi

if [[ -z "$expected_version" && -f "${ROOT_DIR}/artifacts/latest-lt-version.txt" ]]; then
    expected_version="$(cat "${ROOT_DIR}/artifacts/latest-lt-version.txt")"
fi

[[ "$expected_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Expected LT version is missing or invalid." >&2
    exit 1
}

expected_ami="${AMI_ID:-}"

if [[ -z "$expected_ami" && -f "${ROOT_DIR}/artifacts/latest-ami-id.txt" ]]; then
    expected_ami="$(cat "${ROOT_DIR}/artifacts/latest-ami-id.txt")"
fi

[[ -n "$expected_ami" ]] || {
    echo "ERROR: Expected AMI ID is missing." >&2
    exit 1
}

echo "========================================"
echo "VERIFYING INSTANCE REFRESH"
echo "========================================"
echo "ASG:             $ASG_NAME"
echo "Refresh ID:      $id"
echo "Expected LT:     $expected_version"
echo "Expected AMI:    $expected_ami"
echo

deadline=$((SECONDS + REFRESH_TIMEOUT_SECONDS))

while true; do
    obj="$("${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" \
        --instance-refresh-ids "$id" \
        --query 'InstanceRefreshes[0]' \
        --output json)"

    status="$(jq -r '.Status // "Unknown"' <<< "$obj")"
    percentage="$(jq -r '.PercentageComplete // 0' <<< "$obj")"
    remaining="$(jq -r '.InstancesToUpdate // 0' <<< "$obj")"

    echo "Refresh: $id | Status: $status | Progress: ${percentage}% | Remaining: $remaining"

    case "$status" in
        Successful)
            break
            ;;
        Failed|Cancelled|RollbackFailed|RollbackSuccessful)
            echo "ERROR: Instance Refresh ended with status: $status" >&2
            jq . <<< "$obj"
            exit 1
            ;;
        Pending|InProgress|Cancelling|RollbackInProgress)
            ;;
        *)
            echo "ERROR: Unexpected Instance Refresh status: $status" >&2
            jq . <<< "$obj"
            exit 1
            ;;
    esac

    if (( SECONDS >= deadline )); then
        echo "ERROR: Timed out waiting for Instance Refresh." >&2
        exit 1
    fi

    sleep "$REFRESH_POLL_INTERVAL_SECONDS"
done

echo
echo "Instance Refresh reports Successful. Verifying ASG instances..."

asg_json="$("${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --output json)"

asg_count="$(jq '.AutoScalingGroups | length' <<< "$asg_json")"

[[ "$asg_count" == "1" ]] || {
    echo "ERROR: ASG not found after refresh." >&2
    exit 1
}

actual_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId' <<< "$asg_json")"
actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version' <<< "$asg_json")"
desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<< "$asg_json")"
health_type="$(jq -r '.AutoScalingGroups[0].HealthCheckType' <<< "$asg_json")"

[[ "$actual_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template ID mismatch." >&2
    exit 1
}

[[ "$actual_version" == "$expected_version" ]] || {
    echo "ERROR: ASG is using LT version $actual_version, expected $expected_version." >&2
    exit 1
}

[[ "$health_type" == "ELB" ]] || {
    echo "ERROR: ASG health check type is not ELB." >&2
    exit 1
}

instances="$(jq '.AutoScalingGroups[0].Instances' <<< "$asg_json")"
instance_count="$(jq 'length' <<< "$instances")"

(( instance_count > 0 )) || {
    echo "ERROR: ASG has no instances." >&2
    exit 1
}

[[ "$instance_count" -ge "$desired" ]] || {
    echo "ERROR: ASG has fewer instances than its desired capacity." >&2
    exit 1
}

bad_instances="$(jq \
    --arg version "$expected_version" \
    '[.[] | select(
        .LifecycleState != "InService" or
        .HealthStatus != "Healthy" or
        (.LaunchTemplate.Version | tostring) != $version
    )] | length' <<< "$instances")"

[[ "$bad_instances" == "0" ]] || {
    echo "ERROR: One or more ASG instances are not InService/Healthy on the expected LT version." >&2
    jq '.[] | {InstanceId,HealthStatus,LifecycleState,LaunchTemplate}' <<< "$instances"
    exit 1
}

instance_ids="$(jq -r '.[].InstanceId' <<< "$instances")"

while IFS= read -r instance_id; do
    [[ -n "$instance_id" ]] || continue

    actual_ami="$("${AWS[@]}" ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].ImageId' \
        --output text)"

    [[ "$actual_ami" == "$expected_ami" ]] || {
        echo "ERROR: Instance $instance_id is using AMI $actual_ami, expected $expected_ami." >&2
        exit 1
    }

done <<< "$instance_ids"

echo
echo "ASG instance and AMI checks passed."
echo "Waiting for ASG instances to become healthy in the target group..."

target_deadline=$((SECONDS + TARGET_HEALTH_TIMEOUT_SECONDS))

while true; do
    target_json="$("${AWS[@]}" elbv2 describe-target-health \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --output json)"

    unhealthy=0

    while IFS= read -r instance_id; do
        [[ -n "$instance_id" ]] || continue

        target_state="$(jq -r \
            --arg id "$instance_id" \
            '[.TargetHealthDescriptions[] | select(.Target.Id == $id) | .TargetHealth.State][0] // "not-registered"' \
            <<< "$target_json")"

        echo "Instance $instance_id target state: $target_state"

        if [[ "$target_state" != "healthy" ]]; then
            unhealthy=$((unhealthy + 1))
        fi
    done <<< "$instance_ids"

    if (( unhealthy == 0 )); then
        break
    fi

    if (( SECONDS >= target_deadline )); then
        echo "ERROR: Timed out waiting for ASG target health." >&2
        jq '.TargetHealthDescriptions[] | {Target: .Target.Id, State: .TargetHealth.State, Reason: .TargetHealth.Reason}' <<< "$target_json"
        exit 1
    fi

    sleep "$REFRESH_POLL_INTERVAL_SECONDS"
done

echo
echo "========================================"
echo "INSTANCE REFRESH VERIFICATION PASSED"
echo "========================================"

"${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,Health:HealthStatus,State:LifecycleState,LT:LaunchTemplate.Version}' \
    --output table

echo
echo "All ASG instances are healthy and running the expected AMI."
