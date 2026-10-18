# MERN CI/CD on AWS with Jenkins

A complete, working reference project: a **MongoDB + Express + React + Node.js** app delivered by a
**Jenkins** pipeline with automated tests, code-quality gates, container security scanning, and
zero-downtime **blue-green** and **canary** releases to **AWS (ECS Fargate + ALB)**.

> Full walkthrough: **[docs/STEP_BY_STEP_GUIDE.md](docs/STEP_BY_STEP_GUIDE.md)**

## What you get

| Area | Implementation |
|---|---|
| App | React (Vite) frontend, Express API, MongoDB (Atlas) - a small "Release board" task app |
| CI | ESLint, Jest + Supertest (real MongoDB), Vitest + Testing Library, coverage thresholds |
| Code quality | SonarQube analysis + **quality gate** that fails the pipeline, `npm audit` |
| Container security | Multi-stage non-root Dockerfiles, Trivy scan, ECR scan-on-push, immutable tags |
| Infra as code | Terraform: VPC, ALB, ECR, ECS Fargate, IAM (least-privilege Jenkins policy), SSM secret |
| Blue-green | Idle environment is deployed + health-checked, traffic flips 100% in one API call, auto-rollback |
| Canary | Traffic steps 10% -> 50% -> 100% with probes + CloudWatch 5XX checks, auto-rollback |
| Rollback | `scripts/rollback.sh` - seconds, even after the old version was scaled down |

## Repository layout

```
.
├── Jenkinsfile                  # the CI/CD pipeline
├── backend/                     # Express API (+ Dockerfile, ESLint, Jest tests)
├── frontend/                    # React app (+ Dockerfile, nginx, ESLint, Vitest tests)
├── scripts/                     # deployment logic used by Jenkins
│   ├── lib.sh                   #   shared helpers (traffic shifting, health waits, probes)
│   ├── deploy-bluegreen.sh
│   ├── deploy-canary.sh
│   ├── rollback.sh
│   ├── finalize.sh              #   scale the old color down
│   └── smoke-test.sh
├── infra/terraform/             # AWS infrastructure
├── jenkins/                     # Jenkins image (docker, aws, trivy, plugins)
├── docker-compose.yml           # app + Jenkins + SonarQube local stack
├── docker-compose.jenkins.yml   # Jenkins + SonarQube only
├── sonar-project.properties
└── docs/STEP_BY_STEP_GUIDE.md
```

## Quick start

```bash
# 1. run the app, Jenkins, and SonarQube locally
docker compose up --build
# App:       http://localhost:8085
# Jenkins:   http://localhost:8082
# SonarQube: http://localhost:9000

# Jenkins initial admin password
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword

# 2. create the AWS infrastructure
cd infra/terraform && cp terraform.tfvars.example terraform.tfvars   # edit mongodb_uri
terraform init && terraform apply
```

Then follow Parts 5-9 of the guide to configure Jenkins and run your first release.

## Architecture

```
 Developer ──push──▶ GitHub ──webhook──▶ Jenkins
                                           │ lint · test · Sonar gate · build · Trivy
                                           ▼
                                      Amazon ECR  (immutable image tags)
                                           │ deploy-bluegreen.sh / deploy-canary.sh
                                           ▼
   Users ──▶ ALB :80 ──┬─ /api/*  ─▶ backend-blue (w=100) | backend-green (w=0)    ┐ weighted
                       └─ default ─▶ frontend-blue (w=100) | frontend-green (w=0) ┘ forwarding
                                           │ ECS Fargate in private subnets
                                           ▼
                                    MongoDB Atlas  (URI from SSM SecureString)
```
