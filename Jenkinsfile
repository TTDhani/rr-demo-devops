
pipeline {
    agent any

    parameters {
        string(name: 'APP_BUILD_NUMBER', defaultValue: '')
        string(name: 'APP_GIT_COMMIT', defaultValue: '')
    }

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

                script {
                    if (!(params.APP_BUILD_NUMBER ==~ /^[0-9]+$/)) {
                        error('Invalid application build number.')
                    }

                    if (!(params.APP_GIT_COMMIT ==~ /^[a-fA-F0-9]{40}$/)) {
                        error('Invalid application Git commit.')
                    }
                }

                sh '''
                    set -eu
                    command -v aws >/dev/null
                    command -v jq >/dev/null
                    bash -n scripts/common.sh
                    bash -n scripts/deploy.sh
                    bash -n scripts/rollback.sh
                    chmod +x scripts/*.sh
                '''
            }
        }

        stage('Preflight') {
            steps {
                withCredentials([
                    file(credentialsId: 'rr-demo-poc-env', variable: 'POC_ENV_FILE')
                ]) {
                    withEnv([
                        "APP_BUILD_NUMBER=${params.APP_BUILD_NUMBER}",
                        "APP_GIT_COMMIT=${params.APP_GIT_COMMIT}"
                    ]) {
                        sh '''
                            set -eu

                            export CONFIG_FILE="$WORKSPACE/poc.runtime.env"
                            cp "$POC_ENV_FILE" "$CONFIG_FILE"
                            chmod 600 "$CONFIG_FILE"

                            sed -i 's/^APPLY=.*/APPLY="false"/' "$CONFIG_FILE"

                            bash scripts/deploy.sh
                        '''
                    }
                }
            }
        }

        stage('Approve Infrastructure') {
            steps {
                timeout(time: 15, unit: 'MINUTES') {
                    input(
                        message: "Apply infrastructure changes for rr-demo build #${params.APP_BUILD_NUMBER}?",
                        ok: 'Approve',
                        submitter: 'admin'
                    )
                }
            }
        }

        stage('Deploy Infrastructure') {
            steps {
                withEnv([
                    "APP_BUILD_NUMBER=${params.APP_BUILD_NUMBER}",
                    "APP_GIT_COMMIT=${params.APP_GIT_COMMIT}"
                ]) {
                    sh '''
                        set -eu

                        export CONFIG_FILE="$WORKSPACE/poc.runtime.env"
                        test -f "$CONFIG_FILE"
                        chmod 600 "$CONFIG_FILE"

                        sed -i 's/^APPLY=.*/APPLY="true"/' "$CONFIG_FILE"

                        bash scripts/deploy.sh
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Infrastructure rollout successful for rr-demo build #${params.APP_BUILD_NUMBER}."
        }
        failure {
            echo 'Infrastructure rollout failed. Check AWS refresh status before retrying.'
        }
        aborted {
            echo 'Infrastructure rollout aborted.'
        }
        always {
            archiveArtifacts(
                artifacts: 'artifacts/**',
                allowEmptyArchive: true
            )
            cleanWs(deleteDirs: true, notFailBuild: true)
        }
    }
}
