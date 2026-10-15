#!/usr/bin/env bash
# Shared helpers for blue-green / canary deployments on ECS Fargate + ALB.
#
# Model: for each component (backend, frontend) there are TWO ECS services
# (<project>-<component>-blue and -green) and TWO ALB target groups.
# The ALB listener (frontend) and the /api/* rule (backend) use *weighted
# forwarding*; changing the weights moves traffic between colors instantly.
#
# Required env: AWS_REGION   Optional: PROJECT (mern-cicd), DESIRED_COUNT (2), ECR_REGISTRY
set -euo pipefail

AWS_REGION="${AWS_REGION:?AWS_REGION must be set}"
export AWS_DEFAULT_REGION="$AWS_REGION"
PROJECT="${PROJECT:-mern-cicd}"
CLUSTER="${PROJECT}-cluster"
DESIRED_COUNT="${DESIRED_COUNT:-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENTS=(backend frontend)

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "ERROR: $*"; exit 1; }
other_color() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }

# ---------- ALB lookups (resolved by naming convention, no state needed) ----------
alb_arn()  { aws elbv2 describe-load-balancers --names "${PROJECT}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text; }
alb_dns()  { aws elbv2 describe-load-balancers --names "${PROJECT}-alb" --query 'LoadBalancers[0].DNSName' --output text; }
listener_arn() { aws elbv2 describe-listeners --load-balancer-arn "$(alb_arn)" --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text; }
# backend_rule_arn() { aws elbv2 describe-rules --listener-arn "$(listener_arn)" --query 'Rules[?Priority==`10`].RuleArn | [0]' --output text; }
backend_rule_arn() {
  local arn
  arn=$(aws elbv2 describe-rules --listener-arn "$(listener_arn)" --query "Rules[?Priority=='10'].RuleArn | [0]" --output text)
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    echo "ERROR: backend listener rule (priority 10) not found" >&2
    return 1
  fi
  echo "$arn"
}
tg_arn() { aws elbv2 describe-target-groups --names "${PROJECT}-$1-$2" --query 'TargetGroups[0].TargetGroupArn' --output text; }  # component color

forward_json() {  # blue_arn green_arn blue_weight green_weight
  jq -nc --arg b "$1" --arg g "$2" --argjson bw "$3" --argjson gw "$4" \
    '[{Type:"forward",ForwardConfig:{TargetGroups:[{TargetGroupArn:$b,Weight:$bw},{TargetGroupArn:$g,Weight:$gw}]}}]'
}

# Percentage of traffic currently sent to GREEN (0-100)
current_green_pct() {
  local g; g="$(tg_arn backend green)"
  aws elbv2 describe-rules --rule-arns "$(backend_rule_arn)" \
    --query 'Rules[0].Actions[0].ForwardConfig.TargetGroups' --output json \
    | jq -r --arg g "$g" '[.[] | select(.TargetGroupArn==$g) | .Weight][0] // 0'
}
# The "live" color is whichever one receives the majority of traffic
active_color() { if [ "$(current_green_pct)" -ge 50 ]; then echo green; else echo blue; fi; }

# set_traffic <green_pct>: move traffic for BOTH frontend and backend in one go
set_traffic() {
  local gw="$1" bw=$((100 - $1))
  log "Setting traffic split -> blue=${bw}% green=${gw}%"
  aws elbv2 modify-rule --rule-arn "$(backend_rule_arn)" \
    --actions "$(forward_json "$(tg_arn backend blue)" "$(tg_arn backend green)" "$bw" "$gw")" >/dev/null
  aws elbv2 modify-listener --listener-arn "$(listener_arn)" \
    --default-actions "$(forward_json "$(tg_arn frontend blue)" "$(tg_arn frontend green)" "$bw" "$gw")" >/dev/null
}
# set_color_pct <color> <pct>: send <pct>% of traffic to <color>, rest to the other
set_color_pct() {
  if [ "$1" = green ]; then set_traffic "$2"; else set_traffic $((100 - $2)); fi
}

# ---------- ECS helpers ----------
# register_taskdef <component> <image> <version> -> prints new task definition ARN
register_taskdef() {
  local comp="$1" image="$2" version="$3" td new
  td="$(aws ecs describe-task-definition --task-definition "${PROJECT}-${comp}" --query taskDefinition --output json)"
  new="$(jq --arg img "$image" --arg ver "$version" '
      del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy)
      | .containerDefinitions[0].image = $img
      | .containerDefinitions[0].environment =
          ((.containerDefinitions[0].environment // []) | map(select(.name != "APP_VERSION"))
           + [{name:"APP_VERSION", value:$ver}])' <<<"$td")"
  aws ecs register-task-definition --cli-input-json "$new" --query taskDefinition.taskDefinitionArn --output text
}

scale_color() {  # <color> <count>
  local comp
  for comp in "${COMPONENTS[@]}"; do
    aws ecs update-service --cluster "$CLUSTER" --service "${PROJECT}-${comp}-$1" --desired-count "$2" >/dev/null
  done
}

wait_color_stable() {  # <color>
  aws ecs wait services-stable --cluster "$CLUSTER" \
    --services "${PROJECT}-backend-$1" "${PROJECT}-frontend-$1"
}

# wait until every registered target in the group is healthy (and there are enough of them)
wait_tg_healthy() {  # <tg_arn> [attempts]
  local tg="$1" tries="${2:-40}" states healthy total i
  for i in $(seq 1 "$tries"); do
    states="$(aws elbv2 describe-target-health --target-group-arn "$tg" \
              --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
    healthy="$(tr '\t' '\n' <<<"$states" | grep -c '^healthy$' || true)"
    total="$(tr '\t' '\n' <<<"$states" | grep -c . || true)"
    if [ "$healthy" -ge "$DESIRED_COUNT" ] && [ "$healthy" -eq "$total" ]; then
      log "Target group healthy ($healthy/$total): ${tg##*/}"; return 0
    fi
    log "Waiting for targets ($healthy/$total healthy, need $DESIRED_COUNT) [$i/$tries]"
    sleep 15
  done
  return 1
}

# deploy_idle <image_tag> <color>: roll the new release onto the idle color only
deploy_idle() {
  local tag="$1" color="$2" comp td registry="${ECR_REGISTRY:?ECR_REGISTRY must be set}"
  for comp in "${COMPONENTS[@]}"; do
    # explicit "|| return 1": this function is called inside "if !"/"||", where set -e is disabled
    td="$(register_taskdef "$comp" "${registry}/${PROJECT}-${comp}:${tag}" "$tag")" || return 1
    log "Registered $td"
    aws ecs update-service --cluster "$CLUSTER" --service "${PROJECT}-${comp}-${color}" \
      --task-definition "$td" --desired-count "$DESIRED_COUNT" --force-new-deployment >/dev/null || return 1
  done
  log "Waiting for ECS services (${color}) to become stable..."
  wait_color_stable "$color" || return 1
  for comp in "${COMPONENTS[@]}"; do wait_tg_healthy "$(tg_arn "$comp" "$color")" || return 1; done
}

# ---------- verification helpers ----------
# probe <base_url> <count> <expected_version> [interval_seconds]
# Hits /api/health repeatedly. Sets PROBE_TOTAL, PROBE_FAIL, PROBE_NEW (responses served by <expected_version>)
probe() {
  local url="$1" n="$2" ver="$3" gap="${4:-0.5}" i out code body v
  PROBE_TOTAL=0; PROBE_FAIL=0; PROBE_NEW=0
  for i in $(seq 1 "$n"); do
    out="$(curl -s -m 5 -w '\n%{http_code}' "${url}/api/health" || true)"
    code="$(tail -n1 <<<"$out")"; body="$(sed '$d' <<<"$out")"
    v="$(jq -r '.version // empty' <<<"$body" 2>/dev/null || true)"
    PROBE_TOTAL=$((PROBE_TOTAL + 1))
    [ "$code" = "200" ] || PROBE_FAIL=$((PROBE_FAIL + 1))
    [ "$v" = "$ver" ] && PROBE_NEW=$((PROBE_NEW + 1))
    sleep "$gap"
  done
}

# cw_sum <metric> <tg_arn> <minutes> -> sum of the ALB metric for that target group
cw_sum() {
  local metric="$1" tg="$2" mins="$3" tgd lbd
  tgd="$(sed 's/^.*:\(targetgroup\/.*\)$/\1/' <<<"$tg")"
  lbd="$(alb_arn | sed 's/^.*:loadbalancer\///')"
  aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name "$metric" \
    --dimensions "Name=TargetGroup,Value=$tgd" "Name=LoadBalancer,Value=$lbd" \
    --start-time "$(date -u -d "-${mins} minutes" +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
    --period 60 --statistics Sum --query 'Datapoints[].Sum' --output text \
    | tr '\t' '\n' | awk '{s+=$1} END{printf "%d", s+0}'
}

write_state() {  # <active> <previous> <tag>   (picked up by Jenkins for display / rollback)
  printf 'ACTIVE_COLOR=%s\nPREVIOUS_COLOR=%s\nDEPLOYED_TAG=%s\n' "$1" "$2" "$3" > "${STATE_FILE:-deploy-state.env}"
}
