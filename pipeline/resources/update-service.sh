#!/bin/bash

USAGE="usage: ./update-service.sh <imageTag> <environment> <serviceName> <serviceRepositoryName>"
if [ "$#" -lt 4 ] ; then
  echo "${USAGE}"
  exit 1
fi

IMAGE_TAG=$1
ENVIRONMENT=$2
SERVICE_NAME=$3
SERVICE_REPOSITORY_NAME=$4
TAG_ESCAPED=$(echo "${IMAGE_TAG}" | sed -e 's/\\/\\\\/g' -e 's/\//\\\//g' -e 's/&/\\\&/g')
TIMEOUT=120

# Retrieve 'Task Id', 'Task Definition, 'Task Family', 'Cluster' and 'Service Id' of the service to update
TASK_ARN=$(aws ecs list-task-definitions --status ACTIVE --sort DESC | jq '.taskDefinitionArns[]' \
        | grep "${ENVIRONMENT}" | grep "${SERVICE_NAME}" | awk 'NR==1{print $1}' | cut -d'"' -f2)
TASK_DEF=$(aws ecs describe-task-definition --task-definition "${TASK_ARN}")
TASK_FAMILY=$(echo "${TASK_DEF}" | jq '.taskDefinition.family' | cut -d'"' -f2)
NEW_TASK_DEF=$(echo "${TASK_DEF}" \
        | sed -e "s|${SERVICE_REPOSITORY_NAME}:.*\"|${SERVICE_REPOSITORY_NAME}:${TAG_ESCAPED}\"|g" \
        | jq '.taskDefinition|{family: .family, volumes: .volumes, containerDefinitions: .containerDefinitions}' )

CLUSTER_ARN=$(aws ecs list-clusters | jq '.clusterArns[]' | grep "${ENVIRONMENT}" | cut -d'"' -f2 )
SERVICE_ARN=$(aws ecs list-services --cluster "${CLUSTER_ARN}" | jq '.serviceArns[]' | grep "${SERVICE_NAME}" | cut -d'"' -f2 )

# Register the new task definition for this build, and store its ARN
NEW_TASKDEF_ARN=$(aws ecs register-task-definition --cli-input-json "${NEW_TASK_DEF}" | jq .taskDefinition.taskDefinitionArn | tr -d '"')
STATUS=$?

if [ "${STATUS}" -ne 0 ]; then
    echo "ERROR: Registering the task definition ${TASK_FAMILY} failed."
    exit "${STATUS}"
fi

# Retrieve the actual revision and desired count of the task
TASK_REVISION=$(aws ecs describe-task-definition --task-definition "${TASK_FAMILY}" | jq '.taskDefinition.revision' )
DESIRED_COUNT=$(aws ecs describe-services --services "${SERVICE_ARN}" --cluster "${CLUSTER_ARN}" | jq '.services[0].desiredCount' )

if [ "${DESIRED_COUNT}" = "0" ]; then
    DESIRED_COUNT="1"
fi

echo -e "--------------------------------------"
echo -e "Family: ${TASK_FAMILY}"
echo -e "TaskArn (old): ${TASK_ARN}"
echo -e "TaskArn (new): ${NEW_TASKDEF_ARN}"
echo -e "ClusterArn: ${CLUSTER_ARN}"
echo -e "ServiceArn: ${SERVICE_ARN}"
echo -e "Revision: ${TASK_REVISION}"
echo -e "Count: ${DESIRED_COUNT} "
echo -e "--------------------------------------"

# Update the service with the new task definition and desired count
aws ecs update-service --cluster "${CLUSTER_ARN}" --service "${SERVICE_ARN}" --task-definition "${TASK_FAMILY}:${TASK_REVISION}" --desired-count "${DESIRED_COUNT}"
STATUS=$?

if [ "${STATUS}" -ne 0 ]; then
    echo "ERROR: Updating the Service ${SERVICE_ARN} failed."
    exit "${STATUS}"
fi

# See if the service is able to come up again
every=10
i=0
while [ $i -lt "${TIMEOUT}" ]
do
  # Scan the list of running tasks for that service, and see if one of them is the
  # new version of the task definition

  RUNNING=$(aws ecs list-tasks --cluster "${CLUSTER_ARN}"  --service-name "${SERVICE_ARN}" --desired-status RUNNING \
    | jq '.taskArns[]' \
    | xargs -I{} aws ecs describe-tasks --cluster ${CLUSTER_ARN} --tasks {} \
    | jq ".tasks[]| if .taskDefinitionArn == \"${NEW_TASKDEF_ARN}\" then . else empty end|.lastStatus" \
    | grep -e "RUNNING" )

  if [ "${RUNNING}" ]; then
    echo "Service updated successfully, new task definition running."
    exit 0
  fi

  sleep $every
  i=$(( $i + $every ))
done

# Timeout
echo "ERROR: New task definition not running within $TIMEOUT seconds"
exit 1