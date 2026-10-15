#!/usr/bin/env bash
# One-time AWS bootstrap for the blue/green + canary deploy scripts (scripts/lib.sh).
#
# Creates, in the DEFAULT VPC of $AWS_REGION (default ap-south-2):
#   - security groups, CloudWatch log groups, ecsTaskExecutionRole (+ SSM read access)
#   - ECS cluster  <project>-cluster
#   - ALB          <project>-alb  with a port-80 listener (weighted forward -> frontend)
#                  and a priority-10 rule /api/* (weighted forward -> backend)
#   - 4 target groups   <project>-{backend,frontend}-{blue,green}
#   - task definitions  <project>-backend, <project>-frontend   (latest image found in ECR)
#   - 4 ECS services    <project>-{backend,frontend}-{blue,green}
#                       blue = DESIRED_COUNT tasks (live), green = 0 tasks (idle)
#
# Usage (Git Bash, WSL or Linux; needs only the aws CLI):
#   MONGO_URI='mongodb+srv://user:pass@cluster.mongodb.net/mern_cicd?retryWrites=true&w=majority' \
#     bash scripts/setup-aws.sh up
#   bash scripts/setup-aws.sh status
#   bash scripts/setup-aws.sh down        # deletes everything this script created (stops billing)
#
# Optional env: AWS_REGION, PROJECT, DESIRED_COUNT (2), IMAGE_TAG (default: newest tag in ECR)
# MONGO_URI is stored as an encrypted SSM parameter and injected into the backend task
# as a secret; it is never written to Git or to the task definition in plain text.
set -euo pipefail

# Git Bash on Windows rewrites arguments that start with "/" (e.g. /ecs/..., /api/*).
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
export AWS_PAGER=""

AWS_REGION="${AWS_REGION:-ap-south-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
PROJECT="${PROJECT:-mern-cicd}"
CLUSTER="${PROJECT}-cluster"
DESIRED_COUNT="${DESIRED_COUNT:-2}"
EXEC_ROLE="ecsTaskExecutionRole"
PARAM_NAME="/${PROJECT}/MONGO_URI"
ALB_NAME="${PROJECT}-alb"
ALB_SG_NAME="${PROJECT}-alb-sg"
TASK_SG_NAME="${PROJECT}-tasks-sg"

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# aws.exe prints CRLF line endings under Git Bash; strip the CR so variables stay clean.
aws() { command aws "$@" | tr -d '\r'; }

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die "AWS credentials not working"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

none() { [ -z "${1:-}" ] || [ "$1" = "None" ] || [ "$1" = "null" ]; }

# ---------------------------------------------------------------------------
# lookups
# ---------------------------------------------------------------------------
find_vpc() { aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text; }

find_sg() {  # <name> <vpc>
  aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$2" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true
}

find_alb() {
  aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true
}

find_tg() {  # <name>
  aws elbv2 describe-target-groups --names "$1" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true
}

latest_tag() {  # <component>
  aws ecr describe-images --repository-name "${PROJECT}-$1" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text 2>/dev/null || true
}

forward_json() {  # blue_arn green_arn blue_weight green_weight
  printf '[{"Type":"forward","ForwardConfig":{"TargetGroups":[{"TargetGroupArn":"%s","Weight":%s},{"TargetGroupArn":"%s","Weight":%s}]}}]' \
    "$1" "$3" "$2" "$4"
}

# ---------------------------------------------------------------------------
# create helpers (all idempotent)
# ---------------------------------------------------------------------------
ensure_sg() {  # <name> <description> <vpc>
  local id
  id="$(find_sg "$1" "$3")"
  if none "$id"; then
    id="$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$3" \
          --query GroupId --output text)"
    log "Created security group $1 ($id)"
  fi
  echo "$id"
}

ensure_tg() {  # <name> <port> <health_path> <vpc>
  local arn
  arn="$(find_tg "$1")"
  if none "$arn"; then
    arn="$(aws elbv2 create-target-group --name "$1" --protocol HTTP --port "$2" --vpc-id "$4" \
           --target-type ip --health-check-path "$3" --health-check-interval-seconds 15 \
           --health-check-timeout-seconds 5 --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
           --matcher HttpCode=200 --query 'TargetGroups[0].TargetGroupArn' --output text)"
    aws elbv2 modify-target-group-attributes --target-group-arn "$arn" \
      --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
    log "Created target group $1"
  fi
  echo "$arn"
}

td_json() {  # <component> <port> <image> <tag> <extra_env_json> <secrets_json>
  cat <<EOF | tr -d '\n'
{
  "family": "${PROJECT}-$1",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "runtimePlatform": {"operatingSystemFamily": "LINUX", "cpuArchitecture": "X86_64"},
  "containerDefinitions": [{
    "name": "$1",
    "image": "$3",
    "essential": true,
    "portMappings": [{"containerPort": $2, "protocol": "tcp"}],
    "environment": [{"name": "APP_VERSION", "value": "$4"}$5],
    "secrets": [$6],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT}-$1",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }]
}
EOF
}

ensure_service() {  # <component> <color> <count> <tg_arn> <port>
  local name="${PROJECT}-$1-$2" status
  status="$(aws ecs describe-services --cluster "$CLUSTER" --services "$name" \
            --query 'services[0].status' --output text 2>/dev/null || true)"
  if [ "$status" = "ACTIVE" ]; then
    log "Service $name already exists"
    return 0
  fi
  aws ecs create-service --cluster "$CLUSTER" --service-name "$name" \
    --task-definition "${PROJECT}-$1" --desired-count "$3" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_CSV}],securityGroups=[${TASK_SG}],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$4,containerName=$1,containerPort=$5" \
    --health-check-grace-period-seconds 90 \
    --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200" >/dev/null
  log "Created service $name (desired=$3)"
}

# ---------------------------------------------------------------------------
# up
# ---------------------------------------------------------------------------
cmd_up() {
  local vpc subnets alb_sg listener rule alb_dns tag_be tag_fe
  local be_blue be_green fe_blue fe_green

  vpc="$(find_vpc)"; none "$vpc" && die "No default VPC in $AWS_REGION"
  subnets="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" Name=default-for-az,Values=true \
             --query 'Subnets[].SubnetId' --output text)"
  read -ra SUBNET_ARR <<<"$subnets"
  [ "${#SUBNET_ARR[@]}" -ge 2 ] || die "Need at least 2 subnets in different AZs (found ${#SUBNET_ARR[@]})"
  SUBNET_CSV="$(IFS=,; echo "${SUBNET_ARR[*]}")"
  log "VPC $vpc, subnets: $SUBNET_CSV"

  # --- images must already be in ECR (run the Jenkins pipeline once first) ---
  tag_be="${IMAGE_TAG:-$(latest_tag backend)}"
  tag_fe="${IMAGE_TAG:-$(latest_tag frontend)}"
  none "$tag_be" && die "No image in ECR repo ${PROJECT}-backend. Run the Jenkins pipeline (Push to ECR) first."
  none "$tag_fe" && die "No image in ECR repo ${PROJECT}-frontend. Run the Jenkins pipeline (Push to ECR) first."
  log "Using images: backend:$tag_be  frontend:$tag_fe"

  # --- MongoDB connection string -> encrypted SSM parameter ---
  if [ -n "${MONGO_URI:-}" ]; then
    aws ssm put-parameter --name "$PARAM_NAME" --type SecureString --value "$MONGO_URI" --overwrite >/dev/null
    log "Stored MONGO_URI in SSM parameter $PARAM_NAME"
  else
    aws ssm get-parameter --name "$PARAM_NAME" >/dev/null 2>&1 \
      || die "Set MONGO_URI first (e.g. your MongoDB Atlas connection string)"
    log "Reusing existing SSM parameter $PARAM_NAME"
  fi

  # --- IAM: task execution role (pull from ECR, write logs, read the SSM secret) ---
  aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null 2>&1 || true
  if ! aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    log "Created role $EXEC_ROLE (waiting for IAM propagation)"
    sleep 10
  fi
  aws iam attach-role-policy --role-name "$EXEC_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
  aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name "${PROJECT}-ssm-read" --policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ssm:GetParameters\"],\"Resource\":\"arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${PARAM_NAME}\"}]}" >/dev/null
  EXEC_ROLE_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query Role.Arn --output text)"

  # --- log groups ---
  for c in backend frontend; do
    aws logs create-log-group --log-group-name "/ecs/${PROJECT}-$c" >/dev/null 2>&1 || true
    aws logs put-retention-policy --log-group-name "/ecs/${PROJECT}-$c" --retention-in-days 7 >/dev/null
  done

  # --- security groups ---
  alb_sg="$(ensure_sg "$ALB_SG_NAME" "ALB for $PROJECT" "$vpc")"
  TASK_SG="$(ensure_sg "$TASK_SG_NAME" "ECS tasks for $PROJECT" "$vpc")"
  aws ec2 authorize-security-group-ingress --group-id "$alb_sg" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-ingress --group-id "$TASK_SG" --protocol tcp --port 5000 --source-group "$alb_sg" >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-ingress --group-id "$TASK_SG" --protocol tcp --port 80 --source-group "$alb_sg" >/dev/null 2>&1 || true

  # --- ECS cluster ---
  aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
  log "Cluster $CLUSTER ready"

  # --- target groups ---
  be_blue="$(ensure_tg  "${PROJECT}-backend-blue"   5000 /api/health "$vpc")"
  be_green="$(ensure_tg "${PROJECT}-backend-green"  5000 /api/health "$vpc")"
  fe_blue="$(ensure_tg  "${PROJECT}-frontend-blue"  80   /health     "$vpc")"
  fe_green="$(ensure_tg "${PROJECT}-frontend-green" 80   /health     "$vpc")"

  # --- load balancer, listener, /api/* rule ---
  alb_arn="$(find_alb)"
  if none "$alb_arn"; then
    alb_arn="$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internet-facing \
               --subnets "${SUBNET_ARR[@]}" --security-groups "$alb_sg" \
               --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
    log "Created ALB $ALB_NAME (waiting until active...)"
    aws elbv2 wait load-balancer-available --load-balancer-arns "$alb_arn"
  fi

  listener="$(aws elbv2 describe-listeners --load-balancer-arn "$alb_arn" \
              --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text 2>/dev/null || true)"
  if none "$listener"; then
    listener="$(aws elbv2 create-listener --load-balancer-arn "$alb_arn" --protocol HTTP --port 80 \
                --default-actions "$(forward_json "$fe_blue" "$fe_green" 100 0)" \
                --query 'Listeners[0].ListenerArn' --output text)"
    log "Created listener :80 (frontend blue=100 green=0)"
  fi

  rule="$(aws elbv2 describe-rules --listener-arn "$listener" \
          --query 'Rules[?Priority==`"10"`].RuleArn | [0]' --output text 2>/dev/null || true)"
  if none "$rule"; then
    aws elbv2 create-rule --listener-arn "$listener" --priority 10 \
      --conditions 'Field=path-pattern,Values=/api/*' \
      --actions "$(forward_json "$be_blue" "$be_green" 100 0)" >/dev/null
    log "Created rule priority 10: /api/* (backend blue=100 green=0)"
  fi

  # --- task definitions (first revision; the pipeline registers new ones per release) ---
  local mongo_secret="{\"name\":\"MONGO_URI\",\"valueFrom\":\"arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${PARAM_NAME}\"}"
  aws ecs register-task-definition --cli-input-json \
    "$(td_json backend 5000 "${ECR_REGISTRY}/${PROJECT}-backend:${tag_be}" "$tag_be" \
        ',{"name":"PORT","value":"5000"},{"name":"NODE_ENV","value":"production"}' "$mongo_secret")" >/dev/null
  aws ecs register-task-definition --cli-input-json \
    "$(td_json frontend 80 "${ECR_REGISTRY}/${PROJECT}-frontend:${tag_fe}" "$tag_fe" '' '')" >/dev/null
  log "Registered task definitions"

  # --- services: blue live, green idle ---
  ensure_service backend  blue  "$DESIRED_COUNT" "$be_blue"  5000
  ensure_service backend  green 0                "$be_green" 5000
  ensure_service frontend blue  "$DESIRED_COUNT" "$fe_blue"  80
  ensure_service frontend green 0                "$fe_green" 80

  log "Waiting for the blue services to become stable (can take a few minutes)..."
  aws ecs wait services-stable --cluster "$CLUSTER" \
    --services "${PROJECT}-backend-blue" "${PROJECT}-frontend-blue" \
    || log "WARNING: services not stable yet - check: bash scripts/setup-aws.sh status  (and the CloudWatch logs /ecs/${PROJECT}-backend)"

  alb_dns="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)"
  log "Done."
  echo
  echo "App URL        : http://${alb_dns}"
  echo "Backend health : http://${alb_dns}/api/health"
  echo
  echo "Next: run the Jenkins job with DEPLOY_STRATEGY=bluegreen."
  echo "To stop all AWS charges: bash scripts/setup-aws.sh down"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
  local alb_arn dns
  alb_arn="$(find_alb)"
  if none "$alb_arn"; then log "ALB $ALB_NAME not found - run: up"; return 0; fi
  dns="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)"
  echo "URL: http://${dns}"
  echo
  aws ecs describe-services --cluster "$CLUSTER" \
    --services "${PROJECT}-backend-blue" "${PROJECT}-backend-green" "${PROJECT}-frontend-blue" "${PROJECT}-frontend-green" \
    --query 'services[].{service:serviceName,status:status,desired:desiredCount,running:runningCount}' --output table
  local c k tg
  for c in backend frontend; do
    for k in blue green; do
      tg="$(find_tg "${PROJECT}-$c-$k")"
      none "$tg" && continue
      echo "targets ${PROJECT}-$c-$k: $(aws elbv2 describe-target-health --target-group-arn "$tg" \
        --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
    done
  done
}

# ---------------------------------------------------------------------------
# down
# ---------------------------------------------------------------------------
retry() {  # <attempts> <cmd...>
  local n="$1" i; shift
  for i in $(seq 1 "$n"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 15
  done
  return 1
}

cmd_down() {
  local vpc alb_arn c k name tg sg td

  log "Deleting ECS services..."
  for c in backend frontend; do
    for k in blue green; do
      name="${PROJECT}-$c-$k"
      aws ecs update-service --cluster "$CLUSTER" --service "$name" --desired-count 0 >/dev/null 2>&1 || true
      aws ecs delete-service --cluster "$CLUSTER" --service "$name" --force >/dev/null 2>&1 || true
    done
  done
  aws ecs wait services-inactive --cluster "$CLUSTER" \
    --services "${PROJECT}-backend-blue" "${PROJECT}-backend-green" "${PROJECT}-frontend-blue" "${PROJECT}-frontend-green" \
    >/dev/null 2>&1 || true

  log "Deleting load balancer..."
  alb_arn="$(find_alb)"
  if ! none "$alb_arn"; then
    aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn" >/dev/null 2>&1 || true
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$alb_arn" >/dev/null 2>&1 || true
  fi

  log "Deleting target groups..."
  for c in backend frontend; do
    for k in blue green; do
      tg="$(find_tg "${PROJECT}-$c-$k")"
      none "$tg" && continue
      retry 8 aws elbv2 delete-target-group --target-group-arn "$tg" || log "Could not delete target group ${PROJECT}-$c-$k yet"
    done
  done

  log "Deleting cluster..."
  aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true

  log "Deleting security groups (waiting for network interfaces to be released)..."
  vpc="$(find_vpc)"
  for name in "$TASK_SG_NAME" "$ALB_SG_NAME"; do   # tasks SG first: it references the ALB SG
    sg="$(find_sg "$name" "$vpc")"
    none "$sg" && continue
    retry 12 aws ec2 delete-security-group --group-id "$sg" || log "Could not delete $name yet - rerun 'down' in a few minutes"
  done

  log "Deleting log groups, SSM parameter and task definitions..."
  for c in backend frontend; do
    aws logs delete-log-group --log-group-name "/ecs/${PROJECT}-$c" >/dev/null 2>&1 || true
    for td in $(aws ecs list-task-definitions --family-prefix "${PROJECT}-$c" --status ACTIVE \
                 --query 'taskDefinitionArns[]' --output text 2>/dev/null || true); do
      aws ecs deregister-task-definition --task-definition "$td" >/dev/null 2>&1 || true
    done
  done
  aws ssm delete-parameter --name "$PARAM_NAME" >/dev/null 2>&1 || true

  log "Done. Kept (no hourly cost): ECR repositories and images, IAM role $EXEC_ROLE."
}

case "${1:-}" in
  up)     cmd_up ;;
  status) cmd_status ;;
  down)   cmd_down ;;
  *)      echo "usage: bash scripts/setup-aws.sh {up|status|down}" >&2; exit 2 ;;
esac
