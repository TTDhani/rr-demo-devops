
#!/usr/bin/env bash
set -Eeuo pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${ROOT_DIR}/config/poc.env}"

[[ -f "$CONFIG_FILE" ]] || {
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
}

APPLY_OVERRIDE="${APPLY:-}"
source "$CONFIG_FILE"

[[ -z "$APPLY_OVERRIDE" ]] || export APPLY="$APPLY_OVERRIDE"

: "${AWS_REGION:?AWS_REGION is required}"
: "${EXPECTED_ACCOUNT_ID:?EXPECTED_ACCOUNT_ID is required}"
: "${APP_NAME:?APP_NAME is required}"

# --------------------------------------------------
# AWS CLI
# --------------------------------------------------

command -v aws >/dev/null || {
    echo "ERROR: AWS CLI is required." >&2
    exit 1
}

command -v jq >/dev/null || {
    echo "ERROR: jq is required." >&2
    exit 1
}

AWS=(aws --region "$AWS_REGION" --no-cli-pager)

if [[ -n "${AWS_PROFILE:-}" ]]; then
    AWS+=(--profile "$AWS_PROFILE")
fi

ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity \
    --query Account --output text)"

[[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || {
    echo "ERROR: AWS account mismatch. Expected $EXPECTED_ACCOUNT_ID, got $ACCOUNT_ID." >&2
    exit 1
}

echo "AWS account and region verified."

# --------------------------------------------------
# Defaults
# --------------------------------------------------

: "${APPLY:=false}"
: "${REFRESH_TIMEOUT_SECONDS:=1800}"
: "${REFRESH_POLL_INTERVAL_SECONDS:=30}"
: "${TARGET_HEALTH_RETRIES:=5}"
: "${TARGET_HEALTH_RETRY_INTERVAL_SECONDS:=30}"
: "${ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS:=600}"
: "${INSTANCE_WARMUP_SECONDS:=600}"
: "${MIN_HEALTHY_PERCENTAGE:=90}"
: "${MAX_HEALTHY_PERCENTAGE:=190}"
: "${SKIP_MATCHING:=true}"
: "${AUTO_ROLLBACK:=true}"

# --------------------------------------------------
# General helpers
# --------------------------------------------------

require_value() {
    local name="$1"
    local value="${!name:-}"

    if [[ -z "$value" || "$value" == REPLACE_* ]]; then
        echo "ERROR: Required configuration missing: $name" >&2
        return 1
    fi
}

artifact_dir() {
    mkdir -p "$ROOT_DIR/artifacts"
    printf '%s\n' "$ROOT_DIR/artifacts"
}

get_asg_json() {
    "${AWS[@]}" autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${1:?ASG name required}" \
        --output json
}

# --------------------------------------------------
# Refresh configuration validation
# --------------------------------------------------

validate_refresh_settings() {
    local value

    for value in \
        REFRESH_TIMEOUT_SECONDS \
        REFRESH_POLL_INTERVAL_SECONDS \
        TARGET_HEALTH_RETRIES \
        TARGET_HEALTH_RETRY_INTERVAL_SECONDS \
        ASG_HEALTH_CHECK_GRACE_PERIOD_SECONDS \
        INSTANCE_WARMUP_SECONDS \
        MIN_HEALTHY_PERCENTAGE \
        MAX_HEALTHY_PERCENTAGE
    do
        [[ "${!value}" =~ ^[0-9]+$ ]] || {
            echo "ERROR: Invalid numeric setting: $value" >&2
            return 1
        }
    done

    (( REFRESH_TIMEOUT_SECONDS > 0 )) || return 1
    (( REFRESH_POLL_INTERVAL_SECONDS > 0 )) || return 1
    (( TARGET_HEALTH_RETRIES > 0 )) || return 1
    (( MIN_HEALTHY_PERCENTAGE >= 0 && MIN_HEALTHY_PERCENTAGE <= 100 )) || return 1
    (( MAX_HEALTHY_PERCENTAGE >= 100 && MAX_HEALTHY_PERCENTAGE <= 200 )) || return 1

    [[ "$SKIP_MATCHING" == true || "$SKIP_MATCHING" == false ]] || return 1
    [[ "$AUTO_ROLLBACK" == true || "$AUTO_ROLLBACK" == false ]] || return 1
}

# --------------------------------------------------
# Launch Template version resolution
# --------------------------------------------------

resolve_asg_version() {
    local version="$1"

    case "$version" in
        '$Latest')
            "${AWS[@]}" ec2 describe-launch-template-versions \
                --launch-template-id "$LAUNCH_TEMPLATE_ID" \
                --versions '$Latest' \
                --query 'LaunchTemplateVersions[0].VersionNumber' \
                --output text
            ;;
        '$Default')
            "${AWS[@]}" ec2 describe-launch-template-versions \
                --launch-template-id "$LAUNCH_TEMPLATE_ID" \
                --versions '$Default' \
                --query 'LaunchTemplateVersions[0].VersionNumber' \
                --output text
            ;;
        *)
            printf '%s\n' "$version"
            ;;
    esac
}

# --------------------------------------------------
# Instance refresh checks
# --------------------------------------------------

assert_no_active_refresh() {
    local refreshes active

    refreshes="$("${AWS[@]}" autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG_NAME" \
        --max-records 20 \
        --output json)"

    active="$(jq -r '
        [.InstanceRefreshes[]?
        | select(
            .Status == "Pending" or
            .Status == "InProgress" or
            .Status == "Cancelling" or
            .Status == "RollbackInProgress"
        )] | length
    ' <<< "$refreshes")"

    [[ "$active" == 0 ]] || {
        echo "ERROR: An active instance refresh already exists. Check AWS before continuing." >&2
        return 1
    }
}

# --------------------------------------------------
# Start instance refresh
# --------------------------------------------------

start_refresh() {
    local version="$1"
    local desired_file="$2"
    local prefs_file="$3"
    local refresh_id
    local output

    echo "Starting ASG instance refresh..."

    output="$("${AWS[@]}" autoscaling start-instance-refresh \
        --auto-scaling-group-name "$ASG_NAME" \
        --desired-configuration "file://${desired_file}" \
        --preferences "file://${prefs_file}" \
        --output json)"

    refresh_id="$(jq -r '.InstanceRefreshId // empty' <<< "$output")"

    [[ -n "$refresh_id" ]] || {
        echo "ERROR: Could not obtain instance refresh ID." >&2
        return 1
    }

    printf '%s\n' "$refresh_id" > "$(artifact_dir)/instance-refresh-id.txt"

    echo "Instance refresh started: $refresh_id"

    wait_for_refresh "$refresh_id"
}

# --------------------------------------------------
# Wait for instance refresh
# --------------------------------------------------

wait_for_refresh() {
    local refresh_id="$1"
    local deadline=$((SECONDS + REFRESH_TIMEOUT_SECONDS))
    local status obj progress last_progress=""

    while (( SECONDS < deadline )); do
        obj="$("${AWS[@]}" autoscaling describe-instance-refreshes \
            --auto-scaling-group-name "$ASG_NAME" \
            --instance-refresh-ids "$refresh_id" \
            --query 'InstanceRefreshes[0]' \
            --output json)"

        status="$(jq -r '.Status // "Unknown"' <<< "$obj")"
        progress="$(jq -r '.PercentageComplete // 0' <<< "$obj")"

        if [[ "$status:$progress" != "$last_progress" ]]; then
            echo "Instance refresh: ${status} (${progress}%)"
            last_progress="$status:$progress"
        fi

        case "$status" in
            Successful)
                echo "Instance refresh completed."
                return 0
                ;;
            Failed|Cancelled|RollbackFailed|RollbackSuccessful)
                echo "ERROR: Instance refresh ended with status ${status}." >&2
                jq '{Status,StatusReason,PercentageComplete}' <<< "$obj" >&2
                return 1
                ;;
            Pending|InProgress|Cancelling|RollbackInProgress)
                sleep "$REFRESH_POLL_INTERVAL_SECONDS"
                ;;
            *)
                echo "ERROR: Unexpected refresh status: ${status}" >&2
                return 1
                ;;
        esac
    done

    echo "ERROR: Jenkins monitoring timed out. AWS refresh may still be running. Check AWS before retrying." >&2
    return 2
}

# --------------------------------------------------
# Final ASG verification
# --------------------------------------------------

verify_asg_instances() {
    local expected_version="$1"
    local expected_ami="$2"
    local attempt asg_json instance_ids instance_id
    local actual_version actual_ami lifecycle health
    local target_health

    echo "Verifying ASG instances..."

    for ((attempt=1; attempt<=TARGET_HEALTH_RETRIES; attempt++)); do
        asg_json="$(get_asg_json "$ASG_NAME")"

        instance_ids="$(jq -r '
            [.AutoScalingGroups[0].Instances[]?
            | select(.LifecycleState=="InService" and .HealthStatus=="Healthy")
            | .InstanceId] | .[]
        ' <<< "$asg_json")"

        if [[ -n "$instance_ids" ]]; then
            while IFS= read -r instance_id; do
                [[ -n "$instance_id" ]] || continue

                actual_version="$(jq -r --arg id "$instance_id" '
                    .AutoScalingGroups[0].Instances[]
                    | select(.InstanceId==$id)
                    | .LaunchTemplate.Version // empty
                ' <<< "$asg_json")"

                lifecycle="$(jq -r --arg id "$instance_id" '
                    .AutoScalingGroups[0].Instances[]
                    | select(.InstanceId==$id)
                    | .LifecycleState
                ' <<< "$asg_json")"

                health="$(jq -r --arg id "$instance_id" '
                    .AutoScalingGroups[0].Instances[]
                    | select(.InstanceId==$id)
                    | .HealthStatus
                ' <<< "$asg_json")"

                actual_ami="$("${AWS[@]}" ec2 describe-instances \
                    --instance-ids "$instance_id" \
                    --query 'Reservations[0].Instances[0].ImageId' \
                    --output text)"

                target_health="$("${AWS[@]}" elbv2 describe-target-health \
                    --target-group-arn "$TARGET_GROUP_ARN" \
                    --targets "Id=$instance_id" \
                    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
                    --output text)"

                if [[ "$actual_version" != "$expected_version" ||
                      "$actual_ami" != "$expected_ami" ||
                      "$lifecycle" != "InService" ||
                      "$health" != "Healthy" ||
                      "$target_health" != "healthy" ]]; then
                    echo "Instance verification pending: $instance_id"
                    continue 2
                fi
            done <<< "$instance_ids"

            echo "ASG instance verification successful."
            return 0
        fi

        echo "Waiting for healthy ASG instances (${attempt}/${TARGET_HEALTH_RETRIES})..."
        sleep "$TARGET_HEALTH_RETRY_INTERVAL_SECONDS"
    done

    echo "ERROR: ASG instance verification failed." >&2
    return 1
}
