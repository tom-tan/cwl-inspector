FROM ruby:alpine

LABEL maintainer="Tomoya Tanjo <ttanjo@gmail.com>"

COPY cwl-inspector.rb /usr/bin/cwl-inspector

ENTRYPOINT ["cwl-inspector"]
