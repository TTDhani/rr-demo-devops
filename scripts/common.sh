
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
