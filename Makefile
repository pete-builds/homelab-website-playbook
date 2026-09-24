# make test: everything CI runs. Docker is needed for the last two.
.PHONY: test lint unit linux e2e
test: lint unit linux e2e
lint:
	shellcheck -S warning scripts/*.sh scripts/*/*.sh templates/updates/homelab-* tests/*.sh tests/linux/*.sh
unit:
	python3 tests/validate-skills.py
	python3 tests/check-themes.py
	python3 tests/test_cloudflare.py
linux:
	./tests/run-linux-checks.sh
e2e:
	./tests/test-site-e2e.sh
