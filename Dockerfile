FROM alpine:3.6

LABEL maintainer="Tomoya Tanjo <ttanjo@gmail.com>"

RUN apk --no-cache add ruby

COPY cwl-inspector.rb /usr/bin/cwl-inspector

ENTRYPOINT ["cwl-inspector"]
