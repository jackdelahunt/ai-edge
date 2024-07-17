#!/usr/bin/env bash
REPO_ROOT_DIR=$(dirname ${BASH_SOURCE[0]})/../../..
PIPELINES_DIR="$REPO_ROOT_DIR/manifests"

source "$REPO_ROOT_DIR"/test/shell-pipeline-tests/common.sh

NAMESPACE="pipeline-test-openvino-bike-rentals"
oc delete project "$NAMESPACE" --ignore-not-found --timeout=60s
oc new-project "$NAMESPACE"

echo "Waiting for OpenShift Pipelines operator to be fully installed"
waitForOpResult 60 "True" "N/A" "oc get tektonconfig -n openshift-operators config -o jsonpath={.status.conditions[?\(@.type==\'Ready\'\)].status}"
waitForOpResult 10 "pipeline" "N/A" "oc get serviceaccount -o=custom-columns=NAME:.metadata.name | grep pipeline"

##### AIEDGE E2E PIPELINE
AIEDGE_E2E_PIPELINE_DIR_PATH="$REPO_ROOT_DIR"/pipelines/tekton/aiedge-e2e

AWS_SECRET_PATH_TEMPLATE="$AIEDGE_E2E_PIPELINE_DIR_PATH"/templates/credentials-s3.secret.yaml.template
AWS_SECRET_PATH="$AIEDGE_E2E_PIPELINE_DIR_PATH"/templates/credentials-s3.secret.yaml

createS3Secret "$AWS_SECRET_PATH_TEMPLATE" "$AWS_SECRET_PATH"

oc create -f "$AWS_SECRET_PATH"

IMAGE_REGISTRY_SECRET_PATH_TEMPLATE="$AIEDGE_E2E_PIPELINE_DIR_PATH"/templates/credentials-image-registry.secret.yaml.template
IMAGE_REGISTRY_SECRET_PATH="$AIEDGE_E2E_PIPELINE_DIR_PATH"/templates/credentials-image-registry.secret.yaml

createImageRegistrySecret "$IMAGE_REGISTRY_SECRET_PATH_TEMPLATE" "$IMAGE_REGISTRY_SECRET_PATH"

oc create -f "$IMAGE_REGISTRY_SECRET_PATH"
oc secret link pipeline credentials-image-registry

## apply test data directory
oc apply -k "$AIEDGE_E2E_PIPELINE_DIR_PATH"/test-data

## oc apply -k pipelines
oc apply -k "$PIPELINES_DIR"/

## prepare parameters
AIEDGE_E2E_PIPELINE_OVERRIDDEN_PATH="$AIEDGE_E2E_PIPELINE_DIR_PATH"/s3-fetch.pipelinerun-overridden.yaml
cp "$AIEDGE_E2E_PIPELINE_DIR_PATH"/s3-fetch.pipelinerun.yaml "$AIEDGE_E2E_PIPELINE_OVERRIDDEN_PATH"
sed -i "s|value: rhoai-edge-models|value: rhoai-edge-models-ci|" "$AIEDGE_E2E_PIPELINE_OVERRIDDEN_PATH"
sed -i "s|value: \"delete\"|value: \"keep\"|" "$AIEDGE_E2E_PIPELINE_OVERRIDDEN_PATH"
usePRBranchInPipelineRunIfPRCheck "$AIEDGE_E2E_PIPELINE_OVERRIDDEN_PATH"

## oc create pipeline run
oc create -f "$AIEDGE_E2E_PIPELINE_OVERRIDDEN_PATH"
sleep 5 # Just to have the startTime field available

PIPELINE_RUN_NAME=$(oc get pipelinerun --sort-by={.status.startTime} -o=custom-columns=NAME:.metadata.name | grep "s3-fetch-.*" | tail -n 1)

if [[ $PIPELINE_RUN_NAME == "" ]]; then
  echo "Could not find any pipeline run"
  exit 1
fi

## wait for the result
waitForOpResult 200 "True" "False" "oc get pipelinerun $PIPELINE_RUN_NAME -o jsonpath={.status.conditions[?\(@.type==\'Succeeded\'\)].status}"
PIPELINE_RUN_RESULT=$?

saveArtifacts "$PIPELINE_RUN_NAME"

if [[ $PIPELINE_RUN_RESULT != 0 ]]; then
  echo "The pipeline failed"
  exit 1
else
  echo "The pipeline finished successfully"
fi
