PREFIX ?= /usr/local
INSTALL_TARGET = $(PREFIX)/bin/fp

build:
	zig build -Doptimize=ReleaseFast

install: build
	cp zig-out/bin/fp $(DESTDIR)$(INSTALL_TARGET)
	install -m 644 fp.1 $(DESTDIR)$(PREFIX)/share/man/man1/fp.1

clean:
	rm -r zig-out

install-completion:
	install -m 644 completions.fish $(HOME)/.config/fish/completions/fp.fish

.PHONY: install install-completion
