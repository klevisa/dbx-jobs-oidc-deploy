#!/usr/bin/env bash
# Positive: main/prod deploys. Negative: a feature branch can't get credentials.
# Also checks the deployer can use the job SPs but is not an admin.
set -uo pipefail
cd "$(dirname "$0")/.."; source setup/config.env
API="repos/$GH_REPO"; fails=0
A=(-p "$DATABRICKS_ACCOUNT_PROFILE"); W=(-p "$DATABRICKS_WORKSPACE_PROFILE")
pass(){ printf '   \033[32mPASS\033[0m %s\n' "$*"; }; fail(){ printf '   \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }
say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
check(){ if eval "$2"; then pass "$1"; else fail "$1"; fi; }
wait_run(){ local wf=$1 br=$2 since=$3 rid=""
  for _ in $(seq 1 40); do rid=$(gh run list -R "$GH_REPO" -w "$wf" --json databaseId,headBranch,createdAt -q "[.[]|select(.headBranch==\"$br\" and .createdAt>=\"$since\")][0].databaseId" 2>/dev/null); [ -n "$rid" ] && break; sleep 3; done
  [ -n "$rid" ] || return
  for _ in $(seq 1 100); do [ "$(gh api "$API/actions/runs/$rid" -q .status)" = completed ] && break; sleep 6; done; echo "$rid"; }

say "Databricks: role grants"
DEP=$(gh variable get DEPLOYER_SP_APP_ID -R "$GH_REPO")
for v in ETL_SP_APP_ID REPORTS_SP_APP_ID; do
  app=$(gh variable get $v -R "$GH_REPO")
  rs=$(databricks account access-control get-rule-set "accounts/$DATABRICKS_ACCOUNT_ID/servicePrincipals/$app/ruleSets/default" "" "${A[@]}" -o json)
  check "deployer has servicePrincipal.user on $v" 'jq -e --arg p "servicePrincipals/$DEP" ".grant_rules[]|select(.role==\"roles/servicePrincipal.user\")|.principals|index(\$p)" <<<"$rs" >/dev/null'
done
check "deployer is not a workspace admin" '! databricks groups list "${W[@]}" --filter "displayName eq admins" -o json | jq -e --arg d "$DEP" ".[0].members[]?|select(.display==\$d)" >/dev/null'

say "Positive: deploy from main"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ); gh workflow run deploy.yml -R "$GH_REPO" --ref main >/dev/null
rid=$(wait_run deploy main "$since"); check "deploy run $rid succeeded" '[ "$(gh api "$API/actions/runs/$rid" -q .conclusion)" = success ]'
for j in oidc-demo-etl oidc-demo-reports; do
  jid=$(databricks jobs list "${W[@]}" --name "$j" -o json | jq -r '.[0].job_id')
  ra=$(databricks jobs get "$jid" "${W[@]}" -o json | jq -r '.run_as_user_name // empty')
  check "$j runs as a job SP ($ra), not the deployer" '[ -n "$ra" ] && [ "$ra" != "$DEP" ]'
done

say "Negative: feature branch can't get credentials"
br="verify-steal-$(date +%s)"; since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh api "$API/git/refs" -f ref="refs/heads/$br" -f sha="$(gh api "$API/git/ref/heads/main" -q .object.sha)" >/dev/null
gh api -X PUT "$API/contents/.github/workflows/steal-test.yml" -f branch="$br" -f message="verify" -f content="$(base64 < setup/steal-test.yml)" >/dev/null
rid=$(wait_run steal-test "$br" "$since")
jobs=$(gh api "$API/actions/runs/$rid/jobs" -q '.jobs[]|"\(.name) \(.id)"'); jid(){ awk -v n="$1" '$1==n{print $2}' <<<"$jobs"; }
check "environment refuses the branch" 'gh api "$API/check-runs/$(jid with-env)/annotations" -q ".[].message" | grep -q "not allowed to deploy"'
check "Databricks rejects the token" 'sleep 5; gh api "$API/actions/jobs/$(jid no-env-databricks)/logs" 2>/dev/null | grep -q TOKEN_SUBJECT_INVALID'
gh api -X DELETE "$API/git/refs/heads/$br" >/dev/null && echo "   (deleted $br)"
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
