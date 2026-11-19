#!/bin/bash
# Slurm jobs table (status line + Job ID / Name / Status / Elapsed / Node(s)).
# Same look as the PyTorch-Lightning dashboard's Slurm summary, but driven by
# the workflow's job ids instead of a slurm_jobids.txt file.
#
# Requires JOBS (space/comma separated job IDs, from $drona_info_jobs).
#
# Pending jobs get one extra line: why they wait and the scheduler's estimated
# start. Only data from the squeue call made anyway, so refreshing stays cheap;
# the full picture (queue position, priority factors, hints) is the separate
# drona_slurm_pending.sh card. Labels match that card's titles.

html_escape() {
    local s=$1
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

source "$DRONA_RUNTIME_DIR/schedulers/slurm/drona_job_line.sh" 2>/dev/null \
    || { pending_line() { printf '%s' "$1"; }; outcome_line() { :; }; }

read -ra JOB_LIST <<< "${JOBS//,/ }"

ROWS=""
HAS_RUNNING=false
HAS_PENDING=false
HAS_FAILED=false
HAS_DONE=false
HAS_CANCELLED=false

for JID in "${JOB_LIST[@]}"; do
    [[ -z "$JID" ]] && continue
    # Name is last so a "|" in a job name cannot shift the other fields
    REASON=""; START=""; DEPS=""; EXITC=""
    ROW=$(squeue -j "$JID" -h -o "%i|%T|%M|%N|%r|%S|%E|%j" 2>/dev/null | head -1)
    if [[ -n "$ROW" ]]; then
        IFS='|' read -r ID STATE ELAPSED NODES REASON START DEPS NAME <<< "$ROW"
    else
        ROW=$(sacct -j "$JID" -X -n -p --format=JobID,State,Elapsed,NodeList,ExitCode,JobName 2>/dev/null | head -1 | sed 's/|$//')
        IFS='|' read -r ID STATE ELAPSED NODES EXITC NAME <<< "$ROW"
    fi
    ID=${ID:-$JID}
    FULL_STATE=$STATE
    STATE=${STATE%% *}

    case "$STATE" in
        RUNNING|COMPLETING|CONFIGURING) CLASS="table-info"; HAS_RUNNING=true ;;
        PENDING)   CLASS="table-warning"; HAS_PENDING=true ;;
        COMPLETED) CLASS="table-success"; HAS_DONE=true ;;
        CANCELLED*|PREEMPTED)
                   CLASS="table-secondary"; HAS_CANCELLED=true ;;
        FAILED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE)
                   CLASS="table-danger"; HAS_FAILED=true ;;
        *)         CLASS="" ;;
    esac

    ROWS+="<tr class='$CLASS'><td>$(html_escape "$ID")</td><td>$(html_escape "${NAME:-—}")</td><td>$(html_escape "${STATE:-unknown}")</td><td>$(html_escape "${ELAPSED:-—}")</td><td>$(html_escape "${NODES:-—}")</td></tr>"

    if [[ "$STATE" == "PENDING" && -n "$REASON" ]]; then
        WHY=$(pending_line "$REASON" "$START" "$DEPS")
        ROWS+="<tr class='$CLASS'><td colspan='5' style='border-top:0;padding-top:0;color:#6c757d;font-size:var(--drona-text-caption)'>&#8627; $(html_escape "$WHY")</td></tr>"
    elif [[ -n "$EXITC" ]]; then
        WHY=$(outcome_line "$FULL_STATE" "$EXITC")
        [[ -n "$WHY" ]] && ROWS+="<tr class='$CLASS'><td colspan='5' style='border-top:0;padding-top:0;color:#6c757d;font-size:var(--drona-text-caption)'>&#8627; $(html_escape "$WHY")</td></tr>"
    fi
done

if [[ -z "$ROWS" ]]; then
    echo "<div style='font-size:var(--drona-text-data);color:#6c757d;padding:4px 2px'>No Slurm jobs yet.</div>"
    exit 0
fi

if $HAS_FAILED; then
    DOT="#dc3545"; LABEL="Failed — check the job logs."
elif $HAS_RUNNING; then
    DOT="#0d6efd"; LABEL="Running"
elif $HAS_PENDING; then
    DOT="#ffc107"; LABEL="Pending — queued, waiting to start."
elif $HAS_DONE; then
    DOT="#198754"; LABEL="Completed"
elif $HAS_CANCELLED; then
    DOT="#6c757d"; LABEL="Cancelled"
else
    DOT="#adb5bd"; LABEL="Status unavailable"
fi

echo "<div style='display:flex;align-items:center;gap:7px;margin-bottom:8px;font-size:var(--drona-text-data);color:#495057'>"
echo "  <span style='width:8px;height:8px;border-radius:50%;background:${DOT};flex-shrink:0;display:inline-block'></span>"
echo "  ${LABEL}"
echo "</div>"
echo "<table class='table table-sm table-bordered mb-0' style='font-size:var(--drona-text-data)'>"
echo "<thead class='table-light'><tr><th>Job ID</th><th>Name</th><th>Status</th><th>Elapsed</th><th>Node(s)</th></tr></thead>"
echo "<tbody>${ROWS}</tbody></table>"
echo "<div style='margin-top:4px;text-align:right;font-size:var(--drona-text-caption);color:#94a3b8'>Updated $(date +%H:%M:%S)</div>"
