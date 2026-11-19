#!/bin/bash
# How a finished job ended: outcome in plain language with a hint, the exit
# code explained, steps that failed, the first error line found in its log,
# the timeline (queue wait, run time, share of the time limit used) and
# workflow jobs that will never run because of it.
#
# Params:
#   JOBID - the selected job ($drona_job_scope). Empty: the first job of JOBS.
#   JOBS  - the workflow's jobs ($drona_info_jobs), for the dependency check.
#
# Cost (see md-files/finished-job-insights-cost.md): meant to be fetched once
# (no refreshInterval). Slurm is only asked about this job and the workflow's
# own jobs (sacct -j, squeue -j); partition/node/user lookups run only for the
# states they explain; the log scan reads at most the first 64 KB and the last
# 1 MB of one file, under a 2 s timeout.

JOBID="${JOBID//[^0-9_]/}"
read -ra JOB_LIST <<< "${JOBS//,/ }"
[[ -n "$JOBID" ]] || JOBID="${JOB_LIST[0]//[^0-9_]/}"
[[ -n "$JOBID" ]] || exit 0

source "$DRONA_RUNTIME_DIR/schedulers/slurm/drona_job_line.sh" 2>/dev/null \
    || { exit_meaning() { echo "exit $1"; }; human_duration() { echo "${1}s"; }; }

escape_html() {
    local s=$1
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

to_epoch() { [[ "$1" =~ ^[0-9]{4}- ]] && date -d "$1" +%s 2>/dev/null; }
fmt_when() { date -d "@$1" +'%a %b %-d, %H:%M'; }

# Slurm duration (D-HH:MM:SS, HH:MM:SS, MM:SS) -> seconds
dur_seconds() {
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
FIELDS="JobID,State,ExitCode,DerivedExitCode,Submit,Start,End,Elapsed,Timelimit,Partition,NodeList,Restarts,ReqMem,StdErr,StdOut,WorkDir,User,JobName"
REC=$(sacct -j "$JOBID" -X -n -P -o "$FIELDS" 2>/dev/null | head -n 1)
if [[ -z "$REC" ]]; then
    echo "<div style=\"font-size:var(--drona-text-caption);color:#64748b\">No accounting record for job $(escape_html "$JOBID") yet; it can take a minute after the job ends. Checked $(date +%H:%M:%S).</div>"
    exit 0
fi
IFS='|' read -r ID STATE EXITC DERIVED SUBMIT START END ELAPSED TLIMIT PART NODES RESTARTS REQMEM STDERR STDOUT WORKDIR JUSER NAME <<< "$REC"
BASE_STATE=${STATE%% *}

# Steps that did not end COMPLETED 0:0 (extern skipped; output capped)
FAILED_STEPS=$(sacct -j "$JOBID" -n -P -o JobID,State,ExitCode,MaxRSS,NodeList 2>/dev/null | head -n 200 | awk -F'|' '
    $1 !~ /\./ || $1 ~ /\.extern$/ { next }
    $2 == "COMPLETED" && $3 == "0:0" { next }
    { split($1, a, "."); print a[2] "|" $2 "|" $3 "|" $4 "|" $5 }')

# 3145728K -> 3.0 GB
human_size() {
    awk -v v="$1" 'BEGIN {
        if (v == "") { print ""; exit }
        u = substr(v, length(v)); n = v + 0
        f["K"] = 1024; f["M"] = 1048576; f["G"] = 1073741824; f["T"] = 1099511627776
        b = (u in f) ? n * f[u] : n
        if (b >= 1073741824) printf "%.1f GB\n", b / 1073741824
        else if (b >= 1048576) printf "%.0f MB\n", b / 1048576
        else printf "%.0f KB\n", b / 1024
    }'
}

# ---------------------------------------------------------------- outcome text
TITLE=""; TEXT=""; HINT=""; SEVERITY="ok"
case "$BASE_STATE" in
    COMPLETED)
        TITLE="Finished successfully"
        TEXT="The job script ended with exit code 0."
        if [[ -n "$DERIVED" && "$DERIVED" != "0:0" ]]; then
            SEVERITY="warn"
            TITLE="Finished, but a step reported an error"
            TEXT="The job script ended with exit code 0, but at least one step did not ($(exit_meaning "$DERIVED")). The script may have carried on after a failed command."
            HINT="Check the failed step below and the error log; add 'set -e' to stop the script at the first failing command."
        fi ;;
    FAILED)
        SEVERITY="stop"; TITLE="Failed"
        TEXT="The job script ended with $(exit_meaning "$EXITC")."
        case "${EXITC%%:*}" in
            127) HINT="A command was not found. Often a missing 'module load' or a typo in the command or path." ;;
            126) HINT="A file was run as a command but is not executable (chmod +x) or is not a program." ;;
            137) HINT="Killed with SIGKILL, usually for using more memory than requested. Check the memory numbers in Job Resources." ;;
            139) HINT="The program crashed (segmentation fault): a bug, a library mismatch or too small a stack. Check the modules it was built with." ;;
            *)   HINT="See the error line below and the Job Logs card for the program's own message." ;;
        esac ;;
    OUT_OF_MEMORY)
        SEVERITY="stop"; TITLE="Ran out of memory"
        PEAK=$(awk -F'|' '$2 == "OUT_OF_MEMORY" { print $4; exit }' <<< "$FAILED_STEPS")
        TEXT="A step used all the memory it was given and was killed"
        [[ -n "$PEAK" ]] && TEXT+=" (peak $(human_size "$PEAK")"
        [[ -n "$PEAK" && -n "$REQMEM" ]] && TEXT+=" of $REQMEM requested"
        [[ -n "$PEAK" ]] && TEXT+=")"
        TEXT+="."
        HINT="Request more memory (--mem), e.g. 1.5 to 2 times the current request, or reduce what the program keeps in memory (smaller batches, fewer threads)." ;;
    TIMEOUT)
        SEVERITY="stop"; TITLE="Hit its time limit"
        TEXT="The job ran for its full time limit ($TLIMIT) and was stopped."
        PMAX=$(scontrol show partition "${PART%%,*}" -o 2>/dev/null | grep -oE 'MaxTime=[^ ]+' | cut -d= -f2)
        HINT="Request more time (--time)"
        [[ -n "$PMAX" && "$PMAX" != "UNLIMITED" ]] && HINT+="; partition ${PART%%,*} allows up to $PMAX"
        HINT+=". For long runs, use the program's checkpoint/restart so a new job can continue." ;;
    CANCELLED)
        SEVERITY="warn"; TITLE="Cancelled"
        BY=${STATE#CANCELLED}; BY=${BY# by }
        if [[ -n "$BY" ]]; then
            if [[ "$BY" == "$(id -u)" ]]; then WHO="you"
            else WHO=$(timeout 2 getent passwd "$BY" 2>/dev/null | cut -d: -f1); WHO=${WHO:-uid $BY}
            fi
            TITLE="Cancelled by $WHO"
        fi
        if [[ -z "$(to_epoch "$START")" ]]; then
            TEXT="The job was cancelled while it was still pending; it never ran."
        else
            TEXT="The job was cancelled while running, after $ELAPSED."
        fi ;;
    NODE_FAIL|BOOT_FAIL)
        SEVERITY="warn"; TITLE="A node failed"
        TEXT="A node the job ran on ($NODES) failed. This was not caused by the job."
        DOWN=$(sinfo -n "$NODES" -h -o "%n %T" 2>/dev/null | awk '$2 ~ /down|drain|fail|maint/ { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
        [[ -n "$DOWN" ]] && TEXT+=" Still unavailable: $DOWN."
        HINT="Resubmit the job." ;;
    PREEMPTED)
        SEVERITY="warn"; TITLE="Preempted"
        TEXT="The job was stopped to make room for a higher-priority job."
        HINT="Resubmit, or use a partition or QOS without preemption." ;;
    DEADLINE)
        SEVERITY="stop"; TITLE="Missed its deadline"
        TEXT="The job could not finish before its --deadline." ;;
    *)
        SEVERITY="warn"; TITLE="$STATE"
        TEXT="Slurm reports the job as $STATE ($(exit_meaning "$EXITC"))." ;;
esac

# ---------------------------------------------------------------- first error line
# The job's own log files only, bounded: first 64 KB + last 1 MB, 2 s timeout.
expand_log_path() {
    local p=$1 arr=${ID%%_*} task=""
    [[ "$ID" == *_* ]] && task=${ID#*_}
    [[ -z "$p" || "$p" == "(null)" ]] && return
    p=${p//%%/$'\x01'}
    p=${p//%A/$arr}; p=${p//%a/$task}; p=${p//%j/$ID}; p=${p//%J/$ID}
    p=${p//%x/$NAME}; p=${p//%u/$JUSER}; p=${p//%N/${NODES%%[,\[]*}}
    p=${p//$'\x01'/%}
    [[ "$p" == /* ]] || p="$WORKDIR/$p"
    printf '%s' "$p"
}

ERR_FILE=$(expand_log_path "$STDERR")
OUT_FILE=$(expand_log_path "$STDOUT")
LOG_HIT=""; LOG_WHAT=""; LOG_FILE=""
scan_log() {
    local f=$1 size chunk
    [[ -n "$f" && -r "$f" ]] || return 1
    size=$(timeout 2 stat -c %s "$f" 2>/dev/null) || return 1
    if (( size <= 1114112 )); then
        chunk=$(timeout 2 cat "$f" 2>/dev/null)
    else
        chunk=$(timeout 2 head -c 65536 "$f" 2>/dev/null; echo; timeout 2 tail -c 1048576 "$f" 2>/dev/null)
    fi
    [[ -n "$chunk" ]] || return 1
    local pat label line
    while IFS='|' read -r label pat; do
        line=$(grep -m1 -aiE "$pat" <<< "$chunk")
        if [[ -n "$line" ]]; then
            LOG_WHAT=$label; LOG_HIT=${line:0:240}; LOG_FILE=$f
            return 0
        fi
    done <<'PATTERNS'
GPU out of memory|CUDA out of memory|CUDA error: out of memory|OutOfMemoryError
Killed for using too much memory|oom-kill|oom_kill|Out of memory|Exceeded job memory limit
Time limit reached|DUE TO TIME LIMIT
Segmentation fault|segfault|SIGSEGV
Module error|Lmod has detected the following error|Unable to locate a modulefile|module: command not found
Command not found|command not found
Missing Python package|ModuleNotFoundError|No module named|ImportError
Disk full or quota exceeded|Disk quota exceeded|No space left on device
Permission problem|Permission denied
Missing file|No such file or directory
MPI error|MPI_ABORT|PMIX ERROR|mpirun noticed
PATTERNS
    # Python: the last "SomethingError: ..." line is the one that matters
    line=$(grep -aE '^[A-Za-z_][A-Za-z0-9_.]*(Error|Exception)(:|$)' <<< "$chunk" | tail -n 1)
    if [[ -n "$line" ]]; then
        LOG_WHAT="Python error"; LOG_HIT=${line:0:240}; LOG_FILE=$f
        return 0
    fi
    return 1
}
scan_log "$ERR_FILE" || { [[ "$OUT_FILE" != "$ERR_FILE" ]] && scan_log "$OUT_FILE"; }
[[ -z "$LOG_HIT" && "$HINT" == "See the error line below"* ]] && HINT="Check the Job Logs card for the program's own error message."

# ---------------------------------------------------------------- timeline
SUBMIT_E=$(to_epoch "$SUBMIT"); START_E=$(to_epoch "$START"); END_E=$(to_epoch "$END")
QUEUE_MAIN="—"; QUEUE_SUB=""
RUN_MAIN="—"; RUN_SUB=""
LIMIT_MAIN="—"; LIMIT_SUB="time limit $TLIMIT"
if [[ -n "$SUBMIT_E" && -n "$START_E" ]]; then
    QUEUE_MAIN=$(human_duration $(( START_E - SUBMIT_E )))
    QUEUE_SUB="submitted $(fmt_when "$SUBMIT_E")"
elif [[ -n "$SUBMIT_E" ]]; then
    QUEUE_MAIN="never started"; QUEUE_SUB="submitted $(fmt_when "$SUBMIT_E")"
fi
EL_S=$(dur_seconds "$ELAPSED"); TL_S=$(dur_seconds "$TLIMIT")
if [[ -n "$START_E" ]]; then
    RUN_MAIN=$(human_duration "$EL_S")
    [[ -n "$END_E" ]] && RUN_SUB="ended $(fmt_when "$END_E")"
    if (( TL_S > 0 )); then
        PCT=$(( 100 * EL_S / TL_S ))
        LIMIT_MAIN="$PCT %"
        (( PCT == 0 )) && LIMIT_MAIN="< 1 %"
    fi
fi

# ---------------------------------------------------------------- workflow effect
BLOCKED=""
if [[ "$BASE_STATE" != "COMPLETED" ]]; then
    for J in "${JOB_LIST[@]}"; do
        J=${J//[^0-9_]/}
        [[ -n "$J" && "$J" != "$ID" && "$J" != "$JOBID" ]] || continue
        L=$(squeue -j "$J" -h -o "%i|%r|%E" 2>/dev/null | head -n 1)
        [[ -n "$L" ]] || continue
        IFS='|' read -r BJ BR BE <<< "$L"
        if [[ "$BR" == "DependencyNeverSatisfied" || ( "$BR" == "Dependency" && "$BE" == *"$ID"* ) ]]; then
            BLOCKED+="${BLOCKED:+, }$BJ"
        fi
    done
fi

# ---------------------------------------------------------------- render
case "$SEVERITY" in
    stop) ACCENT="#dc2626"; BG="#fef2f2" ;;
    warn) ACCENT="#d97706"; BG="#fffbeb" ;;
    *)    ACCENT="#059669"; BG="#ecfdf5" ;;
esac

stat_box() {
    printf '<div style="flex:1 1 150px;min-width:140px;padding:8px 10px;border:1px solid #e2e8f0;border-radius:6px;background:#fff">'
    printf '<div style="font-size:var(--drona-text-caption);color:#64748b;text-transform:uppercase;letter-spacing:.04em">%s</div>' "$1"
    printf '<div style="font-size:var(--drona-text-data);font-weight:600;color:#0f172a;margin-top:2px">%s</div>' "$(escape_html "$2")"
    printf '<div style="font-size:var(--drona-text-caption);color:#64748b;margin-top:1px">%s</div>' "$(escape_html "$3")"
    printf '</div>'
}

printf '<div style="font-size:var(--drona-text-data);color:#1e293b">'

printf '<div style="border-left:4px solid %s;background:%s;padding:8px 12px;border-radius:4px;margin-bottom:10px">' "$ACCENT" "$BG"
printf '<div style="font-weight:600;color:%s">%s <span style="font-weight:400;color:#64748b;font-size:var(--drona-text-caption)">· Job %s · %s · exit code %s</span></div>' \
    "$ACCENT" "$(escape_html "$TITLE")" "$(escape_html "$ID")" "$(escape_html "$STATE")" "$(escape_html "$EXITC")"
[[ -n "$TEXT" ]] && printf '<div style="margin-top:3px">%s</div>' "$(escape_html "$TEXT")"
[[ -n "$HINT" ]] && printf '<div style="margin-top:3px;color:#475569"><b>What you can do:</b> %s</div>' "$(escape_html "$HINT")"
[[ -n "$BLOCKED" ]] && printf '<div style="margin-top:3px;color:#b91c1c"><b>Workflow:</b> %s</div>' \
    "$(escape_html "Job(s) $BLOCKED depend on this job and will never start. Cancel them, fix the problem, and rerun the workflow.")"
printf '</div>'

if [[ -n "$LOG_HIT" ]]; then
    printf '<div style="margin-bottom:10px">'
    printf '<div style="font-size:var(--drona-text-caption);color:#64748b">%s · first match in <span style="font-family:var(--drona-font-mono)">%s</span></div>' \
        "$(escape_html "$LOG_WHAT")" "$(escape_html "${LOG_FILE##*/}")"
    printf '<div style="font-family:var(--drona-font-mono);font-size:var(--drona-text-caption);background:#f8fafc;border:1px solid #e2e8f0;border-radius:4px;padding:4px 8px;margin-top:2px;white-space:pre-wrap;word-break:break-all">%s</div>' \
        "$(escape_html "$LOG_HIT")"
    printf '</div>'
fi

if [[ -n "$FAILED_STEPS" ]]; then
    printf '<div style="margin-bottom:10px;font-size:var(--drona-text-caption)"><div style="color:#64748b">Steps that did not succeed</div>'
    N_FAILED=$(wc -l <<< "$FAILED_STEPS")
    while IFS='|' read -r S_ID S_STATE S_EXIT S_RSS S_NODES; do
        printf '<div>step <b>%s</b> · %s · %s%s · %s</div>' "$(escape_html "$S_ID")" "$(escape_html "$S_STATE")" \
            "$(escape_html "$(exit_meaning "$S_EXIT")")" \
            "$([[ -n "$S_RSS" ]] && printf ' · peak memory %s' "$(human_size "$S_RSS")")" "$(escape_html "$S_NODES")"
    done < <(head -n 5 <<< "$FAILED_STEPS")
    (( N_FAILED > 5 )) && printf '<div style="color:#64748b">and %d more step(s)</div>' $(( N_FAILED - 5 ))
    printf '</div>'
fi

printf '<div style="display:flex;flex-wrap:wrap;gap:8px">'
stat_box "Waited in queue" "$QUEUE_MAIN" "$QUEUE_SUB"
stat_box "Ran for" "$RUN_MAIN" "$RUN_SUB"
stat_box "Time limit used" "$LIMIT_MAIN" "$LIMIT_SUB"
printf '</div>'


EXTRA="Partition $PART · nodes ${NODES:-none}"
[[ "$RESTARTS" =~ ^[0-9]+$ ]] && (( RESTARTS > 0 )) && EXTRA+=" · requeued $RESTARTS time(s)"
printf '<div style="margin-top:8px;font-size:var(--drona-text-caption);color:#64748b">%s</div>' "$(escape_html "$EXTRA")"
printf '<div style="margin-top:4px;font-size:var(--drona-text-caption);color:#94a3b8">Checked %s. A finished job does not change; use refresh after a rerun.</div>' "$(date +%H:%M:%S)"

printf '</div>\n'
