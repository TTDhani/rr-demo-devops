
#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------

: "${AWS_REGION:?AWS_REGION is required}"
: "${ASG_NAME:?ASG_NAME is required}"
: "${TARGET_GROUP_ARN:?TARGET_GROUP_ARN is required}"
: "${LT_ID:?LT_ID is required}"
: "${EXPECTED_LT_VERSION:?EXPECTED_LT_VERSION is required}"

POLL_INTERVAL=20
MAX_WAIT_SECONDS=1800

# File created before starting the refresh.
BASELINE_FILE="artifacts/pre-refresh-instance-ids.txt"

mkdir -p artifacts

if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "ERROR: Baseline instance ID file is missing."
    exit 1
fi

echo "=========================================="
echo "NEW ASG INSTANCE HEALTH VERIFICATION"
echo "=========================================="

echo "ASG: $ASG_NAME"
echo "Launch Template: $LT_ID"
echo "Expected version: $EXPECTED_LT_VERSION"
echo "Target Group: $TARGET_GROUP_ARN"

echo
echo "Existing instances before refresh:"
cat "$BASELINE_FILE"

START_TIME=$(date +%s)
NEW_INSTANCE_ID=""

# ---------------------------------------------------------
# STEP 1: DISCOVER THE NEW INSTANCE
# ---------------------------------------------------------

while true; do

    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if (( ELAPSED >= MAX_WAIT_SECONDS )); then
        echo "ERROR: Timed out waiting for new ASG instance."
        exit 1
    fi

    echo
    echo "Discovering replacement instance..."

    ASG_INSTANCES=$(
        aws autoscaling describe-auto-scaling-groups \
            --region "$AWS_REGION" \
            --auto-scaling-group-names "$ASG_NAME" \
            --output json
    )

    NEW_INSTANCE_ID=$(
        echo "$ASG_INSTANCES" |
        jq -r \
          --arg lt "$LT_ID" \
          --arg version "$EXPECTED_LT_VERSION" \
          --argjson old "$(jq -R -s 'split("\n") | map(select(length > 0))' "$BASELINE_FILE")" \
          '
          [
            .AutoScalingGroups[0].Instances[]
            | select(
                .LaunchTemplate.LaunchTemplateId == $lt
                and .LaunchTemplate.Version == $version
                and (.InstanceId as $id | ($old | index($id) | not))
            )
          ]
          | sort_by(.InstanceId)
          | .[0].InstanceId // empty
          '
    )

    if [[ -n "$NEW_INSTANCE_ID" ]]; then
        echo "New replacement instance discovered: $NEW_INSTANCE_ID"
        break
    fi

    echo "Replacement instance not found yet."
    sleep "$POLL_INTERVAL"

done

# ---------------------------------------------------------
# STEP 2: MONITOR ONLY THE NEW INSTANCE
# ---------------------------------------------------------

while true; do

    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if (( ELAPSED >= MAX_WAIT_SECONDS )); then
        echo "ERROR: New instance health verification timed out."
        exit 1
    fi

    echo
    echo "------------------------------------------"
    echo "Checking new instance: $NEW_INSTANCE_ID"
    echo "------------------------------------------"

    INSTANCE_INFO=$(
        aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --instance-ids "$NEW_INSTANCE_ID" \
            --output json
    )

    EC2_STATE=$(
        echo "$INSTANCE_INFO" |
        jq -r '.Reservations[0].Instances[0].State.Name // "unknown"'
    )

    STATUS_CHECKS=$(
        aws ec2 describe-instance-status \
            --region "$AWS_REGION" \
            --instance-ids "$NEW_INSTANCE_ID" \
            --include-all-instances \
            --output json
    )

    SYSTEM_STATUS=$(
        echo "$STATUS_CHECKS" |
        jq -r '.InstanceStatuses[0].SystemStatus.Status // "initializing"'
    )

    INSTANCE_STATUS=$(
        echo "$STATUS_CHECKS" |
        jq -r '.InstanceStatuses[0].InstanceStatus.Status // "initializing"'
    )

    ASG_STATE=$(
        aws autoscaling describe-auto-scaling-groups \
            --region "$AWS_REGION" \
            --auto-scaling-group-names "$ASG_NAME" \
            --query "AutoScalingGroups[0].Instances[?InstanceId=='$NEW_INSTANCE_ID'].LifecycleState | [0]" \
            --output text
    )

    ASG_HEALTH=$(
        aws autoscaling describe-auto-scaling-groups \
            --region "$AWS_REGION" \
            --auto-scaling-group-names "$ASG_NAME" \
            --query "AutoScalingGroups[0].Instances[?InstanceId=='$NEW_INSTANCE_ID'].HealthStatus | [0]" \
            --output text
    )

    TARGET_HEALTH=$(
        aws elbv2 describe-target-health \
            --region "$AWS_REGION" \
            --target-group-arn "$TARGET_GROUP_ARN" \
            --targets Id="$NEW_INSTANCE_ID",Port=3000 \
            --query 'TargetHealthDescriptions[0].TargetHealth.State' \
            --output text
    )

    TARGET_REASON=$(
        aws elbv2 describe-target-health \
            --region "$AWS_REGION" \
            --target-group-arn "$TARGET_GROUP_ARN" \
            --targets Id="$NEW_INSTANCE_ID",Port=3000 \
            --query 'TargetHealthDescriptions[0].TargetHealth.Reason' \
            --output text
    )

    echo "Instance ID:      $NEW_INSTANCE_ID"
    echo "EC2 state:        $EC2_STATE"
    echo "System status:    $SYSTEM_STATUS"
    echo "Instance status:  $INSTANCE_STATUS"
    echo "ASG lifecycle:    $ASG_STATE"
    echo "ASG health:       $ASG_HEALTH"
    echo "Target health:    $TARGET_HEALTH"
    echo "Target reason:    $TARGET_REASON"

    # Only the replacement instance determines this check.
    if [[ "$EC2_STATE" == "running" ]] &&
       [[ "$SYSTEM_STATUS" == "ok" ]] &&
       [[ "$INSTANCE_STATUS" == "ok" ]] &&
       [[ "$ASG_STATE" == "InService" ]] &&
       [[ "$ASG_HEALTH" == "Healthy" ]] &&
       [[ "$TARGET_HEALTH" == "healthy" ]]; then

        echo
        echo "=========================================="
        echo "NEW INSTANCE HEALTHY"
        echo "=========================================="
        echo "Instance: $NEW_INSTANCE_ID"
        echo "EC2: running"
        echo "EC2 status checks: passed"
        echo "ASG: InService / Healthy"
        echo "Target Group: healthy"
        break
    fi

    if [[ "$EC2_STATE" == "terminated" ]] ||
       [[ "$ASG_STATE" == "Terminating" ]]; then
        echo "ERROR: Replacement instance was terminated."
        echo "Inspect ASG scaling activities and target health."
        exit 1
    fi

    echo "Replacement is not fully healthy yet."
    echo "Retrying in ${POLL_INTERVAL}s..."

    sleep "$POLL_INTERVAL"

done

# ---------------------------------------------------------
# STEP 3: VERIFY INSTANCE REFRESH
# ---------------------------------------------------------

echo
echo "New instance passed all health checks."
echo "Now verifying final Instance Refresh status..."

# Keep your existing refresh-ID monitoring here.
# Do not mark the rollout successful until AWS reports
# the Instance Refresh status as Successful.

echo "New instance verification completed."
