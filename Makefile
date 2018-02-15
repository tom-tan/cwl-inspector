
all: lint

lint:
	flake8 cwl_inspector.py
	pydocstyle cwl_inspector.py

test:
	python -Wi -m unittest discover tests
