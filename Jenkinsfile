
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

        stage('Checkout and Validate') {
            steps {
                checkout scm

                sh '''
                    set -eu

                    echo "Validating required tools..."

                    command -v aws
                    command -v jq
                    command -v bash

                    aws --version
                    jq --version

                    chmod +x scripts/*.sh

                    echo "Git revision:"
                    git rev-parse --short HEAD
                '''
            }
        }

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

                        sed -i 's/^APPLY=.*/APPLY="false"/' "$CONFIG_FILE"

                        ./scripts/01-preflight.sh

                        echo "AWS preflight completed successfully."
                    '''
                }
            }
        }

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

        stage('Execute Full Infrastructure Rollout') {
            steps {
                sh '''
                    set -eu

                    export CONFIG_FILE="$WORKSPACE/poc.runtime.env"

                    if [ ! -f "$CONFIG_FILE" ]; then
                        echo "ERROR: Runtime configuration file not found."
                        exit 1
                    fi

                    sed -i 's/^APPLY=.*/APPLY="true"/' "$CONFIG_FILE"

                    echo "===================================="
                    echo "STEP 1: CREATE AMI"
                    echo "===================================="

                    ./scripts/02-create-ami.sh

                    echo "===================================="
                    echo "STEP 2: CREATE LAUNCH TEMPLATE VERSION"
                    echo "===================================="

                    ./scripts/03-create-lt-version.sh

                    echo "===================================="
                    echo "STEP 3: UPDATE AUTO SCALING GROUP"
                    echo "===================================="

                    ./scripts/04-update-asg.sh

                    echo "===================================="
                    echo "STEP 4: START INSTANCE REFRESH"
                    echo "===================================="

                    ./scripts/05-start-instance-refresh.sh

                    echo "===================================="
                    echo "STEP 5: VERIFY INSTANCE REFRESH"
                    echo "===================================="

                    ./scripts/06-verify-refresh.sh

                    echo "===================================="
                    echo "FULL ROLLOUT COMPLETED"
                    echo "===================================="
                '''
            }
        }
    }

    post {
        success {
            echo 'RR-demo infrastructure rollout completed successfully.'
        }

        failure {
            echo 'Infrastructure rollout failed.'
            echo 'Check ASG and Instance Refresh status before retrying.'
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
