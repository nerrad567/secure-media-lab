#!/bin/bash
set -euo pipefail

# =============================================================================
# Configuration Variables
# =============================================================================
# These values can be modified here or loaded from an external .env file.
ENV_FILE="/home/darren/media-stack/scripts/vpsSync/.env"     # File with qBittorrent credentials
QB_HOST="10.0.0.1:8080"                                      # qBittorrent Web UI host:port (via VPN)
REMOTE_HOST="syncuser@10.0.0.1"                              # SSH login for remote server (via VPN)
REMOTE_BASE="/home/syncuser/media-stack/downloads"           # Remote base directory for media files
LOCAL_BASE="/mnt/pool/staging"                               # Local staging directory for downloads
LOG_DIR="/home/darren/media-stack/scripts/vpsSync/sync_logs" # Directory for logs & tracker files
SSH_KEY="/home/darren/.ssh/id_rsa_liteserver_86201470"       # SSH key for remote access
DIRS=("ebooks" "manual" "movies" "music" "tv")               # Subdirectories to sync
TRACKER_FILE="$LOG_DIR/sync_tracker.txt"                     # File to persist torrent status info

# Main log file – all runs append here.
MAIN_LOG_FILE="$LOG_DIR/sync.log"

# -----------------------------------------------------------------------------
# RSYNC Options
# -----------------------------------------------------------------------------
# DRY_RUN: set to "--dry-run" for test mode, or "" for live transfers.
DRY_RUN=""

# RSYNC_OPTS: common options:
#   -a: Archive mode (preserves permissions, timestamps, symlinks, etc.)
#   -v: Verbose output.
#   -z: Compress file data during transfer.
#   --progress: Show progress during transfer.
#   --partial: Keep partially transferred files.
#   --append-verify: Append to partially transferred files and verify integrity.
RSYNC_OPTS="-az --progress --partial --append-verify $DRY_RUN"

# RSYNC_RSH: remote shell command; uses SSH with the provided key.
RSYNC_RSH="ssh -i $SSH_KEY"

# -----------------------------------------------------------------------------
# Log Rotation and Retention Settings
# -----------------------------------------------------------------------------
# Maximum log file size in bytes (default 10 MB).
MAX_LOG_SIZE=10485760
# Delete archived logs older than this many days.
LOG_RETENTION_DAYS=365

# -----------------------------------------------------------------------------
# Toggle Debugging (set DEBUG=1 to enable, 0 to disable)
# -----------------------------------------------------------------------------
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
            debug "Log file exceeds threshold ($MAX_LOG_SIZE bytes). Rotating log to: $archive_file"
            mv "$MAIN_LOG_FILE" "$archive_file"
            touch "$MAIN_LOG_FILE"
        else
            debug "Log file size is under threshold; no rotation needed."
        fi
    else
        debug "No log file exists; nothing to rotate."
    fi
}

# =============================================================================
# Cleanup Old Log Files Function
# =============================================================================
cleanup_logs() {
    debug "=== Cleaning up archived logs older than $LOG_RETENTION_DAYS days ==="
    # Look for archived logs matching MAIN_LOG_FILE.TIMESTAMP.log and delete those older than retention period.
    find "$LOG_DIR" -type f -name "sync.log.*.log" -mtime +$LOG_RETENTION_DAYS -print -exec rm {} \;
    debug "Old log cleanup completed."
}

# =============================================================================
# Pre-flight: Check for Required Programs
# =============================================================================
check_requirements() {
    debug "=== Starting Requirements Check ==="
    local required_programs=(curl jq rsync ssh bc sed awk sort date tee)
    for prog in "${required_programs[@]}"; do
        debug "Checking for: $prog"
        if ! command -v "$prog" >/dev/null 2>&1; then
            error_exit "Required program '$prog' not found. Please install it."
        fi
    done
    debug "All required programs are available."
}

# =============================================================================
# Load Environment Variables from ENV_FILE
# =============================================================================
load_environment() {
    debug "=== Loading Environment Variables from: $ENV_FILE ==="
    if [[ -f "$ENV_FILE" ]]; then
        source <(sed 's/\r$//' "$ENV_FILE")
        debug "Environment variables loaded."
    else
        error_exit ".env file not found at $ENV_FILE"
    fi
}

# =============================================================================
# Authenticate with qBittorrent
# =============================================================================
authenticate() {
    debug "=== Authenticating with qBittorrent ==="
    curl -s -c /tmp/qb_cookie.txt \
         --data "username=$QB_USER&password=$QB_PASS" \
         "http://$QB_HOST/api/v2/auth/login" >/tmp/login_response.txt
    local login_response
    login_response=$(cat /tmp/login_response.txt)
    debug "Login response: $login_response"
    if ! grep -qi "Ok" /tmp/login_response.txt; then
        error_exit "Login failed! Please check credentials in $ENV_FILE or Web UI settings."
    fi
    debug "Authentication successful."
    unset QB_PASS
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
    debug "Torrent info successfully fetched."
}

# =============================================================================
# Sync Directories Using Tracker-Based Exclusion (Step 3)
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
            debug "   Running rsync for $dir with options: $RSYNC_OPTS and exclusion args: ${exclude_args[*]}"
            echo -e "\033[1;32m╔══════════════════════════════════════════════════════════════════════════════════════ RSYNC OUTPUT START ═══════════════════════════════════════════════════════════════════════════════════════╗\033[0m"
            rsync $RSYNC_OPTS -e "$RSYNC_RSH" "${exclude_args[@]}" \
                  "$REMOTE_HOST:$REMOTE_BASE/$dir/" "$LOCAL_BASE/$dir/"
            echo -e "\033[1;32m╚══════════════════════════════════════════════════════════════════════════════════════ RSYNC OUTPUT END   ═══════════════════════════════════════════════════════════════════════════════════════╝\033[0m"

        else
            echo "   No exclusions for $dir. Running full sync..."
            echo -e "\033[1;32m╔══════════════════════════════════════════════════════════════════════════════════════ RSYNC OUTPUT START ═══════════════════════════════════════════════════════════════════════════════════════╗\033[0m"
            rsync $RSYNC_OPTS -e "$RSYNC_RSH" "$REMOTE_HOST:$REMOTE_BASE/$dir/" "$LOCAL_BASE/$dir/"
            echo -e "\033[1;32m╚══════════════════════════════════════════════════════════════════════════════════════ RSYNC OUTPUT END   ═══════════════════════════════════════════════════════════════════════════════════════╝\033[0m"


        fi

        local rsync_exit=$?
        if [[ $rsync_exit -eq 0 ]]; then
            echo ">> Finished syncing $dir."
        else
            echo ">> ERROR: Sync for $dir failed (rsync exit code: $rsync_exit)"
        fi
    done
    debug "=== Directory Sync Process Completed ==="
}

# =============================================================================
# Update Tracker with Torrent Status (Step 4)
# =============================================================================
update_tracker() {
    debug "=== Starting Tracker Update Process ==="
    curl -S -s -b /tmp/qb_cookie.txt "http://$QB_HOST/api/v2/torrents/info" >/tmp/torrent_status.json
    if [[ ! -s /tmp/torrent_status.json ]]; then
        echo "ERROR: Torrent info fetch failed or empty. Tracker update skipped."
        return
    fi

    >"$TRACKER_FILE.tmp"
    debug "Processing torrent entries for tracker update..."
    while IFS= read -r torrent; do
        debug "-----------------------------------------------------"
        debug "Processing torrent JSON: $torrent"

        local hash name progress content_path
        hash=$(echo "$torrent" | jq -r '.hash')
        name=$(echo "$torrent" | jq -r '.name')
        progress=$(echo "$torrent" | jq -r '.progress')
        content_path=$(echo "$torrent" | jq -r '.content_path')

        debug "   Hash: $hash"
        debug "   Name: $name"
        debug "   Progress: $progress"
        debug "   Content Path: $content_path"

        if [[ -z "$hash" || -z "$content_path" ]]; then
            debug "   Skipping torrent (missing hash or content_path)."
            continue
        fi

        local adjusted_path
        adjusted_path="${content_path#/downloads/}"
        debug "   Adjusted path (sans '/downloads/'): $adjusted_path"

        local cat_dir=""
        for d in "${DIRS[@]}"; do
            if [[ "$adjusted_path" == "$d/"* ]]; then
                cat_dir="$d"
                break
            fi
        done
        debug "   Detected category: $cat_dir"
        if [[ -z "$cat_dir" ]]; then
            debug "   Unable to determine category from adjusted path: $adjusted_path. Skipping torrent."
            continue
        fi

        local relative_path
        relative_path="${adjusted_path#$cat_dir/}"
        debug "   Relative path (after removing category): $relative_path"

        local folder
        if [[ -z "$relative_path" || "$relative_path" == "$cat_dir" ]]; then
            folder="$name"
            debug "   Relative path empty/equal to category; using torrent name as folder: '$folder'"
        elif [[ "$relative_path" =~ \.[[:alnum:]]{1,5}$ ]]; then
            folder="$name"
            debug "   Relative path ends with file extension; treating as single-file torrent. Using torrent name: '$folder'"
        elif [[ "$relative_path" == */* ]]; then
            folder=$(echo "$relative_path" | cut -d'/' -f1)
            debug "   Multi-file torrent detected; extracted folder: '$folder'"
        else
            folder="$relative_path"
            debug "   Using relative path directly as folder: '$folder'"
        fi

        local local_file
        local_file="$LOCAL_BASE/$cat_dir/$folder"
        debug "   Computed local file path: $local_file"

        local prev_status
        prev_status=$(awk -F' *\\| *' -v h="$hash" '$1 == "hash:" h {print $3}' "$TRACKER_FILE" 2>/dev/null)
        debug "   Previous status: $prev_status"

        local status
        if (($(echo "$progress < 1" | bc -l))); then
            status="partial"
        elif [[ "$progress" = "1" || "$prev_status" == "status:complete" ]]; then
            status="complete"
        else
            status="partial"
        fi
        debug "   Determined torrent status: $status"

        local tracker_entry
        tracker_entry="hash:$hash | file:$local_file | status:$status | last_sync:$(date -Iseconds)"
        debug "   Tracker entry: $tracker_entry"
        echo "$tracker_entry" >>"$TRACKER_FILE.tmp"
        debug "   Finished processing torrent $hash"
    done < <(jq -r '.[] | {hash: .hash, name: .name, progress: .progress, content_path: .content_path} | @json' /tmp/torrent_status.json)

    debug "All torrent entries processed."
    if [[ -s "$TRACKER_FILE.tmp" ]]; then
        debug "Sorting and updating tracker file..."
        sort -u "$TRACKER_FILE.tmp" >"$TRACKER_FILE"
        debug "Tracker file updated successfully."
    else
        debug "No valid tracker entries found. Clearing tracker file."
        >"$TRACKER_FILE"
    fi
}

# =============================================================================
# Cleanup Temporary Files
# =============================================================================
cleanup() {
    debug "=== Starting Cleanup of Temporary Files ==="
    rm /tmp/torrent_status.json /tmp/qb_cookie.txt /tmp/login_response.txt "$TRACKER_FILE.tmp" 2>/dev/null || true
    echo "Cleanup completed."
    debug "Temporary files removed."
}

# =============================================================================
# Main Script Execution
# =============================================================================
# Ensure log directory exists.
debug "=== Script Initialization ==="
mkdir -p "$LOG_DIR" || error_exit "Failed to create log directory: $LOG_DIR"

# Rotate the main log file if it exceeds the maximum size.
rotate_logs

# Redirect all output (both stdout and stderr) to the main log file (append mode).
debug "=== Redirecting Output to Main Log File: $MAIN_LOG_FILE ==="
exec > >(tee -a "$MAIN_LOG_FILE") 2>&1

echo "════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════"
echo "=== Sync Process Started at $(date) ==="
echo "════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════"
debug "Script execution initiated."

check_requirements
load_environment
authenticate
fetch_torrent_info

debug "=== Current Tracker File Contents ==="
if [[ -f "$TRACKER_FILE" ]]; then
    debug "$(cat "$TRACKER_FILE")"
else
    debug "No tracker file found yet."
fi


sync_directories
update_tracker
cleanup

# Archive old logs.
cleanup_logs
echo "=== Sync Process Completed at $(date) ==="
echo "════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════"
echo -e " \n \n \n \n \n"

debug "Script finished execution."
