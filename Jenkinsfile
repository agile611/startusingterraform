pipeline {
    agent { label 'vps' }

    environment {
        COURSE    = "${env.JOB_NAME.tokenize('/')[0]}"
        SITES_DIR = "/opt/agile611/stacks/devops/sites"
        BASE_URL  = "https://docs.agile611.com"        // 👈 el teu domini
        BUILD_IMG = "python:3.12-slim"
    }

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 15, unit: 'MINUTES')
    }

    stages {
        stage('Checkout') {
            steps { checkout scm }
        }

        stage('Build MkDocs') {
            steps {
                sh '''
                  docker run --rm \
                    -u "$(id -u):$(id -g)" \
                    -v "$WORKSPACE":/docs -w /docs \
                    -e HOME=/tmp \
                    -e SITE_URL="${BASE_URL}/${COURSE}/" \
                    ${BUILD_IMG} bash -c '
                      set -e
                      pip install --no-cache-dir -q --user -r requirements.txt
                      export PATH=$HOME/.local/bin:$PATH
                      if grep -q "^site_url:" mkdocs.yml; then
                        sed -i "s|^site_url:.*|site_url: ${SITE_URL}|" mkdocs.yml
                      else
                        echo "site_url: ${SITE_URL}" >> mkdocs.yml
                      fi
                      mkdocs build --strict --site-dir site
                    '
                '''
            }
        }

        stage('Deploy') {
            steps {
                sh '''
                  set -e
                  rm -rf "${SITES_DIR}/${COURSE}.new" "${SITES_DIR}/${COURSE}.old"
                  cp -r site "${SITES_DIR}/${COURSE}.new"
                  chmod -R a+rX "${SITES_DIR}/${COURSE}.new"
                  [ -d "${SITES_DIR}/${COURSE}" ] && mv "${SITES_DIR}/${COURSE}" "${SITES_DIR}/${COURSE}.old" || true
                  mv "${SITES_DIR}/${COURSE}.new" "${SITES_DIR}/${COURSE}"
                  rm -rf "${SITES_DIR}/${COURSE}.old"
                '''
            }
        }
    }

    post {
        success { echo "✅ Publicat a ${BASE_URL}/${COURSE}/" }
        failure { echo "❌ Build fallit per ${COURSE}" }
        always  { cleanWs() }
    }
}