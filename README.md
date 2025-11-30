**CINEMA PI: HEADLESS MEDIA PLAYER FOR RASPBERRY PI 5
**
Cinema Pi transforms a Raspberry Pi 5 running a minimal OS (like Pi OS Lite 64-bit) into a dedicated, high-performance media player, entirely controlled via SSH.

This solution leverages the Raspberry Pi's hardware decoding capabilities (mpv) and HDMI-CEC features to offer a truly minimalist, remote-controlled viewing experience for high-bitrate content stored on an external drive.

This application was created with the help of Gemini, Claude, and ChatGPT. 

KEY FEATURES

Headless Operation: No desktop environment required. Control everything from your computer or phone using SSH.

High Performance: Uses optimized mpv settings for smooth playback of high-bitrate video, leveraging the Pi 5's hardware decoder.

Plug-and-Play: Automatically mounts your external NTFS drive at boot using its UUID.

HDMI-CEC Control: Automatically turns your TV on/off when starting/stopping playback.

Intuitive Bash Interface: All functions are exposed via simple commands like 'play', 'stop', 'pause', 'rewind', and 'volume'.

Advanced Control: Includes features for managing Audio/Subtitle tracks, jumping to specific times, and creating file-specific bookmarks ('mark', 'goto').

INSTALLATION

The installation is handled by the script 'install-cinema-pi.sh'.

PREREQUISITES

A Raspberry Pi 5 with a recent installation of Raspberry Pi OS Lite (64-bit).

An external USB drive.

SSH access to the Raspberry Pi.

The UUID of your external drive (obtainable with the command 'sudo blkid').

STEPS

Configure the Script: Open 'install-cinema-pi-en.sh' and edit the first three configuration variables:

DISK_UUID: Set this to the UUID of your external drive.

MOUNT_POINT: Define the mount path (e.g., /mnt/MediaDrive).

FILMS_DIR: Define the path to your video library (e.g., /mnt/MediaDrive/Movies).

Execute the Script:
bash install-cinema-pi.sh

Finalize: The script will install dependencies (mpv, cec-utils, ntfs-3g, fzf, socat), configure auto-mounting in /etc/fstab, set up the control scripts, and add the 'cinema' bash function and its aliases to your ~/.bashrc.

Reload Shell:
source ~/.bashrc

USAGE (AVAILABLE COMMANDS)

After installation and sourcing ~/.bashrc, you can use the commands directly from your SSH session.

COMMAND


DESCRIPTION

'play'

Starts an interactive selection menu powered by fzf to choose a movie.

'play [name]'

Starts the movie whose name contains the search term.

'random'

Selects and starts a movie randomly from the configured directory.

'list'

Displays a list of all detected movie files (names only).

'stop'

Terminates playback (pkill mpv) and sends a CEC standby signal to the TV.

'pause'

Pauses or resumes playback.

'continue'

Forces playback resume (unpause).

'timing'

Displays the current playback position and total duration (e.g., 01:23:45 / 02:00:00).

'timing hh:mm:ss'

Jumps to an absolute time position (e.g., timing 1:15:00).

'rewind'

'rewind [x]'

Jumps backward by x seconds (default: 10 seconds).

'jump'

'jump [x]'

Jumps forward by x seconds (default: 10 seconds).

'volume'

'volume [+/-#]'

Adjusts the volume relative (+5, -10) or sets an absolute value (50).

'subs'

'subs [on/off]'

'audio'

'audio [#]'

Cycles audio tracks, or selects track number.

'mark'

'mark [name]'

Creates a bookmark at the current position for the playing file.

'goto'

'goto <name>'

Jumps to the specified bookmark for the currently playing file.

'marks'

Lists all saved bookmarks for the current movie.

'unmark'

'unmark [name]'

Deletes a specific bookmark, or all bookmarks if no name is provided.

'status'

Displays the current playback status, movie name, and track IDs.

'loop'

Toggles file looping on/off.

'diag'

diag / diagnostic

Runs a diagnostic check on hardware decoders, DRM connectors, disk mount point, and CEC devices.

HOW IT WORKS (TECHNICAL DETAILS)

Mounting: The script adds a line to /etc/fstab using the drive's UUID and the 'ntfs-3g' driver, ensuring the external drive is mounted automatically and persistently at /mnt/MediaDrive.

Playback: The 'play.sh' script uses 'setsid mpv ... &' to launch the player in the background, fully detached from the SSH session.

Control: The 'control.sh' script uses 'socat' to send JSON IPC commands to the 'mpv' instance listening on the /tmp/mpv-socket file.

Bookmarks: Bookmarks are stored in ~/.cinema_pi/marks.txt using the full file path, bookmark name, and time position in seconds.
