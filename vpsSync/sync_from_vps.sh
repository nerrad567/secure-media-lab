#!/bin/bash
set -euo pipefail

# =============================================================================
# Setup & Check for Lock File
# =============================================================================
LOCK_FILE="/tmp/$(basename "$0").lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Another instance of $(basename "$0") is already running. Exiting."; exit 1; }

# =============================================================================
# Configuration Variables
# =============================================================================
# Default ENV_FILE path; can be overridden by environment or command-line arg
ENV_FILE="${ENV_FILE:-/path/to/.env}"

# Load environment variables from .env file
if [[ -f "$ENV_FILE" ]]; then
    source <(sed 's/\r$//' "$ENV_FILE")
else
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# Validate required variables
: "${QB_USER:?ERROR: QB_USER not set in $ENV_FILE}"
: "${QB_PASS:?ERROR: QB_PASS not set in $ENV_FILE}"
: "${QB_HOST:?ERROR: QB_HOST not set in $ENV_FILE}"
: "${REMOTE_HOST:?ERROR: REMOTE_HOST not set in $ENV_FILE}"
: "${REMOTE_BASE:?ERROR: REMOTE_BASE not set in $ENV_FILE}"
: "${LOCAL_BASE:?ERROR: LOCAL_BASE not set in $ENV_FILE}"
: "${LOG_DIR:?ERROR: LOG_DIR not set in $ENV_FILE}"
: "${SSH_KEY:?ERROR: SSH_KEY not set in $ENV_FILE}"

# Other configuration variables
DIRS=("ebooks" "manual" "movies" "music" "tv")               # Subdirectories to sync
TRACKER_FILE="$LOG_DIR/sync_tracker.txt"                    # File to persist torrent status info
MAIN_LOG_FILE="$LOG_DIR/sync.log"                           # Main log file

# RSYNC Options
DRY_RUN=""
RSYNC_OPTS="-az --progress --partial --append-verify $DRY_RUN"
RSYNC_RSH="ssh -i $SSH_KEY"

# Log Rotation and Retention Settings
MAX_LOG_SIZE=10485760  # 10 MB
LOG_RETENTION_DAYS=365

# Toggle Debugging
DEBUG=${DEBUG:-0}

# =============================================================================
# Debug and Error Handling Functions
# =============================================================================
debug() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo "DEBUG: $*"
    fi
}

error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# =============================================================================
# Log Rotation Function
# =============================================================================
rotate_logs() {
    debug "=== Checking if log rotation is needed ==="
    if [[ -f "$MAIN_LOG_FILE" ]]; then
        local filesize
        filesize=$(stat -c%s "$MAIN_LOG_FILE")
        debug "Current log file size: $filesize bytes"
        if [[ $filesize -ge $MAX_LOG_SIZE ]]; then
            local archive_file
            archive_file="${MAIN_LOG_FILE}.$(date +%Y%m%d_%H%M%S).log"
            debug "Rotating log to: $archive_file"
            mv "$MAIN_LOG_FILE" "$archive_file"
            touch "$MAIN_LOG_FILE"
        fi
    fi
}

# =============================================================================
# Cleanup Old Log Files Function
# =============================================================================
cleanup_logs() {
    debug "=== Cleaning up archived logs older than $LOG_RETENTION_DAYS days ==="
    find "$LOG_DIR" -type f -name "sync.log.*.log" -mtime +$LOG_RETENTION_DAYS -print -exec rm {} \;
}

# =============================================================================
# Pre-flight: Check for Required Programs
# =============================================================================
check_requirements() {
    debug "=== Starting Requirements Check ==="
    local required_programs=(curl jq rsync ssh bc sed awk sort date tee)
    for prog in "${required_programs[@]}"; do
        if ! command -v "$prog" >/dev/null 2>&1; then
            error_exit "Required program '$prog' not found. Please install it."
        fi
    done
}

# =============================================================================
# Authenticate with qBittorrent
# =============================================================================
authenticate() {
    debug "=== Authenticating with qBittorrent ==="
    curl -s -c /tmp/qb_cookie.txt \
         --data "username=$QB_USER&password=$QB_PASS" \
         "http://$QB_HOST/api/v2/auth/login" >/tmp/login_response.txt
    if ! grep -qi "Ok" /tmp/login_response.txt; then
        error_exit "Login failed! Check credentials in $ENV_FILE or Web UI settings."
    fi
    unset QB_PASS  # Clear password from memory after use
}

# =============================================================================
# Fetch Torrent Info from qBittorrent
# =============================================================================
fetch_torrent_info() {
    debug "=== Fetching Torrent Info ==="
    curl -S -s -b /tmp/qb_cookie.txt "http://$QB_HOST/api/v2/torrents/info" >/tmp/torrent_status.json
    if [[ ! -s /tmp/torrent_status.json ]]; then
        error_exit "Failed to fetch torrent info or received an empty response."
    fi
}

# =============================================================================
# Sync Directories Using Tracker-Based Exclusion
# =============================================================================
sync_directories() {
    debug "=== Starting Directory Sync Process ==="
    for dir in "${DIRS[@]}"; do
        echo ">> Syncing $dir..."
        local exclude_list=()
        if [[ -f "$TRACKER_FILE" ]]; then
            echo "   Building exclusion list for $dir..."
            mapfile -t exclude_list < <(awk -F'|' -v dir="$dir" \
                '$3 ~ /status:complete/ && $2 ~ dir {
                    gsub(".*"dir"/", "", $2);
                    sub("/[^/]*$", "", $2);
                    sub(/[[:space:]]*$/, "", $2);
                    print $2
                }' "$TRACKER_FILE" | sort -u)
            echo "   Exclusion list for $dir:"
            for item in "${exclude_list[@]}"; do
                echo "     - $item"
            done
        fi

        if ((${#exclude_list[@]} > 0)); then
            local exclude_args=()
            for item in "${exclude_list[@]}"; do
                echo "   Excluding directory: '$item'"
                exclude_args+=(--exclude="$item/")
            done
            center_text_line_with_format 80 " RSYNC OUTPUT STARTING " "▓" "\033[32m" both
            rsync $RSYNC_OPTS -e "$RSYNC_RSH" "${exclude_args[@]}" \
                  "$REMOTE_HOST:$REMOTE_BASE/$dir/" "$LOCAL_BASE/$dir/"
            center_text_line_with_format 80 " RSYNC OUTPUT FINISHED " "▓" "\033[32m" both
        else
            echo "   No exclusions for $dir. Running full sync..."
            center_text_line_with_format 80 " RSYNC OUTPUT STARTING " "▓" "\033[32m" both
            rsync $RSYNC_OPTS -e "$RSYNC_RSH" "$REMOTE_HOST:$REMOTE_BASE/$dir/" "$LOCAL_BASE/$dir/"
            center_text_line_with_format 80 " RSYNC OUTPUT FINISHED " "▓" "\033[32m" both
        fi

        local rsync_exit=$?
        if [[ $rsync_exit -eq 0 ]]; then
            echo ">> Finished syncing $dir."
        else
            echo ">> ERROR: Sync for $dir failed (rsync exit code: $rsync_exit)"
        fi
    done
}

# =============================================================================
# Update Tracker with Torrent Status
# =============================================================================
update_tracker() {
    debug "=== Starting Tracker Update Process ==="
    curl -S -s -b /tmp/qb_cookie.txt "http://$QB_HOST/api/v2/torrents/info" >/tmp/torrent_status.json
    if [[ ! -s /tmp/torrent_status.json ]]; then
        echo "ERROR: Torrent info fetch failed or empty. Tracker update skipped."
        return
    fi

    >"$TRACKER_FILE.tmp"
    while IFS= read -r torrent; do
        local hash name progress content_path
        hash=$(echo "$torrent" | jq -r '.hash')
        name=$(echo "$torrent" | jq -r '.name')
        progress=$(echo "$torrent" | jq -r '.progress')
        content_path=$(echo "$torrent" | jq -r '.content_path')

        if [[ -z "$hash" || -z "$content_path" ]]; then
            debug "Skipping torrent (missing hash or content_path)."
            continue
        fi

        local adjusted_path
        adjusted_path="${content_path#/downloads/}"
        local cat_dir=""
        for d in "${DIRS[@]}"; do
            if [[ "$adjusted_path" == "$d/"* ]]; then
                cat_dir="$d"
                break
            fi
        done
        if [[ -z "$cat_dir" ]]; then
            debug "Unable to determine category from path: $adjusted_path. Skipping."
            continue
        fi

        local relative_path
        relative_path="${adjusted_path#$cat_dir/}"
        local folder
        if [[ -z "$relative_path" || "$relative_path" == "$cat_dir" ]]; then
            folder="$name"
        elif [[ "$relative_path" =~ \.[[:alnum:]]{1,5}$ ]]; then
            folder="$name"
        elif [[ "$relative_path" == */* ]]; then
            folder=$(echo "$relative_path" | cut -d'/' -f1)
        else
            folder="$relative_path"
        fi

        local local_file
        local_file="$LOCAL_BASE/$cat_dir/$folder"
        local prev_status
        prev_status=$(awk -F' *\\| *' -v h="$hash" '$1 == "hash:" h {print $3}' "$TRACKER_FILE" 2>/dev/null)
        local status
        if (($(echo "$progress < 1" | bc -l))); then
            status="partial"
        elif [[ "$progress" = "1" || "$prev_status" == "status:complete" ]]; then
            status="complete"
        else
            status="partial"
        fi

        echo "hash:$hash | file:$local_file | status:$status | last_sync:$(date -Iseconds)" >>"$TRACKER_FILE.tmp"
    done < <(jq -r '.[] | {hash: .hash, name: .name, progress: .progress, content_path: .content_path} | @json' /tmp/torrent_status.json)

    if [[ -s "$TRACKER_FILE.tmp" ]]; then
        sort -u "$TRACKER_FILE.tmp" >"$TRACKER_FILE"
    else
        >"$TRACKER_FILE"
    fi
}

# =============================================================================
# Cleanup Temporary Files
# =============================================================================
cleanup() {
    debug "=== Starting Cleanup ==="
    rm /tmp/torrent_status.json /tmp/qb_cookie.txt /tmp/login_response.txt "$TRACKER_FILE.tmp" 2>/dev/null || true
    echo "Cleanup completed."
}

# =============================================================================
# Separator Text Centralizer
# =============================================================================
center_text_line_with_format() {
    local total_width=${1:-80}
    local text=${2:-" S E P E R A T O R "}
    local fill_char=${3:-"▓"}
    local base_color=${4:-"\033[34m"}
    local style=${5:-"none"}
    local reset_color="\033[0m"
    local style_code=""

    case "$style" in
        underline) style_code="\033[4m" ;;
        overline) style_code="\033[53m" ;;
        both) style_code="\033[4;53m" ;;
        *) style_code="" ;;
    esac

    local color="${base_color}${style_code}"
    local text_length=${#text}
    local padding_total=$(( total_width - text_length ))
    (( padding_total < 0 )) && padding_total=0
    local padding_left=$(( padding_total / 2 ))
    local padding_right=$(( padding_total - padding_left ))

    local left_padding
    left_padding=$(printf "${fill_char}%.0s" $(seq 1 $padding_left))
    local right_padding
    right_padding=$(printf "${fill_char}%.0s" $(seq 1 $padding_right))

    echo -e "${color}${left_padding}${text}${right_padding}${reset_color}"
}

# =============================================================================
# Main Script Execution
# =============================================================================
debug "=== Script Initialization ==="
mkdir -p "$LOG_DIR" || error_exit "Failed to create log directory: $LOG_DIR"

rotate_logs
exec > >(tee -a "$MAIN_LOG_FILE") 2>&1

center_text_line_with_format 80 " Sync Process Started at $(date) " "▓" "\033[34m" overline

check_requirements
authenticate
fetch_torrent_info
sync_directories
update_tracker
cleanup
cleanup_logs

center_text_line_with_format 80 " Sync Process Completed at $(date) " "▓" "\033[34m" underline
echo -e " \n"

debug "Script finished execution."
