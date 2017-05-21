#!/bin/sh

PROXY_SERVICE=$PROXY_SERVICE_ENV_VAR

echo "Redeploying proxy service [${PROXY_SERVICE}]..."
# proxy=`docker service ps --status Running | grep "^${PROXY_SERVICE}" | awk '{print $2}'`
# docker service redeploy $proxy
docker service update ${PROXY_SERVICE} --force
echo "Redeployed proxy service [${PROXY_SERVICE}]"
