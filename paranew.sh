#!/bin/bash
DIR_PATH=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )

# Telegram Configuration
BOT_TOKEN=#bottoken
CHAT_ID=#chatid
NODE_NAME="1"  # Change this for each node
HOST_NAME=$(hostname)

# Function to send Telegram messages
send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="🖥️ ${NODE_NAME} (${HOST_NAME}): ${message}" \
        -d parse_mode="HTML"
}

# Detect OS and architecture
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    release_os="linux"
    if [[ $(uname -m) == "aarch64"* ]]; then
        release_arch="arm64"
    else
        release_arch="amd64"
    fi
else
    release_os="darwin"
    release_arch="arm64"
fi

# Default parameters if not provided
os=${1:-$release_os}
architecture=${2:-$release_arch}
startingCore=${3:-0}
maxCores=${4:-2}
crashed=0

# Process tracking
declare -a worker_pids
master_pid=""
PID_FILE="$DIR_PATH/master.pid"
WORKER_PID_FILE="$DIR_PATH/workers.pid"

check_and_download_updates() {
    local new_release=false
    local downloaded_files=""
    local files=$(curl -s https://releases.quilibrium.com/release | grep "$os-$architecture" 2>/dev/null)
    local update_message=""
    
    # Download all files for the latest version
    for file in $files; do
        if ! test -f "$DIR_PATH/$file"; then
            curl -s "https://releases.quilibrium.com/$file" > "$DIR_PATH/$file" 2>/dev/null
            # Add executable permissions to binary files
            if [[ $file =~ ^node-.*-$os-$architecture$ ]]; then
                chmod +x "$DIR_PATH/$file"
                echo "Added executable permissions to $file"
            fi
            new_release=true
            downloaded_files="${downloaded_files}• ${file}\n"
        fi
    done

    if $new_release; then
        # Only log and send messages if we actually found updates
        echo "Updates found and downloaded"
        if [ -n "$downloaded_files" ]; then
            update_message="⬇️ New files downloaded:\n${downloaded_files}"
            send_telegram_message "$update_message"

            # If there's a binary in the updates, prepare for restart
            if echo "$downloaded_files" | grep -q "^• node-.*-$os-$architecture$"; then
                send_telegram_message "🔄 Binary update detected - will restart service"
            fi
        fi
        return 0
    fi
    return 1
}

get_latest_version() {
    local files=$(curl -s https://releases.quilibrium.com/release | grep "$os-$architecture")
    if [ -n "$files" ]; then
        echo "$files" | cut -d '-' -f 2 | sort -V | tail -n 1
    else
        echo "Error: No versions found for $os-$architecture" >&2
        return 1
    fi
}

get_running_version() {
    if [ -f "$PID_FILE" ]; then
        local master_pid=$(cat "$PID_FILE")
        if kill -0 "$master_pid" 2>/dev/null; then
            local cmd=$(ps -p "$master_pid" -o command=)
            echo "$cmd" | grep -o "node-[0-9.]*-" | cut -d '-' -f 2
            return 0
        fi
    fi
    return 1
}

graceful_shutdown() {
    send_telegram_message "🛑 Initiating graceful shutdown..."
    
    # Send SIGINT to master and all workers immediately
    if [[ -n "$master_pid" && -e "/proc/$master_pid" ]]; then
        echo "Sending SIGINT to master process $master_pid"
        kill -SIGINT "$master_pid"
    fi
    
    for pid in "${worker_pids[@]}"; do
        if [[ -e "/proc/$pid" ]]; then
            echo "Sending SIGINT to worker process $pid"
            kill -SIGINT "$pid"
        fi
    done

    # Wait up to 120 seconds for all processes to stop
    local timeout=120
    while [ $timeout -gt 0 ]; do
        all_stopped=true

        # Check if master is still running
        if [[ -n "$master_pid" && -e "/proc/$master_pid" ]]; then
            all_stopped=false
        fi

        # Check if any workers are still running
        for pid in "${worker_pids[@]}"; do
            if [[ -e "/proc/$pid" ]]; then
                all_stopped=false
                break
            fi
        done

        if $all_stopped; then
            break
        fi

        sleep 1
        timeout=$((timeout - 1))
    done

    # If timeout reached, force kill any remaining processes
    if [ $timeout -eq 0 ]; then
        echo "Timeout reached, force killing remaining processes"
        if [[ -n "$master_pid" && -e "/proc/$master_pid" ]]; then
            kill -9 "$master_pid"
        fi
        for pid in "${worker_pids[@]}"; do
            if [[ -e "/proc/$pid" ]]; then
                kill -9 "$pid"
            fi
        done
    fi
    
    # Clean up PID files
    rm -f "$PID_FILE" "$WORKER_PID_FILE"
    
    # Clear the PID arrays
    worker_pids=()
    master_pid=""
    
    send_telegram_message "✅ Graceful shutdown completed"
}

start_process() {
    local current_version=$(get_latest_version)
    if [ -z "$current_version" ]; then
        local message="❌ Error: Could not determine latest version. Exiting."
        echo "$message"
        send_telegram_message "$message"
        exit 1
    fi
    
    local binary="$DIR_PATH/node-$current_version-$os-$architecture"
    if [ ! -f "$binary" ]; then
        echo "Binary $binary not found. Checking for updates..."
        check_and_download_updates
    fi
    
    # Start master node if starting from core 0
    if [ $startingCore -eq 0 ]; then
        "$binary" &
        master_pid=$!
        echo $master_pid > "$PID_FILE"
        send_telegram_message "🔄 Started master process with PID: $master_pid"
        maxCores=$((maxCores - 1))
    fi
    
    echo "Node parent PID: $$"
    echo "Max Cores: $maxCores"
    echo "Starting Core: $startingCore"
    
    # Start worker nodes and save PIDs
    worker_pids=()
    > "$WORKER_PID_FILE"  # Clear worker PID file
    for i in $(seq 1 $maxCores); do
        core=$((startingCore + i))
        echo "Deploying: $core data worker with params: --core=$core --parent-process=$$"
        "$binary" --core=$core --parent-process=$$ &
        worker_pid=$!
        worker_pids+=($worker_pid)
        echo "$worker_pid" >> "$WORKER_PID_FILE"
        echo "Started worker $core with PID: $worker_pid"
    done
    
    send_telegram_message "✅ All processes started successfully with version $current_version"
}

# Signal handlers
handle_sigint() {
    local message="Received SIGINT signal"
    echo "$message"
    send_telegram_message "$message"
    graceful_shutdown
    exit 0
}

handle_sigterm() {
    local message="Received SIGTERM signal"
    echo "$message"
    send_telegram_message "$message"
    graceful_shutdown
    exit 0
}

cleanup() {
    graceful_shutdown
    rm -f "$PID_FILE" "$WORKER_PID_FILE"
}

# Set up signal handlers
trap 'handle_sigint' SIGINT
trap 'handle_sigterm' SIGTERM
trap 'cleanup' EXIT

# Initial startup message
send_telegram_message "🚀 Node script starting up..."

# Initial update check and start
echo "Performing initial update check..."
check_and_download_updates
start_process

# Main loop
while true; do
    all_running=true
    
    # Check master process using PID file
    if [ -f "$PID_FILE" ]; then
        saved_master_pid=$(cat "$PID_FILE")
        if ! kill -0 "$saved_master_pid" 2>/dev/null; then
            message="⚠️ Master process $saved_master_pid is no longer running"
            echo "$message"
            send_telegram_message "$message"
            all_running=false
        fi
    fi
    
    # Check all worker processes
    for pid in "${worker_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            message="⚠️ Worker process $pid is no longer running"
            echo "$message"
            send_telegram_message "$message"
            all_running=false
            break
        fi
    done
    
    if ! $all_running; then
        message="🔄 One or more processes crashed or stopped. Restarting... (Crash count: $crashed)"
        echo "$message"
        send_telegram_message "$message"
        crashed=$((crashed + 1))
        graceful_shutdown
        check_and_download_updates
        start_process
    elif check_and_download_updates; then
        message="⬆️ Update available. Initiating graceful restart..."
        echo "$message"
        send_telegram_message "$message"
        graceful_shutdown
        start_process
    fi
    
    sleep 120
done
