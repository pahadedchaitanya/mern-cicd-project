#!/usr/bin/env bash
# Smoke-test the live ALB and assert it is serving the release we just deployed.
# Usage: verify-production.sh <image_tag>
# (Kept as a script, not inline Jenkins shell: `sh` in Jenkins is dash, which has no `source`.)
source "$(dirname "$0")/lib.sh"
TAG="${1:?image tag required}"
"$SCRIPT_DIR/smoke-test.sh" "http://$(alb_dns)" "$TAG"
