VERSION := 0.1.0
.PHONY: check test integration openwrt-smoke dist
check:
	sh -n wtctl scripts/install.sh tests/run.sh tests/test.sh tests/startup.sh tests/openwrt-smoke.sh tests/build-device-probe.sh tests/shutdown-race.sh
	docker run --rm -v "$(CURDIR):/work:ro" koalaman/shellcheck:stable -s sh /work/wtctl /work/scripts/install.sh /work/tests/run.sh /work/tests/test.sh /work/tests/startup.sh /work/tests/openwrt-smoke.sh /work/tests/build-device-probe.sh /work/tests/shutdown-race.sh
	PYTHONDONTWRITEBYTECODE=1 python3 tests/device-reboot-helper-test.py
	PYTHONDONTWRITEBYTECODE=1 python3 tests/device-onsite-helper-test.py
	python3 -c 'import ast,pathlib; [ast.parse(p.read_text(), filename=str(p)) for p in pathlib.Path("tests").glob("*.py")]'

test:
	./tests/run.sh

integration:
	./tests/run.sh --integration

openwrt-smoke:
	./tests/openwrt-smoke.sh

dist: check
	mkdir -p dist/wtctl-$(VERSION)
	cp wtctl README.md Makefile dist/wtctl-$(VERSION)/
	cp -R scripts docs tests dist/wtctl-$(VERSION)/
	COPYFILE_DISABLE=1 tar -czf dist/wtctl-$(VERSION).tar.gz -C dist wtctl-$(VERSION)
	rm -rf dist/wtctl-$(VERSION)
