PREFIX ?= /usr
DESTDIR ?=

install:
	install -d $(DESTDIR)/etc/thepid1/runlevels
	install -d $(DESTDIR)/etc/thepid1/scripts
	install -d $(DESTDIR)/sbin
	install -d $(DESTDIR)$(PREFIX)/bin

	install -m 755 thepid1/pid1.lua $(DESTDIR)/etc/thepid1/pid1.lua
	install -m 644 thepid1/runlevels/*.lua $(DESTDIR)/etc/thepid1/runlevels/
	install -m 755 pid1 $(DESTDIR)$(PREFIX)/bin/pid1

	ln -sf /etc/thepid1/pid1.lua $(DESTDIR)/sbin/thepid1
