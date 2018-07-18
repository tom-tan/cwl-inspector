FROM alpine:3.8

LABEL maintainer="Tomoya Tanjo <ttanjo@gmail.com>"

RUN apk --no-cache add ruby ruby-json nodejs && \
    gem install --no-ri --no-rdoc parslet

COPY cwl /usr/bin/cwl

ENTRYPOINT ["/usr/bin/cwl/inspector.rb"]
