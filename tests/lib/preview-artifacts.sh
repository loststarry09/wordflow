#!/usr/bin/env bash
# Shared acceptance predicate: metadata must name real, non-empty artifacts.
wf_preview_artifacts_exist() {
  local metadata="$1" artifact
  jq -e '.preview.artifacts | type=="array" and length>0 and all(.[]; type=="string" and length>0)' \
    <<<"$metadata" >/dev/null 2>&1 || return 1
  while IFS= read -r -d '' artifact; do
    [[ -f "$artifact" && -s "$artifact" ]] || return 1
  done < <(jq -j '.preview.artifacts[] | ., "\u0000"' <<<"$metadata")
}
