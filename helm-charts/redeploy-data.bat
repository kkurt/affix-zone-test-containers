kubectl delete namespace affixzone-test-containers
helm package test-containers-data
helm upgrade affixzone-test-containers-data affixzone-test-containers-data-0.1.0.tgz --install --create-namespace --namespace affixzone-test-containers --wait
