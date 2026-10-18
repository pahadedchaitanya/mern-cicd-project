// ============================================================================
// MERN CI/CD pipeline - Jenkins declarative pipeline
//
// CI  : install -> lint -> unit tests (+coverage) -> SonarQube + quality gate
//       -> dependency audit -> docker build -> Trivy image scan
//
// CD  : (main branch only) push to ECR -> approval -> blue-green OR canary
//       deploy to ECS Fargate behind an ALB -> verify -> retire old version
//
// Works as a Multibranch Pipeline (recommended) AND as a plain
// "Pipeline script from SCM" job - branch checks use currentBranch() below.
//
// Jenkins prerequisites (all baked into jenkins/Dockerfile except the config):
//   Image tools  : node 22, npm, docker CLI, aws cli v2, jq, curl, trivy
//   Tool config  : SonarQube Scanner named "SonarScanner"   (Manage Jenkins > Tools)
//   Sonar server : named "sonarqube"                        (Manage Jenkins > System)
//   Credentials  : "aws-jenkins" (AWS Credentials)          (only needed for the CD stages)
// ============================================================================


// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

// Branch name that works for Multibranch (BRANCH_NAME) and plain SCM jobs (GIT_BRANCH).
// NOTE: `when { branch 'main' }` only works in Multibranch jobs and silently skips the
// stage everywhere else - which would skip the Quality Gate and every deploy stage.
def currentBranch() {
    def name = env.BRANCH_NAME ?: env.GIT_BRANCH ?: ''
    return name.replaceFirst(/^origin\//, '')
}

def isMain() {
    return currentBranch() == 'main'
}

def isMainOrDevelop() {
    return currentBranch() ==~ /main|develop/
}

def withAws(Closure body) {
    withCredentials([
        [
            $class: 'AmazonWebServicesCredentialsBinding',
            credentialsId: 'aws-jenkins',
            accessKeyVariable: 'AWS_ACCESS_KEY_ID',
            secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
        ]
    ]) {
        withEnv([
            "AWS_REGION=${env.AWS_REGION}",
            "AWS_DEFAULT_REGION=${env.AWS_REGION}"
        ]) {
            body()
        }
    }
}


pipeline {

    agent any

    options {
        timestamps()

        // Includes the manual approval waits (30 + 60 min max) plus build and deploy time
        timeout(time: 150, unit: 'MINUTES')

        buildDiscarder(logRotator(numToKeepStr: '20'))

        // Prevent two deployments from running at the same time
        disableConcurrentBuilds()

        // The first stage runs `checkout scm` itself - avoid checking out twice
        skipDefaultCheckout(true)
    }

    parameters {
        choice(
            name: 'DEPLOY_STRATEGY',
            choices: ['none', 'bluegreen', 'canary'],
            description: 'Select none for CI only (build, test, and push images to ECR; no AWS deployment).'
        )

        booleanParam(
            name: 'REQUIRE_APPROVAL',
            defaultValue: true,
            description: 'Ask a human before deploying to production'
        )

        booleanParam(
            name: 'TRIVY_ENFORCE',
            defaultValue: true,
            description: 'Fail the build on fixable CRITICAL image vulnerabilities. Untick to only report them.'
        )

        string(
            name: 'CANARY_STEPS',
            defaultValue: '10 50 100',
            description: 'Canary only: traffic percentages to step through'
        )

        string(
            name: 'BAKE_SECONDS',
            defaultValue: '120',
            description: 'Canary only: observation time at each step'
        )
    }

    environment {
        AWS_REGION = 'ap-south-2'
        PROJECT    = 'mern-cicd'
        CI         = 'true'

        // mongodb-memory-server would otherwise download a ~100 MB mongod binary during
        // `npm ci`. CI uses a real MongoDB container instead (scripts/ci-mongo.sh).
        MONGOMS_DISABLE_POSTINSTALL = '1'

        NPM_CONFIG_UPDATE_NOTIFIER = 'false'
        NPM_CONFIG_FUND            = 'false'
    }

    stages {

        // ====================================================================
        // CHECKOUT & INIT
        // ====================================================================
        stage('Checkout & Init') {
            steps {
                script {
                    // checkout scm returns the Git variables; in a plain "Pipeline script from SCM"
                    // job BRANCH_NAME is not set, so take the branch from GIT_BRANCH (origin/main).
                    def scmVars = checkout scm
                    if (!env.BRANCH_NAME && scmVars?.GIT_BRANCH) {
                        env.GIT_BRANCH = scmVars.GIT_BRANCH
                    }

                    def sha = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()

                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-${sha}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${sha}"

                    echo "Branch: ${currentBranch()}  |  Image tag: ${env.IMAGE_TAG}"
                }

                // Fail early, with a clear message, if the Jenkins image is missing something.
                sh '''
                    for tool in node npm docker git curl jq aws trivy; do
                        command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' is not installed on this Jenkins agent"; exit 1; }
                    done
                    node --version
                    npm --version
                    docker --version
                    docker info --format 'Docker daemon reachable, server {{.ServerVersion}}'
                '''
            }
        }


        // ====================================================================
        // INSTALL DEPENDENCIES
        // ====================================================================
        stage('Install Dependencies') {
            parallel {
                stage('Backend') {
                    steps {
                        dir('backend') {
                            sh 'npm ci'
                        }
                    }
                }

                stage('Frontend') {
                    steps {
                        dir('frontend') {
                            sh 'npm ci'
                        }
                    }
                }
            }
        }


        // ====================================================================
        // LINT
        // ====================================================================
        stage('Lint') {
            parallel {
                stage('Backend ESLint') {
                    steps {
                        dir('backend') {
                            sh 'npm run lint'
                        }
                    }
                }

                stage('Frontend ESLint') {
                    steps {
                        dir('frontend') {
                            sh 'npm run lint'
                        }
                    }
                }
            }
        }


        // ====================================================================
        // UNIT TESTS
        // ====================================================================
        stage('Unit Tests') {
            parallel {

                // ------------------------------------------------------------
                // Backend: Jest + Supertest against a REAL MongoDB container.
                //
                // scripts/ci-mongo.sh starts MongoDB on the same Docker network
                // as Jenkins (auto-detected), proves it is reachable from Jenkins,
                // and prints MONGO_TEST_URI. If MongoDB cannot be reached the stage
                // fails right there with diagnostics, not with 9 failing tests.
                // ------------------------------------------------------------
                stage('Backend (Jest + MongoDB)') {
                    steps {
                        script {
                            // Unique per job AND build: in a multibranch project two
                            // branches can both be on build #5 at the same time.
                            def mongo = "mongo-test-${env.BUILD_NUMBER}-${Math.abs(env.JOB_NAME.hashCode())}"

                            try {
                                def output = sh(
                                    returnStdout: true,
                                    script: "bash scripts/ci-mongo.sh start ${mongo}"
                                ).trim()

                                def mongoUri = output.readLines().last().replace('MONGO_TEST_URI=', '')

                                dir('backend') {
                                    withEnv(["MONGO_TEST_URI=${mongoUri}"]) {
                                        sh 'echo "Running backend tests against $MONGO_TEST_URI" && npm test'
                                    }
                                }
                            }
                            finally {
                                sh "bash scripts/ci-mongo.sh stop ${mongo}"

                                junit(
                                    allowEmptyResults: true,
                                    testResults: 'backend/reports/junit.xml'
                                )
                            }
                        }
                    }
                }

                // ------------------------------------------------------------
                // Frontend: Vitest + Testing Library (jsdom, no database)
                // ------------------------------------------------------------
                stage('Frontend (Vitest)') {
                    steps {
                        dir('frontend') {
                            sh 'npm test'
                        }
                    }

                    post {
                        always {
                            junit(
                                allowEmptyResults: true,
                                testResults: 'frontend/reports/junit.xml'
                            )
                        }
                    }
                }
            }
        }


        // ====================================================================
        // SONARQUBE ANALYSIS  (main and develop)
        // ====================================================================
        stage('SonarQube Analysis') {
            when {
                expression { isMainOrDevelop() }
            }

            steps {
                script {
                    // Jest/Vitest write "SF:src/app.js"; Sonar runs from the repo root and
                    // needs "SF:backend/src/app.js" / "SF:frontend/src/App.jsx".
                    sh '''
                        for app in backend frontend; do
                            if [ -f "$app/coverage/lcov.info" ]; then
                                sed -i "s#^SF:src/#SF:$app/src/#" "$app/coverage/lcov.info"
                            else
                                echo "WARNING: $app/coverage/lcov.info missing - Sonar will show 0% coverage for $app"
                            fi
                        done
                    '''

                    def scannerHome = tool 'SonarScanner'

                    withSonarQubeEnv('sonarqube') {
                        sh "${scannerHome}/bin/sonar-scanner -Dsonar.projectVersion=${env.IMAGE_TAG}"
                    }
                }
            }
        }


        // ====================================================================
        // QUALITY GATE
        // Needs the SonarQube webhook -> http://jenkins:8080/sonarqube-webhook/
        // ====================================================================
        stage('Quality Gate') {
            when {
                expression { isMainOrDevelop() }
            }

            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    waitForQualityGate(abortPipeline: true)
                }
            }
        }


        // ====================================================================
        // DEPENDENCY AUDIT  (vulnerabilities make the build UNSTABLE, not FAILED)
        // ====================================================================
        stage('Dependency Audit') {
            steps {
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    dir('backend') {
                        sh 'npm audit --omit=dev --audit-level=high'
                    }

                    dir('frontend') {
                        sh 'npm audit --omit=dev --audit-level=high'
                    }
                }
            }
        }


        // ====================================================================
        // BUILD DOCKER IMAGES
        // ====================================================================
        stage('Build Docker Images') {
            parallel {
                stage('Backend image') {
                    steps {
                        sh 'docker build -t "$PROJECT-backend:$IMAGE_TAG" backend'
                    }
                }

                stage('Frontend image') {
                    steps {
                        sh 'docker build -t "$PROJECT-frontend:$IMAGE_TAG" frontend'
                    }
                }
            }
        }


        // ====================================================================
        // TRIVY IMAGE SCAN
        // Scans BOTH images before failing, so one run shows every problem.
        // ====================================================================
        stage('Trivy Image Scan') {
            steps {
                withEnv(["TRIVY_EXIT_CODE=${params.TRIVY_ENFORCE ? 1 : 0}"]) {
                    sh '''
                        rc=0
                        for c in backend frontend; do
                            echo "=== Trivy: $PROJECT-$c:$IMAGE_TAG"
                            trivy image \
                                --no-progress \
                                --scanners vuln \
                                --timeout 10m \
                                --severity CRITICAL \
                                --ignore-unfixed \
                                --exit-code "$TRIVY_EXIT_CODE" \
                                "$PROJECT-$c:$IMAGE_TAG" || rc=1
                        done
                        exit $rc
                    '''
                }
            }
        }


        // ====================================================================
        // PUSH TO ECR  (main only)
        // ====================================================================
        stage('Push to ECR') {
            when {
                expression { isMain() }
            }

            steps {
                script {
                    withAws {
                        env.ECR_REGISTRY = sh(
                            returnStdout: true,
                            script: '''echo "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"'''
                        ).trim()

                        // Single-quoted on purpose: the shell, not Groovy, expands $c and the other variables.
                        sh '''
                            aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_REGISTRY"

                            for c in backend frontend; do
                                docker tag  "$PROJECT-$c:$IMAGE_TAG" "$ECR_REGISTRY/$PROJECT-$c:$IMAGE_TAG"
                                docker push "$ECR_REGISTRY/$PROJECT-$c:$IMAGE_TAG"
                            done
                        '''
                    }
                }
            }
        }


        // ====================================================================
        // APPROVE PRODUCTION RELEASE
        // ====================================================================
        stage('Approve Production Release') {
            when {
                allOf {
                    expression { isMain() }
                    expression { params.DEPLOY_STRATEGY != 'none' }
                    expression { params.REQUIRE_APPROVAL }
                }
            }

            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input(
                        message: "Release ${env.IMAGE_TAG} to production using ${params.DEPLOY_STRATEGY}?",
                        ok: 'Deploy'
                    )
                }
            }
        }


        // ====================================================================
        // DEPLOY TO AWS
        // Scripts are run with `bash` so they do not depend on the executable
        // bit (lost when a repo is zipped or committed from Windows).
        // ====================================================================
        stage('Deploy to AWS') {
            when {
                allOf {
                    expression { isMain() }
                    expression { params.DEPLOY_STRATEGY != 'none' }
                }
            }

            steps {
                script {
                    withAws {
                        withEnv([
                            "ECR_REGISTRY=${env.ECR_REGISTRY}",
                            "CANARY_STEPS=${params.CANARY_STEPS}",
                            "BAKE_SECONDS=${params.BAKE_SECONDS}"
                        ]) {
                            sh "bash scripts/deploy-${params.DEPLOY_STRATEGY}.sh '${env.IMAGE_TAG}'"
                        }
                    }
                }
            }

            post {
                always {
                    archiveArtifacts(artifacts: 'deploy-state.env', allowEmptyArchive: true)
                }
            }
        }


        // ====================================================================
        // VERIFY PRODUCTION
        // ====================================================================
        stage('Verify Production') {
            when {
                allOf {
                    expression { isMain() }
                    expression { params.DEPLOY_STRATEGY != 'none' }
                }
            }

            steps {
                script {
                    withAws {
                        sh 'bash scripts/verify-production.sh "$IMAGE_TAG"'
                    }
                }
            }
        }


        // ====================================================================
        // RETIRE PREVIOUS VERSION
        // ====================================================================
        stage('Retire Previous Version') {
            when {
                allOf {
                    expression { isMain() }
                    expression { params.DEPLOY_STRATEGY != 'none' }
                    expression { params.REQUIRE_APPROVAL }
                }
            }

            steps {
                script {
                    def proceed = true

                    try {
                        timeout(time: 60, unit: 'MINUTES') {
                            input(
                                message: 'Release looks healthy? Scale the previous version down (rollback will still be possible).',
                                ok: 'Scale down'
                            )
                        }
                    }
                    catch (err) {
                        proceed = false
                        echo 'Not confirmed - previous version left running. Run scripts/finalize.sh later.'
                    }

                    if (proceed) {
                        withAws {
                            sh 'bash scripts/finalize.sh'
                        }
                    }
                }
            }
        }
    }


    // ========================================================================
    // POST ACTIONS
    // ========================================================================
    post {
        always {
            archiveArtifacts(
                artifacts: 'backend/coverage/**,frontend/coverage/**',
                allowEmptyArchive: true
            )

            sh 'docker image prune -f || true'

            cleanWs(deleteDirs: true, notFailBuild: true)
        }

        success {
            echo "Pipeline succeeded: ${env.IMAGE_TAG}"
        }

        failure {
            echo '''Pipeline failed.
If the failure happened during deployment, the deployment scripts have already
restored traffic to the previous version.'''

            // emailext to: 'team@example.com',
            //     subject: "FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
            //     body: "${env.BUILD_URL}"
        }
    }
}