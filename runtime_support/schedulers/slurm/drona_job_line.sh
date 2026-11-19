# One-line explanations of a job's state, shared by the Slurm jobs card and
# table retrievers (and the outcome card's exit-code text). Source it, then:
#   pending_line REASON START DEPS   (squeue %r, %S, %E)
#     -> "Waiting for higher-priority jobs · est. start in 2 h 3 min (Thu 06:30)"
#   outcome_line STATE EXITCODE      (sacct State, ExitCode)
#     -> "Ran out of memory" / "Failed: exit 127, command not found"; empty for a
#        successful job
#   exit_meaning EXITCODE            -> "exit 127, command not found"
# No extra Slurm calls: everything comes from the caller's squeue/sacct line.
# Labels match the titles of the detailed cards (drona_slurm_pending.sh,
# drona_slurm_outcome.sh).

# 7380 -> "2 h 3 min"
human_duration() {
    local s=$1
    if (( s >= 86400 )); then echo "$(( s / 86400 )) d $(( s % 86400 / 3600 )) h"
    elif (( s >= 3600 )); then echo "$(( s / 3600 )) h $(( s % 3600 / 60 )) min"
    elif (( s >= 60 )); then echo "$(( s / 60 )) min"
    else echo "< 1 min"
    fi
}

# Short reason label (REASON from squeue %r, DEPS from %E)
pending_reason() {
    local r=$1 deps=$2
    case "$r" in
        Priority)  echo "Waiting for higher-priority jobs" ;;
        Resources) echo "Next in line, waiting for resources" ;;
        None)      echo "Not evaluated by the scheduler yet" ;;
        Dependency)
            deps=$(sed -E 's/\(unfulfilled\)//g; s/,/, /g' <<< "$deps")
            echo "Waiting for other jobs ($deps)" ;;
        DependencyNeverSatisfied) echo "Dependency can never be met: cancel and resubmit" ;;
        JobHeldUser)  echo "Held by you (scontrol release)" ;;
        JobHeldAdmin) echo "Held by an administrator" ;;
        BeginTime)    echo "Scheduled for later (--begin)" ;;
        BadConstraints) echo "Request cannot be satisfied: cancel and resubmit" ;;
        PartitionTimeLimit|*MaxWallDurationPerJobLimit) echo "Time limit too long for the partition/QOS" ;;
        PartitionDown|PartitionInactive) echo "Partition unavailable" ;;
        Reservation)  echo "Waiting for its reservation" ;;
        ReqNodeNotAvail*) echo "Needed nodes unavailable (down, drained or reserved)" ;;
        QOS*Min*|Assoc*Min*)
            if [[ "$r" == *RunMin* ]]; then echo "Running-job budget reached"; else echo "Allocation used up"; fi ;;
        QOS*|Assoc*)  echo "Usage limit reached ($r)" ;;
        *)            echo "$r" ;;
    esac
}

pending_line() {
    local why start_epoch now
    why=$(pending_reason "$1" "$3")
    if [[ "$2" =~ ^[0-9]{4}- ]] && start_epoch=$(date -d "$2" +%s 2>/dev/null); then
        now=$(date +%s)
        if (( start_epoch > now )); then
            why+=" · est. start in $(human_duration $(( start_epoch - now ))) ($(date -d "@$start_epoch" +'%a %H:%M'))"
        else
            why+=" · est. start: any moment"
        fi
    fi
    printf '%s' "$why"
}

# sacct ExitCode "code:signal" -> short meaning
exit_meaning() {
    local code=${1%%:*} sig=${1#*:}
    [[ "$1" == *:* ]] || sig=0
    [[ $code =~ ^[0-9]+$ ]] || code=0
    [[ $sig =~ ^[0-9]+$ ]] || sig=0
    if (( sig == 125 )); then
        echo "killed by Slurm for exceeding its memory"
        return
    elif (( sig > 0 )); then
        echo "killed by signal $sig$(signal_name "$sig")"
        return
    fi
    case $code in
        0)   echo "exit 0" ;;
        1)   echo "exit 1, general error" ;;
        2)   echo "exit 2, invalid arguments or shell usage" ;;
        126) echo "exit 126, command not executable" ;;
        127) echo "exit 127, command not found" ;;
        *)
            if (( code > 128 && code < 160 )); then
                echo "exit $code, killed by signal $(( code - 128 ))$(signal_name $(( code - 128 )))"
            else
                echo "exit $code"
            fi ;;
    esac
}

signal_name() {
    case $1 in
        1)  echo " (SIGHUP)" ;;
        2)  echo " (SIGINT, interrupted)" ;;
        6)  echo " (SIGABRT, aborted)" ;;
        7)  echo " (SIGBUS, bus error)" ;;
        8)  echo " (SIGFPE, arithmetic error)" ;;
        9)  echo " (SIGKILL, often memory or time limit)" ;;
        11) echo " (SIGSEGV, segmentation fault)" ;;
        15) echo " (SIGTERM, time limit or cancel)" ;;
    esac
}

outcome_line() {
    local state=$1 exitc=$2
    case "$state" in
        COMPLETED*)
            [[ "$exitc" == "0:0" || -z "$exitc" ]] && return
            echo "Completed, $(exit_meaning "$exitc")" ;;
        FAILED*)        echo "Failed: $(exit_meaning "$exitc")" ;;
        OUT_OF_MEMORY*) echo "Ran out of memory: request more with --mem" ;;
        TIMEOUT*)       echo "Hit its time limit" ;;
        CANCELLED\ by\ *)
            if [[ "${state##* }" == "$(id -u)" ]]; then echo "Cancelled by you"
            else echo "Cancelled by another user or an administrator"
            fi ;;
        CANCELLED*)     echo "Cancelled" ;;
        NODE_FAIL*)     echo "A node failed (not caused by the job): resubmit" ;;
        BOOT_FAIL*)     echo "A node failed to boot (not caused by the job): resubmit" ;;
        PREEMPTED*)     echo "Preempted by a higher-priority job" ;;
        DEADLINE*)      echo "Could not finish before its --deadline" ;;
        *)              echo "$state" ;;
    esac
}
