
pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 120, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    environment {
        AWS_DEFAULT_REGION = 'ap-south-1'
    }

    stages {

        // =====================================================
        // STAGE 1: CHECKOUT AND VALIDATE
        // =====================================================
        stage('Checkout and Validate') {
            steps {
                checkout scm

                sh '''
                    set -eu

                    echo "===================================="
                    echo "CHECKOUT AND VALIDATE"
                    echo "===================================="

                    echo "Validating required tools..."

                    command -v aws
                    command -v jq
                    command -v bash

                    aws --version
                    jq --version
                    bash --version

                    echo "Validating infrastructure scripts..."

                    for f in scripts/*.sh; do
                        echo "Checking: $f"
                        bash -n "$f"
                    done

                    echo "All Bash scripts passed syntax validation."

                    chmod +x scripts/*.sh

                    echo "Git revision:"
                    git rev-parse --short HEAD

                    echo "Checkout and validation completed."
                '''
            }
        }

        // =====================================================
        // STAGE 2: AWS PREFLIGHT
        // =====================================================
        stage('AWS Preflight') {
            steps {
                withCredentials([
                    file(
                        credentialsId: 'rr-demo-poc-env',
                        variable: 'POC_ENV_FILE'
                    )
                ]) {
                    sh '''
                        set -eu

                        export CONFIG_FILE="$WORKSPACE/poc.runtime.env"

                        echo "===================================="
                        echo "RR-DEMO AWS PREFLIGHT"
                        echo "===================================="

                        test -f "$POC_ENV_FILE"

                        cp "$POC_ENV_FILE" "$CONFIG_FILE"
                        chmod 600 "$CONFIG_FILE"

                        # Force read-only preflight
                        sed -i 's/^APPLY=.*/APPLY="false"/' "$CONFIG_FILE"

                        echo "Executing preflight using Bash..."

                        bash ./scripts/01-preflight.sh

                        echo "AWS preflight completed successfully."
                    '''
                }
            }
        }

        // =====================================================
        // STAGE 3: MANUAL APPROVAL
        // =====================================================
        stage('Approve Infrastructure Changes') {
            steps {
                timeout(time: 15, unit: 'MINUTES') {
                    input(
                        message: 'Preflight completed. Approve AMI creation, Launch Template update and ASG Instance Refresh?',
                        ok: 'Approve Full Rollout'
                    )
                }
            }
        }

        // =====================================================
        // STAGE 4: FULL INFRASTRUCTURE ROLLOUT
        // =====================================================
        stage('Execute Full Infrastructure Rollout') {
            steps {
                sh '''
                    set -eu

                    export CONFIG_FILE="$WORKSPACE/poc.runtime.env"

                    echo "===================================="
                    echo "RR-DEMO INFRASTRUCTURE ROLLOUT"
                    echo "===================================="

                    if [ ! -f "$CONFIG_FILE" ]; then
                        echo "ERROR: Runtime configuration file not found."
                        exit 1
                    fi

                    chmod 600 "$CONFIG_FILE"

                    # Enable changes only after manual approval
                    sed -i 's/^APPLY=.*/APPLY="true"/' "$CONFIG_FILE"

                    # -------------------------------------------------
                    # STEP 1: CREATE AMI
                    # -------------------------------------------------
                    echo "===================================="
                    echo "STEP 1: CREATE AMI"
                    echo "===================================="

                    bash ./scripts/02-create-ami.sh

                    # -------------------------------------------------
                    # STEP 2: CREATE LAUNCH TEMPLATE VERSION
                    # -------------------------------------------------
                    echo "===================================="
                    echo "STEP 2: CREATE LAUNCH TEMPLATE VERSION"
                    echo "===================================="

                    bash ./scripts/03-create-lt-version.sh

                    # -------------------------------------------------
                    # STEP 3: UPDATE ASG
                    # -------------------------------------------------
                    echo "===================================="
                    echo "STEP 3: UPDATE AUTO SCALING GROUP"
                    echo "===================================="

                    bash ./scripts/04-update-asg.sh

                    # -------------------------------------------------
                    # STEP 4: START INSTANCE REFRESH
                    # -------------------------------------------------
                    echo "===================================="
                    echo "STEP 4: START INSTANCE REFRESH"
                    echo "===================================="

                    bash ./scripts/05-start-instance-refresh.sh

                    # -------------------------------------------------
                    # STEP 5: VERIFY INSTANCE REFRESH
                    # -------------------------------------------------
                    echo "===================================="
                    echo "STEP 5: VERIFY INSTANCE REFRESH"
                    echo "===================================="

                    bash ./scripts/06-verify-refresh.sh

                    echo "===================================="
                    echo "FULL INFRASTRUCTURE ROLLOUT COMPLETED"
                    echo "===================================="
                '''
            }
        }
    }

    // =========================================================
    // POST BUILD ACTIONS
    // =========================================================
    post {

        success {
            echo 'RR-demo infrastructure rollout completed successfully.'
        }

        failure {
            echo 'Infrastructure rollout failed.'
            echo 'Check the failed stage and AWS resource status before retrying.'
        }

        aborted {
            echo 'Infrastructure rollout was aborted.'
        }

        always {
            archiveArtifacts(
                artifacts: 'artifacts/**',
                allowEmptyArchive: true
            )

            cleanWs(
                deleteDirs: true,
                disableDeferredWipeout: true,
                notFailBuild: true
            )

            echo 'Infrastructure pipeline execution finished.'
        }
    }
}
