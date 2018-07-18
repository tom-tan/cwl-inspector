#!/bin/sh

echo $DOCKER_PASS | docker login -u $DOCKER_USER --password-stdin
docker build -t $DOCKER_USER/cwl-inspector:latest .
docker push $DOCKER_USER/cwl-inspector:latest
