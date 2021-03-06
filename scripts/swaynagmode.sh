#!/bin/bash

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# https://github.com/swaywm/sway/blob/master/contrib/grimshot

declare        prog="swaynagmode"
declare     version="v0.2.1"
declare     authors=("Maddison Hellstrom <github.com/b0o>")
declare  repository="github.com/b0o/swaynagmode"
declare     license="GPL"
declare license_url="https://www.gnu.org/licenses/gpl-3.0.txt"

mapfile -t usage << EOF
$prog
$version
$repository

A wrapper script which provides programmatic control
over swaynag, intended for use with keyboard bindings.

To create a nag, simply use swaynag options as normal - they will be parsed and passed through.

To customise a nag, use these additional options:

  short      long           description
  -M <mode>  --mode         name of sway mode to trigger on init (default: nag)
                            NOTE: beginning in sway version 1.2, mode names are case-sensitive
  -D <mode>  --mode-default name of sway mode to trigger on exit (default: default)
             --no-mode      disable triggering of sway modes
  -i <index> --initial      index of the initially selected button (default: 0)
  -K         --no-kill      don't add a kill command to the button actions
  -R         --reverse      reverse the button order

To control an existing nag, use the following options:

  short           long       description
  -x              --exit     dismisses the nag without performing any actions
  -S <prev|next>  --select   selects the previous/next button, wrapping around each end
                             (as specified in arguments left to right, buttons appear from right to
                             left)
  -C              --confirm  accepts the selected button (indicated with [brackets]) and executes its
                             action.

Global options:
  short  long       description
  -h     --help     display usage information for $prog and swaynag
  -H     --help-snm display usage information for $prog
  -v     --version  output version

Caveats:
  - Only one instance of swaynagmode may be run at a time.

Example sway configuration:

  # nag
  set {
    \$nag         exec swaynagmode
    \$nag_exit    \$nag --exit
    \$nag_confirm \$nag --confirm
    \$nag_select  \$nag --select
  }
  mode "nag" {
    bindsym {
      Ctrl+d    mode "default"

      Ctrl+c    \$nag_exit
      q         \$nag_exit
      Escape    \$nag_exit

      Return    \$nag_confirm

      Tab       \$nag_select prev
      Shift+Tab \$nag_select next

      Left      \$nag_select next
      Right     \$nag_select prev

      Up        \$nag_select next
      Down      \$nag_select prev
    }
  }
  bindsym {
    \$super+Shift+q \$nag -t "warning" -m "Exit Sway?" -b "Exit" "swaymsg exit" -b "Reload" "swaymsg reload"
  }
  # -R is recommended for swaynag_command so that, upon a syntax error in your sway config, the
  # 'Reload Sway' option will be initially selected instead of the 'Exit Sway' option
  swaynag_command \$nag -R


(c) 2019-$(date +%Y) ${authors[*]}

$license License ($license_url)
EOF

# XXX: this is a bodge to prevent swaynagmode from segfaulting when killing/restarting swaynag
[[ -v WAYLAND_SOCKET ]] && unset WAYLAND_SOCKET

declare nag="swaynag"
declare msg="swaymsg"

declare mode_nag="nag"
declare mode_def="default"

declare -i no_mode=0
declare -i no_kill=0

declare -i button_reverse=0

declare -a args

declare -a buttons
declare -a actions
declare -a methods
declare -i btn_cursor=0

declare -i nag_pid=-1

declare M_TERM=TERM
declare M_NOTERM=NOTERM

declare S_CONF=HUP
declare S_NEXT=CONT
declare S_PREV=USR2

function usage() {
  printf '%s\n' "${usage[@]}"
}

function _pkill() {
  pkill -ox "$@" >&2 || {
    echo "no such process: $*" >&2
  }
}

function init() {
  while [[ $# -gt 0 ]]; do
    [[ $1 =~ ^(-x|--exit)$ ]] && {
      _pkill -INT "$prog"
      exit 0
    }

    [[ $1 =~ ^(-C|--confirm)$ ]] && {
      _pkill -"$S_CONF" "$prog"
      exit 0
    }

    [[ $1 =~ ^(-h|--help)$ ]] && {
      echo "swaynagmode help:"
      usage
      echo -e "\nswaynag help:"
      "$nag" "$1"
      exit 0
    }

    [[ $1 =~ ^(-H|--help-snm)$ ]] && {
      usage
      exit 0
    }

    [[ $1 =~ ^(-v|--version)$ ]] && {
      echo "$prog $version"
      "$nag" "$1"
      exit 0
    }

    [[ $1 =~ ^(-S|--select)$ ]] && {
      declare sig
      case $2 in
      "prev")
        sig=$S_PREV
        ;;
      "next")
        sig=$S_NEXT
        ;;
      *)
        echo "error: --select: expected one of (prev|next)" >&2
        exit 1
        ;;
      esac
      _pkill -"$sig" "$prog"
      exit 0
    }

    [[ $1 =~ ^(-i|--initial)$ ]] && {
      btn_cursor=$2
      [[ $btn_cursor -ne $2 ]] && {
        echo "error: --initial: expected int, got '$2'" >&2
        exit 1
      }
      shift 2
    }

    [[ $1 =~ ^(-K|--no-kill)$ ]] && {
      no_kill=1
      shift
    }

    [[ $1 =~ ^(-R|--reverse)$ ]] && {
      button_reverse=1
      shift
    }

    [[ $1 =~ ^(--no-mode)$ ]] && {
      no_mode=1
      shift
    }

    [[ $1 =~ ^(-M|--mode)$ ]] && {
      mode_nag=$2
      [[ -z $mode_nag ]] && {
        echo "error: --mode: expected string, got '$2'" >&2
        exit 1
      }
      shift 2
    }

    [[ $1 =~ ^(-D|--mode-default)$ ]] && {
      mode_def=$2
      [[ -z $mode_def ]] && {
        echo "error: --mode-default: expected string, got '$2'" >&2
        exit 1
      }
      shift 2
    }

    [[ $1 =~ ^(-b|--button|-B|--button-no-terminal)$ ]] && {
      declare act_method=$M_NOTERM
      [[ $1 =~ ^(-b|--button)$ ]] && {
        act_method=$M_TERM
      }
      methods+=("$act_method")

      shift
      buttons+=("$1")
      shift
      actions+=("$1")
      shift
      continue
    }

    [[ $1 =~ ^(-l|--detailed-message)$ ]] && {
      detailed_msg="$(mktemp "/tmp/${prog}-msg-XXXXXX")" || {
        echo "error: failed to create temp file for detailed message" >&2
        return 1
      }
      chmod u+rw "$detailed_msg"
      cat > "$detailed_msg"
    }

    args+=("$1")
    shift
  done
  [[ ${#buttons[@]} -gt 0 && ($btn_cursor -ge ${#buttons[@]} || $btn_cursor -lt 0)  ]] && {
    echo "error: --initial: index out of range: $btn_cursor" >&2
    exit 1
  }
  [[ $button_reverse -eq 1 ]] && {
    declare -a buttons_tmp=("${buttons[@]}")
    declare -a actions_tmp=("${actions[@]}")
    declare -a methods_tmp=("${methods[@]}")
    buttons=()
    actions=()
    methods=()
    for ((i = ${#buttons_tmp[@]} - 1; i >= 0; i--)); do
      echo "$i" >&2
      buttons+=("${buttons_tmp[$i]}")
      actions+=("${actions_tmp[$i]}")
      methods+=("${methods_tmp[$i]}")
    done
  }
  [[ $(pgrep -xc "$prog") -gt 1 ]] && exit 1
}

function handle_exit() {
  kill "$nag_pid" > /dev/null 2>&1 || true
  [[ $no_mode -eq 0 ]] && "$msg" mode "$mode_def"
  [[ -n $detailed_msg && -e $detailed_msg ]] && rm "$detailed_msg"
  exit 0
}

function exec_cmd() {
  sh -c "$@" &
  disown $!
}

function term_exec_cmd() {
  declare term="$1"
  declare action="$2"

  declare script
  script="$(mktemp "/tmp/${prog}-cmd-XXXXXX")" || {
    echo "error: failed to create temp script" >&2
    return 1
  }
  chmod u+rwx "$script"
  cat > "$script" << EOF
#!/bin/sh
rm $script
$action
EOF

  exec_cmd "$(printf "%s -e %s" "$term" "$script")"
}

function handle_confirm() {
  declare cmd="${actions[$btn_cursor]}"
  declare mtd="${methods[$btn_cursor]}"
  if [[ $mtd == "$M_TERM" && -n $TERMINAL ]]; then
    term_exec_cmd "$TERMINAL" "$cmd" || {
      echo "warning: failed executing action via TERMINAL ($TERMINAL): $cmd" >&2
      exit 1
    }
  else
    exec_cmd "$cmd" || {
      echo "warning: failed executing action: $cmd" >&2
      exit 1
    }
  fi
  [[ $no_kill -eq 0 ]] && {
    exit 0
  }
  display_nag
}

function handle_select() {
  declare -i dir=${1:-1}
  declare -i dest=$((btn_cursor + dir))
  if [[ $dest -ge ${#buttons[@]} ]]; then
    dest=0
  elif [[ $dest -lt 0 ]]; then
    dest=$((${#buttons[@]} - 1))
  fi
  btn_cursor=$dest
  display_nag
}

kill_nag()  {
  [[ $nag_pid -eq -1 ]] && return
  if ps "$nag_pid" > /dev/null 2>&1; then
    kill "$nag_pid"
    nag_pid=-1
  fi
}

function display_nag()  {
  declare -a nag_cmd
  declare -i i=0
  for btn in "${buttons[@]}"; do
    declare cmd=""
    declare mtd="${methods[$i]}"
    if [[ $mtd == "$M_TERM" ]]; then
      cmd="-b"
    else
      cmd="-B"
    fi
    declare txt="$btn"
    declare act="${actions[$i]}"
    [[ $no_kill -eq 0 ]] && {
      act="$prog --exit && $act"
    }
    [[ $i -eq $btn_cursor ]] && {
      txt="[${txt}]"
    }
    nag_cmd+=("${cmd}" "${txt}" "${act}")
    ((i++))
  done
  kill_nag
  [[ $no_mode -eq 0 ]] && $msg mode "$mode_nag"
  if [[ -n "$detailed_msg" ]]; then
    "$nag" "${args[@]}" "${nag_cmd[@]}" < "$detailed_msg" &
  else
    "$nag" "${args[@]}" "${nag_cmd[@]}" &
  fi
  nag_pid=$!
  wait "$nag_pid" || true
}

init "$@"

trap 'exit 0'           INT  # die with grace
trap 'handle_exit'      EXIT
trap 'handle_confirm'   $S_CONF
trap 'handle_select -1' $S_PREV
trap 'handle_select  1' $S_NEXT

display_nag
