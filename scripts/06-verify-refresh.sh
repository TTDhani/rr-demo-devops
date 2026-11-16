#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_value ASG_NAME
require_value LAUNCH_TEMPLATE_ID
require_value TARGET_GROUP_ARN

: "${REFRESH_TIMEOUT_SECONDS:=1800}"
: "${REFRESH_POLL_INTERVAL_SECONDS:=30}"
: "${REFRESH_DIAGNOSTIC_INTERVAL_SECONDS:=60}"
: "${TARGET_HEALTH_RETRIES:=5}"
: "${TARGET_HEALTH_RETRY_INTERVAL_SECONDS:=30}"

for value in \
    "$REFRESH_TIMEOUT_SECONDS" \
    "$REFRESH_POLL_INTERVAL_SECONDS" \
    "$REFRESH_DIAGNOSTIC_INTERVAL_SECONDS" \
    "$TARGET_HEALTH_RETRIES" \
    "$TARGET_HEALTH_RETRY_INTERVAL_SECONDS"; do
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "ERROR: Invalid numeric monitoring setting: $value" >&2
        exit 1
    }
done

(( REFRESH_TIMEOUT_SECONDS > 0 && REFRESH_POLL_INTERVAL_SECONDS > 0 )) || {
    echo "ERROR: Monitoring timeout and poll interval must be greater than zero." >&2
    exit 1
}

ARTIFACT_DIR="$(artifact_dir)"

id="${REFRESH_ID:-}"
if [[ -z "$id" && -f "$ARTIFACT_DIR/latest-refresh-id.txt" ]]; then
    id="$(tr -d '[:space:]' < "$ARTIFACT_DIR/latest-refresh-id.txt")"
fi
[[ -n "$id" && "$id" != "None" ]] || {
    echo "ERROR: REFRESH_ID is missing." >&2
    exit 1
}

expected_version="${NEW_LT_VERSION:-${EXPECTED_LT_VERSION:-}}"
if [[ -z "$expected_version" && -f "$ARTIFACT_DIR/refresh-lt-version.txt" ]]; then
    expected_version="$(tr -d '[:space:]' < "$ARTIFACT_DIR/refresh-lt-version.txt")"
fi
if [[ -z "$expected_version" && -f "$ARTIFACT_DIR/latest-lt-version.txt" ]]; then
    expected_version="$(tr -d '[:space:]' < "$ARTIFACT_DIR/latest-lt-version.txt")"
fi

[[ "$expected_version" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Expected numeric LT version is missing or invalid." >&2
    exit 1
}

expected_ami="${AMI_ID:-}"
if [[ -z "$expected_ami" && -f "$ARTIFACT_DIR/refresh-ami-id.txt" ]]; then
    expected_ami="$(tr -d '[:space:]' < "$ARTIFACT_DIR/refresh-ami-id.txt")"
fi
if [[ -z "$expected_ami" && -f "$ARTIFACT_DIR/latest-ami-id.txt" ]]; then
    expected_ami="$(tr -d '[:space:]' < "$ARTIFACT_DIR/latest-ami-id.txt")"
fi
if [[ -z "$expected_ami" ]]; then
    expected_ami="$("${AWS[@]}" ec2 describe-launch-template-versions \
        --launch-template-id "$LAUNCH_TEMPLATE_ID" \
        --versions "$expected_version" \
        --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' \
        --output text)"
fi

[[ -n "$expected_ami" && "$expected_ami" != "None" ]] || {
    echo "ERROR: Could not determine expected AMI." >&2
    exit 1
}

echo "================================================"
echo "RR-DEMO INSTANCE REFRESH VERIFICATION"
echo "================================================"
echo "Region              : $AWS_REGION"
echo "Account             : $ACCOUNT_ID"
echo "ASG                 : $ASG_NAME"
echo "Refresh ID          : $id"
echo "Launch Template     : $LAUNCH_TEMPLATE_ID"
echo "Expected LT version : $expected_version"
echo "Expected AMI        : $expected_ami"
echo "Monitoring timeout  : ${REFRESH_TIMEOUT_SECONDS}s"
echo "Poll interval       : ${REFRESH_POLL_INTERVAL_SECONDS}s"
echo "================================================"

# Verify the exact Launch Template version and AMI before monitoring.
lt_json="$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --versions "$expected_version" \
    --output json)"

lt_id="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateId // empty' <<< "$lt_json")"
lt_ami="$(jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId // empty' <<< "$lt_json")"

[[ "$lt_id" == "$LAUNCH_TEMPLATE_ID" && "$lt_ami" == "$expected_ami" ]] || {
    echo "ERROR: Expected Launch Template version does not point to expected AMI." >&2
    exit 1
}

# Verify the ASG desired configuration.
asg_json="$(get_asg_json "$ASG_NAME")"
asg_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
asg_lt_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"

[[ "$asg_lt_id" == "$LAUNCH_TEMPLATE_ID" && "$asg_lt_version" == "$expected_version" ]] || {
    echo "ERROR: ASG is not configured with the expected numeric LT version." >&2
    echo "ASG LT: $asg_lt_id / $asg_lt_version" >&2
    exit 1
}

print_diagnostics() {
    echo
    echo "=============== REFRESH DIAGNOSTICS ==============="

    "${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" \
        --instance-refresh-ids "$id" \
        --query 'InstanceRefreshes[0].{Status:Status,Reason:StatusReason,Progress:PercentageComplete,Remaining:InstancesToUpdate}' \
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
    echo "--- Target Group Health ---"
    "${AWS[@]}" elbv2 describe-target-health \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --output table || true

    echo "==================================================="
}

# Monitor the AWS-managed refresh.
deadline=$((SECONDS + REFRESH_TIMEOUT_SECONDS))
next_diagnostic=$((SECONDS + REFRESH_DIAGNOSTIC_INTERVAL_SECONDS))

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
            echo "AWS reports Instance Refresh Successful."
            break
            ;;
        Failed|Cancelled|RollbackFailed|RollbackSuccessful)
            echo "ERROR: Instance Refresh ended with status $status." >&2
            jq . <<< "$obj"
            print_diagnostics
            exit 1
            ;;
        Pending|InProgress|Cancelling|RollbackInProgress)
            ;;
        *)
            echo "ERROR: Unexpected refresh status: $status" >&2
            jq . <<< "$obj"
            print_diagnostics
            exit 1
            ;;
    esac

    if (( SECONDS >= next_diagnostic )); then
        print_diagnostics
        next_diagnostic=$((SECONDS + REFRESH_DIAGNOSTIC_INTERVAL_SECONDS))
    fi

    if (( SECONDS >= deadline )); then
        echo "ERROR: Jenkins monitoring timeout reached after ${REFRESH_TIMEOUT_SECONDS}s." >&2
        echo "This does not cancel the AWS Instance Refresh." >&2
        echo "Check the AWS refresh ID before retrying or starting another refresh." >&2
        print_diagnostics
        exit 2
    fi

    sleep "$REFRESH_POLL_INTERVAL_SECONDS"
done

# Final ASG and instance verification.
echo
echo "=== Final ASG Verification ==="

asg_json="$(get_asg_json "$ASG_NAME")"

actual_lt_id="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId // empty' <<< "$asg_json")"
actual_version="$(jq -r '.AutoScalingGroups[0].LaunchTemplate.Version // empty' <<< "$asg_json")"
desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity // 0' <<< "$asg_json")"
health_type="$(jq -r '.AutoScalingGroups[0].HealthCheckType // empty' <<< "$asg_json")"
instances="$(jq '.AutoScalingGroups[0].Instances // []' <<< "$asg_json")"
instance_count="$(jq 'length' <<< "$instances")"

[[ "$actual_lt_id" == "$LAUNCH_TEMPLATE_ID" && "$actual_version" == "$expected_version" ]] || {
    echo "ERROR: ASG LT configuration changed unexpectedly." >&2
    exit 1
}
[[ "$health_type" == "ELB" ]] || {
    echo "ERROR: ASG health-check type is not ELB." >&2
    exit 1
}
(( instance_count >= desired && instance_count > 0 )) || {
    echo "ERROR: ASG has fewer instances than desired capacity." >&2
    print_diagnostics
    exit 1
}

bad_instances="$(jq --arg version "$expected_version" \
    '[.[] | select(
        .LifecycleState != "InService" or
        .HealthStatus != "Healthy" or
        (.LaunchTemplate.Version | tostring) != $version
    )] | length' <<< "$instances")"

[[ "$bad_instances" == "0" ]] || {
    echo "ERROR: One or more ASG instances are not InService/Healthy on the expected LT version." >&2
    jq '.[] | {InstanceId,HealthStatus,LifecycleState,LaunchTemplate}' <<< "$instances"
    print_diagnostics
    exit 1
}

instance_ids="$(jq -r '.[].InstanceId' <<< "$instances")"

# Verify each ASG instance is running the expected AMI.
echo
echo "=== Verifying AMI on ASG Instances ==="

while IFS= read -r instance_id; do
    [[ -n "$instance_id" ]] || continue

    actual_ami="$("${AWS[@]}" ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].ImageId' \
        --output text)"

    echo "Instance: $instance_id | AMI: $actual_ami"

    [[ "$actual_ami" == "$expected_ami" ]] || {
        echo "ERROR: Instance $instance_id uses AMI $actual_ami; expected $expected_ami." >&2
        exit 1
    }
done <<< "$instance_ids"

# Allow target health to settle after the refresh reports Successful.
# ALB continues its own configured health-check schedule independently.
echo
echo "=== Verifying Target Group Health ==="

target_attempt=1
target_healthy=false

while (( target_attempt <= TARGET_HEALTH_RETRIES )); do
    target_json="$("${AWS[@]}" elbv2 describe-target-health \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --output json)"

    all_healthy=true

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

        echo "Attempt $target_attempt/$TARGET_HEALTH_RETRIES | $instance_id | $target_state | $target_reason"

        [[ "$target_state" == "healthy" ]] || all_healthy=false
    done <<< "$instance_ids"

    if [[ "$all_healthy" == true ]]; then
        target_healthy=true
        break
    fi

    if (( target_attempt < TARGET_HEALTH_RETRIES )); then
        echo "Target group is not fully healthy yet. Waiting ${TARGET_HEALTH_RETRY_INTERVAL_SECONDS}s..."
        sleep "$TARGET_HEALTH_RETRY_INTERVAL_SECONDS"
    fi

    target_attempt=$((target_attempt + 1))
done

[[ "$target_healthy" == true ]] || {
    echo "ERROR: Target group did not become fully healthy after $TARGET_HEALTH_RETRIES checks." >&2
    print_diagnostics
    exit 1
}

echo
echo "================================================"
echo "INSTANCE REFRESH VERIFICATION PASSED"
echo "================================================"
echo "ASG          : $ASG_NAME"
echo "Refresh ID   : $id"
echo "LT           : $LAUNCH_TEMPLATE_ID"
echo "LT version   : $expected_version"
echo "AMI          : $expected_ami"
echo
echo "All ASG instances are InService and Healthy."
echo "All instances use the expected LT version and AMI."
echo "All ASG instances are healthy in the target group."
echo "================================================"

"${AWS[@]}" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,Health:HealthStatus,State:LifecycleState,LT:LaunchTemplate.Version}' \
    --output table
