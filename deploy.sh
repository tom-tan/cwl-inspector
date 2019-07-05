#!/bin/sh

tag=${TRAVIS_TAG:-latest}

echo $DOCKER_PASS | docker login -u $DOCKER_USER --password-stdin
docker build -t $DOCKER_USER/cwl-inspector:$tag .
docker push $DOCKER_USER/cwl-inspector:$tag
