#!/bin/bash

USAGE="usage: ./update-service.sh <taskDefinitionJsonTemplate> <imageVersion> <environment> <serviceName>"
if [ "$#" -lt 4 ] ; then
  echo "${USAGE}"
  exit 1
fi

TASK_DEFINITION_FILE=$1
IMAGE_VERSION=$2
ENVIRONMENT=$3
SERVICE_NAME=$4

# Retrieve 'Task Family', 'Cluster' and 'Service Id' of the service to update
TASK_FAMILY=$(cat "${TASK_DEFINITION_FILE}" | jq '.family' | cut -d'"' -f2  )
CLUSTER=$(aws ecs list-clusters | jq '.clusterArns[]' | grep "${ENVIRONMENT}" | cut -d'"' -f2 )
SERVICE_ID=$(aws ecs list-services --cluster "${CLUSTER}" | jq '.serviceArns[]' | grep "${SERVICE_NAME}" | cut -d'"' -f2 )

# Create a new task definition for this build
sed -e "s;%IMAGE_VERSION%;${IMAGE_VERSION};g" "${TASK_DEFINITION_FILE}" > ${TASK_DEFINITION_FILE}.new
aws ecs register-task-definition --cli-input-json file://${TASK_DEFINITION_FILE}.new
STATUS=$?

if [ "${STATUS}" -ne 0 ]; then
    echo "ERROR: Registering the task definition ${TASK_FAMILY} failed."
    exit "${STATUS}"
fi

# Retrieve the actual revision and desired count of the task
TASK_REVISION=$(aws ecs describe-task-definition --task-definition "${TASK_FAMILY}" | jq '.taskDefinition.revision' )
DESIRED_COUNT=$(aws ecs describe-services --services "${SERVICE_ID}" --cluster "${CLUSTER}" | jq '.services[0].desiredCount' )

if [ "${DESIRED_COUNT}" = "0" ]; then
    DESIRED_COUNT="1"
fi

echo -e "Family: ${TASK_FAMILY}"
echo -e "Cluster: ${CLUSTER}"
echo -e "Service: ${SERVICE_ID}"
echo -e "Revision: ${TASK_REVISION}"
echo -e "Count: ${DESIRED_COUNT} "


# Update the service with the new task definition and desired count
aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE_ID}" --task-definition "${TASK_FAMILY}:${TASK_REVISION}" --desired-count "${DESIRED_COUNT}"
STATUS=$?

if [ "${STATUS}" -ne 0 ]; then
    echo "ERROR: Updating the Service ${SERVICE_ID} failed."
    exit "${STATUS}"
fi