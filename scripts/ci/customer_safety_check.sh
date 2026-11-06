#!/usr/bin/env bash
# ==============================================================================
# Customer-safety check for this public repository (generic, no denylist).
#
# Fails when the working tree (tracked files plus untracked files that are not
# git-ignored) contains:
#   1. Terraform state, variable or crash files:
#        *.tfstate, *.tfstate.*, terraform.tfvars, *.auto.tfvars, *.tfvars.json,
#        crash.log, crash.*.log
#      (*.tfvars.example files are allowed).
#   2. Real-looking Cloud SQL tenant project IDs, i.e. the producer project in
#      a PSC service attachment link: <letter><6+ lowercase letters/digits>-tp.
#      Documented placeholders are allowed (ALLOWED_TENANT_PROJECTS).
#   3. 12-digit numbers that look like Google Cloud project numbers (including
#      the p<number>- prefix of Cloud SQL service agents), unless they are
#      documented placeholders (ALLOWED_PROJECT_NUMBERS). Write PROJECT_NUMBER
#      in docs instead of a number.
#
# Usage: scripts/ci/customer_safety_check.sh
# Env:   ALLOWED_TENANT_PROJECTS / ALLOWED_PROJECT_NUMBERS (space-separated)
#        extend the built-in placeholder allow-lists.
# ==============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ALLOWED_TENANT_PROJECTS="example-tp ${ALLOWED_TENANT_PROJECTS:-}"
ALLOWED_PROJECT_NUMBERS="123456789012 000000000000 ${ALLOWED_PROJECT_NUMBERS:-}"

# Files never scanned for patterns 2 and 3: provider lock files (hashes) and
# this script (it holds the allow-lists).
EXCLUDES=(
  ':(exclude,glob)**/.terraform.lock.hcl'
  ':(exclude)scripts/ci/customer_safety_check.sh'
)

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "${needle}" == "${item}" ]] && return 0
  done
  return 1
}

# ------------------------------------------------------------------------------
# 1. Forbidden files
# ------------------------------------------------------------------------------
echo "== Forbidden files (state, tfvars, crash logs)"
while IFS= read -r -d '' f; do
  base="${f##*/}"
  case "${base}" in
    *.tfvars.example) continue ;;
    *.tfstate | *.tfstate.* | terraform.tfvars | *.auto.tfvars | *.tfvars.json | crash.log | crash.*.log)
      fail "forbidden file in the repository: ${f}"
      ;;
  esac
done < <(git ls-files -z --cached --others --exclude-standard)

# ------------------------------------------------------------------------------
# Pattern scan helper: prints "file:line:match" for every match.
# ------------------------------------------------------------------------------
scan() {
  git grep --untracked -I -n -o -P -e "$1" -- . "${EXCLUDES[@]}" || true
}

# ------------------------------------------------------------------------------
# 2. Cloud SQL tenant project IDs
# ------------------------------------------------------------------------------
echo "== Cloud SQL tenant project IDs (allowed: ${ALLOWED_TENANT_PROJECTS% })"
read -r -a allowed_tp <<<"${ALLOWED_TENANT_PROJECTS}"
while IFS= read -r hit; do
  [[ -z "${hit}" ]] && continue
  match="${hit#*:*:}"
  location="${hit%":${match}"}"
  if ! in_list "${match}" "${allowed_tp[@]}"; then
    fail "real-looking Cloud SQL tenant project '${match}' at ${location} (use a placeholder such as example-tp)"
  fi
done < <(scan '(?<![A-Za-z0-9-])[a-z][a-z0-9]{6,}-tp(?![A-Za-z0-9-])')

# ------------------------------------------------------------------------------
# 3. Project numbers
# ------------------------------------------------------------------------------
echo "== 12-digit project numbers (allowed: ${ALLOWED_PROJECT_NUMBERS% })"
read -r -a allowed_pn <<<"${ALLOWED_PROJECT_NUMBERS}"
while IFS= read -r hit; do
  [[ -z "${hit}" ]] && continue
  match="${hit#*:*:}"
  location="${hit%":${match}"}"
  number="${match#p}"
  if ! in_list "${number}" "${allowed_pn[@]}"; then
    fail "12-digit number '${match}' at ${location} looks like a project number (use PROJECT_NUMBER or 123456789012)"
  fi
done < <(scan '(?<![A-Za-z0-9])p?[0-9]{12}(?![A-Za-z0-9])')

if ((failures > 0)); then
  echo "customer_safety_check: ${failures} finding(s)." >&2
  exit 1
fi
echo "customer_safety_check: OK"
