
pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 120, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    parameters {
        choice(
            name: 'ACTION',
            choices: [
                'PREFLIGHT',
                'CREATE_AMI',
                'CREATE_LT_VERSION',
                'UPDATE_ASG',
                'START_REFRESH',
                'VERIFY_REFRESH',
                'FULL_ROLLOUT'
            ],
            description: 'Select an infrastructure operation.'
        )

        booleanParam(
            name: 'APPLY',
            defaultValue: false,
            description: 'Enable AWS changes. Keep unchecked for dry-run.'
        )
    }

    environment {
        AWS_DEFAULT_REGION = 'ap-south-1'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Validate Tools') {
            steps {
                sh '''
                    set -eu

                    echo "===================================="
                    echo "VALIDATING REQUIRED TOOLS"
                    echo "===================================="

                    command -v aws
                    command -v jq
                    command -v bash

                    echo "AWS CLI version:"
                    aws --version

                    echo "JQ version:"
                    jq --version

                    echo "Git revision:"
                    git rev-parse --short HEAD

                    chmod +x scripts/*.sh
                '''
            }
        }

        stage('Approve Full Infrastructure Rollout') {
            when {
                expression {
                    params.ACTION == 'FULL_ROLLOUT' && params.APPLY
                }
            }

            steps {
                timeout(time: 15, unit: 'MINUTES') {
                    input(
                        message: 'Application deployment succeeded. Approve AMI creation from Demand-a2, Launch Template update and ASG Instance Refresh?',
                        ok: 'Approve Infrastructure Rollout'
                    )
                }
            }
        }

        stage('Infrastructure Operation') {
            steps {
                withCredentials([
                    file(
                        credentialsId: 'rr-demo-poc-env',
                        variable: 'POC_ENV_FILE'
                    )
                ]) {

                    withEnv([
                        "ACTION=${params.ACTION}",
                        "APPLY=${params.APPLY}"
                    ]) {

                        sh '''
                            set -eu

                            echo "===================================="
                            echo "RR-DEMO INFRASTRUCTURE AUTOMATION"
                            echo "===================================="

                            export CONFIG_FILE="$POC_ENV_FILE"

                            echo "Selected Action: ${ACTION}"
                            echo "Apply Enabled: ${APPLY}"
                            echo "AWS Region: ${AWS_DEFAULT_REGION}"

                            if [ ! -f "$CONFIG_FILE" ]; then
                                echo "ERROR: POC environment configuration not found."
                                exit 1
                            fi

                            echo "POC configuration file found."

                            echo "===================================="
                            echo "RUNNING AWS PREFLIGHT"
                            echo "===================================="

                            ./scripts/01-preflight.sh

                            if [ "${ACTION}" = "PREFLIGHT" ]; then
                                echo "Preflight completed successfully."
                                echo "No infrastructure changes requested."
                                exit 0
                            fi

                            echo "===================================="
                            echo "EXECUTING SELECTED OPERATION"
                            echo "===================================="

                            case "${ACTION}" in

                                CREATE_AMI)
                                    echo "Starting AMI creation..."
                                    ./scripts/02-create-ami.sh
                                    ;;

                                CREATE_LT_VERSION)
                                    echo "Creating Launch Template version..."
                                    ./scripts/03-create-lt-version.sh
                                    ;;

                                UPDATE_ASG)
                                    echo "Updating Auto Scaling Group..."
                                    ./scripts/04-update-asg.sh
                                    ;;

                                START_REFRESH)
                                    echo "Starting Instance Refresh..."
                                    ./scripts/05-start-instance-refresh.sh
                                    ;;

                                VERIFY_REFRESH)
                                    echo "Verifying Instance Refresh..."
                                    ./scripts/06-verify-refresh.sh
                                    ;;

                                FULL_ROLLOUT)
                                    if [ "${APPLY}" != "true" ]; then
                                        echo "ERROR: FULL_ROLLOUT requires APPLY=true."
                                        exit 1
                                    fi

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
                                    ;;

                                *)
                                    echo "ERROR: Unsupported action: ${ACTION}"
                                    exit 2
                                    ;;

                            esac

                            echo "Infrastructure operation completed."
                        '''
                    }
                }
            }
        }
    }

    post {

        success {
            echo 'Infrastructure pipeline completed successfully.'
        }

        failure {
            echo 'Infrastructure pipeline failed. Review console output before retrying.'
        }

        always {

            archiveArtifacts(
                artifacts: 'artifacts/**',
                allowEmptyArchive: true
            )

            echo 'Cleaning infrastructure workspace...'

            cleanWs(
                deleteDirs: true,
                disableDeferredWipeout: true,
                notFailBuild: true
            )

            echo 'Infrastructure pipeline execution finished.'
        }
    }
}
