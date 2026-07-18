#!/usr/bin/env bash
###############################################################################
# common_lib.sh
#
# Shared library used by run_daily.sh / run_weekly.sh / run_fourweekly.sh /
# run_monthly.sh
#
# Responsibilities:
#   1. Read the OFSAA batch date from BATCH_DATE_FILE
#   2. Provide date-condition checks (Friday / last Friday / last day of month)
#   3. Provide a resumable task-runner engine:
#        - Tasks live in a master ".conf" file (one shell command per line)
#        - On first run for a given batch date, the master file is copied to
#          a per-date "run" file under the log folder for that date.
#        - The runner walks the per-date run file top to bottom, skipping
#          blank lines and lines starting with '#'.
#        - The first task that fails stops the whole script immediately.
#          The failure (and everything completed before it) is written to
#          the log file.
#        - To resume: open the per-date run file, put a '#' in front of
#          every task that is confirmed OK (already done / verified), fix
#          whatever caused the failure, then re-run the wrapper script.
#          Commented lines are skipped, execution continues from the next
#          uncommented line. The master .conf file itself is never touched,
#          so tomorrow's / next week's run always starts from a clean copy.
#        - When every line in the run file has completed successfully, a
#          SUCCESS marker is written for that date, and further runs on the
#          same date are treated as already-done (use --force to redo).
###############################################################################

set -u

# ---------------------------------------------------------------------------
# Global configuration (shared across all wrapper scripts)
# ---------------------------------------------------------------------------
BATCH_DATE_FILE="/u02/OFSAA/Scripts/Batch_date/current_batch_date.txt"
LOG_BASE_DIR="/u02/OFSAA/scripts/logs"

# ---------------------------------------------------------------------------
# Logging helper. Writes to both stdout and the run's log file (once
# LOG_FILE is set by init_run_dirs).
# ---------------------------------------------------------------------------
log() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[$ts] $msg" | tee -a "$LOG_FILE"
    else
        echo "[$ts] $msg"
    fi
}

die() {
    log "ERROR: $1"
    exit 1
}

# Portable uppercase (avoids ${var^^} which needs bash 4+)
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# ---------------------------------------------------------------------------
# Read and parse the batch date from BATCH_DATE_FILE.
# Sets globals: BATCH_DATE_RAW (as read from file), BATCH_DATE (YYYYMMDD,
# same as raw once validated), and BATCH_YEAR / BATCH_MONTH / BATCH_DAY
# (integers, used by the pure-arithmetic date-condition functions below).
#
# FORMAT: the file is expected to contain exactly one date in YYYYMMDD
# format (e.g. 20260718). This is validated strictly using bash arithmetic
# only - no external 'date -d' call, since -d is a GNU coreutils extension
# not available on Solaris/AIX/HP-UX/BusyBox date. Anything not matching
# YYYYMMDD, or not a real calendar date, aborts with a clear error.
# ---------------------------------------------------------------------------
parse_batch_date() {
    [[ -f "$BATCH_DATE_FILE" ]] || die "Batch date file not found: $BATCH_DATE_FILE"

    BATCH_DATE_RAW=$(head -n 1 "$BATCH_DATE_FILE" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$BATCH_DATE_RAW" ]] || die "Batch date file is empty: $BATCH_DATE_FILE"

    if [[ ! "$BATCH_DATE_RAW" =~ ^[0-9]{8}$ ]]; then
        die "Batch date '$BATCH_DATE_RAW' in $BATCH_DATE_FILE is not in the expected YYYYMMDD format."
    fi

    BATCH_YEAR=$((10#${BATCH_DATE_RAW:0:4}))
    BATCH_MONTH=$((10#${BATCH_DATE_RAW:4:2}))
    BATCH_DAY=$((10#${BATCH_DATE_RAW:6:2}))

    if [[ $BATCH_MONTH -lt 1 || $BATCH_MONTH -gt 12 ]]; then
        die "Batch date '$BATCH_DATE_RAW' in $BATCH_DATE_FILE has an invalid month."
    fi

    local dim
    dim=$(days_in_month "$BATCH_YEAR" "$BATCH_MONTH")
    if [[ $BATCH_DAY -lt 1 || $BATCH_DAY -gt $dim ]]; then
        die "Batch date '$BATCH_DATE_RAW' in $BATCH_DATE_FILE is not a valid calendar date."
    fi

    # BATCH_DATE is used as the log-folder name; keep it as the validated
    # YYYYMMDD string.
    BATCH_DATE="$BATCH_DATE_RAW"
}

# ---------------------------------------------------------------------------
# Pure-arithmetic date helpers (no external 'date -d' dependency, so these
# work identically on GNU/Linux, Solaris, AIX, HP-UX, BusyBox, etc.)
# ---------------------------------------------------------------------------

# is_leap_year <year>
is_leap_year() {
    local y=$1
    (( (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) ))
}

# days_in_month <year> <month>  -> echoes the number of days
days_in_month() {
    local y=$1 m=$2
    local -a dim=(31 28 31 30 31 30 31 31 30 31 30 31)
    if [[ $m -eq 2 ]] && is_leap_year "$y"; then
        echo 29
    else
        echo "${dim[$((m-1))]}"
    fi
}

# day_of_week <year> <month> <day> -> echoes 0=Sunday .. 6=Saturday
# Implementation: Zeller's congruence (Gregorian calendar).
day_of_week() {
    local y=$1 m=$2 d=$3
    if [[ $m -lt 3 ]]; then
        m=$((m + 12))
        y=$((y - 1))
    fi
    local K=$((y % 100))
    local J=$((y / 100))
    local h=$(( (d + (13*(m+1))/5 + K + K/4 + J/4 + 5*J) % 7 ))
    # h: 0=Saturday,1=Sunday,2=Monday,3=Tuesday,4=Wednesday,5=Thursday,6=Friday
    # Convert to standard 0=Sunday .. 6=Saturday
    echo $(( (h + 6) % 7 ))
}

is_friday() {
    local dow
    dow=$(day_of_week "$BATCH_YEAR" "$BATCH_MONTH" "$BATCH_DAY")
    [[ $dow -eq 5 ]]
}

is_last_friday_of_month() {
    is_friday || return 1
    local dim
    dim=$(days_in_month "$BATCH_YEAR" "$BATCH_MONTH")
    # last Friday of the month if there is no Friday 7 days later still in this month
    [[ $((BATCH_DAY + 7)) -gt $dim ]]
}

is_last_day_of_month() {
    local dim
    dim=$(days_in_month "$BATCH_YEAR" "$BATCH_MONTH")
    [[ $BATCH_DAY -eq $dim ]]
}

# ---------------------------------------------------------------------------
# init_run_dirs <run_type>
#   Sets up the per-date log directory and the global LOG_FILE / RUN_FILE /
#   SUCCESS_MARKER / LOCK_DIR paths. Requires BATCH_DATE to be set already.
# ---------------------------------------------------------------------------
init_run_dirs() {
    local run_type="$1"
    LOG_DIR="${LOG_BASE_DIR}/${BATCH_DATE}"
    mkdir -p "$LOG_DIR" || die "Could not create log directory: $LOG_DIR"

    LOG_FILE="${LOG_DIR}/${run_type}_run.log"
    RUN_FILE="${LOG_DIR}/${run_type}_tasks_run.conf"
    SUCCESS_MARKER="${LOG_DIR}/${run_type}.SUCCESS"
    LOCK_DIR="${LOG_DIR}/${run_type}.lockdir"
}

# ---------------------------------------------------------------------------
# acquire_lock <lockdir>
#   Portable single-instance lock using 'mkdir', which is atomic on every
#   POSIX filesystem. Deliberately NOT using 'flock' - that command is part
#   of GNU util-linux and is not available on Solaris, AIX, or HP-UX.
#   If a lock directory already exists, checks whether the PID recorded
#   inside it is still alive; a lock left behind by a crashed/killed
#   process is treated as stale and cleared automatically.
#   Registers a trap so the lock is released on any exit (success, error,
#   or signal).
# ---------------------------------------------------------------------------
acquire_lock() {
    local lockdir="$1"

    if mkdir "$lockdir" 2>/dev/null; then
        echo $$ >"$lockdir/pid" 2>/dev/null
        trap 'rm -rf "'"$lockdir"'"' EXIT INT TERM
        return 0
    fi

    # lock dir already exists - is it stale (owning process no longer alive)?
    local old_pid=""
    [[ -f "$lockdir/pid" ]] && old_pid=$(cat "$lockdir/pid" 2>/dev/null)

    if [[ -n "$old_pid" ]] && ! kill -0 "$old_pid" 2>/dev/null; then
        log "Found stale lock (dir: $lockdir, pid: $old_pid no longer running) - clearing it."
        rm -rf "$lockdir"
        if mkdir "$lockdir" 2>/dev/null; then
            echo $$ >"$lockdir/pid" 2>/dev/null
            trap 'rm -rf "'"$lockdir"'"' EXIT INT TERM
            return 0
        fi
    fi

    return 1
}

# ---------------------------------------------------------------------------
# run_tasks <master_task_conf_file> <run_type>
#   The resumable task-runner engine. See header comment for behaviour.
# ---------------------------------------------------------------------------
run_tasks() {
    local master_file="$1"
    local run_type="$2"

    [[ -f "$master_file" ]] || die "Master task file not found: $master_file"

    # ---- single-instance lock for this run_type + date ----
    if ! acquire_lock "$LOCK_DIR"; then
        die "Another instance of ${run_type} run for ${BATCH_DATE} is already in progress (lock: $LOCK_DIR)."
    fi

    # ---- already fully completed for this date? ----
    if [[ -f "$SUCCESS_MARKER" && "${FORCE_RERUN:-0}" != "1" ]]; then
        log "${run_type}: all tasks already completed successfully for batch date ${BATCH_DATE}."
        log "  (marker: $SUCCESS_MARKER). Use --force to re-run anyway."
        exit 0
    fi

    # ---- create the per-date working copy of the task list, if needed ----
    if [[ ! -f "$RUN_FILE" ]]; then
        cp "$master_file" "$RUN_FILE" || die "Could not create run file: $RUN_FILE"
        log "${run_type}: created new per-date task list: $RUN_FILE"
    else
        log "${run_type}: resuming existing per-date task list: $RUN_FILE"
    fi

    log "=============================================================="
    log "$(to_upper "$run_type") run starting for batch date ${BATCH_DATE} (raw: ${BATCH_DATE_RAW})"
    log "Task list : $RUN_FILE"
    log "Log file  : $LOG_FILE"
    log "=============================================================="

    local total remaining
    total=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$RUN_FILE" | wc -l)
    log "Tasks pending in run file: $total"

    local task_num=0
    local line trimmed rc

    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # skip blanks and commented/completed lines
        [[ -z "$trimmed" ]] && continue
        [[ "$trimmed" == \#* ]] && continue

        task_num=$((task_num + 1))
        log "----> [$task_num/$total] START: $trimmed"

        # shellcheck disable=SC2086
        eval "$trimmed" >>"$LOG_FILE" 2>&1
        rc=$?

        if [[ $rc -ne 0 ]]; then
            log "----> [$task_num/$total] FAILED (exit code $rc): $trimmed"
            log "=============================================================="
            log "$(to_upper "$run_type") run HALTED for batch date ${BATCH_DATE}."
            log "Completed successfully: $((task_num - 1)) task(s) above this line."
            log "Failed task            : $trimmed"
            log ""
            log "TO RESUME:"
            log "  1. Investigate/fix the cause of the failure."
            log "  2. Edit: $RUN_FILE"
            log "     - Put '#' in front of any task line already confirmed complete."
            log "     - Leave the failed task (and everything after it) uncommented."
            log "  3. Re-run this wrapper script. It will skip commented lines and"
            log "     resume from the next uncommented task."
            log "=============================================================="
            exit 1
        fi

        log "----> [$task_num/$total] SUCCESS: $trimmed"
    done <"$RUN_FILE"

    touch "$SUCCESS_MARKER"
    log "=============================================================="
    log "$(to_upper "$run_type") run COMPLETED SUCCESSFULLY for batch date ${BATCH_DATE}. ($task_num task(s) executed)"
    log "=============================================================="
}
