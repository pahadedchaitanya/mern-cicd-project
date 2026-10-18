# Step-by-Step Guide: CI/CD for a MERN App with Jenkins on AWS

This guide takes you from an empty machine to a MERN application that is tested, quality-checked,
scanned, and released to AWS with **blue-green** and **canary** strategies - all driven by Jenkins.

**Contents**

1. [Concepts and architecture](#part-1--concepts-and-architecture)
2. [Prerequisites](#part-2--prerequisites)
3. [Run and understand the application](#part-3--run-and-understand-the-application)
4. [Automated tests and code-quality checks](#part-4--automated-tests-and-code-quality-checks)
5. [Set up Jenkins and SonarQube](#part-5--set-up-jenkins-and-sonarqube)
6. [Provision AWS with Terraform](#part-6--provision-aws-with-terraform)
7. [Connect Jenkins to AWS and GitHub](#part-7--connect-jenkins-to-aws-and-github)
8. [Create the pipeline and run the first release](#part-8--create-the-pipeline-and-run-the-first-release)
9. [Blue-green deployments in depth](#part-9--blue-green-deployments-in-depth)
10. [Canary releases in depth](#part-10--canary-releases-in-depth)
11. [Rollback, retire, and operate](#part-11--rollback-retire-and-operate)
12. [Troubleshooting](#part-12--troubleshooting)
13. [Hardening and cost](#part-13--hardening-and-cost)
14. [Clean up](#part-14--clean-up)

---

## Part 1 - Concepts and architecture

### The pipeline

```
Checkout → Install → Lint → Unit tests → SonarQube → Quality Gate → npm audit
        → Docker build → Trivy scan → Push to ECR → Approval → Deploy → Verify → Retire old
                                      └────────── main branch only ──────────┘
```

| Stage | Purpose | Fails the build when |
|---|---|---|
| Lint | ESLint on both packages | any lint error |
| Unit tests | Jest (API, real MongoDB container) + Vitest (React) | a test fails or coverage drops below the threshold in `backend/jest.config.js` |
| SonarQube + Quality Gate | bugs, vulnerabilities, code smells, coverage on new code | the gate is red |
| Dependency audit | `npm audit` for high severity | marks build **unstable** (non-blocking) |
| Trivy | scans the built images | a CRITICAL vulnerability with an available fix |
| Deploy | blue-green or canary on ECS | health checks, smoke tests, or error rate fail (auto-rollback) |

### How traffic shifting works on AWS

There are **two complete copies** of the stack, called *blue* and *green*. Each copy is two ECS
services (backend + frontend). The Application Load Balancer sends traffic using **weighted
forwarding**:

* Listener default action → frontend target groups (`frontend-blue`, `frontend-green`)
* Listener rule `/api/*` (priority 10) → backend target groups (`backend-blue`, `backend-green`)

Changing a weight is one API call, so:

* **Blue-green** = weights go `100/0 → 0/100` after the idle color is proven healthy.
* **Canary** = weights go `100/0 → 90/10 → 50/50 → 0/100`, checking health at each step.
* **Rollback** = put the weights back.

Terraform creates the weights but is told to `ignore_changes` on them, so the pipeline owns them.
The scripts discover everything by **naming convention** (`<project>-alb`, `<project>-backend-blue`,
...), so no state has to be passed around.

> **Why not CodeDeploy?** AWS CodeDeploy can do ECS blue-green/canary natively. This project uses
> ALB weighted routing + scripts instead because every step is visible in Jenkins and in ~200 lines
> of readable Bash - ideal for learning. Part 13 says how to swap in CodeDeploy.

### Database

MongoDB is **MongoDB Atlas** (free M0 tier is fine). Both colors talk to the same database, so schema
changes must be **backward compatible** between two consecutive versions (add fields; do not rename
or remove them in the same release that stops using them).

---

## Part 2 - Prerequisites

| Need | Version / note |
|---|---|
| Docker + Docker Compose v2 | to run the app locally, Jenkins and SonarQube |
| Node.js | 22 LTS (only needed if you run tests outside Docker; Jenkins uses the Node 22 inside its image) |
| Git + a GitHub account | the pipeline is a *multibranch* job fed by GitHub |
| AWS account | admin rights for the initial Terraform run |
| AWS CLI v2 | configured with `aws configure` for the Terraform run |
| Terraform | 1.5 or newer |
| MongoDB Atlas cluster | free M0; create a DB user and keep the connection string |
| 8 GB RAM free | Jenkins + SonarQube are memory-hungry |

On **Linux**, SonarQube (Elasticsearch) needs a kernel setting:

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
```

Put the project in a GitHub repository now:

```bash
cd mern-cicd-project
git init && git add . && git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/<you>/mern-cicd-project.git
git push -u origin main
```

---

## Part 3 - Run and understand the application

```bash
docker compose up --build
```

* App: <http://localhost:8085> - add, complete and delete tasks.
* API health: <http://localhost:5006/api/health>
* Jenkins: <http://localhost:8082>
* SonarQube: <http://localhost:9000>

The default Compose stack starts the app, Jenkins, SonarQube, and both databases. Jenkins and
SonarQube may take a few minutes to finish initializing; check their logs with
`docker compose logs -f jenkins sonarqube`.

The header on the page shows **"API build"**. Locally it says `local`; in AWS it shows the
Jenkins image tag (`<build number>-<git sha>`). You will use it to *see* a blue-green or canary
release happen.

### Things in the code that make safe deployments possible

| Where | What | Why it matters |
|---|---|---|
| `backend/src/routes/health.js` | `/api/health` returns **503** if MongoDB is down; includes `version` | ALB and scripts never route to a broken release; scripts can tell which release answered |
| `backend/src/server.js` | graceful shutdown on `SIGTERM` | ECS drains connections when old tasks stop - no dropped requests |
| `backend/Dockerfile`, `frontend/Dockerfile` | multi-stage, non-root, `HEALTHCHECK` | small, safer images |
| `frontend/nginx.conf` | `/health` endpoint, SPA fallback, long-cache for hashed assets | ALB health check for the frontend |
| `frontend/src/api.js` | calls `/api/...` (relative) | the ALB routes `/api/*`, so the same build works in every environment |

---

## Part 4 - Automated tests and code-quality checks

Run the same checks Jenkins runs. From the repo root:

```bash
# Backend
cd backend
npm ci
npm run lint
npm test            # uses an in-memory MongoDB, or MONGO_TEST_URI if you set it
# Frontend
cd ../frontend
npm ci
npm run lint
npm test
```

* **Backend tests** (`backend/tests/tasks.test.js`) exercise the real Express app with Supertest
  against a real MongoDB. In Jenkins a `mongo:7` container is started per build and passed in via
  `MONGO_TEST_URI`. Locally, `mongodb-memory-server` downloads a MongoDB binary the first time.
* **Frontend tests** (`frontend/tests/App.test.jsx`) render the component with Testing Library and
  a mocked `fetch`.
* **Coverage gates:** `backend/jest.config.js` has `coverageThreshold`. Raise it as the project grows.
* **JUnit XML** is written to `backend/reports/junit.xml` and `frontend/reports/junit.xml`; Jenkins
  shows trends from them.

### Adding your own checks

* New API test → add a file in `backend/tests/` (`*.test.js`).
* New UI test → add `frontend/tests/*.test.jsx`.
* Stricter lint → edit `.eslintrc.json` in each package.

---

## Part 5 - Set up Jenkins and SonarQube

### 5.1 Start them

```bash
docker compose up -d --build jenkins sonarqube
docker compose logs -f jenkins     # wait for the admin password
```

* Jenkins → <http://localhost:8082>
* SonarQube → <http://localhost:9000> (first login `admin` / `admin`, you are asked to change it)

The custom Jenkins image (`jenkins/Dockerfile`) already contains **docker CLI, AWS CLI v2, jq,
curl and Trivy**, and the plugins from `jenkins/plugins.txt`.

> The compose file mounts `/var/run/docker.sock` so Jenkins can build images. That is root-equivalent
> access to the host: perfect for a lab, but use dedicated build agents in production.

### 5.2 First-time Jenkins setup

1. Open Jenkins, paste the initial admin password
   (`docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword`).
2. Choose **Select plugins to install → None** (our plugins are already installed), create your admin user.
3. Confirm the URL (`http://localhost:8082/`).

### 5.3 Configure tools (Manage Jenkins → Tools)

Node.js 22, npm, docker, aws, jq and trivy are already inside the Jenkins image, so no NodeJS tool is needed.

| Tool | Name (must match exactly) | Setting |
|---|---|---|
| SonarQube Scanner | `SonarScanner` | Install automatically from Maven Central (latest) |

### 5.4 Connect Jenkins to SonarQube

1. SonarQube → **My Account → Security → Generate Token** (type *User* or *Global Analysis*). Copy it.
2. Jenkins → **Manage Jenkins → Credentials → (global) → Add Credentials**: kind *Secret text*,
   secret = the token, ID = `sonar-token`.
3. Jenkins → **Manage Jenkins → System → SonarQube servers → Add**:
   * Name: `sonarqube`  (must match `withSonarQubeEnv('sonarqube')`)
   * Server URL: `http://sonarqube:9000` (the compose service name - both containers share a network)
   * Server authentication token: `sonar-token`
4. **Webhook (required for the Quality Gate stage):** SonarQube → **Administration → Configuration →
   Webhooks → Create**: Name `jenkins`, URL `http://jenkins:8080/sonarqube-webhook/`.
   Without it `waitForQualityGate` waits until its timeout. The Compose configuration sets `sonar.validateWebhooks=false`, which SonarQube needs before it will call a private address like `jenkins:8080`.

### 5.5 (Optional) Tighten the Sonar quality gate

SonarQube → **Quality Gates → Create** (copy "Sonar way") and add conditions such as *Coverage on new
code ≥ 80%*, *Duplicated lines on new code ≤ 3%*, *Security rating = A*. Set it as the default.

---

## Part 6 - Provision AWS with Terraform

### 6.1 What gets created

VPC (2 public + 2 private subnets, 1 NAT gateway) · ALB with weighted listener rules · 4 target
groups · 2 ECR repositories (immutable tags, scan on push) · ECS cluster · 4 ECS Fargate services
(`backend/frontend × blue/green`, **desired count 0** until the first release) · IAM roles ·
SSM SecureString for `MONGO_URI` · CloudWatch log groups · an IAM user + least-privilege policy for Jenkins.

### 6.2 Apply it

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars -> put your real MongoDB Atlas connection string in mongodb_uri
terraform init
terraform plan
terraform apply
```

Note the outputs - you need them next:

```
alb_dns_name     = "mern-cicd-alb-123456789.ap-south-1.elb.amazonaws.com"
ecr_registry     = "123456789012.dkr.ecr.ap-south-1.amazonaws.com"
jenkins_iam_user = "mern-cicd-jenkins"
nat_public_ips   = ["13.x.x.x"]
```

### 6.3 Allow the containers into MongoDB Atlas

Fargate tasks sit in private subnets and reach the internet through the NAT gateway. In Atlas →
**Network Access → Add IP Address**, add each address in `nat_public_ips`. (For a throw-away demo
you could use `0.0.0.0/0`; do not do that for real data. VPC peering or PrivateLink is the production answer.)

### 6.4 Create the Jenkins access key

```bash
aws iam create-access-key --user-name mern-cicd-jenkins
```

Copy `AccessKeyId` and `SecretAccessKey` for Part 7. The attached policy lets Jenkins push to
the two ECR repositories, register task definitions, update ECS services, modify the ALB listener
weights, read CloudWatch metrics, and pass the two ECS roles - nothing else.

> **Region / naming:** the Jenkinsfile has `AWS_REGION = 'ap-south-1'` and `PROJECT = 'mern-cicd'`.
> If you change `aws_region` or `project` in Terraform, change them in the Jenkinsfile too.

---

## Part 7 - Connect Jenkins to AWS and GitHub

### 7.1 AWS credentials in Jenkins

**Manage Jenkins → Credentials → Add Credentials**
Kind: **AWS Credentials** · ID: `aws-jenkins` · Access Key ID / Secret Access Key from step 6.4.

*(On AWS-hosted Jenkins you can skip keys and use an EC2 instance role; then remove the
`withAws` credential binding in the Jenkinsfile.)*

### 7.2 GitHub access

* **Public repo:** nothing needed.
* **Private repo:** create a GitHub personal access token (scope `repo`) and add it as a
  *Username with password* credential (ID `github-pat`).

### 7.3 GitHub webhook (so a push starts the build)

GitHub repo → **Settings → Webhooks → Add webhook**
Payload URL `http://<your-jenkins-public-url>/github-webhook/` · content type `application/json` · event *Just the push event*.

Jenkins on localhost is not reachable from GitHub. For a lab, expose it with a tunnel
(`ngrok http 8082`) or skip the webhook and use **Scan Repository Now**.

---

## Part 8 - Create the pipeline and run the first release

### 8.1 Create the job

1. Jenkins → **New Item** → name `mern-cicd` → **Multibranch Pipeline**.
2. **Branch Sources → GitHub** (or Git) → repository URL, credentials if private.
3. **Build Configuration:** mode *by Jenkinsfile*, script path `Jenkinsfile`.
4. **Scan Multibranch Pipeline Triggers:** tick *Periodically if not otherwise run* (e.g. 5 min) as a webhook fallback.
5. **Save.** Jenkins scans the repo and creates a job for `main`.

Why multibranch? Feature branches run **CI only** (lint, test, build, scan). Only `main` pushes to
ECR and deploys - enforced by `when { branch 'main' }` in the Jenkinsfile.

### 8.2 Run CI on a feature branch

```bash
git checkout -b feature/try-ci
echo "// trigger" >> backend/src/app.js
git commit -am "Try CI" && git push -u origin feature/try-ci
```

Watch **Stage View**: it stops after *Trivy Image Scan* - exactly what you want for a branch.

### 8.3 First production release

On `main`: **Build with Parameters**

| Parameter | First run value |
|---|---|
| `DEPLOY_STRATEGY` | `bluegreen` |
| `REQUIRE_APPROVAL` | on |

When the pipeline reaches **Approve Production Release**, click **Deploy**. What happens:

1. Both services of the idle color (`green`, because Terraform starts with blue "live" at 100%)
   are given a new task definition pointing at your image tag and scaled to 2 tasks.
2. The script waits for ECS stability **and** for every ALB target to be healthy
   (health check = `/api/health`, which includes a MongoDB connectivity check).
3. Traffic is flipped to green. The smoke test runs through the ALB DNS name.
4. **Verify Production** repeats the smoke test and asserts the response comes from *this* image tag.
5. **Retire Previous Version** asks for confirmation, then scales the old color to 0.

Open `http://<alb_dns_name>`. The header shows `API build <number>-<sha>`. 🎉

---

## Part 9 - Blue-green deployments in depth

`scripts/deploy-bluegreen.sh <tag>`

```
              before                           during                           after
   ALB ─100%▶ BLUE (v1)            ALB ─100%▶ BLUE (v1)             ALB ─100%▶ GREEN (v2)
               GREEN (idle)                    GREEN (v2 starting,   BLUE (v1, kept warm)
                                               health-checked,
                                               no user traffic)
```

1. `active_color` reads the ALB weights to find the live color; the other is *idle*.
2. `deploy_idle` registers new task-definition revisions (image tag + `APP_VERSION` env var) and
   scales the idle services to `DESIRED_COUNT` (default 2).
3. If the idle color does not become healthy, the script scales it back to 0 and exits - **users never noticed**.
4. `set_color_pct <idle> 100` flips both the frontend listener and the `/api/*` rule.
5. `smoke-test.sh` checks `/api/health` (200 + expected version), `/api/tasks` (reads MongoDB) and
   the SPA shell. On failure the weights are put straight back and the idle color is scaled down.
6. On success the old color stays running as an **instant-rollback standby** until `finalize.sh`.

### Try it

1. Change something visible (e.g. the heading in `frontend/src/App.jsx`), commit to `main`.
2. Run the pipeline with `bluegreen`.
3. In another terminal, watch the version flip:
   ```bash
   while true; do curl -s http://<alb>/api/health | jq -r .version; sleep 1; done
   ```
   You will see the old tag, then (within a few seconds) the new one - with no errors in between.

### Test the automatic rollback

Break the release on purpose: in `backend/src/routes/health.js` return `503` always, commit and run
the pipeline. The idle color never becomes healthy, the script aborts, and production stays on the old version.

---

## Part 10 - Canary releases in depth

`scripts/deploy-canary.sh <tag>`

```
 10%  ALB ─90%▶ BLUE (v1)        bake 2 min · probe · CloudWatch check
          └10%▶ GREEN (v2)
 50%  ALB ─50%▶ BLUE   ─50%▶ GREEN    bake · probe · check
100%  ALB ─────────────────▶ GREEN    final smoke test, BLUE kept as standby
```

At every step the script:

1. Sets the weights (`set_color_pct <new> <pct>`).
2. **Bakes** for `BAKE_SECONDS` while sending `BAKE_SECONDS × 2` requests to `/api/health` through
   the public ALB. It counts non-200 answers and how many requests the *new* version served.
3. Fails if the error rate is above `MAX_ERROR_PCT` (default 1%).
4. Queries CloudWatch (`HTTPCode_Target_5XX_Count` / `RequestCount`, last 5 minutes) per component;
   fails if the new color's 5XX rate is above the threshold. (CloudWatch lags 1-2 minutes, which is why
   the direct probe is the primary signal.)
5. On any failure: weights return to 100% on the stable color, the canary is scaled to 0, the build fails.

### Run it

Jenkins → **Build with Parameters**: `DEPLOY_STRATEGY=canary`, `CANARY_STEPS="10 50 100"`, `BAKE_SECONDS=120`.

Watch the split live:

```bash
for i in $(seq 1 40); do curl -s http://<alb>/api/health | jq -r .version; done | sort | uniq -c
#   36 41-a1b2c3d     <- stable
#    4 42-d4e5f6a     <- canary (≈10%)
```

### Tuning

| Variable | Default | Meaning |
|---|---|---|
| `CANARY_STEPS` | `10 50 100` | e.g. `5 25 50 100` for a more cautious rollout |
| `BAKE_SECONDS` | `120` | observation time per step; use 300+ in real production |
| `MAX_ERROR_PCT` | `1` | allowed failure percentage |
| `USE_CLOUDWATCH` | `true` | set `false` for quiet environments with no traffic |

For real production traffic, replace the synthetic probe with business metrics (latency p95, checkout
success rate) from CloudWatch/Prometheus - add them next to the `cw_sum` calls.

### Blue-green vs canary - which to use

| | Blue-green | Canary |
|---|---|---|
| Blast radius if the release is bad | 100% of users for a few seconds until the smoke test fails | 10% (then 50%) |
| Speed | fastest | slower (bake time) |
| Cost during release | 2× capacity | 2× capacity |
| Best for | small/medium apps, DB-compatible changes, need instant switch | risky changes, high traffic, want real-user validation |

---

## Part 11 - Rollback, retire, and operate

### Roll back (manual)

From Jenkins: add a "Rollback" job running `./scripts/rollback.sh` with the `aws-jenkins` credentials,
or from a shell with AWS access:

```bash
export AWS_REGION=ap-south-1
./scripts/rollback.sh
```

It finds the standby color. If the standby was scaled to 0 it is **started first** (its task
definition still points to the previous image, which ECR keeps), waits for health, flips traffic,
and smoke-tests.

### Retire the old color

`scripts/finalize.sh` scales the standby to 0 (the Jenkinsfile asks for confirmation). It refuses to
run while traffic is split, so you cannot scale down mid-canary.

### Useful commands

```bash
# Which color is live, and traffic split?
source scripts/lib.sh; echo "active=$(active_color) green%=$(current_green_pct)"

# Service state
aws ecs describe-services --cluster mern-cicd-cluster \
  --services mern-cicd-backend-blue mern-cicd-backend-green \
  --query 'services[].{n:serviceName,run:runningCount,want:desiredCount}'

# Logs
aws logs tail /ecs/mern-cicd/backend --follow
```

---

## Part 12 - Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `No such tool 'SonarScanner'` | Tool name mismatch - see Part 5.3 |
| `Quality Gate` stage hangs | Sonar → Jenkins webhook missing (Part 5.4 step 4) |
| Backend tests: `ECONNREFUSED` | Mongo container not ready or Jenkins cannot reach the container IP; check the "Backend (Jest + MongoDB)" log |
| `docker: command not found` / permission denied on the socket | You are not using `jenkins/Dockerfile`, or the socket is not mounted |
| Trivy exits 1 | A CRITICAL fixable CVE - bump the base image/dependency, or consciously add `.trivyignore` |
| `AccessDenied` from aws | Jenkins key missing a permission - compare with `aws_iam_policy.jenkins_deploy` |
| ECR `repository does not exist` | Jenkins and Terraform must use the same AWS account, region, and `project`; apply Terraform there to create the ECR repositories |
| ECR `tag invalid: immutable` | You re-pushed an existing tag. Tags include the build number; do not reuse a workspace's `IMAGE_TAG` |
| ECS service never stable | `aws ecs describe-services ... --query 'services[0].events[:5]'`; usually the container exits - read `/ecs/mern-cicd/backend` logs |
| Targets `unhealthy`, API logs `MongoDB connection error` | Atlas Network Access does not include the NAT IP, or wrong `mongodb_uri` (re-apply Terraform with the corrected value and start a new deployment so tasks re-read the parameter) |
| `503` from ALB right after Terraform | No tasks yet (desired count 0). Run the first pipeline release |
| Canary: "no probe request reached the canary" warning | Very short bake or tiny step; harmless, increase `BAKE_SECONDS` |
| Rollback complains standby has 0 tasks | Expected after `finalize.sh`; the script starts it automatically |

---

## Part 13 - Hardening and cost

**Security**

* Add **HTTPS**: request an ACM certificate, add an `aws_lb_listener` on 443 (same weighted
  `forward` blocks, `ignore_changes`), redirect port 80 to 443, and update `listener_arn()` in
  `scripts/lib.sh` to use port 443.
* Put the Jenkins UI behind HTTPS and SSO; run builds on ephemeral agents, not the controller.
* Use OIDC / instance roles instead of long-lived AWS keys.
* Store the Terraform state in S3 + DynamoDB lock (commented block in `versions.tf`).
* Add AWS WAF to the ALB; use PrivateLink or peering to Atlas.
* Turn the `npm audit` stage from *unstable* into *failing* once the baseline is clean.

**Reliability**

* Add ECS service auto-scaling and one NAT gateway per AZ.
* Add CloudWatch alarms (ALB 5XX, target response time) and wire them into the canary check.
* Add a staging environment: duplicate the Terraform with `environment = "staging"` and a
  different `project` prefix, and add a deploy stage before production.

**Using AWS CodeDeploy instead:** create an `aws_codedeploy_app` (`ECS` platform) and deployment
group with `deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"`, switch the
ECS services to `deployment_controller { type = "CODE_DEPLOY" }`, and replace the deploy script with
`aws deploy create-deployment`. The pipeline up to "Push to ECR" is unchanged.

**Cost (approximate, ap-south-1, always-on)**: NAT gateway ≈ $35/mo, ALB ≈ $20/mo, Fargate tasks
(2 × backend + 2 × frontend at 0.25 vCPU / 0.5 GB) ≈ $35/mo, plus data transfer. During a release
the idle color doubles Fargate cost for a few minutes. Run `finalize.sh` to avoid paying for a
standby, and destroy the stack when you are done learning (Part 14).

---

## Part 14 - Clean up

```bash
# scale everything to zero first (optional, makes destroy faster)
for s in backend-blue backend-green frontend-blue frontend-green; do
  aws ecs update-service --cluster mern-cicd-cluster --service mern-cicd-$s --desired-count 0 >/dev/null
done

cd infra/terraform && terraform destroy

# local tooling
docker compose down -v
```

Also delete the Jenkins IAM access key (`aws iam delete-access-key`) and the Atlas cluster if you created one just for this.
