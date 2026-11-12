
pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 90, unit: 'MINUTES')
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
                'VERIFY_REFRESH'
            ],
            description: 'Run one infrastructure operation at a time.'
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

                            # Load Jenkins Secret File configuration.
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

                            # Always run preflight before an operation.
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
