# This file contains settings specific to the Windows Subsystem for Linux (WSL).

# Only executed if the environment is confirmed as WSL
if grep -qEi '(microsoft|wsl/|wslg/)' /proc/sys/kernel/osrelease /proc/mounts 2>/dev/null; then

    # Bridge to Docker Desktop running on Windows host
    export DOCKER_HOST='tcp://localhost:2375'

    # Testing [interop] for Windows Integration by retrieve Windows UserProfile
    # Using direct call to `cmd.exe` to bypass `appendWindowsPath=false` limitations
    if raw_profile=$(/mnt/c/Windows/System32/cmd.exe /c 'echo %UserProfile%' 2>/dev/null); then

        # Strip Carriage Return (CR) and convert to Unix-style path
        win_user=$(wslpath -u "${raw_profile//$'\r'/}" 2>/dev/null)

        # Append VS Code bin to PATH if it exists and is not already present
        code_bin="$win_user/AppData/Local/Programs/Microsoft VS Code/bin"
        [[ -d "$code_bin" && ":$PATH:" != *":$code_bin:"* ]] && export PATH="$PATH:$code_bin"

        # Alias for Windows File Explorer
        alias explorer='/mnt/c/Windows/explorer.exe'
    fi

    # Cleanup environment variables
    unset raw_profile win_user code_bin
fi
