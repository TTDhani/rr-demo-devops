
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_value SOURCE_INSTANCE_ID
require_value APP_BUILD_NUMBER
require_value APP_GIT_COMMIT

: "${AMI_NAME_PREFIX:=rr-demo-ami}"
: "${NO_REBOOT:=false}"
: "${AMI_WAIT_TIMEOUT_SECONDS:=3600}"

# Validate application build metadata.
[[ "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "APP_BUILD_NUMBER must be numeric" >&2
  exit 1
}

[[ "$APP_GIT_COMMIT" =~ ^[a-fA-F0-9]{7,40}$ ]] || {
  echo "APP_GIT_COMMIT must be a valid Git commit SHA" >&2
  exit 1
}

COMMIT_SHORT="${APP_GIT_COMMIT:0:7}"
BUILD_TIMESTAMP="$(timestamp)"

AMI_NAME="${AMI_NAME_PREFIX}-${APP_NAME}-appbuild-${APP_BUILD_NUMBER}-${COMMIT_SHORT}-${BUILD_TIMESTAMP}"

# Prevent imaging an ASG member.
if [[ -n "${ASG_NAME:-}" && "$ASG_NAME" != REPLACE_* ]]; then
  member="$(
    "${AWS[@]}" autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query "AutoScalingGroups[].Instances[?InstanceId=='${SOURCE_INSTANCE_ID}'].InstanceId | [0]" \
      --output text
  )"

  [[ "$member" == "None" || -z "$member" ]] || {
    echo "Source instance is an ASG member. Use a dedicated image-builder." >&2
    exit 1
  }
fi

# Verify source instance.
SOURCE_STATE="$(
  "${AWS[@]}" ec2 describe-instances \
    --instance-ids "$SOURCE_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text
)"

[[ "$SOURCE_STATE" == "running" ]] || {
  echo "Source instance must be running. Current state: $SOURCE_STATE" >&2
  exit 1
}

# Record the exact image metadata for this rollout.
mkdir -p "${ROOT_DIR}/artifacts"

cat > "${ROOT_DIR}/artifacts/ami-metadata.txt" <<EOF
AMI_NAME=${AMI_NAME}
APP_NAME=${APP_NAME}
APP_BUILD_NUMBER=${APP_BUILD_NUMBER}
APP_GIT_COMMIT=${APP_GIT_COMMIT}
SOURCE_INSTANCE_ID=${SOURCE_INSTANCE_ID}
CREATED_AT_UTC=${BUILD_TIMESTAMP}
EOF

echo "========================================"
echo "AMI CREATION PLAN"
echo "========================================"
echo "Source instance : ${SOURCE_INSTANCE_ID}"
echo "AMI name        : ${AMI_NAME}"
echo "App build       : ${APP_BUILD_NUMBER}"
echo "Git commit      : ${APP_GIT_COMMIT}"
echo "========================================"

args=(
  ec2 create-image
  --instance-id "$SOURCE_INSTANCE_ID"
  --name "$AMI_NAME"
  --description "Application ${APP_NAME}, build ${APP_BUILD_NUMBER}, commit ${APP_GIT_COMMIT}"
  --tag-specifications
  "ResourceType=image,Tags=[{Key=Name,Value=${AMI_NAME}},{Key=Application,Value=${APP_NAME}},{Key=SourceInstance,Value=${SOURCE_INSTANCE_ID}},{Key=AppBuildNumber,Value=${APP_BUILD_NUMBER}},{Key=GitCommit,Value=${APP_GIT_COMMIT}},{Key=ManagedBy,Value=Jenkins}]"
  "ResourceType=volume,Tags=[{Key=Name,Value=${AMI_NAME}},{Key=Application,Value=${APP_NAME}},{Key=AppBuildNumber,Value=${APP_BUILD_NUMBER}},{Key=GitCommit,Value=${APP_GIT_COMMIT}},{Key=ManagedBy,Value=Jenkins}]"
)

if [[ "$NO_REBOOT" == "true" ]]; then
  args+=(--no-reboot)
fi

printf 'Planned command: aws'
printf ' %q' "${args[@]}"
echo

confirm_apply || exit 0

AMI_ID="$("${AWS[@]}" "${args[@]}" --query ImageId --output text)"

[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || {
  echo "AWS did not return an AMI ID" >&2
  exit 1
}

printf '%s\n' "$AMI_ID" > "${ROOT_DIR}/artifacts/latest-ami-id.txt"
printf '%s\n' "$AMI_NAME" > "${ROOT_DIR}/artifacts/latest-ami-name.txt"

echo "AMI creation started: ${AMI_ID}"
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

  [[ "$AMI_STATE" == "available" ]] && {
    echo "AMI successfully created and available."
    echo "AMI ID  : ${AMI_ID}"
    echo "AMI Name: ${AMI_NAME}"
    exit 0
  }

  [[ "$AMI_STATE" == "failed" ]] && {
    echo "AMI creation failed: ${AMI_ID}" >&2
    exit 1
  }

  sleep 20
done

echo "Timed out waiting for AMI ${AMI_ID}" >&2
exit 1
