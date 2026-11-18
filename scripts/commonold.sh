#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${ROOT_DIR}/config/poc.env}"
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: Missing config: $CONFIG_FILE" >&2; exit 1; }

APPLY_OVERRIDE="${APPLY:-}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
[[ -z "$APPLY_OVERRIDE" ]] || APPLY="$APPLY_OVERRIDE"

: "${AWS_REGION:?AWS_REGION is required in poc.env}"
: "${EXPECTED_ACCOUNT_ID:?EXPECTED_ACCOUNT_ID is required in poc.env}"
: "${APP_NAME:?APP_NAME is required in poc.env}"
: "${APPLY:=false}"
: "${ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS:=600}"
: "${MIN_HEALTHY_PERCENTAGE:=90}"
: "${MAX_HEALTHY_PERCENTAGE:=190}"
: "${INSTANCE_WARMUP_SECONDS:=600}"
: "${REFRESH_TIMEOUT_SECONDS:=3600}"
: "${REFRESH_POLL_INTERVAL_SECONDS:=30}"
: "${TARGET_HEALTH_RETRIES:=5}"
: "${TARGET_HEALTH_RETRY_INTERVAL_SECONDS:=30}"
: "${AUTO_ROLLBACK:=true}"
: "${SKIP_MATCHING:=true}"
: "${NO_REBOOT:=false}"
: "${AMI_NAME_PREFIX:=rr-demo-ami}"
: "${LT_VERSION_DESCRIPTION_PREFIX:=rr-demo}"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI is required." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

AWS=(aws --region "$AWS_REGION" --no-cli-pager)
[[ -z "${AWS_PROFILE:-}" ]] || AWS+=(--profile "$AWS_PROFILE")
ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || {
    echo "ERROR: AWS account mismatch. Expected $EXPECTED_ACCOUNT_ID, got $ACCOUNT_ID." >&2
    exit 1
}

require_value() {
    local name="$1" value="${!1:-}"
    [[ -n "$value" && "$value" != REPLACE_* ]] || {
        echo "ERROR: Set $name in $CONFIG_FILE or Jenkins environment." >&2
        exit 1
    }
}

artifact_dir() {
    mkdir -p "$ROOT_DIR/artifacts"
    printf '%s\n' "$ROOT_DIR/artifacts"
}

get_asg_json() {
    "${AWS[@]}" autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$1" --output json
}

assert_no_active_refresh() {
    local count
    count="$("${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" --max-records 20 \
        --query "length(InstanceRefreshes[?Status=='Pending' || Status=='InProgress' || Status=='Cancelling' || Status=='RollbackInProgress'])" \
        --output text)"
    [[ "$count" == "0" ]] || {
        echo "ERROR: An Instance Refresh is already active for $ASG_NAME." >&2
        exit 1
    }
}

resolve_asg_version() {
    local value="$1"
    if [[ "$value" == '$Latest' || "$value" == '$Default' ]]; then
        "${AWS[@]}" ec2 describe-launch-template-versions \
            --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions "$value" \
            --query 'LaunchTemplateVersions[0].VersionNumber' --output text
    else
        printf '%s\n' "$value"
    fi
}

wait_for_refresh() {
    local refresh_id="$1" deadline=$((SECONDS + REFRESH_TIMEOUT_SECONDS)) status obj progress
    while (( SECONDS < deadline )); do
        obj="$("${AWS[@]}" autoscaling describe-instance-refreshes \
            --auto-scaling-group-name "$ASG_NAME" --instance-refresh-ids "$refresh_id" \
            --query 'InstanceRefreshes[0]' --output json)"
        status="$(jq -r '.Status // "Unknown"' <<< "$obj")"
        progress="$(jq -r '.PercentageComplete // 0' <<< "$obj")"
        echo "Instance Refresh: $status (${progress}%)"
        case "$status" in
            Successful) return 0 ;;
            Failed|Cancelled|RollbackFailed|RollbackSuccessful)
                echo "ERROR: Instance Refresh finished with status $status." >&2
                jq '{Status,StatusReason,PercentageComplete}' <<< "$obj" >&2
                return 1
                ;;
            Pending|InProgress|Cancelling|RollbackInProgress) sleep "$REFRESH_POLL_INTERVAL_SECONDS" ;;
            *) echo "ERROR: Unexpected Instance Refresh status: $status" >&2; return 1 ;;
        esac
    done
    echo "ERROR: Monitoring timeout reached. AWS refresh may still be running; check refresh ID $refresh_id before retrying." >&2
    return 2
}

start_refresh() {
    local version="$1" desired_file="$2" prefs_file="$3" refresh_id
    refresh_id="$("${AWS[@]}" autoscaling start-instance-refresh \
        --auto-scaling-group-name "$ASG_NAME" \
        --desired-configuration "file://$desired_file" \
        --preferences "file://$prefs_file" \
        --query InstanceRefreshId --output text)"
    [[ -n "$refresh_id" && "$refresh_id" != "None" ]] || {
        echo "ERROR: AWS did not return an Instance Refresh ID." >&2
        return 1
    }
    printf '%s\n' "$refresh_id" > "$(artifact_dir)/latest-refresh-id.txt"
    printf '%s\n' "$version" > "$(artifact_dir)/refresh-lt-version.txt"
    echo "Instance Refresh started: $refresh_id"
    wait_for_refresh "$refresh_id"
}

validate_refresh_settings() {
    local value
    for value in "$MIN_HEALTHY_PERCENTAGE" "$MAX_HEALTHY_PERCENTAGE" "$INSTANCE_WARMUP_SECONDS" "$REFRESH_TIMEOUT_SECONDS" "$REFRESH_POLL_INTERVAL_SECONDS" "$TARGET_HEALTH_RETRIES" "$TARGET_HEALTH_RETRY_INTERVAL_SECONDS" "$ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS"; do
        [[ "$value" =~ ^[0-9]+$ ]] || { echo "ERROR: Invalid numeric refresh setting: $value" >&2; exit 1; }
    done
    (( MIN_HEALTHY_PERCENTAGE <= 100 && MAX_HEALTHY_PERCENTAGE >= 100 && MAX_HEALTHY_PERCENTAGE <= 200 )) || {
        echo "ERROR: Invalid MinHealthyPercentage/MaxHealthyPercentage." >&2; exit 1;
    }
    (( MAX_HEALTHY_PERCENTAGE >= MIN_HEALTHY_PERCENTAGE && MAX_HEALTHY_PERCENTAGE - MIN_HEALTHY_PERCENTAGE <= 100 )) || {
        echo "ERROR: AWS requires MaxHealthyPercentage >= MinHealthyPercentage and difference <= 100." >&2; exit 1;
    }
    [[ "$AUTO_ROLLBACK" == true || "$AUTO_ROLLBACK" == false ]] || { echo "ERROR: AUTO_ROLLBACK must be true or false." >&2; exit 1; }
    [[ "$SKIP_MATCHING" == true || "$SKIP_MATCHING" == false ]] || { echo "ERROR: SKIP_MATCHING must be true or false." >&2; exit 1; }
    [[ "$NO_REBOOT" == true || "$NO_REBOOT" == false ]] || { echo "ERROR: NO_REBOOT must be true or false." >&2; exit 1; }
}

verify_asg_instances() {
    local expected_version="$1" expected_ami="$2" asg_json instances count bad ids id actual_ami target_json target_state attempt all_healthy
    asg_json="$(get_asg_json "$ASG_NAME")"
    instances="$(jq '.AutoScalingGroups[0].Instances // []' <<< "$asg_json")"
    count="$(jq 'length' <<< "$instances")"
    local desired
    desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity // 0' <<< "$asg_json")"
    (( count >= desired && count > 0 )) || { echo "ERROR: ASG has fewer instances than desired capacity." >&2; return 1; }
    bad="$(jq --arg v "$expected_version" '[.[] | select(.LifecycleState != "InService" or .HealthStatus != "Healthy" or (.LaunchTemplate.Version|tostring) != $v)] | length' <<< "$instances")"
    [[ "$bad" == 0 ]] || { echo "ERROR: ASG contains instances that are not InService/Healthy on LT version $expected_version." >&2; jq '.[] | {InstanceId,HealthStatus,LifecycleState,LaunchTemplate}' <<< "$instances" >&2; return 1; }
    ids="$(jq -r '.[].InstanceId' <<< "$instances")"
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        actual_ami="$("${AWS[@]}" ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].ImageId' --output text)"
        [[ "$actual_ami" == "$expected_ami" ]] || { echo "ERROR: $id runs AMI $actual_ami; expected $expected_ami." >&2; return 1; }
    done <<< "$ids"

    for ((attempt=1; attempt<=TARGET_HEALTH_RETRIES; attempt++)); do
        target_json="$("${AWS[@]}" elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --output json)"
        all_healthy=true
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            target_state="$(jq -r --arg id "$id" '[.TargetHealthDescriptions[] | select(.Target.Id==$id) | .TargetHealth.State][0] // "not-registered"' <<< "$target_json")"
            [[ "$target_state" == healthy ]] || all_healthy=false
        done <<< "$ids"
        [[ "$all_healthy" == true ]] && { echo "All ASG instances and target-group targets are healthy."; return 0; }
        (( attempt == TARGET_HEALTH_RETRIES )) || sleep "$TARGET_HEALTH_RETRY_INTERVAL_SECONDS"
    done
    echo "ERROR: Target Group did not report all ASG instances healthy." >&2
    "${AWS[@]}" elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --output table >&2 || true
    return 1
}
