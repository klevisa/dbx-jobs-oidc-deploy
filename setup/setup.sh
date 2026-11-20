#!/usr/bin/env bash
# Creates everything the code depends on. Safe to re-run.
#   GitHub:     repo, environment "prod" (main only), branch protection, repo variables
#   Databricks: deployer SP (no secret) + federation policy, two job SPs, workspace access,
#               and the deployer's  servicePrincipal.user  role on each job SP
# Needs: gh (repo owner), databricks CLI (account admin + workspace profiles), jq.
set -euo pipefail
trap 'echo "   ✘ failed at line $LINENO: $BASH_COMMAND"' ERR
cd "$(dirname "$0")/.."
source setup/config.env
A=(-p "$DATABRICKS_ACCOUNT_PROFILE"); W=(-p "$DATABRICKS_WORKSPACE_PROFILE")
API="repos/$GH_REPO"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   \033[32m✔\033[0m %s\n' "$*"; }

say "GitHub: repo"
if ! gh repo view "$GH_REPO" >/dev/null 2>&1; then
  gh repo create "$GH_REPO" --public --source . --push >/dev/null
  ok "created and pushed $GH_REPO"
else ok "exists"; fi

say "GitHub: environment '$ENVIRONMENT' (main only, admins can't bypass)"
gh api -X PUT "$API/environments/$ENVIRONMENT" --input - >/dev/null <<J
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true},"can_admins_bypass":false}
J
pol=$(gh api "$API/environments/$ENVIRONMENT/deployment-branch-policies" -q '[.branch_policies[].name]|join(",")')
[ -z "$pol" ] && gh api -X POST "$API/environments/$ENVIRONMENT/deployment-branch-policies" -f name=main -f type=branch >/dev/null
[ -z "$pol" ] || [ "$pol" = main ] || { echo "unexpected branch policies: $pol"; exit 1; }
ok "only main may use $ENVIRONMENT"

say "GitHub: branch protection on main (PR required)"
gh api -X PUT "$API/branches/main/protection" --input - >/dev/null <<J
{"required_status_checks":null,"enforce_admins":$ENFORCE_ADMINS,
 "required_pull_request_reviews":{"required_approving_review_count":0},
 "restrictions":null,"allow_force_pushes":false,"allow_deletions":false}
J
ok "direct pushes to main blocked (admins can bypass: enforce_admins=$ENFORCE_ADMINS)"

mk_sp() {  # name -> prints "appId id"
  local name=$1 j
  j=$(databricks account service-principals list "${A[@]}" --filter "displayName eq \"$name\"" -o json | jq -c '.[0] // empty')
  [ -n "$j" ] || j=$(databricks account service-principals create --display-name "$name" "${A[@]}" -o json | jq -c .)
  jq -r '"\(.applicationId) \(.id)"' <<<"$j"
}
add_to_workspace() {  # id
  databricks account workspace-assignment update "$WORKSPACE_ID" "$1" --json '{"permissions":["USER"]}' "${A[@]}" >/dev/null
  databricks service-principals patch "$1" "${W[@]}" --json \
   '{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],"Operations":[{"op":"add","path":"entitlements","value":[{"value":"workspace-access"}]}]}' >/dev/null
}

say "Databricks: deployer + job service principals (no secrets are ever created)"
read -r DEP_APP DEP_ID < <(mk_sp "$DEPLOYER_SP_NAME")
read -r ETL_APP ETL_ID < <(mk_sp "$ETL_SP_NAME")
read -r REP_APP REP_ID < <(mk_sp "$REPORTS_SP_NAME")
for id in "$DEP_ID" "$ETL_ID" "$REP_ID"; do add_to_workspace "$id"; done
ok "deployer  $DEPLOYER_SP_NAME  $DEP_APP"
ok "etl       $ETL_SP_NAME       $ETL_APP"
ok "reports   $REPORTS_SP_NAME   $REP_APP"

say "Databricks: deployer gets servicePrincipal.user on each job SP (and nothing else)"
for app in "$ETL_APP" "$REP_APP"; do
  rs="accounts/$DATABRICKS_ACCOUNT_ID/servicePrincipals/$app/ruleSets/default"
  cur=$(databricks account access-control get-rule-set "$rs" "" "${A[@]}" -o json)
  new=$(jq -c --arg p "servicePrincipals/$DEP_APP" '
    .grant_rules = ((.grant_rules // []) as $g
      | if any($g[]; .role=="roles/servicePrincipal.user" and (.principals // [] | index($p))) then $g
        elif any($g[]; .role=="roles/servicePrincipal.user") then ($g | map(if .role=="roles/servicePrincipal.user" then .principals += [$p] else . end))
        else $g + [{"role":"roles/servicePrincipal.user","principals":[$p]}] end)' <<<"$cur")
  databricks account access-control update-rule-set --json "{\"name\":\"$rs\",\"rule_set\":$new}" "${A[@]}" >/dev/null
  ok "$app: user=$DEP_APP"
done

say "Databricks: federation policy on the deployer (only this repo's '$ENVIRONMENT' environment)"
# This account issues immutable ID-based subjects: repo:<owner>@<ownerId>/<repo>@<repoId>:environment:<env>
OWNER_ID=$(gh api "$API" -q .owner.id); REPO_ID=$(gh api "$API" -q .id)
SUBJECT="repo:${GH_REPO%/*}@$OWNER_ID/${GH_REPO#*/}@$REPO_ID:environment:$ENVIRONMENT"
have=$(databricks account service-principal-federation-policy list "$DEP_ID" "${A[@]}" -o json | jq -r --arg s "$SUBJECT" '[.[]? | select(.oidc_policy.subject==$s)]|length')
# drop stale policies for this repo with a different subject (e.g. the name-based one)
for pid in $(databricks account service-principal-federation-policy list "$DEP_ID" "${A[@]}" -o json | jq -r --arg s "$SUBJECT" '.[]? | select(.oidc_policy.subject != $s) | .policy_id // .name'); do
  databricks account service-principal-federation-policy delete "$DEP_ID" "$pid" "${A[@]}"
done
[ "$have" != 0 ] || databricks account service-principal-federation-policy create "$DEP_ID" "${A[@]}" >/dev/null --json \
  "{\"oidc_policy\":{\"issuer\":\"https://token.actions.githubusercontent.com\",\"audiences\":[\"$DATABRICKS_ACCOUNT_ID\"],\"subject\":\"$SUBJECT\"}}"
ok "trusts subject: $SUBJECT"

say "GitHub: repo variables (no secrets)"
for kv in DATABRICKS_HOST=$DATABRICKS_HOST DATABRICKS_ACCOUNT_ID=$DATABRICKS_ACCOUNT_ID DEPLOYER_SP_APP_ID=$DEP_APP \
          ETL_SP_APP_ID=$ETL_APP REPORTS_SP_APP_ID=$REP_APP; do gh variable set "${kv%%=*}" -R "$GH_REPO" -b "${kv#*=}"; done
ok "set"
