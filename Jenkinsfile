pipeline {
    agent any
    options {
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }
    parameters {
        choice(name: 'ACTION', choices: ['PREFLIGHT', 'CREATE_AMI', 'CREATE_LT_VERSION', 'UPDATE_ASG', 'START_REFRESH', 'VERIFY_REFRESH'], description: 'Run one operation at a time')
        booleanParam(name: 'APPLY', defaultValue: false, description: 'Execute a mutating operation; false means dry-run')
    }
    environment { AWS_DEFAULT_REGION = 'ap-south-1' }
    stages {
        stage('Checkout') { steps { checkout scm } }
        stage('Preflight') {
            steps {
                sh """
                    set -e
                    test -f config/poc.env || { echo 'Create config/poc.env from config/poc.env.example'; exit 1; }
                    chmod +x scripts/*.sh
                    ./scripts/01-preflight.sh
                """
            }
        }
        stage('Selected operation') {
            steps {
                sh """
                    set -e
                    export APPLY='${params.APPLY}'
                    case '${params.ACTION}' in
                      PREFLIGHT) ./scripts/01-preflight.sh ;;
                      CREATE_AMI) ./scripts/02-create-ami.sh ;;
                      CREATE_LT_VERSION) ./scripts/03-create-lt-version.sh ;;
                      UPDATE_ASG) ./scripts/04-update-asg.sh ;;
                      START_REFRESH) ./scripts/05-start-instance-refresh.sh ;;
                      VERIFY_REFRESH) ./scripts/06-verify-refresh.sh ;;
                      *) echo 'Unsupported action'; exit 2 ;;
                    esac
                """
            }
        }
    }
    post {
        always { archiveArtifacts artifacts: 'artifacts/**', allowEmptyArchive: true }
    }
}
