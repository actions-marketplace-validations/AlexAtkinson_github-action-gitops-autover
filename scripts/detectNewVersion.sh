#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------------
# detectNewVersion.sh
#
# Description
#     Detects new version.
#
# --------------------------------------------------------------------------------------------------
# Source Detection
# --------------------------------------------------------------------------------------------------

sourced=0
if [ -n "$ZSH_EVAL_CONTEXT" ]; then
  case $ZSH_EVAL_CONTEXT in *:file) sourced=1;; esac
elif [ -n "$BASH_VERSION" ]; then
  (return 0 2>/dev/null) && sourced=1
else # All other shells: examine $0 for known shell binary filenames
  # Detects `sh` and `dash`; add additional shell filenames as needed.
  case ${0##*/} in sh|dash) sourced=1;; esac
fi

# --------------------------------------------------------------------------------------------------
# Help
# --------------------------------------------------------------------------------------------------

help="\

NAME
      ${0##*/}

SYNOPSIS
  ${0##*/} [-hefpndl]

DESCRIPTION
      Detects the new version for the repository by analyzing the gitflow branch history since the
      previous version tag.
      Prints only the new version to stdout by default.

      The following options are available:

      -h      Print this menu.

      -e      Export detected new version to defined variable, if valid.

      -f      Forces a re-evaluation of the entire git history.
              Commit classification runs in parallel using nproc-1 jobs (minimum 1).

      -p      Increments PATCH version on _every_ run.
              WARN: This is intended development use only.

      -n      Enables mono-repo mode allowing the product name to match against tags.
              EG: 'bob' would match tags like 'bob_1.2.3'.
              TIP: dir names and product names should match. This arg exists in case they do not.

      -d      The directory of the product to version. EG: 'path/to/bob'.

            -l      Local/debug label overrides for merged PRs.
              Format: '123=semver:patch;124=semver:minor'.

EXAMPLES
      The following detects the new version for the repo.

          ./detectNewVersion.sh

      The following detects the new version for the repo, and exports to the specified variable.

          . ./detectNewVersion.sh -e fooVar

"

printHelp() {
  echo -e "$help" >&2
}

# --------------------------------------------------------------------------------------------------
# Sanity (1/2)
# --------------------------------------------------------------------------------------------------

if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo -e "\e[01;31mFATAL\e[00m: 590 - This is not a git repository!\n"
fi

# --------------------------------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------------------------------

OPTIND=1
while getopts "he:vfpn:d:l:" opt; do
  case $opt in
    h)
      printHelp
      if [[ "$sourced" == 0 ]]; then
        exit 0
      else
        return 0
      fi
      ;;
    e)
      arg_e='set'
      arg_e_val="$OPTARG"
      ;;
    f)
      arg_f='set'
      ;;
    p)
      arg_p='set'
      ;;
    n)
      arg_n='set'
      arg_n_val="$OPTARG"
      arg_opts="$arg_opts -n $OPTARG"
      ;;
    d)
      arg_d='set'
      arg_d_val="$OPTARG"
      arg_d_opt="--full-history"
      arg_opts="$arg_opts -d $OPTARG"
      ;;
    l)
      arg_l_val="$OPTARG"
      ;;
    *)
      echo -e "\e[01;31mERROR\e[00m: 570 - Invalid argument!"
      printHelp
      if [[ "$sourced" == 0 ]]; then
        exit 0
      else
        return 0
      fi
      ;;
  esac
done
shift $((OPTIND-1))

# --------------------------------------------------------------------------------------------------
# Variables
# --------------------------------------------------------------------------------------------------

tsCmd='date --utc +%FT%T.%3NZ'

relative_path="$(dirname "${BASH_SOURCE[0]}")"
dir="$(realpath "${relative_path}")"

lastVersion=$(/usr/bin/env bash -c "${dir}/detectPreviousVersion.sh -9 $arg_opts")
lastVersionMajor=$(/usr/bin/env bash -c "${dir}/validateSemver.sh -p major $lastVersion $arg_opts")
lastVersionMinor=$(/usr/bin/env bash -c "${dir}/validateSemver.sh -p minor $lastVersion $arg_opts")
lastVersionPatch=$(/usr/bin/env bash -c "${dir}/validateSemver.sh -p patch $lastVersion $arg_opts")
lastVersionCommitHash=$(/usr/bin/env bash -c "${dir}/detectPreviousVersion.sh -9 -c $arg_opts")
lastCommitHash=$(git rev-parse HEAD)
firstCommitHash=$(git rev-list --max-parents=0 HEAD | tail -n 1)

ci_name=$("${dir}/detect-ci.sh")
origin=$(git config --get remote.origin.url)

#origin=${ci_name:-origin}
# Executes in ANY CI so long as repo origin is one of the following.
# Uncomment origin override to restrict this.
[[ "$origin" =~ "git@github.com"* || "$ci_name" == "github" ]] && origin_host=github
[[ "$origin" =~ "git@gitlab.com"* || "$ci_name" == "gitlab" ]] && origin_host=gitlab
[[ "$origin" =~ "git@bitbucket.com"* || "$ci_name" == "bitbucket" ]] && origin_host=bitbucket

case "$origin_host" in
  github)
    merge_string="Merge pull request #"
  ;;
  gitlab)
    merge_string="Merge branch"
  ;;
  bitbucket)
    merge_string="Merged in"
  ;;
  *)
    echo -e "\e[01;31mERROR\e[0m: 591 - Unsupported origin host."
    exit 1
  ;;
esac

labelOverrideSource="${arg_l_val:-${AUTOVER_PR_LABEL_OVERRIDES:-}}"

extract_pr_number() {
  local subject="$1"
  local commit_hash="$2"
  local number=''

  case "$origin_host" in
    github)
      number=$(sed -n 's/^Merge pull request #\([0-9][0-9]*\).*/\1/p' <<< "$subject")
      # Squash merges retain the PR number as a '(#123)' suffix on the commit subject.
      [[ -z "$number" ]] && number=$(sed -n 's/.*(#\([0-9][0-9]*\))$/\1/p' <<< "$subject")
    ;;
    gitlab)
      number=$(grep -o '![0-9][0-9]*' <<< "$subject" | head -n 1 | tr -d '!')
      # Merge commits carry the MR reference in the body: 'See merge request group/project!123'.
      [[ -z "$number" && -n "$commit_hash" ]] && number=$(git show -s --format=%b "$commit_hash" 2>/dev/null | grep -o '![0-9][0-9]*' | head -n 1 | tr -d '!')
    ;;
    bitbucket)
      # Both merge and squash commits use: 'Merged in <branch> (pull request #123)'.
      number=$(sed -n 's/.*(pull request #\([0-9][0-9]*\)).*/\1/p' <<< "$subject")
    ;;
  esac

  echo "$number"
}

get_override_labels() {
  local pr_number="$1"
  [[ -z "$labelOverrideSource" ]] && return 0

  while IFS= read -r mapping; do
    [[ -z "$mapping" ]] && continue
    local mapping_pr="${mapping%%=*}"
    if [[ "$mapping_pr" == "$pr_number" && "$mapping" == *"="* ]]; then
      echo "${mapping#*=}"
      return 0
    fi
  done < <(tr ';' '\n' <<< "$labelOverrideSource")
}

get_github_labels() {
  local pr_number="$1"

  local github_token="${GITHUB_TOKEN:-${AUTOVER_GITHUB_TOKEN:-}}"
  local github_repo="${GITHUB_REPOSITORY:-${AUTOVER_GITHUB_REPOSITORY:-}}"
  [[ -z "$github_token" || -z "$github_repo" ]] && return 0

  local api_root="${GITHUB_API_URL:-https://api.github.com}"
  local response
  if ! response=$(curl -fsSL \
    -H "Authorization: Bearer ${github_token}" \
    -H 'Accept: application/vnd.github+json' \
    "${api_root}/repos/${github_repo}/issues/${pr_number}/labels" 2>/dev/null); then
    echo -e "\e[01;31mERROR\e[00m: 592 - Label lookup failed for PR #${pr_number}!" >&2
    return 1
  fi

  grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "$(tr -d '\n' <<< "$response")" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' | paste -sd ',' -
}

get_gitlab_labels() {
  local mr_number="$1"

  local gitlab_token="${GITLAB_TOKEN:-${AUTOVER_GITLAB_TOKEN:-}}"
  local gitlab_project="${CI_PROJECT_ID:-${AUTOVER_GITLAB_PROJECT:-}}"
  [[ -z "$gitlab_token" || -z "$gitlab_project" ]] && return 0

  local api_root="${CI_API_V4_URL:-https://gitlab.com/api/v4}"
  local response
  if ! response=$(curl -fsSL \
    -H "PRIVATE-TOKEN: ${gitlab_token}" \
    "${api_root}/projects/${gitlab_project}/merge_requests/${mr_number}" 2>/dev/null); then
    echo -e "\e[01;31mERROR\e[00m: 592 - Label lookup failed for MR !${mr_number}!" >&2
    return 1
  fi

  tr -d '\n' <<< "$response" | sed -n 's/.*"labels":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | tr -d '"' | paste -sd ',' -
}

get_pr_labels() {
  local pr_number="$1"
  local labels

  labels=$(get_override_labels "$pr_number")
  if [[ -n "$labels" ]]; then
    echo "$labels"
    return 0
  fi

  case "$origin_host" in
    github)
      get_github_labels "$pr_number"
    ;;
    gitlab)
      get_gitlab_labels "$pr_number"
    ;;
    bitbucket)
      # Bitbucket Cloud has no PR labels. Overrides (-l/AUTOVER_PR_LABEL_OVERRIDES) still apply.
      true
    ;;
  esac
}

detect_increment_from_labels() {
  local labels="$1"
  [[ -z "$labels" ]] && return 0

  local normalized_labels
  normalized_labels=",$(tr '[:upper:]' '[:lower:]' <<< "$labels" | tr -d ' '),"

  [[ "$normalized_labels" == *",semver:major,"* || "$normalized_labels" == *",semver-major,"* || "$normalized_labels" == *",semver:breaking,"* || "$normalized_labels" == *",semver-breaking,"* ]] && {
    echo 'major'
    return 0
  }
  [[ "$normalized_labels" == *",semver:minor,"* || "$normalized_labels" == *",semver-minor,"* ]] && {
    echo 'minor'
    return 0
  }
  [[ "$normalized_labels" == *",semver:patch,"* || "$normalized_labels" == *",semver-patch,"* ]] && {
    echo 'patch'
    return 0
  }
}

detect_increment_from_branch() {
  local subject="$1"
  local branch_ref=''
  local branch_type=''

  case "$origin_host" in
    github)
      [[ "$subject" != "$merge_string"* ]] && return 0
      branch_ref="${subject#* from }"
      branch_ref="${branch_ref%% *}"
      branch_type="${branch_ref#*/}"
      branch_type="${branch_type%%/*}"
    ;;
    gitlab)
      branch_ref=$(sed -n "s/^Merge branch '\([^']*\)'.*/\1/p" <<< "$subject")
      branch_type="${branch_ref%%/*}"
    ;;
    bitbucket)
      branch_ref="${subject#Merged in }"
      branch_ref="${branch_ref%% *}"
      branch_type="${branch_ref%%/*}"
    ;;
  esac

  branch_type="${branch_type,,}"
  case "$branch_type" in
    feature|enhancement)
      echo 'minor'
    ;;
    fix|bugfix|hotfix|ops)
      echo 'patch'
    ;;
  esac
}

classify_commit() {
  local historyLine="$1"
  local commitHash="${historyLine%%$'\t'*}"
  local commitSubject="${historyLine#*$'\t'}"
  local incrementType=''
  local prNumber=''
  local prLabels=''

  if grep -q '+semver' <<< "$commitSubject" && grep -qi 'major\|breaking' <<< "$commitSubject"; then
    echo 'major'
    return 0
  fi

  prNumber=$(extract_pr_number "$commitSubject" "$commitHash")
  if [[ -n "$prNumber" ]]; then
    if ! prLabels=$(get_pr_labels "$prNumber"); then
      return 1
    fi
    incrementType=$(detect_increment_from_labels "$prLabels")
  fi

  [[ -z "$incrementType" ]] && incrementType=$(detect_increment_from_branch "$commitSubject")

  echo "$incrementType"
}

# --------------------------------------------------------------------------------------------------
# Sanity (2/2)
# --------------------------------------------------------------------------------------------------

if [[ -n $arg_e ]]; then
  if [[ "$sourced" == 0 ]]; then
    echo -e "[$(${tsCmd})] \e[01;31mERROR\e[00m: 520 - You must source this script when specifying an environment variable! Eg: '. ./${0##*/} -e foo_ver'\n"
    exit 1
  fi
fi

historyStartCommit="$lastVersionCommitHash"
[[ -n $arg_f ]] && historyStartCommit="$firstCommitHash"

historyCmd=(git log)
[[ -n $arg_d_opt ]] && historyCmd+=("$arg_d_opt")
historyCmd+=(--pretty=format:%H%x09%s "${historyStartCommit}..${lastCommitHash}")
[[ -n $arg_d ]] && historyCmd+=(-- "$arg_d_val")

minorIncrementCount=0
patchIncrementCount=0

if [[ -n $arg_f ]]; then
  # Full re-evaluation can walk very large histories; classify commits in parallel.
  parallelJobs=$(( $(nproc 2>/dev/null || echo 2) - 1 ))
  (( parallelJobs < 1 )) && parallelJobs=1

  export -f classify_commit extract_pr_number get_pr_labels get_override_labels get_github_labels get_gitlab_labels detect_increment_from_labels detect_increment_from_branch
  export origin_host merge_string labelOverrideSource

  if ! classificationResults=$("${historyCmd[@]}" | xargs -r -d '\n' -P "$parallelJobs" -n 1 bash -c 'classify_commit "$1"' _); then
    echo -e "\e[01;31mERROR\e[00m: 592 - Label lookup failed!"
    exit 1
  fi

  grep -qx 'major' <<< "$classificationResults" && incrementMajor='true'
  minorIncrementCount=$(grep -cx 'minor' <<< "$classificationResults")
  patchIncrementCount=$(grep -cx 'patch' <<< "$classificationResults")
else
  while IFS= read -r historyLine || [[ -n "$historyLine" ]]; do
    [[ -z "$historyLine" ]] && continue

    if ! incrementType=$(classify_commit "$historyLine"); then
      echo -e "\e[01;31mERROR\e[00m: 592 - Label lookup failed!"
      exit 1
    fi

    case "$incrementType" in
      major)
        incrementMajor='true'
        break
      ;;
      minor)
        minorIncrementCount=$((minorIncrementCount + 1))
      ;;
      patch)
        patchIncrementCount=$((patchIncrementCount + 1))
      ;;
    esac
  done < <("${historyCmd[@]}")
fi

if [[ -z $arg_f && $incrementMajor != 'true' && $minorIncrementCount -eq 0 && $patchIncrementCount -eq 0 ]]; then
  echo -e "\e[01;31mERROR\e[00m: 599 - No feature, enhancement, fix, bugfix, hotfix, or ops branches detected!"
  exit 1
fi

# --------------------------------------------------------------------------------------------------
# Main Operations
# --------------------------------------------------------------------------------------------------

if [[ $incrementMajor == 'true' ]]; then
  newVersionMajor=$((lastVersionMajor + 1))
  newVersionMinor='0'
  newVersionPatch='0'
elif [[ $minorIncrementCount -gt 0 ]]; then
  newVersionMajor=$lastVersionMajor
  newVersionMinor=$((lastVersionMinor + minorIncrementCount))
  newVersionPatch='0'
elif [[ $patchIncrementCount -gt 0 ]]; then
  newVersionMajor=$lastVersionMajor
  newVersionMinor=$lastVersionMinor
  newVersionPatch=$((lastVersionPatch + patchIncrementCount))
elif [[ -n $arg_p ]]; then
  newVersionMajor=$lastVersionMajor
  newVersionMinor=$lastVersionMinor
  newVersionPatch=$((lastVersionPatch + 1))
fi

newVersion=$(/usr/bin/env bash -c "${dir}/validateSemver.sh -9p full $newVersionMajor.$newVersionMinor.$newVersionPatch $arg_opts")
[[ -n $arg_n ]] && newVersion="${arg_n_val}_${newVersion}"

if [[ -n $arg_e ]]; then
  export_var="$arg_e_val"
  eval "${export_var}=${newVersion}"
  export export_var
else
  echo "$newVersion"
fi
