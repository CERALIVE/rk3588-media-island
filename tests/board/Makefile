# Phase-0 board probes — cross-build for the device target suite.
#
# The device is aarch64 Debian 13 (trixie). The probes are built with the
# target-suite cross toolchain so the binary that runs on the bench board is
# the binary CI produced, not something compiled on whatever host happened to
# copy it over. -Werror is not decoration: every UAPI struct in uapi/ carries
# _Static_assert layout checks, and a warning-as-error build is what makes a
# drifted header a red build instead of a malformed ioctl.
#
# Usage:
#   make                 # cross-build every probe for aarch64
#   make CROSS_COMPILE=  # host build (what --self-test runs against locally)
#   make selftest        # host-build and run every probe's --self-test
#   make clean
#
# CI (todo 7) runs exactly:
#   make CROSS_COMPILE=aarch64-linux-gnu- clean all

CROSS_COMPILE ?= aarch64-linux-gnu-
CC            := $(CROSS_COMPILE)gcc
CFLAGS        := -std=c11 -Wall -Wextra -Werror -O2 -I.
OUT           ?= build

PROBES := probe-mpp-uapi probe-rga-uapi librga-compat-probe

# librga-compat-probe resolves librga at run time, so it needs the dynamic
# loader and nothing else. The other two speak ioctls only.
LDLIBS_librga-compat-probe := -ldl

.PHONY: all clean selftest hostbuild

all: $(addprefix $(OUT)/,$(PROBES))

$(OUT):
	mkdir -p $(OUT)

$(OUT)/%: %.c | $(OUT)
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS_$*)

# hostbuild — the same sources through the host compiler, which is what the
# --self-test legs execute on a dev host with no board attached.
hostbuild:
	$(MAKE) CROSS_COMPILE= OUT=build-host all

selftest: hostbuild
	@rc=0; \
	for p in $(PROBES); do \
	  printf '=== %s --self-test ===\n' "$$p"; \
	  ./build-host/$$p --self-test || rc=1; \
	done; \
	exit $$rc

clean:
	rm -rf $(OUT) build-host
