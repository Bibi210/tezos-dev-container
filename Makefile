DESTDIR ?=
SYSTEMCTL ?= systemctl

.PHONY: install uninstall
install:
	install -Dm755 scripts/tezos-dev-images "$(DESTDIR)/usr/local/sbin/tezos-dev-images"
	install -d "$(DESTDIR)/etc/systemd/system"
	install -m644 systemd/tezos-dev-*.service systemd/tezos-dev-*.timer "$(DESTDIR)/etc/systemd/system/"
	@if [ -z "$(DESTDIR)" ]; then \
		$(SYSTEMCTL) daemon-reload && \
		$(SYSTEMCTL) enable --now tezos-dev-pull.timer tezos-dev-clean.timer; \
	fi

uninstall:
	@if [ -z "$(DESTDIR)" ]; then \
		$(SYSTEMCTL) disable --now tezos-dev-pull.timer tezos-dev-clean.timer && \
		$(SYSTEMCTL) stop tezos-dev-pull.service tezos-dev-clean.service; \
	fi
	rm -f "$(DESTDIR)/usr/local/sbin/tezos-dev-images"
	rm -f "$(DESTDIR)/etc/systemd/system/tezos-dev-pull.service" \
		"$(DESTDIR)/etc/systemd/system/tezos-dev-pull.timer" \
		"$(DESTDIR)/etc/systemd/system/tezos-dev-clean.service" \
		"$(DESTDIR)/etc/systemd/system/tezos-dev-clean.timer"
	@if [ -z "$(DESTDIR)" ]; then $(SYSTEMCTL) daemon-reload; fi
