#!/usr/bin/env bash

TEST_ROOT=$(mktemp -d)
TEST_REPO="$TEST_ROOT/repo"
PR_NUMBER=1000
LABEL_OVERRIDES=''
FAILURE=''

trap 'rm -rf "$TEST_ROOT"' EXIT

printHeading() {
  local txt="$*"
  printf "\n\e[01;39m%s\e[0m\n" "$txt"
  printf '%*s\n' "${#txt}" '' | tr ' ' '-'
}

script_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

setup_repo() {
  mkdir -p "$TEST_REPO"
  cd "$TEST_REPO" || exit 1
  git init >/dev/null 2>&1
  git config user.name test-user
  git config user.email test@example.com
  git remote add origin git@github.com:example/test.git
  mkdir -p A B C D E F
  echo init > README.md
  git add README.md A B C >/dev/null 2>&1
  git commit -m init >/dev/null 2>&1
}

append_label_override() {
  local pr_number="$1"
  local label="$2"
  [[ -z "$label" ]] && return 0

  [[ -n "$LABEL_OVERRIDES" ]] && LABEL_OVERRIDES+=";"
  LABEL_OVERRIDES+="${pr_number}=${label}"
}

add_history() {
  if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "ERROR: add_history requires 3 or 4 arguments"
    exit 1
  fi

  local directory="$1"
  local count="$2"
  local branch_type="$3"
  local label_override="$4"
  local pr_number=''
  local test_file=''
  local i=''

  for i in $(seq 1 "$count"); do
    PR_NUMBER=$((PR_NUMBER + 1))
    pr_number="$PR_NUMBER"
    test_file="$directory/${branch_type}_${i}_$(date +%s%N)"
    echo "$pr_number" >> "$test_file"
    git add "$test_file" >/dev/null 2>&1
    git commit -m "Merge pull request #${pr_number} from example/${branch_type}/${directory}_${i}" >/dev/null 2>&1
    append_label_override "$pr_number" "$label_override"
  done
}

add_repo_history() {
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "ERROR: add_repo_history requires 2 or 3 arguments"
    exit 1
  fi

  local count="$1"
  local branch_type="$2"
  local label_override="$3"
  local pr_number=''
  local test_file=''
  local i=''

  for i in $(seq 1 "$count"); do
    PR_NUMBER=$((PR_NUMBER + 1))
    pr_number="$PR_NUMBER"
    test_file="repo_${branch_type}_${i}_$(date +%s%N)"
    echo "$pr_number" >> "$test_file"
    git add "$test_file" >/dev/null 2>&1
    git commit -m "Merge pull request #${pr_number} from example/${branch_type}/repo_${i}" >/dev/null 2>&1
    append_label_override "$pr_number" "$label_override"
  done
}

add_repo_major_commit() {
  local marker_file=''

  marker_file="repo_major_$(date +%s%N)"
  echo major > "$marker_file"
  git add "$marker_file" >/dev/null 2>&1
  git commit -m "+semver major tests" >/dev/null 2>&1
}

add_repo_squash_history() {
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "ERROR: add_repo_squash_history requires 1 or 2 arguments"
    exit 1
  fi

  local count="$1"
  local label_override="$2"
  local pr_number=''
  local test_file=''
  local i=''

  for i in $(seq 1 "$count"); do
    PR_NUMBER=$((PR_NUMBER + 1))
    pr_number="$PR_NUMBER"
    test_file="repo_squash_${i}_$(date +%s%N)"
    echo "$pr_number" >> "$test_file"
    git add "$test_file" >/dev/null 2>&1
    git commit -m "Some squashed change ${i} (#${pr_number})" >/dev/null 2>&1
    append_label_override "$pr_number" "$label_override"
  done
}

add_major_commit() {
  local directory="$1"
  local marker_file=''

  marker_file="$directory/major_$(date +%s%N)"
  echo major > "$marker_file"
  git add "$marker_file" >/dev/null 2>&1
  git commit -m "+semver major tests" >/dev/null 2>&1
}

run_detect_previous() {
  local directory="$1"

  if [[ "$directory" == './' ]]; then
    "$script_dir/detectPreviousVersion.sh"
  else
    "$script_dir/detectPreviousVersion.sh" -d "$directory" -n "${directory##*/}"
  fi
}

run_detect_new() {
  local directory="$1"
  local cmd=("$script_dir/detectNewVersion.sh")

  if [[ "$directory" != './' ]]; then
    cmd+=(-d "$directory" -n "${directory##*/}")
  fi

  [[ -n "$LABEL_OVERRIDES" ]] && cmd+=(-l "$LABEL_OVERRIDES")

  "${cmd[@]}" 2>&1
}

assert_match() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if grep -q "$expected" <<< "$actual"; then
    echo -e " \e[01;32mOK\e[0m - $actual"
    summary_row "$label" "✅" "$actual"
  else
    FAILURE='true'
    echo -e " \e[01;31mFAIL\e[0m - expected '$expected', got '$actual'"
    summary_row "$label" "❌" "expected '$expected', got '$actual'"
  fi
}

summary_init() {
  [[ -z "$GITHUB_STEP_SUMMARY" ]] && return 0

  {
    echo '### Test Results'
    echo ''
    echo '| Test | Result | Output |'
    echo '| ---- | :----: | ------ |'
  } >> "$GITHUB_STEP_SUMMARY"
}

summary_row() {
  [[ -z "$GITHUB_STEP_SUMMARY" ]] && return 0

  local label="$1"
  local result="$2"
  local output="$3"

  # Strip ANSI color codes and escape pipes so the output renders cleanly in markdown.
  output=$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/|/\\|/g' <<< "$output")
  echo "| ${label} | ${result} | ${output} |" >> "$GITHUB_STEP_SUMMARY"
}

test_previous() {
  local directory="$1"
  local expected="$2"
  local comment="$3"
  local actual=''
  local label="Previous Version ${directory} (${comment})"

  echo -e "\e[01;39m${label}\e[0m"
  actual=$(run_detect_previous "$directory")
  assert_match "$label" "$expected" "$actual"
}

test_new() {
  local directory="$1"
  local expected="$2"
  local comment="$3"
  local actual=''
  local label="New Version ${directory} (${comment})"

  echo -e "\e[01;39m${label}\e[0m"
  actual=$(run_detect_new "$directory")
  assert_match "$label" "$expected" "$actual"
}

test_new_full() {
  local directory="$1"
  local expected="$2"
  local comment="$3"
  local actual=''
  local label="New Version (full re-evaluation) ${directory} (${comment})"
  local cmd=("$script_dir/detectNewVersion.sh" -f)

  if [[ "$directory" != './' ]]; then
    cmd+=(-d "$directory" -n "${directory##*/}")
  fi

  [[ -n "$LABEL_OVERRIDES" ]] && cmd+=(-l "$LABEL_OVERRIDES")

  echo -e "\e[01;39m${label}\e[0m"
  actual=$("${cmd[@]}" 2>&1)
  assert_match "$label" "$expected" "$actual"
}

setup_repo

printHeading 'Running isolated local tests'
summary_init

test_previous './' '0.0.0' 'repo initializes at zero'
test_new './' '599' 'repo without qualifying merges'

add_repo_history 2 feature
add_repo_history 1 enhancement
test_new './' '0.3.0' 'repo feature and enhancement branches increment minor versions'
git tag -a '0.3.0' -m TAG >/dev/null 2>&1
test_previous './' '0.3.0' 'repo previous version tagged'

add_repo_history 1 fix
add_repo_history 1 bugfix
add_repo_history 1 hotfix
add_repo_history 1 ops
test_new './' '0.3.4' 'repo fix, bugfix, hotfix, and ops branches increment patch versions'
git tag -a '0.3.4' -m TAG >/dev/null 2>&1
test_previous './' '0.3.4' 'repo previous patch version tagged'

add_repo_history 1 feature 'semver:patch'
test_new './' '0.3.5' 'repo semver patch label overrides feature branch'
git tag -a '0.3.5' -m TAG >/dev/null 2>&1

add_repo_history 1 fix 'semver:minor'
test_new './' '0.4.0' 'repo semver minor label overrides fix branch'
git tag -a '0.4.0' -m TAG >/dev/null 2>&1

add_repo_history 1 ops 'semver:major'
test_new './' '1.0.0' 'repo semver major label overrides ops branch'
git tag -a '1.0.0' -m TAG >/dev/null 2>&1

add_repo_major_commit
test_new './' '2.0.0' 'repo commit-level semver major still works'
git tag -a '2.0.0' -m TAG >/dev/null 2>&1

add_repo_squash_history 1 'semver:minor'
test_new './' '2.1.0' 'squash-merged PR classified via semver minor label'
git tag -a '2.1.0' -m TAG >/dev/null 2>&1

add_repo_squash_history 1
test_new './' '599' 'unlabeled squash-merged PR is not classified'
add_repo_history 1 fix
test_new './' '2.1.1' 'unlabeled squash merge ignored alongside fix merge'
git tag -a '2.1.1' -m TAG >/dev/null 2>&1

test_previous 'A' 'A_0.0.0' 'directory initializes independently'
test_new 'A' '599' 'directory without qualifying merges'

test_previous 'B' 'B_0.0.0' 'directory initializes independently'
add_history 'B' 3 ops
test_new 'B' 'B_0.0.3' 'patches +3'
git tag -a 'B_0.0.3' -m TAG >/dev/null 2>&1
test_previous 'B' 'B_0.0.3' 'previous version tagged'

test_previous 'A' 'A_0.0.0' 'newer B tag does not affect A history'

test_previous 'C' 'C_0.0.0' 'directory initializes independently'
add_history 'C' 5 feature
test_new 'C' 'C_0.5.0' 'features +5'
git tag -a 'C_0.5.0' -m TAG >/dev/null 2>&1

add_history 'C' 1 feature 'semver:patch'
test_new 'C' 'C_0.5.1' 'semver patch label overrides feature branch'
git tag -a 'C_0.5.1' -m TAG >/dev/null 2>&1

add_history 'C' 1 ops 'semver:minor'
test_new 'C' 'C_0.6.0' 'semver minor label overrides ops branch'
git tag -a 'C_0.6.0' -m TAG >/dev/null 2>&1

add_history 'C' 1 ops 'semver:major'
test_new 'C' 'C_1.0.0' 'semver major label overrides ops branch'
git tag -a 'C_1.0.0' -m TAG >/dev/null 2>&1

add_major_commit 'C'
test_new 'C' 'C_2.0.0' 'commit-level semver major still works'

test_previous 'D' 'D_0.0.0' 'directory initializes independently'
add_history 'D' 2 feature
add_history 'D' 3 enhancement
test_new 'D' 'D_0.5.0' 'feature and enhancement branches increment minor versions'
git tag -a 'D_0.5.0' -m TAG >/dev/null 2>&1

test_previous 'E' 'E_0.0.0' 'directory initializes independently'
add_history 'E' 1 fix
add_history 'E' 1 bugfix
add_history 'E' 1 hotfix
add_history 'E' 1 ops
test_new 'E' 'E_0.0.4' 'fix, bugfix, hotfix, and ops branches increment patch versions'
git tag -a 'E_0.0.4' -m TAG >/dev/null 2>&1

test_previous 'F' 'F_0.0.0' 'directory initializes independently'
add_history 'F' 1 enhancement 'semver:patch'
test_new 'F' 'F_0.0.1' 'semver patch label overrides enhancement minor branch'
git tag -a 'F_0.0.1' -m TAG >/dev/null 2>&1

add_history 'F' 1 fix 'semver:minor'
test_new 'F' 'F_0.1.0' 'semver minor label overrides fix patch branch'
git tag -a 'F_0.1.0' -m TAG >/dev/null 2>&1

add_history 'F' 1 hotfix 'semver:major'
test_new 'F' 'F_1.0.0' 'semver major label overrides hotfix patch branch'

test_new_full './' '3.0.0' 'parallel full re-evaluation detects repo major'
test_new_full 'F' 'F_1.0.0' 'parallel full re-evaluation detects directory major'

if [[ -n "$FAILURE" ]]; then
  exit 1
fi

