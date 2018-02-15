FROM alpine:3.6 AS builder

RUN apk --no-cache add python3 git && \
    pip3 install schema_salad && \
    git clone https://github.com/common-workflow-language/common-workflow-language.git && \
    schema-salad-tool --codegen python common-workflow-language/v1.0/CommonWorkflowLanguage.yml > cwl_parser.py

FROM alpine:3.6

LABEL maintainer="Tomoya Tanjo <ttanjo@gmail.com>"

COPY cwl_inspector.py /cwl-inspector
COPY --from=builder cwl_parser.py /cwl_parser.py
COPY requirements.txt /

RUN apk --no-cache add python3 && \
    pip3 install -r requirements.txt && \
    rm requirements.txt

ENTRYPOINT ["python3", "cwl-inspector"]
