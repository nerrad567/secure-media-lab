#!/bin/bash

# Configuration
# Paths and settings for syncing and tracking torrents
ENV_FILE="/mnt/f/Scripts/vpsSync/.env"                 # Environment file with qBittorrent credentials
QB_HOST="10.0.0.1:8080"                                # qBittorrent Web UI host and port
REMOTE_HOST="syncuser@10.0.0.1"                        # Remote server SSH login
REMOTE_BASE="/home/syncuser/media-stack/downloads"     # Remote base directory for media files
LOCAL_BASE="/mnt/StagingSSD"                           # Local base directory for synced files
LOG_DIR="/mnt/f/Scripts/vpsSync/sync_logs"             # Directory for logs and tracker files
SSH_KEY="/home/darre/.ssh/id_rsa_liteserver_86201470"  # SSH key for remote access
DIRS=("ebooks" "manual" "movies" "music" "tv")         # Subdirectories to sync
TRACKER_FILE="$LOG_DIR/sync_tracker.txt"               # Persistent file to track torrent status
LOG_FILE="$LOG_DIR/sync_$(date +%Y%m%d_%H%M%S).log"    # Log file with timestamp

# Ensure log directory exists
echo "Checking log directory..."
mkdir -p "$LOG_DIR" || { echo "Critical: Failed to create log directory: $LOG_DIR"; exit 1; }

# Redirect all output to log file and console
echo "Redirecting output to $LOG_FILE"
exec > >(tee "$LOG_FILE") 2>&1

echo "Starting sync process at $(date)"

# Load environment variables (e.g., QB_USER, QB_PASS) from .env
echo "Loading environment variables..."
if [ -f "$ENV_FILE" ]; then
  source <(sed 's/\r$//' "$ENV_FILE")  # Remove Windows line endings if present
else
  echo "Critical: .env file not found at $ENV_FILE"
  exit 1
fi

# Step 1: Authenticate with qBittorrent
echo -n "Authenticating... "
curl -s -c /tmp/qb_cookie.txt \
  --data "username=$QB_USER&password=$QB_PASS" \
  "http://$QB_HOST/api/v2/auth/login" > /tmp/login_response.txt
login_response=$(cat /tmp/login_response.txt)
if ! grep -qi "Ok" /tmp/login_response.txt; then
  echo "Error: Login failed! Check credentials in $ENV_FILE or Web UI settings: $login_response"
  exit 1
fi
echo "Done"
unset QB_PASS  # Clear password from memory

# Step 2: Fetch initial torrent info
echo -n "Fetching Torrent Info... "
curl -S -s -b /tmp/qb_cookie.txt "http://$QB_HOST/api/v2/torrents/info" > /tmp/torrent_status.json
if [ ! -s /tmp/torrent_status.json ]; then
  echo "Error: Failed to fetch torrent info or response is empty"
  exit 1
fi
echo "Done"

# Debug: Display current tracker file contents
echo "Current tracker file contents:"
if [ -f "$TRACKER_FILE" ]; then
  cat "$TRACKER_FILE"
else
  echo "No tracker file found yet."
fi

# Step 3: Sync directories with tracker-based exclusion
for dir in "${DIRS[@]}"; do
  echo "Syncing $dir..."

  # Build exclusion list from tracker for completed torrents
  exclude_list=()
  if [ -f "$TRACKER_FILE" ]; then
    echo "Building exclusion list for $dir..."
    # Extract directory names of completed torrents, trim trailing spaces
    mapfile -t exclude_list < <(awk -F'|' -v dir="$dir" '$3 ~ /status:complete/ && $2 ~ dir {gsub(".*"dir"/", "", $2); sub("/[^/]*$", "", $2); sub(/[[:space:]]*$/, "", $2); print $2}' "$TRACKER_FILE" | sort -u)
    echo "Raw exclude_list contents:"
    printf '%s\n' "${exclude_list[@]}"
  fi

  # Sync with exclusions if any
  if [ ${#exclude_list[@]} -gt 0 ]; then
    for item in "${exclude_list[@]}"; do
      echo "Excluding completed directories: '$item'"
    done
    exclude_args=()
    for item in "${exclude_list[@]}"; do
      exclude_args+=(--exclude="$item/")  # Combine --exclude and pattern into one element
    done
    rsync -avz --progress --partial --append-verify \
      -e "ssh -i $SSH_KEY" \
      "${exclude_args[@]}" \
      "$REMOTE_HOST:$REMOTE_BASE/$dir/" "$LOCAL_BASE/$dir/"
  else
    echo "No completed directories to exclude."
    rsync -avz --progress --partial --append-verify \
      -e "ssh -i $SSH_KEY" \
      "$REMOTE_HOST:$REMOTE_BASE/$dir/" "$LOCAL_BASE/$dir/"
  fi
  rsync_exit=$?
  if [ $rsync_exit -eq 0 ]; then
    echo "Done"
  else
    echo "Error: Failed to sync $dir (rsync exit code: $rsync_exit)"
  fi
done

# Step 4: Update tracker with torrent status
echo -n "Updating Download Status Tracker... "
curl -S -s -b /tmp/qb_cookie.txt "http://$QB_HOST/api/v2/torrents/info" > /tmp/torrent_status.json
if [ ! -s /tmp/torrent_status.json ]; then
  echo "Error: Torrent info fetch failed or empty"
  > "$TRACKER_FILE"
else
  if ! jq -e . /tmp/torrent_status.json >/dev/null 2>&1; then
    echo "Error: Invalid JSON in /tmp/torrent_status.json"
    exit 1
  fi

  # Debug: Show torrent progress from qBittorrent
  echo "Torrent progress from qBittorrent:"
  jq -r '.[] | "Name: \(.name), Progress: \(.progress)"' /tmp/torrent_status.json

  > "$TRACKER_FILE.tmp"
  while IFS= read -r torrent; do
    # Extract torrent details
    hash=$(echo "$torrent" | jq -r '.hash')
    name=$(echo "$torrent" | jq -r '.name')
    progress=$(echo "$torrent" | jq -r '.progress')
    content_path=$(echo "$torrent" | jq -r '.content_path')

    if [ -z "$hash" ] || [ -z "$content_path" ]; then
      echo "Warning: Skipping invalid torrent entry: $torrent"
      continue
    fi

    # Map remote path to local path
    adjusted_path="${content_path#/downloads/}"
    file_name=$(basename "$adjusted_path")
    local_file=""
    for dir in "${DIRS[@]}"; do
      if [[ "$adjusted_path" == "$dir/"* ]]; then
        local_file="$LOCAL_BASE/$dir/$file_name"
        break
      fi
    done

    if [ -z "$local_file" ]; then
      echo "Warning: Could not map $content_path (adjusted: $adjusted_path) to a local directory"
      continue
    fi

    # Check previous status from tracker
    prev_status=$(awk -F'|' -v hash="$hash" '$1 == "hash:"hash {print $3}' "$TRACKER_FILE" 2>/dev/null)

    # Set status:
    # - partial: if progress < 1 (not done in qBittorrent)
    # - complete: if progress = 1 (assume synced if complete in qBittorrent)
    # - complete: if previously complete (persists across runs)
    if (( $(echo "$progress < 1" | bc -l) )); then
      status="partial"
    elif [ "$progress" = "1" ] || [ "$prev_status" = "status:complete" ]; then
      status="complete"  # Mark complete if qBittorrent says so or previously complete
    else
      status="partial"  # Default to partial if not complete
    fi

    # Write tracker entry
    echo "hash:$hash | file:$local_file | status:$status | last_sync:$(date -Iseconds)" >> "$TRACKER_FILE.tmp"
  done < <(jq -r '.[] | {hash: .hash, name: .name, progress: .progress, content_path: .content_path} | @json' /tmp/torrent_status.json)

  # Update tracker file if valid entries exist
  if [ -s "$TRACKER_FILE.tmp" ]; then
    sort -u "$TRACKER_FILE.tmp" > "$TRACKER_FILE"
    echo "Done"
  else
    echo "Warning: No valid tracker entries to write"
    > "$TRACKER_FILE"
    echo "Done"
  fi
fi

# Cleanup temporary files
echo -n "Cleaning Up... "
rm /tmp/torrent_status.json /tmp/qb_cookie.txt /tmp/login_response.txt "$TRACKER_FILE.tmp" 2>/dev/null
echo "Done"

echo "Sync completed at $(date)"