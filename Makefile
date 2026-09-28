# make test: everything CI runs. Docker is needed for linux, e2e and deploy.
.PHONY: test lint unit linux e2e deploy
test: lint unit linux e2e deploy
lint:
	shellcheck -S warning playbook scripts/*.sh scripts/*/*.sh templates/updates/homelab-* templates/watch/homelab-* tests/*.sh tests/linux/*.sh
unit:
	./tests/test-lib.sh
	python3 tests/validate-skills.py
	python3 tests/check-themes.py
	python3 tests/check-settings.py
	python3 tests/test_cloudflare.py
	python3 tests/test_verify_site.py
	python3 tests/test_diagnose.py
	python3 tests/test_status.py
	node --test tests/test-check-dist.mjs
linux:
	./tests/run-linux-checks.sh
e2e:
	./tests/test-site-e2e.sh
deploy:
	./tests/test-deploy.sh
