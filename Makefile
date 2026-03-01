PREFIX ?= /usr/local
INSTALL_TARGET = $(PREFIX)/bin/fp

install:
	zig build -Doptimize=ReleaseFast
	cp zig-out/bin/fp $(INSTALL_TARGET)
	install -m 644 fp.1 /usr/share/man/man1/fp.1

install-completion:
	install -m 644 completions.fish $(HOME)/.config/fish/completions/fp.fish

.PHONY: install install-completion
