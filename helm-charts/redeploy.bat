helm uninstall affixzone-test-containers --namespace affixzone-test-containers
helm package test-containers
helm install affixzone-test-containers affixzone-test-containers-0.1.0.tgz --create-namespace --namespace affixzone-test-containers