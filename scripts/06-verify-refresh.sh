
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value TARGET_GROUP_ARN

# Jenkins monitoring timeout. This does NOT change AWS refresh timing.
: "${REFRESH_TIMEOUT_SECONDS:=600}"
: "${REFRESH_POLL_INTERVAL_SECONDS:=30}"
: "${REFRESH_DIAGNOSTIC_INTERVAL_SECONDS:=60}"

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

echo "================================================"
echo "RR-DEMO INSTANCE REFRESH VERIFICATION"
echo "================================================"
echo "ASG:                 $ASG_NAME"
echo "Refresh ID:          $id"
echo "Expected LT ID:      $LAUNCH_TEMPLATE_ID"
echo "Expected LT version: $expected_version"
echo "Expected AMI:        $expected_ami"
echo "Monitor timeout:     ${REFRESH_TIMEOUT_SECONDS}s"
echo "Poll interval:       ${REFRESH_POLL_INTERVAL_SECONDS}s"
echo "================================================"

# Verify the expected Launch Template version exists
# and points to the expected AMI.
echo
echo "Checking expected Launch Template configuration..."

lt_json="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$expected_version" \
    --output json)"

lt_ami="$(jq -r \
    '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' \
    <<< "$lt_json")"

[[ -n "$lt_ami" ]] || {
    echo "ERROR: Could not read AMI from expected Launch Template version." >&2
    jq . <<< "$lt_json"
    exit 1
}

[[ "$lt_ami" == "$expected_ami" ]] || {
    echo "ERROR: LT version $expected_version points to $lt_ami, expected $expected_ami." >&2
    exit 1
}

echo "PASS: LT version $expected_version points to AMI $expected_ami."

# Check that the ASG is configured to use the expected LT version.
asg_initial="$("${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --output json)"

asg_lt_id="$(jq -r \
    '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' \
    <<< "$asg_initial")"

asg_lt_version="$(jq -r \
    '.AutoScalingGroups[0].LaunchTemplate.Version // empty' \
    <<< "$asg_initial")"

[[ "$asg_lt_id" == "$LAUNCH_TEMPLATE_ID" ]] || {
    echo "ERROR: ASG Launch Template ID does not match." >&2
    exit 1
}

[[ "$asg_lt_version" == "$expected_version" ]] || {
    echo "ERROR: ASG uses LT version $asg_lt_version; expected $expected_version." >&2
    exit 1
}

echo "PASS: ASG is configured with LT version $expected_version."

# Print useful diagnostics while AWS is refreshing.
print_refresh_diagnostics() {
    echo
    echo "=============== REFRESH DIAGNOSTICS ==============="

    echo
    echo "--- Instance Refresh ---"

    "${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" \
        --instance-refresh-ids "$id" \
        --query 'InstanceRefreshes[0].{Status:Status,Reason:StatusReason,Progress:PercentageComplete,Remaining:InstancesToUpdate,Start:StartTime,Details:ProgressDetails}' \
        --output json || true

    echo
    echo "--- Recent ASG Activities ---"

    "${AWS[@]}" autoscaling describe-scaling-activities \
        --auto-scaling-group-name "$ASG_NAME" \
        --max-records 10 \
        --query 'Activities[*].{Time:StartTime,Status:StatusCode,Description:Description,Cause:Cause}' \
        --output table || true

    echo
    echo "--- ASG Instances ---"

    "${AWS[@]}" autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --query 'AutoScalingGroups[0].Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus,LT:LaunchTemplate.Version}' \
        --output table || true

    echo
    echo "--- EC2 Status Checks ---"

    instance_ids="$("${AWS[@]}" autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
        --output text 2>/dev/null || true)"

    if [[ -n "$instance_ids" && "$instance_ids" != "None" ]]; then
        # Convert the AWS CLI text output into individual IDs.
        read -r -a ids_array <<< "$instance_ids"

        "${AWS[@]}" ec2 describe-instance-status \
            --instance-ids "${ids_array[@]}" \
            --include-all-instances \
            --query 'InstanceStatuses[*].{ID:InstanceId,State:InstanceState.Name,System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
            --output table || true
    else
        echo "No ASG instance IDs currently returned."
    fi

    echo
    echo "--- Target Group Health ---"

    "${AWS[@]}" elbv2 describe-target-health \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --query 'TargetHealthDescriptions[*].{ID:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
        --output table || true

    echo
    echo "==================================================="
}

deadline=$((SECONDS + REFRESH_TIMEOUT_SECONDS))
next_diagnostic=$((SECONDS + REFRESH_DIAGNOSTIC_INTERVAL_SECONDS))

echo
echo "Monitoring AWS Instance Refresh..."

while true; do

    obj="$("${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" \
        --instance-refresh-ids "$id" \
        --query 'InstanceRefreshes[0]' \
        --output json)"

    status="$(jq -r '.Status // "Unknown"' <<< "$obj")"
    percentage="$(jq -r '.PercentageComplete // 0' <<< "$obj")"
    remaining="$(jq -r '.InstancesToUpdate // 0' <<< "$obj")"
    reason="$(jq -r '.StatusReason // "No reason provided"' <<< "$obj")"

    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Refresh: $id"
    echo "Status: $status | Progress: ${percentage}% | Remaining: $remaining"
    echo "Reason: $reason"

    case "$status" in
        Successful)
            echo
            echo "AWS reports Instance Refresh Successful."
            break
            ;;

        Failed|Cancelled|RollbackFailed|RollbackSuccessful)
            echo
            echo "ERROR: Instance Refresh ended with status: $status" >&2
            jq . <<< "$obj"
            print_refresh_diagnostics
            exit 1
            ;;

        Pending|InProgress|Cancelling|RollbackInProgress)
            ;;

        *)
            echo "ERROR: Unexpected refresh status: $status" >&2
            jq . <<< "$obj"
            print_refresh_diagnostics
            exit 1
            ;;
    esac

    if (( SECONDS >= next_diagnostic )); then
        print_refresh_diagnostics
        next_diagnostic=$((SECONDS + REFRESH_DIAGNOSTIC_INTERVAL_SECONDS))
    fi

    if (( SECONDS >= deadline )); then
        echo
        echo "ERROR: Jenkins monitoring timeout reached after ${REFRESH_TIMEOUT_SECONDS}s." >&2
        echo "IMPORTANT: This does NOT cancel the AWS Instance Refresh."
        echo "AWS may still be processing the refresh."
        print_refresh_diagnostics
        exit 2
    fi

    sleep "$REFRESH_POLL_INTERVAL_SECONDS"
done

# Final ASG verification.
echo
echo "Checking final ASG configuration..."

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
    echo "ERROR: ASG uses LT version $actual_version, expected $expected_version." >&2
    exit 1
}

[[ "$health_type" == "ELB" ]] || {
    echo "ERROR: ASG HealthCheckType is not ELB." >&2
    exit 1
}

instances="$(jq '.AutoScalingGroups[0].Instances' <<< "$asg_json")"
instance_count="$(jq 'length' <<< "$instances")"

(( instance_count > 0 )) || {
    echo "ERROR: ASG has no instances." >&2
    exit 1
}

[[ "$instance_count" -ge "$desired" ]] || {
    echo "ERROR: ASG has fewer instances than desired capacity." >&2
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
    echo "ERROR: ASG instances are not all healthy on the expected LT version." >&2
    jq '.[] | {InstanceId,HealthStatus,LifecycleState,LaunchTemplate}' <<< "$instances"
    exit 1
}

instance_ids="$(jq -r '.[].InstanceId' <<< "$instances")"

echo
echo "Checking AMI on every ASG instance..."

while IFS= read -r instance_id; do
    [[ -n "$instance_id" ]] || continue

    actual_ami="$("${AWS[@]}" ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].ImageId' \
        --output text)"

    echo "Instance: $instance_id | AMI: $actual_ami"

    [[ "$actual_ami" == "$expected_ami" ]] || {
        echo "ERROR: Instance $instance_id uses AMI $actual_ami, expected $expected_ami." >&2
        exit 1
    }
done <<< "$instance_ids"

echo
echo "Checking target group health..."

target_json="$("${AWS[@]}" elbv2 describe-target-health \
    --target-group-arn "$TARGET_GROUP_ARN" \
    --output json)"

while IFS= read -r instance_id; do
    [[ -n "$instance_id" ]] || continue

    target_state="$(jq -r \
        --arg id "$instance_id" \
        '[.TargetHealthDescriptions[] | select(.Target.Id == $id) | .TargetHealth.State][0] // "not-registered"' \
        <<< "$target_json")"

    target_reason="$(jq -r \
        --arg id "$instance_id" \
        '[.TargetHealthDescriptions[] | select(.Target.Id == $id) | .TargetHealth.Reason][0] // "unknown"' \
        <<< "$target_json")"

    echo "Instance: $instance_id | Target: $target_state | Reason: $target_reason"

    [[ "$target_state" == "healthy" ]] || {
        echo "ERROR: Instance $instance_id is not healthy in the target group." >&2
        exit 1
    }
done <<< "$instance_ids"

echo
echo "================================================"
echo "INSTANCE REFRESH VERIFICATION PASSED"
echo "================================================"
echo "ASG:       $ASG_NAME"
echo "LT:        $LAUNCH_TEMPLATE_ID"
echo "LT Version: $expected_version"
echo "AMI:       $expected_ami"
echo
echo "All ASG instances are InService and Healthy."
echo "All ASG instances use the expected LT version and AMI."
echo "All ASG instances are healthy in the target group."
echo "================================================"

"${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,Health:HealthStatus,State:LifecycleState,LT:LaunchTemplate.Version}' \
    --output table
