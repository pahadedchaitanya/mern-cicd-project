#!/usr/bin/env bash
# Blue-green release: deploy to the idle color, verify, flip 100% of traffic,
# smoke-test, and flip back automatically if verification fails.
# Usage: deploy-bluegreen.sh <image_tag>
source "$(dirname "$0")/lib.sh"
TAG="${1:?image tag required}"
ALB_URL="${ALB_URL:-http://$(alb_dns)}"

ACTIVE="$(active_color)"; IDLE="$(other_color "$ACTIVE")"
log "Blue-green deploy of '$TAG': live=$ACTIVE, deploying to idle=$IDLE"

if ! deploy_idle "$TAG" "$IDLE"; then
  log "Idle environment failed to become healthy - aborting, live traffic untouched"
  scale_color "$IDLE" 0
  exit 1
fi

log "Cutting over to $IDLE"
set_color_pct "$IDLE" 100
sleep 10

if ! bash "$SCRIPT_DIR/smoke-test.sh" "$ALB_URL" "$TAG"; then
  log "Smoke test failed - rolling back to $ACTIVE"
  set_color_pct "$ACTIVE" 100
  scale_color "$IDLE" 0
  exit 1
fi

write_state "$IDLE" "$ACTIVE" "$TAG"
log "SUCCESS: $IDLE is live ($TAG). $ACTIVE is kept running as an instant-rollback standby."
log "Run scripts/finalize.sh once you are happy to scale the standby down."
