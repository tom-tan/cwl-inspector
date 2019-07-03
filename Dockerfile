FROM alpine:3.8

LABEL maintainer="Tomoya Tanjo <ttanjo@gmail.com>"

RUN apk --no-cache add ruby ruby-json ruby-etc nodejs

COPY cwl /usr/bin/cwl

ENTRYPOINT ["/usr/bin/cwl/inspector.rb"]
