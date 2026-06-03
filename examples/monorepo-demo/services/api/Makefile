.PHONY: lint test install

install:
	pip install -e ".[dev]"

lint:
	ruff check app tests

test:
	pytest -q
