# Critter compiler-optimization study
#
#   make                 build all variants (PGO targets run a training pass)
#   make o2              build one variant
#   make SENSOR=sim      build against the simulated sensor (no HAT needed)
#   make clean           remove build/  (do this after changing SENSOR or EXTRA)
#
# Optional knobs (keep empty for the baseline study):
#   ARCH="-mcpu=native"                  tune for the exact Pi CPU
#   EXTRA="-DSAMPLES_PER_ROOM=131072"    change the workload size

ifeq ($(origin CC),default)
CC     := gcc
endif
SENSOR ?= sensehat
ARCH   ?=
EXTRA  ?=
BUILD  := build

SRCS   := main.c unit_io.c unit_memory.c unit_compute.c dataset.c util.c parallel.c \
          pmu.c sensor_$(SENSOR).c
HDRS   := $(wildcard src/*.h)
COMMON := -std=gnu11 -Wall -Wextra -pthread $(ARCH) $(EXTRA)
LDLIBS := -lm

VARIANTS := o0 o2 o2_lto o2_pgo o2_pgo_lto o2_threads o2_pgo_xseed o2_pgo_lto_xseed

.PHONY: all clean variant $(VARIANTS)
.NOTPARALLEL:

all: $(VARIANTS)

# ---- single-step variants ------------------------------------------------
o0:
	@$(MAKE) --no-print-directory variant V=$@ VFLAGS="-O0"
o2:
	@$(MAKE) --no-print-directory variant V=$@ VFLAGS="-O2"
o2_lto:
	@$(MAKE) --no-print-directory variant V=$@ VFLAGS="-O2 -flto=auto"
o2_threads:
	@$(MAKE) --no-print-directory variant V=$@ VFLAGS="-O2 -DCRITTER_THREADS"

# ---- profile-guided variants (three steps) -------------------------------
# 1. build with -fprofile-generate (instrumented)
#    (-fprofile-update=single: these builds are single-threaded, and the
#    default with -pthread is slow atomic counter updates)
# 2. run it: writes one .gcda profile per object file into build/<variant>/
#    ($(3) is the dataset seed for the training run; the _xseed variants
#    train on a different deployment than the one the benchmarks measure)
# 3. delete the objects (keep the .gcda) and rebuild with -fprofile-use
#    into the same paths so GCC finds the matching profiles
define pgo_build
	@echo "== $(1): PGO step 1/3 - instrumented build"
	@rm -rf $(BUILD)/$(1) $(BUILD)/critter_$(1) $(BUILD)/critter_$(1)_train
	@$(MAKE) --no-print-directory variant V=$(1) VFLAGS="$(2) -fprofile-generate -fprofile-update=single"
	@mv $(BUILD)/critter_$(1) $(BUILD)/critter_$(1)_train
	@echo "== $(1): PGO step 2/3 - training run (dataset seed $(3))"
	@t0=$$(date +%s.%N); ./$(BUILD)/critter_$(1)_train -q -s $(3) > /dev/null; t1=$$(date +%s.%N); \
	  awk -v a=$$t0 -v b=$$t1 -v v=$(1) 'BEGIN { printf "TRAINTIME,%s,%.3f\n", v, b - a }'
	@echo "== $(1): PGO step 3/3 - optimized rebuild using the profile"
	@rm -f $(BUILD)/$(1)/*.o
	@$(MAKE) --no-print-directory variant V=$(1) VFLAGS="$(2) -fprofile-use -fprofile-correction"
endef

o2_pgo:
	$(call pgo_build,$@,-O2,0)
o2_pgo_lto:
	$(call pgo_build,$@,-O2 -flto=auto,0)
o2_pgo_xseed:
	$(call pgo_build,$@,-O2,7)
o2_pgo_lto_xseed:
	$(call pgo_build,$@,-O2 -flto=auto,7)

# ---- generic rules for one variant (invoked recursively with V and VFLAGS)
ifdef V
OBJDIR := $(BUILD)/$(V)
OBJS   := $(addprefix $(OBJDIR)/,$(SRCS:.c=.o))

variant: $(BUILD)/critter_$(V)

$(BUILD)/critter_$(V): $(OBJS)
	$(CC) $(VFLAGS) $(COMMON) $^ -o $@ $(LDLIBS)

$(OBJDIR)/%.o: src/%.c $(HDRS)
	@mkdir -p $(OBJDIR)
	$(CC) $(VFLAGS) $(COMMON) -DVARIANT='"$(V)"' -c $< -o $@
endif

clean:
	rm -rf $(BUILD)
