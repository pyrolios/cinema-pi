#!/bin/bash
# ==========================================
# CINEMA PI
# Transforms a Raspberry Pi 5 into a minimalist and high-performance media player, fully controllable via SSH.
# Designed for high-bitrate video playback from an external drive. Simple control using intuitive bash commands.
# No graphical interface required. Video playback on HDMI0, detached mode, Pi OS Lite 64-bit.
# Installation is fully automated by this script.
# ==========================================

set -e

# 🔧 CONFIGURATION - MODIFY THIS SECTION ONLY
# You must set the UUID of your external drive and the paths to your content.
DISK_UUID="D842574742572990"
MOUNT_POINT="/mnt/MediaDrive"
FILMS_DIR="/mnt/MediaDrive/Movies"

echo "[*] Installing Cinema Pi"

# 1. CLEANUP
# Backs up the current .bashrc and removes any previous Cinema Pi configuration
cp ~/.bashrc ~/.bashrc.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
sed -i '/# CINEMA PI/,/# END CINEMA/d' ~/.bashrc
rm -rf ~/.cinema_pi
sudo rm -f /etc/sudoers.d/cinema

# 2. INSTALL DEPENDENCIES
sudo apt update -qq
sudo apt install -y mpv cec-utils ntfs-3g fzf socat

# 3. NTFS DISK MOUNT SETUP
sudo mkdir -p "$MOUNT_POINT"
sudo chown $USER:$USER "$MOUNT_POINT"
if ! sudo grep -q "$DISK_UUID" /etc/fstab; then
    # Add an entry to /etc/fstab for persistent mounting
    sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
    echo "UUID=$DISK_UUID $MOUNT_POINT ntfs-3g defaults,nofail,uid=1000,gid=1000,dmask=022,fmask=133,big_writes,noatime 0 0" | sudo tee -a /etc/fstab > /dev/null
fi
sudo mount -a 2>/dev/null || echo "[!] Mount failed: Check if the disk is connected and the UUID is correct."

# 4. HDMI-CEC CONFIGURATION
sudo usermod -aG video $USER

# 5. SCRIPTS
mkdir -p ~/.cinema_pi

# play.sh optimized for maximum smoothness and low-level hardware control
cat > ~/.cinema_pi/play.sh << 'ENDPLAY'
#!/bin/bash
# Note: mpv must receive the full path for bookmark persistence
FILMS_DIR="${FILMS_DIR:-/mnt/MediaDrive/Movies}"
FULL_PATH="$FILMS_DIR/$1"

if [ ! -f "$FULL_PATH" ]; then
    echo "[X] File not found: $FULL_PATH"
    exit 1
fi

pkill -15 mpv 2>/dev/null
sleep 0.3

echo "[TV] Turning TV on..."
echo "on 0" | cec-client -s -d 1 >/dev/null 2>&1 &
sleep 5

echo "[>>] Loading movie..."
echo "[>] Playing: $(basename "$FULL_PATH")"

# Optimized MPV launch - Stable anti-stutter configuration
setsid mpv --fs \
    --vo=gpu \
    --gpu-api=opengl \
    --gpu-dumb-mode=yes \
    --drm-connector=HDMI-A-1 \
    --hwdec=drm-copy \
    --ao=alsa \
    --cache=yes \
    --cache-secs=300 \
    --demuxer-max-bytes=2048M \
    --demuxer-readahead-secs=180 \
    --stream-buffer-size=16M \
    --hr-seek=yes \
    --hr-seek-framedrop=no \
    --audio-buffer=1.0 \
    --opengl-glfinish=yes \
    --really-quiet \
    --no-terminal \
    --no-input-default-bindings \
    --input-ipc-server=/tmp/mpv-socket \
    "$FULL_PATH" </dev/null >/dev/null 2>&1 &

echo "[OK] Playback started (use 'stop' to quit)"
ENDPLAY

# stop.sh - Stops the movie and turns off the TV
cat > ~/.cinema_pi/stop.sh << 'ENDSTOP'
#!/bin/bash
echo "[||] Stopping playback..."
pkill -15 mpv 2>/dev/null
sleep 0.5
echo "[TV] Turning TV off..."
echo "standby 0" | cec-client -s -d 1 >/dev/null 2>&1 &
sleep 0.5
echo "[OK] Playback stopped - TV standby"
ENDSTOP

# diagnostic.sh
cat > ~/.cinema_pi/diagnostic.sh << 'ENDDIAG'
#!/bin/bash
echo "[?] Cinema Pi Diagnostic - Configuration Check..."
echo "[1] Available DRM Connectors:"
modetest -c 2>/dev/null | grep -A 1 "^Connectors:" || echo "   [!] modetest not available"
echo "[2] Available Hardware Decoders:"
mpv --hwdec=help | grep -E "v4l2m2m|rpi|mmal|drm"
echo "[3] Disk Mount Point:"
if mountpoint -q "$FILMS_DIR" 2>/dev/null || [ -d "$FILMS_DIR" ]; then
    echo "   [OK] $FILMS_DIR is accessible"
    ls -lh "$FILMS_DIR" | head -5
else
    echo "   [X] $FILMS_DIR is inaccessible"
fi
echo "[4] CEC Devices:"
echo "scan" | cec-client -s -d 1 2>&1 | grep -E "device|POWER"
ENDDIAG

# control.sh - Control MPV via IPC
cat > ~/.cinema_pi/control.sh << 'ENDCONTROL'
#!/bin/bash
SOCKET="/tmp/mpv-socket"
MARKS_FILE="$HOME/.cinema_pi/marks.txt"

if [ ! -S "$SOCKET" ]; then
    echo "[X] No playback currently running"
    exit 1
fi

mpv_cmd() {
    # JSON command must be on a single line
    # Fix: Use grep -v to suppress MPV's common success response forms
    echo "$1" | socat - "$SOCKET" 2>/dev/null | grep -v -E '\{"request_id":0,"error":"success"\}|\{"data":null,"request_id":0,"error":"success"\}'
}

getCurrentPath() {
    # Retrieves the FULL path of the currently playing file
    mpv_cmd '{"command": ["get_property", "path"]}' | grep -o '"data":"[^"]*"' | cut -d'"' -f4
}

getCurrentFilename() {
    # Retrieves the filename (for display)
    mpv_cmd '{"command": ["get_property", "filename"]}' | grep -o '"data":"[^"]*"' | cut -d'"' -f4
}

case "$1" in
    pause)
        mpv_cmd '{"command": ["cycle", "pause"]}'
        echo "[||] Paused/Resumed"
        ;;
    continue)
        mpv_cmd '{"command": ["set_property", "pause", false]}'
        echo "[>] Resuming playback"
        ;;
    timing)
        if [ -n "$2" ]; then
            # Convert xx:xx:xx to seconds
            IFS=':' read -ra TIME <<< "$2"
            if [ ${#TIME[@]} -eq 3 ]; then
                SECS=$((10#${TIME[0]} * 3600 + 10#${TIME[1]} * 60 + 10#${TIME[2]}))
            elif [ ${#TIME[@]} -eq 2 ]; then
                SECS=$((10#${TIME[0]} * 60 + 10#${TIME[1]}))
            else
                SECS="$2"
            fi
            mpv_cmd "{\"command\": [\"seek\", $SECS, \"absolute\"]}"
            echo "[>>] Jumped to $2"
        else
            RESULT=$(mpv_cmd '{"command": ["get_property", "time-pos"]}' | grep -o '"data":[0-9.]*' | cut -d: -f2)
            DURATION=$(mpv_cmd '{"command": ["get_property", "duration"]}' | grep -o '"data":[0-9.]*' | cut -d: -f2)
            if [ -n "$RESULT" ] && [ -n "$DURATION" ]; then
                POS=$(printf "%.0f" "$RESULT")
                DUR=$(printf "%.0f" "$DURATION")
                POS_H=$((POS / 3600))
                POS_M=$(((POS % 3600) / 60))
                POS_S=$((POS % 60))
                DUR_H=$((DUR / 3600))
                DUR_M=$(((DUR % 3600) / 60))
                DUR_S=$((DUR % 60))
                printf "[TIME] Position: %02d:%02d:%02d / %02d:%02d:%02d\n" $POS_H $POS_M $POS_S $DUR_H $DUR_M $DUR_S
            else
                echo "[X] Could not retrieve timing"
            fi
        fi
        ;;
    rewind)
        SECS="${2:-10}"
        mpv_cmd "{\"command\": [\"seek\", -$SECS, \"relative\"]}"
        echo "[<<] Rewinding by ${SECS}s"
        ;;
    jump)
        SECS="${2:-10}"
        mpv_cmd "{\"command\": [\"seek\", $SECS, \"relative\"]}"
        echo "[>>] Jumping forward by ${SECS}s"
        ;;
    mark)
        if [ -z "$2" ]; then
            echo -n "[*] Bookmark name: "
            read MARK_NAME
        else
            MARK_NAME="$2"
        fi
        RESULT=$(mpv_cmd '{"command": ["get_property", "time-pos"]}' | grep -o '"data":[0-9.]*' | cut -d: -f2)
        # Using the FULL path for persistence
        FULL_PATH=$(getCurrentPath) 
        if [ -n "$RESULT" ] && [ -n "$FULL_PATH" ]; then
            POS=$(printf "%.0f" "$RESULT")
            # Adding the FULL file path to link the bookmark
            echo "$FULL_PATH|$MARK_NAME|$POS" >> "$MARKS_FILE"
            POS_H=$((POS / 3600))
            POS_M=$(((POS % 3600) / 60))
            POS_S=$((POS % 60))
            printf "[OK] Bookmark '%s' created at %02d:%02d:%02d for '%s'\n" "$MARK_NAME" $POS_H $POS_M $POS_S "$(basename "$FULL_PATH")"
        else
            echo "[X] Could not create bookmark"
        fi
        ;;
    goto)
        if [ -z "$2" ]; then
            echo "[X] Usage: cinema goto <bookmark_name>"
            exit 1
        fi
        # Using the full path to search for the bookmark
        FULL_PATH=$(getCurrentPath) 
        if [ -f "$MARKS_FILE" ]; then
            # Search for the bookmark linked to the current movie via its full path
            MARK=$(grep "^$FULL_PATH|$2|" "$MARKS_FILE" | tail -1)
            if [ -n "$MARK" ]; then
                POS=$(echo "$MARK" | cut -d'|' -f3)
                mpv_cmd "{\"command\": [\"seek\", $POS, \"absolute\"]}"
                POS_H=$((POS / 3600))
                POS_M=$(((POS % 3600) / 60))
                POS_S=$((POS % 60))
                printf "[>>] Jumping back to bookmark '%s' (%02d:%02d:%02d)\n" "$2" $POS_H $POS_M $POS_S
            else
                echo "[X] Bookmark '$2' not found for this movie"
            fi
        else
            echo "[X] No bookmarks saved"
        fi
        ;;
    marks)
        if [ -f "$MARKS_FILE" ]; then
            FULL_PATH=$(getCurrentPath)
            echo "[*] Bookmarks for current movie ('$(basename "$FULL_PATH")'):"
            # Filter by full path
            grep "^$FULL_PATH|" "$MARKS_FILE" | while IFS='|' read -r file name pos; do
                POS_H=$((pos / 3600))
                POS_M=$(((pos % 3600) / 60))
                POS_S=$((pos % 60))
                printf "   - %s (%02d:%02d:%02d)\n" "$name" $POS_H $POS_M $POS_S
            done
            if ! grep -q "^$FULL_PATH|" "$MARKS_FILE"; then
                echo "   (No bookmarks found for this movie)"
            fi
        else
            echo "[X] No bookmarks saved"
        fi
        ;;
    unmark)
        FULL_PATH=$(getCurrentPath)
        FILENAME=$(basename "$FULL_PATH")
        if [ -f "$MARKS_FILE" ]; then
            if [ -z "$2" ]; then
                # Delete ALL bookmarks for the current movie
                grep -v "^$FULL_PATH|" "$MARKS_FILE" > "${MARKS_FILE}.tmp"
                mv "${MARKS_FILE}.tmp" "$MARKS_FILE"
                echo "[OK] All bookmarks for '$FILENAME' have been deleted."
            else
                # Delete a specific bookmark
                if grep -q "^$FULL_PATH|$2|" "$MARKS_FILE"; then
                    grep -v "^$FULL_PATH|$2|" "$MARKS_FILE" > "${MARKS_FILE}.tmp"
                    mv "${MARKS_FILE}.tmp" "$MARKS_FILE"
                    echo "[OK] Bookmark '$2' deleted for '$FILENAME'."
                else
                    echo "[X] Bookmark '$2' not found for this movie."
                fi
            fi
        else
            echo "[X] No bookmarks saved."
        fi
        ;;
    subs)
        if [ -z "$2" ]; then
            # Cycle to the next subtitle track or disable/enable
            mpv_cmd '{"command": ["cycle", "sub"]}'
            echo "[S] Subtitle track changed (or enabled/disabled)."
        elif [ "$2" = "off" ]; then
            # Disable
            mpv_cmd '{"command": ["set_property", "sub-visibility", false]}'
            echo "[S] Subtitles disabled."
        elif [ "$2" = "on" ]; then
            # Enable
            mpv_cmd '{"command": ["set_property", "sub-visibility", true]}'
            echo "[S] Subtitles enabled."
        elif [[ "$2" =~ ^[0-9]+$ ]]; then
            # Select a track by number
            mpv_cmd "{\"command\": [\"set_property\", \"sid\", $2]}"
            echo "[S] Subtitle track selected: $2."
        else
            echo "[X] Usage: subs [on|off|number|cycle]"
        fi
        ;;
    audio)
        if [ -z "$2" ]; then
            # Cycle to the next audio track
            mpv_cmd '{"command": ["cycle", "audio"]}'
            echo "[A] Audio track changed."
        elif [[ "$2" =~ ^[0-9]+$ ]]; then
            # Select a track by number
            mpv_cmd "{\"command\": [\"set_property\", \"aid\", $2]}"
            echo "[A] Audio track selected: $2."
        else
            echo "[X] Usage: audio [number|cycle]"
        fi
        ;;
    volume)
        if [[ "$2" =~ ^[+-][0-9]+$ ]]; then
            # Increase/decrease volume
            mpv_cmd "{\"command\": [\"add\", \"volume\", \"$2\"]}"
            echo "[V] Volume adjusted."
        elif [[ "$2" =~ ^[0-9]+$ ]]; then
            # Set absolute volume
            mpv_cmd "{\"command\": [\"set_property\", \"volume\", \"$2\"]}"
            echo "[V] Volume set to $2%."
        else
            # Display current volume
            VOL=$(mpv_cmd '{"command": ["get_property", "volume"]}' | grep -o '"data":[0-9.]*' | cut -d: -f2 | cut -d'.' -f1)
            echo "[V] Current volume: ${VOL}%."
        fi
        ;;
    status)
        if [ ! -S "$SOCKET" ]; then
            echo "[X] No playback currently running."
            exit 1
        fi
        FILENAME=$(getCurrentFilename)
        PAUSED=$(mpv_cmd '{"command": ["get_property", "pause"]}' | grep -o '"data":[^}]*' | cut -d':' -f2)
        TIME_POS=$(mpv_cmd '{"command": ["get_property", "time-pos"]}' | grep -o '"data":[0-9.]*' | cut -d: -f2)
        DURATION=$(mpv_cmd '{"command": ["get_property", "duration"]}' | grep -o '"data":[0-9.]*' | cut -d: -f2)
        AUDIO_ID=$(mpv_cmd '{"command": ["get_property", "aid"]}' | grep -o '"data":[0-9.]*' | cut -d: -f2)
        SUB_ID=$(mpv_cmd '{"command": ["get_property", "sid"]}' | grep -o '"data":[0-9.]*' | cut -d: -f2)
        
        POS=$(printf "%.0f" "$TIME_POS" 2>/dev/null)
        DUR=$(printf "%.0f" "$DURATION" 2>/dev/null)
        
        POS_H=$((POS / 3600))
        POS_M=$(((POS % 3600) / 60))
        POS_S=$((POS % 60))
        DUR_H=$((DUR / 3600))
        DUR_M=$(((DUR % 3600) / 60))
        DUR_S=$((DUR % 60))

        echo "[*] Playback Status:"
        echo "  Movie:   $(basename "$FILENAME")"
        echo "  Status:  $(if [ "$PAUSED" = "true" ]; then echo "Paused"; else echo "Playing"; fi)"
        printf "  Timing:  %02d:%02d:%02d / %02d:%02d:%02d\n" $POS_H $POS_M $POS_S $DUR_H $DUR_M $DUR_S
        echo "  Audio ID: $AUDIO_ID"
        echo "  Subtitle ID: $SUB_ID"
        ;;
    loop)
        mpv_cmd '{"command": ["cycle", "loop-file"]}'
        STATUS=$(mpv_cmd '{"command": ["get_property", "loop-file"]}' | grep -o '"data":[^}]*' | cut -d':' -f2)
        if [ "$STATUS" = "no" ] || [ "$STATUS" = "false" ]; then
            echo "[L] File looping disabled."
        else
            echo "[L] File looping enabled."
        fi
        ;;
    *)
        echo "[X] Unknown command: $1"
        exit 1
        ;;
esac
ENDCONTROL

chmod +x ~/.cinema_pi/*.sh

# bash function cinema (Updated for direct commands)
cat >> ~/.bashrc << 'ENDBASH'
# CINEMA PI
# Ensure the path is correct on your system.
export FILMS_DIR="/mnt/MediaDrive/Movies" 

# Define all available commands for direct execution
CINEMA_COMMANDS="play random stop pause continue timing rewind jump mark goto marks unmark subs audio volume status loop diag list"

# Main cinema function
cinema() {
    # If no argument or if the argument is the function itself (if called directly)
    if [ -z "$1" ] || [ "$1" = "cinema" ]; then
        echo "[*] CINEMA PI - Available Commands (use directly or with 'cinema'):" 
        echo "  Playback:   play, play [name], random, list"
        echo "  Control:    pause, continue, stop, status"
        echo "  Timing:     timing, timing [hh:mm:ss]"
        echo "  Navigation: rewind [x], jump [x]"
        echo "  Tracks:     subs [on|off|#], audio [#]"
        echo "  Volume:     volume [+/-#]"
        echo "  Bookmarks:  mark [name], goto <name>, marks, unmark [name]"
        echo "  Other:      loop, diag, diagnostic"
        return 0
    fi
    
    # Execute the subcommand
    case "$1" in
        play)
            if [ -z "$2" ]; then
                [ ! -d "$FILMS_DIR" ] && echo "[X] $FILMS_DIR not found" && return 1
                cd "$FILMS_DIR" || return 1
                
                # 1. Exclude hidden files (! -iname ".*"). 
                # 2. Remove extension with sed before listing with fzf.
                FILM_LIST=$(find . -maxdepth 1 -type f \
                    \( -iname "*.mp4" -o -iname "*.mkv" \) \
                    ! -iname ".*" \
                    -printf "%f\n" | sort)
                
                # Create a list for display (no extension) and a map (display name -> real name)
                MAP_FILE_NAMES=$(echo "$FILM_LIST" | while read -r line; do echo "$(basename "$line" | sed 's/\.[^.]*$//')~$line"; done)

                # Display the clean list (no extension) in fzf
                DISPLAY_NAME=$(echo "$MAP_FILE_NAMES" | cut -d'~' -f1 | fzf --prompt="[*] Select a movie: " --height=50% --reverse --border)
                
                # Retrieve the actual filename with extension from the display name
                if [ -n "$DISPLAY_NAME" ]; then
                    FULL_FILENAME=$(echo "$MAP_FILE_NAMES" | grep "^$DISPLAY_NAME~" | head -1 | cut -d'~' -f2)
                    [ -n "$FULL_FILENAME" ] && ~/.cinema_pi/play.sh "$FULL_FILENAME"
                fi
            else
                cd "$FILMS_DIR" || return 1
                QUERY="${*:2}"
                # Use the new file filter and search in full names
                FILM=$(find . -maxdepth 1 -type f \
                    \( -iname "*.mp4" -o -iname "*.mkv" \) \
                    ! -iname ".*" \
                    -printf "%f\n" | grep -i "$QUERY" | head -1)
                [ -n "$FILM" ] && ~/.cinema_pi/play.sh "$FILM" || echo "[X] No movie found containing '$QUERY'"
            fi
            ;;
        random)
            cd "$FILMS_DIR" || return 1
            # Exclude hidden files for random selection
            FILM=$(find . -maxdepth 1 -type f \
                \( -iname "*.mp4" -o -iname "*.mkv" \) \
                ! -iname ".*" \
                -printf "%f\n" | shuf -n 1)
            [ -n "$FILM" ] && ~/.cinema_pi/play.sh "$FILM"
            ;;
        stop) ~/.cinema_pi/stop.sh ;;
        pause) ~/.cinema_pi/control.sh pause ;;
        continue) ~/.cinema_pi/control.sh continue ;;
        timing) ~/.cinema_pi/control.sh timing "$2" ;;
        rewind) ~/.cinema_pi/control.sh rewind "${2:-10}" ;;
        jump) ~/.cinema_pi/control.sh jump "${2:-10}" ;;
        mark) ~/.cinema_pi/control.sh mark "$2" ;;
        goto) ~/.cinema_pi/control.sh goto "$2" ;;
        marks) ~/.cinema_pi/control.sh marks ;;
        unmark) ~/.cinema_pi/control.sh unmark "$2" ;;
        subs) ~/.cinema_pi/control.sh subs "$2" ;;
        audio) ~/.cinema_pi/control.sh audio "$2" ;;
        volume) ~/.cinema_pi/control.sh volume "$2" ;;
        status) ~/.cinema_pi/control.sh status ;;
        loop) ~/.cinema_pi/control.sh loop ;;
        diag|diagnostic) ~/.cinema_pi/diagnostic.sh ;;
        list) 
            cd "$FILMS_DIR" || return 1
            # 1. Exclude hidden files. 2. Remove extension for display.
            find . -maxdepth 1 -type f \
                \( -iname "*.mp4" -o -iname "*.mkv" \) \
                ! -iname ".*" \
                -printf "%f\n" | sort | sed 's/\.[^.]*$//'
            ;;
        *) echo "[X] Unknown command: $1" && return 1 ;;
    esac
}

# Create wrapper functions (aliases) for each main command
for cmd in $CINEMA_COMMANDS; do
    # Check if the command does not already exist (to avoid overwriting a system command)
    if ! command -v "$cmd" &> /dev/null; then
        eval "$cmd() { cinema \"$cmd\" \"\$@\"; }"
    fi
done

# END CINEMA
ENDBASH

# 6. GPU and USB OPTIMIZATIONS
CONFIG_TXT=""
[ -f /boot/firmware/config.txt ] && CONFIG_TXT="/boot/firmware/config.txt"
[ -f /boot/config.txt ] && CONFIG_TXT="/boot/config.txt"
[ -n "$CONFIG_TXT" ] && {
    sudo cp "$CONFIG_TXT" "${CONFIG_TXT}.backup.$(date +%Ym%d_%H%M%S)"
    # Ensure at least 256MB for GPU
    grep -q "^gpu_mem=" "$CONFIG_TXT" || echo "gpu_mem=256" | sudo tee -a "$CONFIG_TXT"
    # Force HDMI hotplug detection
    grep -q "^hdmi_force_hotplug=1" "$CONFIG_TXT" || echo "hdmi_force_hotplug=1" | sudo tee -a "$CONFIG_TXT"
}
# Prevent USB drives from entering power saving mode
echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="on"' | sudo tee /etc/udev/rules.d/50-usb-power.rules > /dev/null

# 7. VERIFICATION
command -v mpv >/dev/null 2>&1 || echo "[X] mpv is not installed"
command -v cec-client >/dev/null 2>&1 || echo "[X] cec-client is not installed"
command -v fzf >/dev/null 2>&1 || echo "[X] fzf is not installed"
command -v socat >/dev/null 2>&1 || echo "[X] socat is not installed"
[ -d "$MOUNT_POINT" ] || echo "[X] Mount point is missing"

echo "[OK] INSTALLATION COMPLETE!"
echo "[*] Final step: source ~/.bashrc"