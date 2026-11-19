#!/bin/bash
# Why a pending job is waiting: reason in plain language (with what to do about
# it), the scheduler's estimated start time, the job's position among the jobs
# competing for the same partition, its priority broken down by factor, and the
# resources it asked for.
#
# Params:
#   JOBID - the selected job ($drona_job_scope). Empty: the first job of JOBS.
#   JOBS  - the workflow's jobs ($drona_info_jobs), space or comma separated.
#
# Plain Slurm only (squeue, scontrol, sprio). Prints nothing for a job that is
# not pending, so the element can stay mounted while the status changes.

JOBID="${JOBID//[^0-9_]/}"
if [[ -z "$JOBID" ]]; then
    read -ra JOB_LIST <<< "${JOBS//,/ }"
    JOBID="${JOB_LIST[0]//[^0-9_]/}"
fi
[[ -n "$JOBID" ]] || exit 0

escape_html() {
    local s=$1
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# 7380 -> "2 h 3 min"; 200000 -> "2 d 7 h"
human_duration() {
    local s=$1
    (( s < 0 )) && s=$(( -s ))
    if (( s >= 86400 )); then echo "$(( s / 86400 )) d $(( s % 86400 / 3600 )) h"
    elif (( s >= 3600 )); then echo "$(( s / 3600 )) h $(( s % 3600 / 60 )) min"
    elif (( s >= 60 )); then echo "$(( s / 60 )) min"
    else echo "< 1 min"
    fi
}

# Slurm time limit (D-HH:MM:SS, HH:MM:SS, MM:SS, MM) -> seconds
limit_seconds() {
    awk -v t="$1" 'BEGIN {
        if (t !~ /^[0-9]/) { print 0; exit }
        d = 0
        if (index(t, "-")) { split(t, p, "-"); d = p[1]; t = p[2] }
        n = split(t, p, ":")
        if (n == 1) s = p[1] * 60
        else if (n == 2) s = p[1] * 60 + p[2]
        else s = p[1] * 3600 + p[2] * 60 + p[3]
        print d * 86400 + s
    }'
}

# ---------------------------------------------------------------- job record
SQ=$(squeue -j "$JOBID" -h -o "%i|%P|%Q|%T|%S|%V|%Y|%E|%l|%D|%C|%m|%b|%q|%v|%a|%u|%r" 2>/dev/null | head -n 1)
[[ -n "$SQ" ]] || exit 0
IFS='|' read -r ID PARTS PRIO STATE START SUBMIT SCHEDNODES DEPS TLIMIT NNODES NCPUS MEM GRES QOS RESV ACCOUNT JUSER REASON <<< "$SQ"
[[ "$STATE" == "PENDING" ]] || exit 0

SC=$(scontrol show job -o "$JOBID" 2>/dev/null | head -n 1)
sc_field() { grep -oE "(^| )$1=[^ ]*" <<< "$SC" | head -n 1 | sed "s/^ *$1=//"; }
ELIGIBLE=$(sc_field EligibleTime)
LASTEVAL=$(sc_field LastSchedEval)
SCHEDULER=$(sc_field Scheduler)
REQTRES=$(sc_field ReqTRES)

NOW=$(date +%s)
to_epoch() { [[ "$1" =~ ^[0-9]{4}- ]] && date -d "$1" +%s 2>/dev/null; }
fmt_when() { date -d "@$1" +'%a %b %-d, %H:%M'; }

# ---------------------------------------------------------------- reason text
# REASON_TITLE: short label; REASON_TEXT: what it means; REASON_HINT: what the
# user can do (empty when waiting is all there is to it); SEVERITY: wait|warn|stop
REASON_TITLE="$REASON"; REASON_TEXT=""; REASON_HINT=""; SEVERITY="wait"; COMPETING=0

limit_target() {
    # QOSMaxCpuPerUserLimit -> "CPUs"; AssocGrpGRES -> "GPUs/GRES"
    case "$1" in
        *Cpu*Minutes*|*CPUMins*|*CPURunMins*) echo "CPU-minutes" ;;
        *Billing*Minutes*|*BillingMins*|*BillingRunMins*) echo "billing minutes (allocation balance)" ;;
        *GRES*Minutes*|*GRESMins*|*GRESRunMins*) echo "GPU/GRES-minutes" ;;
        *Cpu*|*CPU*) echo "CPUs" ;;
        *Mem*) echo "memory" ;;
        *Node*) echo "nodes" ;;
        *GRES*|*Gres*) echo "GPUs/GRES" ;;
        *Billing*) echo "billing units" ;;
        *SubmitJob*) echo "submitted jobs" ;;
        *Jobs*|*Job*) echo "running jobs" ;;
        *Wall*) echo "wall time" ;;
        *) echo "resources" ;;
    esac
}

case "$REASON" in
    Priority)
        REASON_TITLE="Waiting for higher-priority jobs"
        REASON_TEXT="Other eligible jobs in the partition have a higher priority. Slurm starts them first, or fits this job into a gap (backfill) if it is short enough."
        REASON_HINT="A shorter time limit (--time) makes it easier to backfill the job into gaps."
        COMPETING=1 ;;
    Resources)
        REASON_TITLE="Next in line, waiting for resources"
        REASON_TEXT="The job is at the front of the queue and waits for enough free nodes, CPUs, memory or GPUs."
        COMPETING=1 ;;
    None)
        REASON_TITLE="Not evaluated yet"
        REASON_TEXT="The scheduler has not looked at this job yet. This usually changes within a minute or two."
        COMPETING=1 ;;
    Dependency)
        REASON_TITLE="Waiting for other jobs"
        DEP_LIST=$(sed -E 's/\(unfulfilled\)//g; s/,/, /g' <<< "$DEPS")
        REASON_TEXT="The job depends on other jobs: $DEP_LIST. It becomes eligible when that condition is met (afterok: finished successfully; afterany: finished; after: started)." ;;
    DependencyNeverSatisfied)
        REASON_TITLE="Dependency can never be met"; SEVERITY="stop"
        REASON_TEXT="A job this one depends on ($DEPS) ended in a way that does not satisfy the dependency, for example it failed while the dependency is afterok. This job will never start."
        REASON_HINT="Cancel this job, fix the earlier step, and resubmit." ;;
    JobHeldUser)
        REASON_TITLE="Held by you"; SEVERITY="warn"
        REASON_TEXT="The job was submitted with --hold or put on hold with scontrol hold."
        REASON_HINT="Release it with: scontrol release $ID" ;;
    JobHeldAdmin)
        REASON_TITLE="Held by an administrator"; SEVERITY="warn"
        REASON_TEXT="An administrator put this job on hold. It will not start until they release it."
        REASON_HINT="Contact your system's support team if you do not know why." ;;
    "job requeued in held state"|launch\ failed\ requeued\ held)
        REASON_TITLE="Requeued and held"; SEVERITY="warn"
        REASON_TEXT="The job failed to launch or was requeued and is now on hold."
        REASON_HINT="Check the job's output, then release it (scontrol release $ID) or cancel and resubmit." ;;
    BeginTime)
        REASON_TITLE="Scheduled for later"
        REASON_TEXT="The job was submitted with --begin and is not eligible before ${ELIGIBLE:-its begin time}." ;;
    BadConstraints)
        REASON_TITLE="Request cannot be satisfied"; SEVERITY="stop"
        REASON_TEXT="No node in the partition matches the requested combination of features, CPUs, memory and GPUs."
        REASON_HINT="Check --constraint, --mem, --gres and --ntasks-per-node against the partition's nodes (sinfo -p $PARTS -o '%n %c %m %G %f'); cancel and resubmit." ;;
    PartitionTimeLimit|QOSMaxWallDurationPerJobLimit|AssocMaxWallDurationPerJobLimit)
        REASON_TITLE="Time limit too long"; SEVERITY="stop"
        REASON_TEXT="The requested time limit ($TLIMIT) is longer than the partition or QOS allows; the job will not start as is."
        REASON_HINT="Lower it, e.g. scontrol update job $ID TimeLimit=<HH:MM:SS>, or cancel and resubmit." ;;
    PartitionNodeLimit|QOSMaxNodePerJobLimit|AssocMaxNodesPerJob)
        REASON_TITLE="Too many nodes requested"; SEVERITY="stop"
        REASON_TEXT="The job asks for more nodes ($NNODES) than the partition or QOS allows per job."
        REASON_HINT="Cancel and resubmit with fewer nodes." ;;
    PartitionDown|PartitionInactive)
        REASON_TITLE="Partition unavailable"; SEVERITY="warn"
        REASON_TEXT="Partition $PARTS is down or inactive, so no jobs start in it right now (often maintenance)." ;;
    InvalidAccount|InvalidQOS|AccountNotAllowed|QOSNotAllowed)
        REASON_TITLE="Account or QOS not valid"; SEVERITY="stop"
        REASON_TEXT="Account $ACCOUNT or QOS $QOS cannot be used for this job or partition."
        REASON_HINT="Cancel and resubmit with a valid account (--account) or QOS." ;;
    Reservation)
        REASON_TITLE="Waiting for its reservation"
        REASON_TEXT="The job runs in reservation $RESV, which has not started yet or has no free resources." ;;
    Licenses)
        REASON_TITLE="Waiting for licenses"
        REASON_TEXT="All licenses the job requested are in use by other jobs." ;;
    Nodes_required_for_job_are_DOWN*|NodeDown)
        REASON_TITLE="Required nodes are down"; SEVERITY="warn"
        REASON_TEXT="Nodes the job needs are down or drained." ;;
    ReqNodeNotAvail*)
        REASON_TITLE="Needed nodes unavailable"
        REASON_TEXT="Nodes the job could use are down, drained or reserved: ${REASON#ReqNodeNotAvail, }."
        COMPETING=1 ;;
    QOS*PerUser*|QOS*PerAccount*|QOSGrp*|QOSMax*|Assoc*)
        WHAT=$(limit_target "$REASON")
        SCOPE="your QOS ($QOS)"
        [[ "$REASON" == Assoc* ]] && SCOPE="your account ($ACCOUNT)"
        if [[ "$REASON" == *Minutes* || "$REASON" == *Mins* ]]; then
            if [[ "$REASON" == *RunMin* ]]; then
                REASON_TITLE="Running-job budget reached"
                REASON_TEXT="The $WHAT that $SCOPE may have tied up in running jobs is used up. The job starts as running jobs finish."
            else
                REASON_TITLE="Allocation used up"; SEVERITY="warn"
                REASON_TEXT="The $WHAT available to $SCOPE are used up, so the job cannot start."
                REASON_HINT="Check your allocation balance or ask for more time on the account."
            fi
        else
            REASON_TITLE="Usage limit reached"
            REASON_TEXT="The limit on $WHAT for $SCOPE is reached by jobs already running. This job starts when some of them finish."
            REASON_HINT="Nothing is wrong with the job; it is held back by your other running jobs ($REASON)."
        fi ;;
    *)
        REASON_TEXT="Slurm reports: $REASON." ;;
esac

# Maintenance: a MAINT reservation that starts before the job could finish
MAINT_NOTE=""
TL_SECS=$(limit_seconds "$TLIMIT")
while IFS= read -r RES; do
    [[ "$RES" == *Flags=*MAINT* ]] || continue
    R_START=$(grep -oE 'StartTime=[^ ]+' <<< "$RES" | cut -d= -f2)
    R_END=$(grep -oE 'EndTime=[^ ]+' <<< "$RES" | cut -d= -f2)
    RS=$(to_epoch "$R_START"); RE=$(to_epoch "$R_END")
    [[ -n "$RS" && -n "$RE" ]] || continue
    (( RE > NOW )) || continue
    if (( TL_SECS > 0 && NOW + TL_SECS > RS )); then
        MAINT_NOTE="Maintenance is scheduled from $(fmt_when "$RS") to $(fmt_when "$RE"). A job with a $TLIMIT time limit started now would run into it, so it cannot start before maintenance unless it fits (shorter --time)."
        break
    fi
done < <(scontrol show res -o 2>/dev/null)

# ---------------------------------------------------------------- start estimate
START_MAIN="No estimate yet"
START_SUB="Slurm sets one after its next backfill pass"
START_EPOCH=$(to_epoch "$START")
if [[ -n "$START_EPOCH" ]] && (( START_EPOCH > NOW )); then
    START_MAIN="in $(human_duration $(( START_EPOCH - NOW )))"
    START_SUB="$(fmt_when "$START_EPOCH")"
    [[ -n "$SCHEDNODES" && "$SCHEDNODES" != "(null)" ]] && START_SUB+=" on $SCHEDNODES"
elif [[ -n "$START_EPOCH" ]]; then
    START_MAIN="Any moment"
    START_SUB="estimated start has passed; resources are being freed"
fi
case "$REASON" in
    Dependency|JobHeld*|DependencyNeverSatisfied|BadConstraints|*TimeLimit*|Invalid*)
        START_MAIN="—"; START_SUB="no estimate while the job is not eligible" ;;
esac

# ---------------------------------------------------------------- queue position
# Rank among jobs that compete for the same partition right now (reasons
# Priority/Resources/None/ReqNodeNotAvail), ordered by priority, ties by job id.
# Array tasks count individually (-r). Jobs that are held, waiting on a
# dependency or on a usage limit are not competing and are not counted.
RANK_MAIN="—"; RANK_SUB="not competing for resources yet"
if (( COMPETING )); then
    BASE_ID="${ID%%_*}"
    IFS=',' read -ra PART_LIST <<< "$PARTS"
    BEST_RANK=""; BEST_TOTAL=""; BEST_PART=""
    for P in "${PART_LIST[@]}"; do
        read -r R T < <(squeue -r -t PD -p "$P" -h -o "%Q|%i|%r" 2>/dev/null | awk -F'|' \
            -v myp="$PRIO" -v myid="$BASE_ID" -v me="$ID" '
            $3 == "Priority" || $3 == "Resources" || $3 == "None" || $3 ~ /^ReqNodeNotAvail/ {
                total++
                if ($2 == me) next
                split($2, a, "_"); id = a[1] + 0
                if ($1 + 0 > myp + 0 || ($1 + 0 == myp + 0 && id < myid + 0)) ahead++
            }
            END { printf "%d %d\n", ahead + 1, total }')
        if [[ -n "$R" ]] && { [[ -z "$BEST_RANK" ]] || (( R < BEST_RANK )); }; then
            BEST_RANK=$R; BEST_TOTAL=$T; BEST_PART=$P
        fi
    done
    if [[ -n "$BEST_RANK" ]]; then
        RANK_MAIN="#$BEST_RANK of $BEST_TOTAL"
        RANK_SUB="by priority in partition $BEST_PART"
        (( ${#PART_LIST[@]} > 1 )) && RANK_SUB+=" (best of ${#PART_LIST[@]} partitions)"
    fi
fi

# ---------------------------------------------------------------- waiting time
SUBMIT_EPOCH=$(to_epoch "$SUBMIT")
WAIT_MAIN="—"; WAIT_SUB=""
if [[ -n "$SUBMIT_EPOCH" ]]; then
    WAIT_MAIN="$(human_duration $(( NOW - SUBMIT_EPOCH )))"
    WAIT_SUB="submitted $(fmt_when "$SUBMIT_EPOCH")"
fi

# ---------------------------------------------------------------- priority factors
# sprio weighted values: age, association, fair-share, job size, partition, QOS, admin, TRES
FACTORS=""
SP=$(sprio -h -j "$ID" -o "%Y|%A|%B|%F|%J|%P|%Q|%S|%T" 2>/dev/null | head -n 1)
if [[ -z "$SP" && "$ID" == *_* ]]; then
    SP=$(sprio -h -j "${ID%%_*}" -o "%Y|%A|%B|%F|%J|%P|%Q|%S|%T" 2>/dev/null | head -n 1)
fi
if [[ -n "$SP" ]]; then
    FACTORS=$(awk -F'|' '
        BEGIN {
            name[2] = "Age";        col[2] = "#0ea5e9"; tip[2] = "grows the longer the job waits"
            name[3] = "Association"; col[3] = "#14b8a6"; tip[3] = "set per account"
            name[4] = "Fair-share"; col[4] = "#6366f1"; tip[4] = "higher when your account has used less than its share recently"
            name[5] = "Job size";   col[5] = "#f59e0b"; tip[5] = "depends on the number of nodes/CPUs requested"
            name[6] = "Partition";  col[6] = "#64748b"; tip[6] = "set per partition"
            name[7] = "QOS";        col[7] = "#ec4899"; tip[7] = "set per QOS"
            name[8] = "Admin";      col[8] = "#94a3b8"; tip[8] = "set by administrators"
            name[9] = "TRES";       col[9] = "#22c55e"; tip[9] = "depends on the resources (CPU, memory, GPUs) requested"
        }
        {
            sum = 0
            for (i = 2; i <= 9; i++) {
                v[i] = 0
                if (i == 9) { n = split($9, t, ","); for (k = 1; k <= n; k++) { split(t[k], kv, "="); v[i] += kv[2] } }
                else v[i] = $i + 0
                if (v[i] > 0) sum += v[i]
            }
            if (sum <= 0) exit
            bar = ""; leg = ""
            for (i = 2; i <= 9; i++) {
                if (v[i] <= 0) continue
                pct = 100 * v[i] / sum
                bar = bar sprintf("<div title=\"%s: %d (%s)\" style=\"width:%.2f%%;background:%s\"></div>", name[i], v[i], tip[i], pct, col[i])
                leg = leg sprintf("<span title=\"%s\" style=\"margin-right:12px;white-space:nowrap\"><span style=\"display:inline-block;width:8px;height:8px;border-radius:2px;background:%s;margin-right:4px\"></span>%s <b>%d</b></span>", tip[i], col[i], name[i], v[i])
            }
            printf "<div style=\"display:flex;height:8px;border-radius:4px;overflow:hidden;background:#e2e8f0;margin:6px 0\">%s</div>", bar
            printf "<div style=\"font-size:var(--drona-text-caption);color:#475569;line-height:1.8\">%s</div>", leg
        }' <<< "$SP")
fi

# ---------------------------------------------------------------- render
case "$SEVERITY" in
    stop) ACCENT="#dc2626"; BG="#fef2f2" ;;
    warn) ACCENT="#d97706"; BG="#fffbeb" ;;
    *)    ACCENT="#2563eb"; BG="#eff6ff" ;;
esac

stat_box() {
    printf '<div style="flex:1 1 150px;min-width:140px;padding:8px 10px;border:1px solid #e2e8f0;border-radius:6px;background:#fff">'
    printf '<div style="font-size:var(--drona-text-caption);color:#64748b;text-transform:uppercase;letter-spacing:.04em">%s</div>' "$1"
    printf '<div style="font-size:var(--drona-text-data);font-weight:600;color:#0f172a;margin-top:2px">%s</div>' "$(escape_html "$2")"
    printf '<div style="font-size:var(--drona-text-caption);color:#64748b;margin-top:1px">%s</div>' "$(escape_html "$3")"
    printf '</div>'
}

REQ="$NNODES node(s) · $NCPUS CPUs · ${MEM} mem"
if [[ -n "$REQTRES" ]]; then
    REQ_MEM=$(grep -oE 'mem=[^,]+' <<< "$REQTRES" | cut -d= -f2)
    REQ_GPU=$(grep -oE 'gres/gpu[^,]*=[0-9]+' <<< "$REQTRES" | head -n 1 | sed 's#gres/##')
    REQ="$NNODES node(s) · $NCPUS CPUs · ${REQ_MEM:-$MEM} memory"
    [[ -n "$REQ_GPU" ]] && REQ+=" · ${REQ_GPU/=/ ×}"
elif [[ -n "$GRES" && "$GRES" != "N/A" && "$GRES" != "(null)" ]]; then
    REQ+=" · $GRES"
fi
REQ+=" · $TLIMIT · partition $PARTS · QOS $QOS"
[[ -n "$RESV" && "$RESV" != "(null)" ]] && REQ+=" · reservation $RESV"

printf '<div style="font-size:var(--drona-text-data);color:#1e293b">'

printf '<div style="border-left:4px solid %s;background:%s;padding:8px 12px;border-radius:4px;margin-bottom:10px">' "$ACCENT" "$BG"
printf '<div style="font-weight:600;color:%s">%s <span style="font-weight:400;color:#64748b;font-size:var(--drona-text-caption)">· Job %s · reason %s</span></div>' \
    "$ACCENT" "$(escape_html "$REASON_TITLE")" "$(escape_html "$ID")" "$(escape_html "$REASON")"
[[ -n "$REASON_TEXT" ]] && printf '<div style="margin-top:3px">%s</div>' "$(escape_html "$REASON_TEXT")"
[[ -n "$REASON_HINT" ]] && printf '<div style="margin-top:3px;color:#475569"><b>What you can do:</b> %s</div>' "$(escape_html "$REASON_HINT")"
[[ -n "$MAINT_NOTE" ]] && printf '<div style="margin-top:3px;color:#b45309"><b>Maintenance:</b> %s</div>' "$(escape_html "$MAINT_NOTE")"
printf '</div>'

printf '<div style="display:flex;flex-wrap:wrap;gap:8px">'
stat_box "Estimated start" "$START_MAIN" "$START_SUB"
stat_box "Queue position" "$RANK_MAIN" "$RANK_SUB"
stat_box "Waiting" "$WAIT_MAIN" "$WAIT_SUB"
stat_box "Priority" "$PRIO" "higher starts earlier"
printf '</div>'

if [[ -n "$FACTORS" ]]; then
    printf '<div style="margin-top:10px"><span style="font-size:var(--drona-text-caption);color:#64748b">Priority made up of</span>%s</div>' "$FACTORS"
fi

printf '<div style="margin-top:8px;font-size:var(--drona-text-caption);color:#64748b">Requested: %s</div>' "$(escape_html "$REQ")"

NOTE="Start estimates assume running jobs use their full time limit, so jobs often start earlier; they can also move later when higher-priority jobs arrive."
LASTEVAL_EPOCH=$(to_epoch "$LASTEVAL")
[[ -n "$LASTEVAL_EPOCH" ]] && NOTE+=" Last evaluated by the scheduler ${SCHEDULER:+(${SCHEDULER%%:*}) }at $(date -d "@$LASTEVAL_EPOCH" +%H:%M)."
printf '<div style="margin-top:4px;font-size:var(--drona-text-caption);color:#94a3b8">%s Updated %s.</div>' "$(escape_html "$NOTE")" "$(date +%H:%M:%S)"

printf '</div>\n'
