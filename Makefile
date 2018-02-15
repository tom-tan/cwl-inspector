
all: lint

lint:
	flake8 cwl_inspector.py
	pydocstyle cwl_inspector.py
