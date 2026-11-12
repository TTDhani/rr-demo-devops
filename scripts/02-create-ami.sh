
#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

for v in SOURCE_INSTANCE_ID TARGET_GROUP_ARN ASG_NAME; do
    require_value "$v"
done

: "${AMI_NAME_PREFIX:=rr-demo-autoscale}"
: "${NO_REBOOT:=true}"
: "${AMI_WAIT_TIMEOUT_SECONDS:=3600}"

# Normalize NO_REBOOT safely
NO_REBOOT="$(printf '%s' "$NO_REBOOT" | tr '[:upper:]' '[:lower:]' | xargs)"

echo "NO_REBOOT validation value: [$NO_REBOOT]"

if [[ "$NO_REBOOT" != "true" ]]; then
    echo "ERROR: NO_REBOOT must be true for a live source instance." >&2
    exit 1
fi

echo "NO_REBOOT validation passed."

# Verify source instance is not part of the ASG
asg="$(get_asg_json "$ASG_NAME")"

member="$(jq --arg id "$SOURCE_INSTANCE_ID" \
    '[.AutoScalingGroups[0].Instances[]? | select(.InstanceId==$id)] | length' \
    <<< "$asg")"

[[ "$member" == "0" ]] || {
    echo "ERROR: Source instance is an ASG member." >&2
    exit 1
}

# Verify source instance is running and healthy
assert_source_healthy_target "$SOURCE_INSTANCE_ID" "$TARGET_GROUP_ARN"

# Prepare AMI creation command
name="${AMI_NAME_PREFIX}-${APP_NAME}-$(timestamp)"

args=(
    ec2 create-image
    --instance-id "$SOURCE_INSTANCE_ID"
    --name "$name"
    --description "Automated ${APP_NAME} image from ${SOURCE_INSTANCE_ID}"
    --no-reboot
)

echo "Planned AWS command:"
printf 'aws'
printf ' %q' "${args[@]}"
echo

# Require APPLY=true before making changes
confirm_apply || exit 0

echo "Creating AMI..."

ami="$("${AWS[@]}" "${args[@]}" --query ImageId --output text)"

[[ -n "$ami" && "$ami" != "None" ]] || {
    echo "ERROR: No AMI ID returned." >&2
    exit 1
}

a="$(artifact_dir)"
printf '%s\n' "$ami" > "$a/latest-ami-id.txt"

echo "AMI creation started: $ami"

deadline=$((SECONDS + AMI_WAIT_TIMEOUT_SECONDS))

while (( SECONDS < deadline )); do
    state="$("${AWS[@]}" ec2 describe-images \
        --image-ids "$ami" \
        --query 'Images[0].State' \
        --output text 2>/dev/null || true)"

    echo "AMI $ami state: ${state:-pending}"

    [[ "$state" == "available" ]] && {
        echo "AMI successfully created: $ami"
        exit 0
    }

    [[ "$state" == "failed" ]] && {
        echo "ERROR: AMI creation failed." >&2
        exit 1
    }

    sleep 20
done

echo "ERROR: Timed out waiting for AMI $ami" >&2
exit 1
