
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ==========================================================
# 1. REQUIRED VARIABLES
# ==========================================================

require_value SOURCE_INSTANCE_ID
require_value APP_BUILD_NUMBER
require_value APP_GIT_COMMIT
require_value APP_NAME

: "${AMI_NAME_PREFIX:=rr-demo-ami}"
: "${NO_REBOOT:=false}"
: "${AMI_WAIT_TIMEOUT_SECONDS:=3600}"

# ==========================================================
# 2. VALIDATE APPLICATION METADATA
# ==========================================================

[[ "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "ERROR: APP_BUILD_NUMBER must be numeric." >&2
    exit 1
}

[[ "$APP_GIT_COMMIT" =~ ^[a-fA-F0-9]{7,40}$ ]] || {
    echo "ERROR: Invalid APP_GIT_COMMIT." >&2
    exit 1
}

COMMIT_SHORT="${APP_GIT_COMMIT:0:7}"
BUILD_TIMESTAMP="$(timestamp)"

AMI_NAME="${AMI_NAME_PREFIX}-${APP_NAME}-appbuild-${APP_BUILD_NUMBER}-${COMMIT_SHORT}-${BUILD_TIMESTAMP}"

# ==========================================================
# 3. VALIDATE SOURCE INSTANCE
# ==========================================================

echo "Checking source instance: ${SOURCE_INSTANCE_ID}"

SOURCE_STATE="$(
    "${AWS[@]}" ec2 describe-instances \
        --instance-ids "$SOURCE_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text
)"

[[ "$SOURCE_STATE" == "running" ]] || {
    echo "ERROR: Source instance is not running: $SOURCE_STATE" >&2
    exit 1
}

echo "Source instance state: ${SOURCE_STATE}"

# Prevent imaging an ASG member.
if [[ -n "${ASG_NAME:-}" && "$ASG_NAME" != REPLACE_* ]]; then

    member="$(
        "${AWS[@]}" autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$ASG_NAME" \
            --query "AutoScalingGroups[].Instances[?InstanceId=='${SOURCE_INSTANCE_ID}'].InstanceId | [0]" \
            --output text
    )"

    [[ "$member" == "None" || -z "$member" ]] || {
        echo "ERROR: Source instance belongs to ASG ${ASG_NAME}." >&2
        echo "Use a dedicated image-builder instance." >&2
        exit 1
    }
fi

# ==========================================================
# 4. CREATE ARTIFACT DIRECTORY AND METADATA
# ==========================================================

mkdir -p "${ROOT_DIR}/artifacts"

cat > "${ROOT_DIR}/artifacts/ami-metadata.txt" <<EOF
AMI_NAME=${AMI_NAME}
APP_NAME=${APP_NAME}
APP_BUILD_NUMBER=${APP_BUILD_NUMBER}
APP_GIT_COMMIT=${APP_GIT_COMMIT}
SOURCE_INSTANCE_ID=${SOURCE_INSTANCE_ID}
CREATED_AT_UTC=${BUILD_TIMESTAMP}
EOF

echo
echo "=========================================="
echo "AMI CREATION PLAN"
echo "=========================================="
echo "Application     : ${APP_NAME}"
echo "Source instance : ${SOURCE_INSTANCE_ID}"
echo "AMI name        : ${AMI_NAME}"
echo "Build number    : ${APP_BUILD_NUMBER}"
echo "Git commit      : ${APP_GIT_COMMIT}"
echo "No reboot       : ${NO_REBOOT}"
echo "=========================================="

# ==========================================================
# 5. PREPARE VALID AMI TAG SPECIFICATION
# ==========================================================

# IMPORTANT:
# CreateImage supports ResourceType=image and
# ResourceType=snapshot for tag specifications.
# Do not use ResourceType=volume here.

AMI_TAGS="ResourceType=image,Tags=[
{Key=Name,Value=${AMI_NAME}},
{Key=Application,Value=${APP_NAME}},
{Key=SourceInstance,Value=${SOURCE_INSTANCE_ID}},
{Key=AppBuildNumber,Value=${APP_BUILD_NUMBER}},
{Key=GitCommit,Value=${APP_GIT_COMMIT}},
{Key=ManagedBy,Value=Jenkins}
]"

SNAPSHOT_TAGS="ResourceType=snapshot,Tags=[
{Key=Name,Value=${AMI_NAME}},
{Key=Application,Value=${APP_NAME}},
{Key=AppBuildNumber,Value=${APP_BUILD_NUMBER}},
{Key=GitCommit,Value=${APP_GIT_COMMIT}},
{Key=ManagedBy,Value=Jenkins}
]"

# ==========================================================
# 6. PREPARE AWS CREATE-IMAGE COMMAND
# ==========================================================

args=(
    ec2 create-image
    --instance-id "$SOURCE_INSTANCE_ID"
    --name "$AMI_NAME"
    --description "Application ${APP_NAME}, build ${APP_BUILD_NUMBER}, commit ${APP_GIT_COMMIT}"
    --tag-specifications
    "$AMI_TAGS"
    "$SNAPSHOT_TAGS"
)

if [[ "$NO_REBOOT" == "true" ]]; then
    args+=(--no-reboot)
fi

echo
echo "Prepared AMI creation command."
echo "Image tags and snapshot tags will be applied separately by AWS."

# ==========================================================
# 7. MANUAL APPROVAL
# ==========================================================

confirm_apply || {
    echo "AMI creation skipped."
    exit 0
}

# ==========================================================
# 8. CREATE AMI
# ==========================================================

echo
echo "Creating AMI from Demand-a2..."

AMI_ID="$(
    "${AWS[@]}" "${args[@]}" \
        --query 'ImageId' \
        --output text
)"

[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || {
    echo "ERROR: AWS did not return a valid AMI ID." >&2
    exit 1
}

printf '%s\n' "$AMI_ID" \
    > "${ROOT_DIR}/artifacts/latest-ami-id.txt"

printf '%s\n' "$AMI_NAME" \
    > "${ROOT_DIR}/artifacts/latest-ami-name.txt"

echo "AMI creation initiated successfully."
echo "AMI ID  : ${AMI_ID}"
echo "AMI Name: ${AMI_NAME}"

# ==========================================================
# 9. WAIT FOR AMI TO BECOME AVAILABLE
# ==========================================================

echo
echo "Waiting for AMI to become available..."

DEADLINE=$((SECONDS + AMI_WAIT_TIMEOUT_SECONDS))

while (( SECONDS < DEADLINE )); do

    AMI_STATE="$(
        "${AWS[@]}" ec2 describe-images \
            --image-ids "$AMI_ID" \
            --query 'Images[0].State' \
            --output text 2>/dev/null || true
    )"

    echo "AMI ${AMI_ID}: ${AMI_STATE:-pending}"

    if [[ "$AMI_STATE" == "available" ]]; then
        echo "AMI successfully created and available."
        break
    fi

    if [[ "$AMI_STATE" == "failed" ]]; then
        echo "ERROR: AMI creation failed." >&2
        exit 1
    fi

    sleep 20
done

if [[ "$AMI_STATE" != "available" ]]; then
    echo "ERROR: Timed out waiting for AMI ${AMI_ID}." >&2
    exit 1
fi

# ==========================================================
# 10. VERIFY AMI TAGS
# ==========================================================

echo
echo "Verifying AMI tags..."

AMI_JSON="$(
    "${AWS[@]}" ec2 describe-images \
        --image-ids "$AMI_ID" \
        --output json
)"

ACTUAL_NAME="$(jq -r '.Images[0].Name' <<< "$AMI_JSON")"

ACTUAL_BUILD="$(
    jq -r '[.Images[0].Tags[]? | select(.Key=="AppBuildNumber") | .Value][0] // empty' \
        <<< "$AMI_JSON"
)"

ACTUAL_COMMIT="$(
    jq -r '[.Images[0].Tags[]? | select(.Key=="GitCommit") | .Value][0] // empty' \
        <<< "$AMI_JSON"
)"

[[ "$ACTUAL_NAME" == "$AMI_NAME" ]] || {
    echo "ERROR: AMI name verification failed." >&2
    exit 1
}

[[ "$ACTUAL_BUILD" == "$APP_BUILD_NUMBER" ]] || {
    echo "ERROR: AMI build tag verification failed." >&2
    exit 1
}

[[ "${ACTUAL_COMMIT,,}" == "${APP_GIT_COMMIT,,}" ]] || {
    echo "ERROR: AMI commit tag verification failed." >&2
    exit 1
}

# ==========================================================
# 11. SAVE FINAL AMI METADATA
# ==========================================================

cat > "${ROOT_DIR}/artifacts/ami-metadata.txt" <<EOF
AMI_ID=${AMI_ID}
AMI_NAME=${AMI_NAME}
APP_NAME=${APP_NAME}
APP_BUILD_NUMBER=${APP_BUILD_NUMBER}
APP_GIT_COMMIT=${APP_GIT_COMMIT}
SOURCE_INSTANCE_ID=${SOURCE_INSTANCE_ID}
AMI_STATE=available
CREATED_AT_UTC=${BUILD_TIMESTAMP}
EOF

# ==========================================================
# 12. FINAL RESULT
# ==========================================================

echo
echo "=========================================="
echo "AMI CREATION COMPLETED SUCCESSFULLY"
echo "=========================================="
echo "AMI ID       : ${AMI_ID}"
echo "AMI Name     : ${AMI_NAME}"
echo "Application  : ${APP_NAME}"
echo "Build Number : ${APP_BUILD_NUMBER}"
echo "Git Commit   : ${APP_GIT_COMMIT}"
echo "AMI State    : available"
echo "=========================================="
echo
echo "Next step: scripts/03-create-lt-version.sh"
