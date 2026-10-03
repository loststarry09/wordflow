#!/usr/bin/env bash
# ADR-0003 guard shared by every filesystem writer. Paths may not exist yet;
# canonical paths catch symlink parents and dot segments, -ef catches hardlinks.
wf_paths_alias() { # <path> <path> -> success iff both identify the same file/path
  [[ -n "$1" && -n "$2" ]] || return 1
  [[ "$1" -ef "$2" || "$(realpath -m -- "$1")" == "$(realpath -m -- "$2")" ]]
}

wf_guard_destination() { # <flag/description> <destination> <protected paths...>
  local label="$1" destination="$2" input
  shift 2
  [[ -n "$destination" ]] || return 0
  for input in "$@"; do
    [[ -n "$input" ]] || continue
    if wf_paths_alias "$destination" "$input"; then
      printf '%s must not overwrite or alias a protected input: %s\n' "$label" "$input" >&2
      exit 2
    fi
  done
}
