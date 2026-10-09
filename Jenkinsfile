// ============================================================================
// MERN CI/CD pipeline - Jenkins declarative pipeline (multibranch)
//
// CI  : install -> lint -> unit tests (+coverage) -> SonarQube + quality gate
//       -> dependency audit -> docker build -> Trivy image scan
//
// CD  : (main branch only) push to ECR -> approval -> blue-green OR canary
//       deploy to ECS Fargate behind an ALB -> verify -> retire old version
//
// Jenkins prerequisites:
//   Tools        : NodeJS "NodeJS-22", SonarQube Scanner "SonarScanner"
//   Sonar server : "sonarqube"
//   Credentials  : "aws-jenkins"
//   On the agent : docker, aws cli v2, jq, curl, trivy
// ============================================================================

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


    // ========================================================================
    // Pipeline options
    // ========================================================================

    options {
        timestamps()

        timeout(
            time: 90,
            unit: 'MINUTES'
        )

        buildDiscarder(
            logRotator(
                numToKeepStr: '20'
            )
        )

        // Prevent two deployments from running at the same time
        disableConcurrentBuilds()
    }


    // ========================================================================
    // Parameters
    // ========================================================================

    parameters {

        choice(
            name: 'DEPLOY_STRATEGY',
            choices: [
                'none',
                'bluegreen',
                'canary'
            ],
            description: 'Select none for CI only (no AWS push or deployment).'
        )


        booleanParam(
            name: 'REQUIRE_APPROVAL',
            defaultValue: true,
            description: 'Ask a human before deploying to production'
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


    // ========================================================================
    // Jenkins tools
    // ========================================================================

    tools {
        nodejs 'NodeJS-22'
    }


    // ========================================================================
    // Environment variables
    // ========================================================================

    environment {

        AWS_REGION = 'ap-south-1'

        PROJECT = 'mern-cicd'

        CI = 'true'

        // Docker network used by your Jenkins Docker Compose setup.
        //
        // Your current network is:
        // mern-cicd-project_default
        //
        // Jenkins container and temporary MongoDB test container
        // will both be connected to this network.
        DOCKER_NETWORK = 'mern-cicd-project_default'
    }


    // ========================================================================
    // Stages
    // ========================================================================

    stages {


        // ====================================================================
        // CHECKOUT & INIT
        // ====================================================================

        stage('Checkout & Init') {

            steps {

                checkout scm

                script {

                    def sha = sh(
                        returnStdout: true,
                        script: 'git rev-parse --short=7 HEAD'
                    ).trim()

                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-${sha}"

                    currentBuild.displayName =
                        "#${env.BUILD_NUMBER} ${sha}"
                }

                sh '''
                    node --version
                    npm --version
                    docker --version
                '''

                echo "Image tag for this build: ${env.IMAGE_TAG}"
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


                // ============================================================
                // BACKEND TESTS
                // ============================================================

                stage('Backend (Jest + MongoDB)') {

                    steps {

                        script {

                            /*
                             * Temporary MongoDB container.
                             *
                             * IMPORTANT:
                             *
                             * Previously MongoDB was started using:
                             *
                             * docker run -d --name mongo-test-X mongo:7
                             *
                             * That puts MongoDB on Docker's default bridge
                             * network.
                             *
                             * Jenkins is running on:
                             *
                             * mern-cicd-project_default
                             *
                             * Therefore Jenkins could not reliably connect
                             * to the MongoDB container.
                             *
                             * Now MongoDB is explicitly connected to the
                             * same Docker network.
                             */

                            def mongo =
                                "mongo-test-${env.BUILD_NUMBER}"


                            // ------------------------------------------------
                            // Remove an old container if one exists
                            // ------------------------------------------------

                            sh """
                                docker rm -f ${mongo} || true
                            """


                            // ------------------------------------------------
                            // Start MongoDB on Jenkins' Docker network
                            // ------------------------------------------------

                            sh """
                                docker run -d \
                                  --name ${mongo} \
                                  --network ${DOCKER_NETWORK} \
                                  mongo:7
                            """


                            try {

                                // --------------------------------------------
                                // Wait for MongoDB to become ready
                                // --------------------------------------------

                                sh """
                                    for i in \$(seq 1 30); do

                                        if docker exec ${mongo} \
                                            mongosh --quiet \
                                            --eval "db.adminCommand('ping')" \
                                            > /dev/null 2>&1
                                        then
                                            echo "MongoDB is ready."
                                            break
                                        fi

                                        echo "Waiting for MongoDB..."
                                        sleep 2

                                    done
                                """


                                // --------------------------------------------
                                // Display MongoDB container information
                                // --------------------------------------------

                                sh """
                                    echo "MongoDB container:"
                                    docker ps --filter "name=${mongo}"

                                    echo ""
                                    echo "MongoDB network:"
                                    docker inspect ${mongo} \
                                      --format '{{json .NetworkSettings.Networks}}'
                                """


                                // --------------------------------------------
                                // Run backend tests
                                //
                                // IMPORTANT:
                                //
                                // We use the Docker container name instead
                                // of the container IP.
                                //
                                // Docker DNS resolves:
                                //
                                // mongo-test-1
                                //
                                // to the MongoDB container.
                                // --------------------------------------------

                                dir('backend') {

                                    withEnv([
                                        "MONGO_TEST_URI=mongodb://${mongo}:27017/ci_test"
                                    ]) {

                                        sh '''
                                            echo "MONGO_TEST_URI=$MONGO_TEST_URI"
                                            npm test
                                        '''
                                    }
                                }

                            }


                            finally {

                                // --------------------------------------------
                                // Always remove temporary MongoDB container
                                // --------------------------------------------

                                sh """
                                    docker rm -f ${mongo} || true
                                """


                                // --------------------------------------------
                                // Publish JUnit results
                                // --------------------------------------------

                                junit(
                                    allowEmptyResults: true,
                                    testResults:
                                        'backend/reports/junit.xml'
                                )
                            }
                        }
                    }
                }


                // ============================================================
                // FRONTEND TESTS
                // ============================================================

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
                                testResults:
                                    'frontend/reports/junit.xml'
                            )
                        }
                    }
                }
            }
        }


        // ====================================================================
        // SONARQUBE ANALYSIS
        // ====================================================================

        stage('SonarQube Analysis') {

            when {

                branch pattern: 'main|develop',
                       comparator: 'REGEXP'
            }

            steps {

                script {

                    /*
                     * Convert coverage paths from:
                     *
                     * src/...
                     *
                     * to:
                     *
                     * backend/src/...
                     *
                     * frontend/src/...
                     */

                    sh """
                        sed -i \
                          's#^SF:src/#SF:backend/src/#' \
                          backend/coverage/lcov.info
                    """

                    sh """
                        sed -i \
                          's#^SF:src/#SF:frontend/src/#' \
                          frontend/coverage/lcov.info
                    """


                    def scannerHome =
                        tool 'SonarScanner'


                    withSonarQubeEnv('sonarqube') {

                        sh """
                            ${scannerHome}/bin/sonar-scanner \
                              -Dsonar.projectVersion=${env.IMAGE_TAG}
                        """
                    }
                }
            }
        }


        // ====================================================================
        // QUALITY GATE
        // ====================================================================

        stage('Quality Gate') {

            when {

                branch pattern: 'main|develop',
                       comparator: 'REGEXP'
            }

            steps {

                timeout(
                    time: 10,
                    unit: 'MINUTES'
                ) {

                    waitForQualityGate(
                        abortPipeline: true
                    )
                }
            }
        }


        // ====================================================================
        // DEPENDENCY AUDIT
        // ====================================================================

        stage('Dependency Audit') {

            steps {

                /*
                 * Vulnerabilities make the build UNSTABLE rather than
                 * immediately FAILED.
                 */

                catchError(
                    buildResult: 'UNSTABLE',
                    stageResult: 'UNSTABLE'
                ) {

                    dir('backend') {

                        sh '''
                            npm audit \
                              --omit=dev \
                              --audit-level=high
                        '''
                    }

                    dir('frontend') {

                        sh '''
                            npm audit \
                              --omit=dev \
                              --audit-level=high
                        '''
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

                        sh """
                            docker build \
                              -t ${env.PROJECT}-backend:${env.IMAGE_TAG} \
                              backend
                        """
                    }
                }


                stage('Frontend image') {

                    steps {

                        sh """
                            docker build \
                              -t ${env.PROJECT}-frontend:${env.IMAGE_TAG} \
                              frontend
                        """
                    }
                }
            }
        }


        // ====================================================================
        // TRIVY IMAGE SCAN
        // ====================================================================

        stage('Trivy Image Scan') {

            steps {

                sh """
                    trivy image \
                      --no-progress \
                      --exit-code 1 \
                      --severity CRITICAL \
                      --ignore-unfixed \
                      ${env.PROJECT}-backend:${env.IMAGE_TAG}
                """

                sh """
                    trivy image \
                      --no-progress \
                      --exit-code 1 \
                      --severity CRITICAL \
                      --ignore-unfixed \
                      ${env.PROJECT}-frontend:${env.IMAGE_TAG}
                """
            }
        }


        // ====================================================================
        // PUSH TO ECR
        // ====================================================================

        stage('Push to ECR') {
            when {
                allOf {
                    branch 'main'
                    expression {
                        params.DEPLOY_STRATEGY != 'none'
                    }
                }
            }


            steps {

                script {

                    withAws {

                        env.ECR_REGISTRY =
                            sh(
                                returnStdout: true,
                                script: '''
                                    echo "$(aws sts get-caller-identity \
                                      --query Account \
                                      --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
                                '''
                            ).trim()


                        sh '''
                            aws ecr get-login-password |
                            docker login \
                              --username AWS \
                              --password-stdin "$ECR_REGISTRY"
                        '''


                        sh """
                            for c in backend frontend; do

                                docker tag \
                                  ${env.PROJECT}-\\\$c:${env.IMAGE_TAG} \
                                  ${env.ECR_REGISTRY}/${env.PROJECT}-\\\$c:${env.IMAGE_TAG}

                                docker push \
                                  ${env.ECR_REGISTRY}/${env.PROJECT}-\\\$c:${env.IMAGE_TAG}

                            done
                        """
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

                    branch 'main'

                    expression {
                        params.DEPLOY_STRATEGY != 'none'
                    }

                    expression {
                        params.REQUIRE_APPROVAL
                    }
                }
            }

            steps {

                timeout(
                    time: 30,
                    unit: 'MINUTES'
                ) {

                    input(
                        message:
                            "Release ${env.IMAGE_TAG} to production using ${params.DEPLOY_STRATEGY}?",
                        ok: 'Deploy'
                    )
                }
            }
        }


        // ====================================================================
        // DEPLOY TO AWS
        // ====================================================================

        stage('Deploy to AWS') {

            when {

                allOf {

                    branch 'main'

                    expression {
                        params.DEPLOY_STRATEGY != 'none'
                    }
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

                            sh """
                                ./scripts/deploy-${params.DEPLOY_STRATEGY}.sh \
                                  ${env.IMAGE_TAG}
                            """
                        }
                    }
                }
            }

            post {

                always {

                    archiveArtifacts(
                        artifacts: 'deploy-state.env',
                        allowEmptyArchive: true
                    )
                }
            }
        }


        // ====================================================================
        // VERIFY PRODUCTION
        // ====================================================================

        stage('Verify Production') {

            when {

                allOf {

                    branch 'main'

                    expression {
                        params.DEPLOY_STRATEGY != 'none'
                    }
                }
            }

            steps {

                script {

                    withAws {

                        sh '''
                            #!/usr/bin/env bash

                            set -e

                            source scripts/lib.sh

                            scripts/smoke-test.sh \
                              "http://$(alb_dns)" \
                              "$IMAGE_TAG"
                        '''
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

                    branch 'main'

                    expression {
                        params.DEPLOY_STRATEGY != 'none'
                    }

                    expression {
                        params.REQUIRE_APPROVAL
                    }
                }
            }

            steps {

                script {

                    def proceed = true


                    try {

                        timeout(
                            time: 60,
                            unit: 'MINUTES'
                        ) {

                            input(
                                message:
                                    'Release looks healthy? Scale the previous version down (rollback will still be possible).',
                                ok: 'Scale down'
                            )
                        }

                    }

                    catch (err) {

                        proceed = false

                        echo '''
                        Not confirmed - previous version left running.
                        Run scripts/finalize.sh later.
                        '''
                    }


                    if (proceed) {

                        withAws {

                            sh './scripts/finalize.sh'
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
                artifacts:
                    'backend/coverage/**,frontend/coverage/**',
                allowEmptyArchive: true
            )


            sh '''
                docker image prune -f || true
            '''


            cleanWs(
                deleteDirs: true,
                notFailBuild: true
            )
        }


        success {

            echo "Pipeline succeeded: ${env.IMAGE_TAG}"
        }


        failure {

            echo '''
            Pipeline failed.

            If the failure happened during deployment,
            the deployment scripts have already restored
            traffic to the previous version.
            '''

            // emailext to:
            //     'team@example.com',
            //     subject:
            //         "FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
            //     body:
            //         "${env.BUILD_URL}"
        }
    }
}