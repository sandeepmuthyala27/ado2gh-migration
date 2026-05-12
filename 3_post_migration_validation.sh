#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="validation-log-$(date +%Y%m%d).txt"
VALIDATION_FAILURES=0
VALIDATION_SUCCESSES=0

write_log() {
  local message="$1"
  echo "$message" | tee -a "$LOG_FILE"
}

is_json() { jq -e . >/dev/null 2>&1; }

urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

clean_field() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#\"}"
  s="${s%\"}"
  s="$(printf '%s' "$s" | xargs)"
  printf '%s' "$s"
}

parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next

  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"

    if [[ "$char" == '"' ]]; then
      if [[ "$in_quotes" == true ]]; then
        if [[ "$next" == '"' ]]; then field+='"'; ((i++))
        else in_quotes=false; fi
      else in_quotes=true; fi
    elif [[ "$char" == ',' && "$in_quotes" == false ]]; then
      fields+=("$field"); field=""
    else field+="$char"
    fi
  done
  fields+=("$field")

  while [ "${#fields[@]}" -lt 7 ]; do fields+=(""); done

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${fields[0]}" "${fields[1]}" "${fields[2]}" \
    "${fields[3]}" "${fields[4]}" "${fields[5]}" "${fields[6]}"
}

validate_migration() {
  local ado_org="$1"
  local ado_team_project="$2"
  local ado_repo="$3"
  local github_org="$4"
  local github_repo="$5"

  local has_validation_errors=0
  write_log "Validating: $ado_repo -> $github_org/$github_repo"

  # GitHub branches
  local gh_branches
  gh_branches=$(gh api "/repos/$github_org/$github_repo/branches" --paginate)
  mapfile -t gh_branch_array < <(echo "$gh_branches" | jq -r '.[].name')

  # GitHub default branch
  local gh_default_branch
  gh_default_branch=$(gh api "/repos/$github_org/$github_repo" --jq '.default_branch')

  # ADO auth
  local base64_auth
  base64_auth=$(printf ":%s" "$ADO_PAT" | base64 -w 0 2>/dev/null || printf ":%s" "$ADO_PAT" | base64)

  # ADO repo lookup
  local encoded_project
  encoded_project=$(urlencode "$ado_team_project")

  local repo_list_resp
  repo_list_resp=$(curl -s -H "Authorization: Basic $base64_auth" \
    "https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories?api-version=7.1")

  local repo_id
  repo_id=$(echo "$repo_list_resp" | jq -r --arg name "$ado_repo" '.value[] | select(.name == $name) | .id')

  local ado_default_ref
  ado_default_ref=$(echo "$repo_list_resp" | jq -r --arg id "$repo_id" '.value[] | select(.id == $id) | .defaultBranch')

  local ado_default_branch="${ado_default_ref#refs/heads/}"

  write_log "Default branch: ADO=$ado_default_branch | GitHub=$gh_default_branch"

  # ADO branches
  local ado_branch_response
  ado_branch_response=$(curl -s -H "Authorization: Basic $base64_auth" \
    "https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories/$repo_id/refs?filter=heads/&api-version=7.1")

  mapfile -t ado_branch_array < <(echo "$ado_branch_response" | jq -r '.value[].name | sub("refs/heads/";"")')

  # Branch count comparison
  local gh_branch_count=${#gh_branch_array[@]}
  local ado_branch_count=${#ado_branch_array[@]}

  local branch_status="❌ Not Matching"
  if [ "$gh_branch_count" -eq "$ado_branch_count" ]; then
    branch_status="✅ Matching"
  else
    has_validation_errors=1
  fi
  write_log "Branch Count: ADO=$ado_branch_count | GitHub=$gh_branch_count | $branch_status"

  # Build sets
  declare -A gh_set=()
  declare -A ado_set=()
  for b in "${gh_branch_array[@]}"; do gh_set["$b"]=1; done
  for b in "${ado_branch_array[@]}"; do ado_set["$b"]=1; done

  # Determine validation branch
  local validation_branch=""
  if [[ "$gh_default_branch" == "$ado_default_branch" ]]; then
    validation_branch="$gh_default_branch"
  elif [[ -n "${gh_set[$gh_default_branch]:-}" ]]; then
    validation_branch="$gh_default_branch"
  elif [[ -n "${gh_set[$ado_default_branch]:-}" ]]; then
    validation_branch="$ado_default_branch"
  else
    has_validation_errors=1
  fi

  # --- Commit + SHA (default branch only) ---
  if [[ "${COMMIT_CHECK:-true}" == "true" && -n "$validation_branch" ]]; then
    local b="$validation_branch"

    # GitHub commits
    local gh_commit_count
    gh_commit_count=$(gh api "/repos/$github_org/$github_repo/commits?sha=$b" --paginate | jq -r 'length')

    local gh_latest_sha
    gh_latest_sha=$(gh api "/repos/$github_org/$github_repo/commits?sha=$b" | jq -r '.[0].sha')

    # ADO commits
    local ado_commit_resp
    ado_commit_resp=$(curl -s -H "Authorization: Basic $base64_auth" \
      "https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories/$repo_id/commits?searchCriteria.itemVersion.version=$b&api-version=7.1")

    local ado_commit_count
    ado_commit_count=$(echo "$ado_commit_resp" | jq -r '.count')

    local ado_latest_sha
    ado_latest_sha=$(echo "$ado_commit_resp" | jq -r '.value[0].commitId')

    # Commit status
    local commit_status="❌ Not Matching"
    if [ "$gh_commit_count" -eq "$ado_commit_count" ]; then
      commit_status="✅ Matching"
    else
      has_validation_errors=1
    fi

    # SHA status
    local sha_status="❌ Not Matching"
    if [ "$gh_latest_sha" = "$ado_latest_sha" ]; then
      sha_status="✅ Matching"
    else
      has_validation_errors=1
    fi

    write_log "Default branch '$b': ADO Commits=$ado_commit_count | GitHub Commits=$gh_commit_count | $commit_status"
    write_log "Default branch '$b': ADO SHA=$ado_latest_sha | GitHub SHA=$gh_latest_sha | $sha_status"
  fi

  return $has_validation_errors
}

# MAIN
CSV_INPUT="${1:-repos_with_status.csv}"

while read -r line; do
  line="${line%$'\r'}"
  [ -z "$line" ] && continue

  IFS=$'\t' read -r org teamproject repo github_org github_repo _ status \
    < <(parse_csv_line "$line")

  org=$(clean_field "$org")
  teamproject=$(clean_field "$teamproject")
  repo=$(clean_field "$repo")
  github_org=$(clean_field "$github_org")
  github_repo=$(clean_field "$github_repo")
  status=$(clean_field "$status")

  if [ "$status" != "Success" ]; then continue; fi

  if validate_migration "$org" "$teamproject" "$repo" "$github_org" "$github_repo"; then
    VALIDATION_SUCCESSES=$((VALIDATION_SUCCESSES + 1))
  else
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
  fi

done < <(tail -n +2 "$CSV_INPUT")

write_log "Summary: $VALIDATION_SUCCESSES succeeded, $VALIDATION_FAILURES failed"

exit 0