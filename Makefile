VERSION := 0.2.0
.PHONY: check test integration compose-test reliability-test stress-test openwrt-smoke dist
check:
	sh -n tests/config-ini.sh tests/netcat-baseline.sh tests/control-config.sh
	sh -n tests/control-timeout.sh
	docker run --rm -v "$(CURDIR):/work:ro" koalaman/shellcheck:stable -s sh /work/tests/control-timeout.sh
	sh -n tests/compose/run.sh tests/compose/device-entrypoint.sh tests/compose/installer-adapters.sh
	sh tests/config-ini.sh
	docker run --rm -v "$(CURDIR):/work:ro" koalaman/shellcheck:stable -s sh /work/tests/compose/run.sh /work/tests/compose/device-entrypoint.sh /work/tests/compose/installer-adapters.sh
	sh -n wtctl scripts/install.sh tests/run.sh tests/test.sh tests/startup.sh tests/openwrt-smoke.sh tests/build-device-probe.sh tests/shutdown-race.sh
	docker run --rm -v "$(CURDIR):/work:ro" koalaman/shellcheck:stable -s sh /work/wtctl /work/scripts/install.sh /work/tests/run.sh /work/tests/test.sh /work/tests/startup.sh /work/tests/openwrt-smoke.sh /work/tests/build-device-probe.sh /work/tests/shutdown-race.sh /work/tests/config-ini.sh /work/tests/netcat-baseline.sh /work/tests/control-config.sh
	PYTHONDONTWRITEBYTECODE=1 python3 tests/device-reboot-helper-test.py
	PYTHONDONTWRITEBYTECODE=1 python3 tests/device-onsite-helper-test.py
	python3 -c 'import ast,pathlib; [ast.parse(p.read_text(), filename=str(p)) for p in pathlib.Path("tests").glob("*.py")]'
	python3 -c 'import ast,pathlib; [ast.parse(p.read_text(), filename=str(p)) for p in pathlib.Path("tests/compose").glob("*.py")]'

test:
	./tests/run.sh

integration:
	./tests/run.sh --integration

compose-test:
	sh tests/compose/run.sh

reliability-test:
	WTCTL_ACCEPTANCE_MODE=reliability sh tests/compose/run.sh

stress-test:
	WTCTL_STRESS=1 WTCTL_ACCEPTANCE_MODE=reliability sh tests/compose/run.sh

openwrt-smoke:
	./tests/openwrt-smoke.sh

dist: check
	mkdir -p dist/wtctl-$(VERSION)
	cp wtctl README.md Makefile dist/wtctl-$(VERSION)/
	cp -R scripts docs tests dist/wtctl-$(VERSION)/
	COPYFILE_DISABLE=1 tar -czf dist/wtctl-$(VERSION).tar.gz -C dist wtctl-$(VERSION)
	rm -rf dist/wtctl-$(VERSION)
