#!/usr/bin/env bash
#
# WordFlow output-name resolution (#13).
#
# Pure path logic: compute the output path for a job from a source path and an
# optional user-specified path, using the frozen default rule (spec
# `docs/spec/v0.1.md` §D2, §D3):
#
#   <source-stem>-排版.docx, then <source-stem>-排版 (2).docx,
#   <source-stem>-排版 (3).docx, …
#
# The suffix is a fixed, non-localised token and the digits are ASCII. The
# operation probes the real filesystem so it never returns a name that already
# exists (it never overwrites, and it never writes anything itself). It does not
# read or write any DOCX; every DOCX operation belongs to OfficeCLI (ADR-0001).
#
# It emits the resolved absolute path on stdout (or a JSON object with --json);
# it exits non-zero instead of guessing when a user-specified file already
# exists. Portability warnings (a name illegal on Windows) go to stderr and to
# the `warnings` field; they never change the resolved path.
#
# Usage:
#   scripts/wf-output-name.sh <source> [--output <path>] [--json]
#
# Exit codes: 0 = path resolved; 2 = bad usage; 3 = user-specified file exists
#             (refusing to overwrite); 4 = no free collision number found.
#
set -euo pipefail

SUFFIX='-排版'
EXT='.docx'
MAX_COLLISIONS=100000

usage() {
  cat <<'EOF'
Usage: wf-output-name.sh <source> [--output <path>] [--json]

Resolve the output path for a WordFlow job:
  <source-stem>-排版.docx, then "-排版 (2)", "-排版 (3)", … (ASCII digits).

Arguments:
  <source>            The source document or name to derive from. Only its name
                      is used; it need not exist and it is never read or changed.
  --output, -o <path> A user-specified target. If <path> is an existing directory
                      (or ends with a slash), the default-named file is placed
                      inside it (still collision-numbered). Otherwise <path> is
                      the exact target: if it already exists the tool refuses
                      (exit 3) rather than overwrite it.
  --json              Emit the result as JSON instead of the bare path.
  -h, --help          Show this help.

Exit codes: 0 resolved; 2 bad usage; 3 specified target exists; 4 no free name.
EOF
}

SRC=''
OUT=''
OUT_SET=0
JSON=0
while (($#)); do
  case "$1" in
    -o|--output)
      (($# >= 2)) || { echo "--output requires a path argument" >&2; exit 2; }
      OUT="$2"; OUT_SET=1; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$SRC" ]]; then
        echo "unexpected argument: $1" >&2; usage >&2; exit 2
      fi
      SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ "$OUT_SET" == 0 || -n "$OUT" ]] || { echo "--output requires a non-empty path" >&2; exit 2; }

# Absolute directory of a path whose directory may or may not exist yet.
abs_dir() {
  local d="$1"
  if [[ -d "$d" ]]; then
    (cd -- "$d" && pwd)
  elif [[ "$d" = /* ]]; then
    printf '%s\n' "${d%/}"
  else
    printf '%s/%s\n' "${PWD%/}" "${d#./}"
  fi
}

# Strip one trailing extension, but keep a leading-dot name whole (".docx").
stem_of() {
  local base="$1"
  if [[ "$base" == *.* && "$base" != .* ]]; then
    printf '%s\n' "${base%.*}"
  else
    printf '%s\n' "$base"
  fi
}

RES_OUT=''; RES_IDX=0; RES_NUM=0

# free_name <dir> <stem> — first free <dir>/<stem>-排版[(n)].docx.
# Sets RES_OUT/RES_IDX/RES_NUM. Returns 4 if every candidate is taken.
free_name() {
  local dir="$1" stem="$2" cand n
  cand="$dir/${stem}${SUFFIX}${EXT}"
  if [[ ! -e "$cand" && ! -L "$cand" ]]; then
    RES_OUT="$cand"; RES_IDX=0; RES_NUM=0; return 0
  fi
  n=2
  while ((n <= MAX_COLLISIONS)); do
    cand="$dir/${stem}${SUFFIX} (${n})${EXT}"
    if [[ ! -e "$cand" && ! -L "$cand" ]]; then
      RES_OUT="$cand"; RES_IDX="$n"; RES_NUM=1; return 0
    fi
    n=$((n + 1))
  done
  return 4
}

src_dir="$(abs_dir "$(dirname -- "$SRC")")"
src_base="$(basename -- "$SRC")"
src_stem="$(stem_of "$src_base")"

mode='default'
out_path=''
collision_index=0
numbered=0

if [[ -z "$OUT" ]]; then
  free_name "$src_dir" "$src_stem" || { echo "no free output name in $src_dir" >&2; exit 4; }
  out_path="$RES_OUT"; collision_index="$RES_IDX"; numbered="$RES_NUM"
elif [[ -d "$OUT" || "$OUT" == */ ]]; then
  dest_dir="$(abs_dir "${OUT%/}")"
  free_name "$dest_dir" "$src_stem" || { echo "no free output name in $dest_dir" >&2; exit 4; }
  out_path="$RES_OUT"; collision_index="$RES_IDX"; numbered="$RES_NUM"
  mode='specified-directory'
else
  out_dir="$(abs_dir "$(dirname -- "$OUT")")"
  out_base="$(basename -- "$OUT")"
  out_path="$out_dir/$out_base"
  if [[ -e "$out_path" || -L "$out_path" ]]; then
    echo "refusing to overwrite existing file: $out_path" >&2
    exit 3
  fi
  mode='specified-file'
fi

# --- portability warnings (never block; never change the path) -------------
warn_path() {
  local p="$1" base dev upper
  base="$(basename -- "$p")"
  case "$p" in
    *[\<\>:\"\|\?\*]*|*\\*)
      echo "path contains a character that is illegal on Windows (< > : \" \\ | ? *)" ;;
  esac
  if [[ "$p" == *[$'\x01'-$'\x1f']* ]]; then
    echo "path contains a control character"
  fi
  dev="${base%%.*}"
  upper="$(printf '%s' "$dev" | tr '[:lower:]' '[:upper:]')"
  case "$upper" in
    CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])
      echo "filename '$base' is a reserved Windows device name" ;;
  esac
  case "$base" in
    *' '|*.)
      echo "filename '$base' ends with a space or dot, which Windows does not preserve" ;;
  esac
}

declare -a warnings=()
mapfile -t warnings < <(warn_path "$out_path")
for w in "${warnings[@]:-}"; do
  if [[ -n "$w" ]]; then printf 'warning: %s\n' "$w" >&2; fi
done

if [[ "$JSON" == 0 ]]; then
  printf '%s\n' "$out_path"
  exit 0
fi

# --- JSON ------------------------------------------------------------------
json_escape() {
  local s="$1" out='' i ch hex cp
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      '"')  out+='\"' ;;
      $'\t') out+='\t' ;;
      $'\r') out+='\r' ;;
      $'\n') out+='\n' ;;
      *)
        printf -v cp '%d' "'$ch"
        if [[ "$ch" == "\\" ]]; then
          out+="\\\\"
        elif ((cp < 32)); then
          printf -v hex '\\u%04x' "$cp"
          out+="$hex"
        else
          out+="$ch"
        fi ;;
    esac
  done
  printf '%s' "$out"
}
jstr() { printf '"%s"' "$(json_escape "$1")"; }

if [[ -n "$OUT" ]]; then requested="$(jstr "$OUT")"; else requested='null'; fi
warn_json='['
sep=''
for w in "${warnings[@]:-}"; do
  if [[ -n "$w" ]]; then
    warn_json+="${sep}$(jstr "$w")"; sep=','
  fi
done
warn_json+=']'

# Recompute the final directory/stem fields from the chosen path.
final_base="$(basename -- "$out_path")"
final_dir="$(abs_dir "$(dirname -- "$out_path")")"
if [[ "$mode" == 'specified-file' ]]; then
  final_stem="$(stem_of "$final_base")"
else
  final_stem="$src_stem"
fi

printf '{\n'
printf '  "source": %s,\n' "$(jstr "$(abs_dir "$(dirname -- "$SRC")")/$src_base")"
printf '  "mode": %s,\n' "$(jstr "$mode")"
printf '  "requested": %s,\n' "$requested"
printf '  "output": %s,\n' "$(jstr "$out_path")"
printf '  "filename": %s,\n' "$(jstr "$final_base")"
printf '  "directory": %s,\n' "$(jstr "$final_dir")"
printf '  "stem": %s,\n' "$(jstr "$final_stem")"
printf '  "suffix": %s,\n' "$(jstr "$SUFFIX")"
printf '  "extension": %s,\n' "$(jstr "$EXT")"
if ((numbered)); then numbered_json='true'; else numbered_json='false'; fi
printf '  "collision_index": %s,\n' "$collision_index"
printf '  "numbered": %s,\n' "$numbered_json"
printf '  "localised": false,\n'
printf '  "warnings": %s\n' "$warn_json"
printf '}\n'
