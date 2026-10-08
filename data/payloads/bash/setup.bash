case $- in *i*) ;; *) return ;; esac
# Keep every unique interactive command, with repeats moved to the newest entry.
HISTSIZE=-1
HISTFILESIZE=-1
HISTCONTROL=erasedups
unset HISTIGNORE
HISTFILE=${HISTFILE:-"$HOME/.bash_history"}
HISTTIMEFORMAT='%F %T '
shopt -s histappend cmdhist lithist

# Load the line editor before prompt/completion setup; attach at the end.
export PATH="$HOME/.local/bin:$PATH"
_miu_blesh="${XDG_DATA_HOME:-$HOME/.local/share}/blesh/ble.sh"
[[ -r $_miu_blesh ]] || _miu_blesh=/usr/share/blesh/ble.sh
if [[ -t 0 && -t 1 && -t 2 && ${TERM:-dumb} != dumb &&
      -r "$_miu_blesh" && ! ${BLE_VERSION-} ]]; then
    source -- "$_miu_blesh" --attach=none
fi


# Save and reload under one lock so terminals cannot overwrite each other's history.
# The helper removes saved duplicates while preserving multiline entries/timestamps.
_bash_history_sync() {
    local previous_status=$? history_lock_fd
    [[ ${HISTFILE-} && $HISTFILE != /dev/null ]] || return "$previous_status"
    exec {history_lock_fd}>"${HISTFILE}.lock" || return "$previous_status"
    if flock -x "$history_lock_fd"; then
        if history -a && history -n &&
           /usr/bin/python3 "$LIBEXEC/deduplicate-history.py" "$HISTFILE"; then
            history -c
            history -r
        fi
    fi
    exec {history_lock_fd}>&-
    return "$previous_status"
}

if [[ ${BLE_VERSION-} ]]; then
    bleopt history_limit_length=0 history_erasedups_limit=0 history_share=
    # Save before execution too, including long-running commands and exec.
    blehook PREEXEC!=_bash_history_sync
    blehook PRECMD!=_bash_history_sync
    # Replace ble.sh's unlocked exit writer with the same synchronized save.
    blehook unload-=ble/history:bash/unload.hook
    blehook unload!=_bash_history_sync
else
    # Plain Bash fallback (for terminals where ble.sh cannot attach).
    if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
        [[ " ${PROMPT_COMMAND[*]} " == *' _bash_history_sync '* ]] ||
            PROMPT_COMMAND=(_bash_history_sync "${PROMPT_COMMAND[@]}")
    elif [[ ${PROMPT_COMMAND-} != *'_bash_history_sync'* ]]; then
        PROMPT_COMMAND="_bash_history_sync${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
    fi
    trap _bash_history_sync EXIT
fi

if [[ ${TERM:-dumb} != dumb && ! ${_BASH_STARSHIP_INITIALIZED-} ]] &&
   command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
    _BASH_STARSHIP_INITIALIZED=1
fi

# Show fetch once per interactive terminal shell, before the first prompt.
# Interactive command runners (bash -ic) and redirected streams skip it.
if [[ -t 0 && -t 1 && -t 2 && ${TERM:-dumb} != dumb &&
      ! ${BASH_EXECUTION_STRING+x} && ! ${_BASH_FETCH_SHOWN-} ]] &&
   command -v fetch >/dev/null 2>&1; then
    _BASH_FETCH_SHOWN=1
    fetch --infinite
fi

# Activate Homebrew and Mise tool paths.
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
fi
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi

# Default terminal editor for applications that honor EDITOR or VISUAL.
export EDITOR=/usr/bin/mcedit
export VISUAL=/usr/bin/mcedit
export FCEDIT=/usr/bin/mcedit

# Explicit versioned commands use Debian's Python, regardless of Mise/venvs.
# Functions also apply to calls inside existing shell functions and hooks.
unalias python3 pip3 2>/dev/null || :
python3() { /usr/bin/python3 "$@"; }
pip3() { /usr/bin/python3 -m pip "$@"; }

if command -v easyvenv >/dev/null 2>&1; then
    eval "$(easyvenv activate bash)"
fi

# Attach the line editor after all startup configuration is complete.
[[ ! ${BLE_VERSION-} ]] || ble-attach
