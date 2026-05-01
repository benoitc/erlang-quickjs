REBAR ?= $(shell which rebar3 2>/dev/null)

.PHONY: all compile test clean distclean submodules

all: submodules compile

submodules:
	@if [ -d .git ] && [ -f .gitmodules ]; then \
		git submodule update --init --recursive; \
	fi

compile: submodules
	@${REBAR} compile

test: compile
	@${REBAR} eunit

clean:
	@${REBAR} clean

distclean: clean
	@rm -rf _build
	@rm -f priv/*.so priv/*.dylib priv/*.dll
