#!/bin/sh

if [ "$TRAVIS_BRANCH" = "master" -a "$TRAVIS_OS_NAME" = "linux" ]; then
    echo $DOCKER_PASS | docker login -u $DOCKER_USER --password-stdin
    docker build -t $DOCKER_USER/cwl-inspector:latest .
    docker push $DOCKER_USER/cwl-inspector:latest
fi
