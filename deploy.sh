#!/bin/sh

if [ "$TRAVIS_BRANCH" = "master" ]; then
    docker login -u $DOCKER_USER -p $DOCKER_PASS
    docker build -t $DOCKER_USER/cwl-inspector:latest .
    docker push $DOCKER_USER/cwl-inspector:latest
fi
