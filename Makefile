
all: lint test

lint:
	flake8 cwl_inspector.py
	pydocstyle cwl_inspector.py

test:
	python -Wi -m unittest discover tests

build:
	docker build -t cwl-inspector:latest .

deploy: build
	docker login -u $(DOCKER_USER) -p $(DOCKER_PASS)
	docker rename cwl-inspector $(DOCKER_USER)/cwl-inspector
	docker push $(DOCKER_USER)/cwl-inspector
