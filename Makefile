# Copyright (c) 2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

LINK_PCRE := 0
FORMAT_MSG := "\\x1B[95mFormatting:\\x1B[39m"
BUILD_MSG := "\\x1B[92mBuilding:\\x1B[39m"

# Determine the OS
detected_OS := $(shell uname -s)
ifneq (,$(findstring MINGW,$(detected_OS)))
  detected_OS := Windows
endif

ifeq ($(detected_OS),Windows)
  # Update MINGW_PATH to standard MinGW location
  MINGW_PATH = /mingw64
  NIM_PARAMS += --passC:"-I$(MINGW_PATH)/include"
  NIM_PARAMS += --passL:"-L$(MINGW_PATH)/lib"

  # Get nat-traversal path from nimble
  NAT_TRAVERSAL_PATH := $(shell nimble path nat_traversal 2>/dev/null)
  ifneq ($(NAT_TRAVERSAL_PATH),)
    NIM_PARAMS += --passL:"-L$(NAT_TRAVERSAL_PATH)/vendor/miniupnp/miniupnpc"
    NIM_PARAMS += --passL:"-L$(NAT_TRAVERSAL_PATH)/vendor/libnatpmp-upstream"
  endif

  LIBS = -lws2_32 -lbcrypt -liphlpapi -luserenv -lntdll -lminiupnpc -lnatpmp -lpq
  NIM_PARAMS += $(foreach lib,$(LIBS),--passL:"$(lib)")

  export PATH := /c/msys64/usr/bin:/c/msys64/mingw64/bin:/c/msys64/usr/lib:/c/msys64/mingw64/lib:$(PATH)

endif

##########
## Main ##
##########
.PHONY: all test update clean examples deps

# default target, because it's the first one that doesn't start with '.'
all: | wakunode2 libwaku

examples: | example2 chat2 chat2bridge

test_file := $(word 2,$(MAKECMDGOALS))
define test_name
$(shell echo '$(MAKECMDGOALS)' | cut -d' ' -f3-)
endef

test:
ifeq ($(strip $(test_file)),)
	$(MAKE) testcommon
	$(MAKE) testwaku
else
	$(MAKE) compile-test TEST_FILE="$(test_file)" TEST_NAME="$(call test_name)"
endif
# this prevents make from erroring on unknown targets like "Index"
%:
	@true

waku.nims:
	ln -s waku.nimble $@

update: | waku.nims
	nimble setup && nimble sync
	$(MAKE) build-nph

clean:
	rm -rf build

build:
	mkdir -p build

## Possible values: prod; debug
TARGET ?= prod

## Git version
GIT_VERSION ?= $(shell git describe --abbrev=6 --always --tags)
## Compilation parameters. If defined in the CLI the assignments won't be executed
NIM_PARAMS := $(NIM_PARAMS) -d:git_version=\"$(GIT_VERSION)\"

## Heaptracker options
HEAPTRACKER ?= 0
HEAPTRACKER_INJECT ?= 0
ifeq ($(HEAPTRACKER), 1)
# Assumes Nim's lib/system/alloc.nim is patched!
TARGET := debug-with-heaptrack

ifeq ($(HEAPTRACKER_INJECT), 1)
# the Nim compiler will load 'libheaptrack_inject.so'
HEAPTRACK_PARAMS := -d:heaptracker -d:heaptracker_inject
NIM_PARAMS := $(NIM_PARAMS) -d:heaptracker -d:heaptracker_inject
else
# the Nim compiler will load 'libheaptrack_preload.so'
HEAPTRACK_PARAMS := -d:heaptracker
NIM_PARAMS := $(NIM_PARAMS) -d:heaptracker
endif

endif
## end of Heaptracker options

##################
## Dependencies ##
##################
.PHONY: deps libbacktrace nat-libs

FOUNDRY_VERSION := 1.5.0
PNPM_VERSION := 10.23.0


rustup:
ifeq (, $(shell which cargo))
# Install Rustup if it's not installed
# -y: Assume "yes" for all prompts
# --default-toolchain stable: Install the stable toolchain
	curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable
endif

rln-deps: rustup
	./scripts/install_rln_tests_dependencies.sh $(FOUNDRY_VERSION) $(PNPM_VERSION)

deps: | nat-libs waku.nims
	nimble setup && nimble sync


### nim-libbacktrace

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(DEBUG), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:release
else
NIM_PARAMS := $(NIM_PARAMS) -d:debug
endif

ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:disable_libbacktrace
endif

# enable experimental exit is dest feature in libp2p mix
NIM_PARAMS := $(NIM_PARAMS) -d:libp2p_mix_experimental_exit_is_dest

# Get libbacktrace path from nimble
LIBBACKTRACE_PATH := $(shell nimble path libbacktrace 2>/dev/null)

libbacktrace:
ifneq ($(LIBBACKTRACE_PATH),)
	@# Check if library already exists (nimble install creates pre-built artifacts)
	@if [ -f "$(LIBBACKTRACE_PATH)/install/usr/lib/libbacktrace.a" ]; then \
		echo "libbacktrace already built"; \
	elif [ -f "$(LIBBACKTRACE_PATH)/Makefile" ]; then \
		$(MAKE) -C $(LIBBACKTRACE_PATH) --no-print-directory BUILD_CXX_LIB=0; \
	else \
		echo "Warning: libbacktrace Makefile not found, library may not be properly installed"; \
		echo "Try: rm -rf ~/.nimble/pkgs2/libbacktrace* && nimble install -y libbacktrace"; \
	fi
endif

clean-libbacktrace:
ifneq ($(LIBBACKTRACE_PATH),)
	@if [ -f "$(LIBBACKTRACE_PATH)/Makefile" ]; then \
		$(MAKE) -C $(LIBBACKTRACE_PATH) clean $(HANDLE_OUTPUT); \
	fi
endif

# Get nat-traversal path from nimble for building native libs
nat-libs:
	@NAT_PATH=$$(nimble path nat_traversal 2>/dev/null); \
	if [ -n "$$NAT_PATH" ]; then \
		echo "Building miniupnpc..."; \
		$(MAKE) -C $$NAT_PATH/vendor/miniupnp/miniupnpc build/libminiupnpc.a; \
		echo "Building libnatpmp..."; \
		$(MAKE) -C $$NAT_PATH/vendor/libnatpmp-upstream libnatpmp.a; \
	fi

clean-nat-libs:
	@NAT_PATH=$$(nimble path nat_traversal 2>/dev/null); \
	if [ -n "$$NAT_PATH" ]; then \
		$(MAKE) -C $$NAT_PATH/vendor/miniupnp/miniupnpc clean; \
		$(MAKE) -C $$NAT_PATH/vendor/libnatpmp-upstream clean; \
	fi

# Extend deps and clean targets
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

ifeq ($(POSTGRES), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:postgres -d:nimDebugDlOpen
endif

ifeq ($(DEBUG_DISCV5), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:debugDiscv5
endif

clean: | clean-libbacktrace clean-nat-libs

##################
##     RLN      ##
##################
.PHONY: librln

LIBRLN_BUILDDIR := $(CURDIR)/vendor/zerokit
LIBRLN_VERSION := v0.9.0

ifeq ($(detected_OS),Windows)
LIBRLN_FILE ?= rln.lib
else
LIBRLN_FILE ?= librln_$(LIBRLN_VERSION).a
endif

$(LIBRLN_FILE):
	echo -e $(BUILD_MSG) "$@" && \
		./scripts/build_rln.sh $(LIBRLN_BUILDDIR) $(LIBRLN_VERSION) $(LIBRLN_FILE)

librln: | $(LIBRLN_FILE)
	$(eval NIM_PARAMS += --passL:$(LIBRLN_FILE) --passL:-lm)

clean-librln:
	cargo clean --manifest-path vendor/zerokit/rln/Cargo.toml
	rm -f $(LIBRLN_FILE)

# Extend clean target
clean: | clean-librln

#################
## Waku Common ##
#################
.PHONY: testcommon

testcommon: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble testcommon $(NIM_PARAMS)


##########
## Waku ##
##########
.PHONY: testwaku wakunode2 testwakunode2 example2 chat2 chat2bridge liteprotocoltester

# install rln-deps only for the testwaku target
testwaku: | build deps rln-deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble test -d:os=$(shell uname) $(NIM_PARAMS)

wakunode2: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
	\
		nimble wakunode2 $(NIM_PARAMS)

benchmarks: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble benchmarks $(NIM_PARAMS)

testwakunode2: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble testwakunode2 $(NIM_PARAMS)

example2: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble example2 $(NIM_PARAMS)

chat2: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble chat2 $(NIM_PARAMS)

chat2mix: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble chat2mix $(NIM_PARAMS)

rln-db-inspector: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
	nimble rln_db_inspector $(NIM_PARAMS)

chat2bridge: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble chat2bridge $(NIM_PARAMS)

liteprotocoltester: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble liteprotocoltester $(NIM_PARAMS)

lightpushwithmix: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble lightpushwithmix $(NIM_PARAMS)

api_example: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble api_example $(NIM_PARAMS)

build/%: | build deps librln
	echo -e $(BUILD_MSG) "build/$*" && \
		nimble buildone $(NIM_PARAMS) $*

compile-test: | build deps librln
	echo -e $(BUILD_MSG) "$(TEST_FILE)" "\"$(TEST_NAME)\"" && \
		nimble buildTest $(NIM_PARAMS) $(TEST_FILE) && \
		nimble execTest $(NIM_PARAMS) $(TEST_FILE) "\"$(TEST_NAME)\""; \

################
## Waku tools ##
################
.PHONY: tools wakucanary networkmonitor

tools: networkmonitor wakucanary

wakucanary: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble wakucanary $(NIM_PARAMS)

networkmonitor: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble networkmonitor $(NIM_PARAMS)

############
## Format ##
############
.PHONY: build-nph install-nph clean-nph print-nph-path

# nph binary location
NPH := $(shell which nph 2>/dev/null || echo "build/nph")

build-nph: | build deps
ifeq ("$(wildcard $(NPH))","")
	@echo "Building nph..."
	nimble install nph
	@echo "nph utility installed"
else
	@echo "nph utility already exists at " $(NPH)
endif

GIT_PRE_COMMIT_HOOK := .git/hooks/pre-commit

install-nph: build-nph
ifeq ("$(wildcard $(GIT_PRE_COMMIT_HOOK))","")
	cp ./scripts/git_pre_commit_format.sh $(GIT_PRE_COMMIT_HOOK)
else
	echo "$(GIT_PRE_COMMIT_HOOK) already present, will NOT override"
	exit 1
endif

nph/%: | build-nph
	echo -e $(FORMAT_MSG) "nph/$*" && \
		$(NPH) $*

clean-nph:
	rm -f $(NPH)

# To avoid hardcoding nph binary location in several places
print-nph-path:
	echo "$(NPH)"

clean: | clean-nph

###################
## Documentation ##
###################
.PHONY: docs coverage

# TODO: Remove unused target
docs: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		nim doc --run --index:on --project --out:.gh-pages waku/waku.nim waku.nims

coverage:
	echo -e $(BUILD_MSG) "build/$@" && \
		./scripts/run_cov.sh -y


#####################
## Container image ##
#####################
# -d:insecure - Necessary to enable Prometheus HTTP endpoint for metrics
# -d:chronicles_colors:none - Necessary to disable colors in logs for Docker
DOCKER_IMAGE_NIMFLAGS ?= -d:chronicles_colors:none -d:insecure -d:postgres
DOCKER_IMAGE_NIMFLAGS := $(DOCKER_IMAGE_NIMFLAGS) $(HEAPTRACK_PARAMS)

# build a docker image for the fleet
docker-image: MAKE_TARGET ?= wakunode2
docker-image: DOCKER_IMAGE_TAG ?= $(MAKE_TARGET)-$(GIT_VERSION)
docker-image: DOCKER_IMAGE_NAME ?= wakuorg/nwaku:$(DOCKER_IMAGE_TAG)
docker-image:
	docker build \
		--build-arg="MAKE_TARGET=$(MAKE_TARGET)" \
		--build-arg="NIMFLAGS=$(DOCKER_IMAGE_NIMFLAGS)" \
		--build-arg="LOG_LEVEL=$(LOG_LEVEL)" \
		--build-arg="HEAPTRACK_BUILD=$(HEAPTRACKER)" \
		--label="commit=$(shell git rev-parse HEAD)" \
		--label="version=$(GIT_VERSION)" \
		--target $(TARGET) \
		--tag $(DOCKER_IMAGE_NAME) .

docker-quick-image: MAKE_TARGET ?= wakunode2
docker-quick-image: DOCKER_IMAGE_TAG ?= $(MAKE_TARGET)-$(GIT_VERSION)
docker-quick-image: DOCKER_IMAGE_NAME ?= wakuorg/nwaku:$(DOCKER_IMAGE_TAG)
docker-quick-image: NIM_PARAMS := $(NIM_PARAMS) -d:chronicles_colors:none -d:insecure -d:postgres --passL:$(LIBRLN_FILE) --passL:-lm
docker-quick-image: | build deps librln wakunode2
	docker build \
		--build-arg="MAKE_TARGET=$(MAKE_TARGET)" \
		--tag $(DOCKER_IMAGE_NAME) \
		--target $(TARGET) \
		--file docker/binaries/Dockerfile.bn.local \
		.

docker-push:
	docker push $(DOCKER_IMAGE_NAME)

####################################
## Container lite-protocol-tester ##
####################################
# -d:insecure - Necessary to enable Prometheus HTTP endpoint for metrics
# -d:chronicles_colors:none - Necessary to disable colors in logs for Docker
DOCKER_LPT_NIMFLAGS ?= -d:chronicles_colors:none -d:insecure

# build a docker image for the fleet
docker-liteprotocoltester: DOCKER_LPT_TAG ?= latest
docker-liteprotocoltester: DOCKER_LPT_NAME ?= wakuorg/liteprotocoltester:$(DOCKER_LPT_TAG)
# --no-cache
docker-liteprotocoltester:
	docker build \
		--build-arg="MAKE_TARGET=liteprotocoltester" \
		--build-arg="NIMFLAGS=$(DOCKER_LPT_NIMFLAGS)" \
		--build-arg="LOG_LEVEL=TRACE" \
		--label="commit=$(shell git rev-parse HEAD)" \
		--label="version=$(GIT_VERSION)" \
		--target $(if $(filter deploy,$(DOCKER_LPT_TAG)),deployment_lpt,standalone_lpt) \
		--tag $(DOCKER_LPT_NAME) \
		--file apps/liteprotocoltester/Dockerfile.liteprotocoltester.compile \
		.

docker-quick-liteprotocoltester: DOCKER_LPT_TAG ?= latest
docker-quick-liteprotocoltester: DOCKER_LPT_NAME ?= wakuorg/liteprotocoltester:$(DOCKER_LPT_TAG)
docker-quick-liteprotocoltester: | liteprotocoltester
	docker build \
		--tag $(DOCKER_LPT_NAME) \
		--file apps/liteprotocoltester/Dockerfile.liteprotocoltester \
		.

docker-liteprotocoltester-push:
	docker push $(DOCKER_LPT_NAME)


################
## C Bindings ##
################
.PHONY: cbindings cwaku_example libwaku

STATIC ?= 0
BUILD_COMMAND ?= libwakuDynamic

ifeq ($(detected_OS),Windows)
	LIB_EXT_DYNAMIC = dll
	LIB_EXT_STATIC = lib
else ifeq ($(detected_OS),Darwin)
	LIB_EXT_DYNAMIC = dylib
	LIB_EXT_STATIC = a
else ifeq ($(detected_OS),Linux)
	LIB_EXT_DYNAMIC = so
	LIB_EXT_STATIC = a
endif

LIB_EXT := $(LIB_EXT_DYNAMIC)
ifeq ($(STATIC), 1)
	LIB_EXT = $(LIB_EXT_STATIC)
	BUILD_COMMAND = libwakuStatic
endif

libwaku: | build deps librln
	echo -e $(BUILD_MSG) "build/$@.$(LIB_EXT)" && nimble $(BUILD_COMMAND) $(NIM_PARAMS) $@.$(LIB_EXT)

#####################
## Mobile Bindings ##
#####################
.PHONY: libwaku-android \
				libwaku-android-precheck \
				libwaku-android-arm64 \
				libwaku-android-amd64 \
				libwaku-android-x86 \
				libwaku-android-arm \
				rebuild-nat-libs \
				build-libwaku-for-android-arch

ANDROID_TARGET ?= 30
ifeq ($(detected_OS),Darwin)
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/darwin-x86_64
else
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64
endif

rebuild-nat-libs: | clean-nat-libs nat-libs

libwaku-android-precheck:
ifndef ANDROID_NDK_HOME
		$(error ANDROID_NDK_HOME is not set)
endif

build-libwaku-for-android-arch:
ifneq ($(findstring /nix/store,$(LIBRLN_FILE)),)
	mkdir -p $(CURDIR)/build/android/$(ABIDIR)/
	cp $(LIBRLN_FILE) $(CURDIR)/build/android/$(ABIDIR)/
else
	./scripts/build_rln_android.sh $(CURDIR)/build $(LIBRLN_BUILDDIR) $(LIBRLN_VERSION) $(CROSS_TARGET) $(ABIDIR)
endif
	$(MAKE) rebuild-nat-libs CC=$(ANDROID_TOOLCHAIN_DIR)/bin/$(ANDROID_COMPILER)
	CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_ARCH=$(ANDROID_ARCH) ANDROID_COMPILER=$(ANDROID_COMPILER) ANDROID_TOOLCHAIN_DIR=$(ANDROID_TOOLCHAIN_DIR) nimble libWakuAndroid $(NIM_PARAMS)

libwaku-android-arm64: ANDROID_ARCH=aarch64-linux-android
libwaku-android-arm64: CPU=arm64
libwaku-android-arm64: ABIDIR=arm64-v8a
libwaku-android-arm64: | libwaku-android-precheck build deps
	$(MAKE) build-libwaku-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libwaku-android-amd64: ANDROID_ARCH=x86_64-linux-android
libwaku-android-amd64: CPU=amd64
libwaku-android-amd64: ABIDIR=x86_64
libwaku-android-amd64: | libwaku-android-precheck build deps
	$(MAKE) build-libwaku-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libwaku-android-x86: ANDROID_ARCH=i686-linux-android
libwaku-android-x86: CPU=i386
libwaku-android-x86: ABIDIR=x86
libwaku-android-x86: | libwaku-android-precheck build deps
	$(MAKE) build-libwaku-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libwaku-android-arm: ANDROID_ARCH=armv7a-linux-androideabi
libwaku-android-arm: CPU=arm
libwaku-android-arm: ABIDIR=armeabi-v7a
libwaku-android-arm: | libwaku-android-precheck build deps
# cross-rs target architecture name does not match the one used in android
	$(MAKE) build-libwaku-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=armv7-linux-androideabi CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libwaku-android:
	$(MAKE) libwaku-android-amd64
	$(MAKE) libwaku-android-arm64
	$(MAKE) libwaku-android-x86
# This target is disabled because on recent versions of cross-rs complain with the following error
# relocation R_ARM_THM_ALU_PREL_11_0 cannot be used against symbol 'stack_init_trampoline_return'; recompile with -fPIC
# It's likely this architecture is not used so we might just not support it.
#	$(MAKE) libwaku-android-arm

#################
## iOS Bindings #
#################
.PHONY: libwaku-ios-precheck \
				libwaku-ios-device \
				libwaku-ios-simulator \
				libwaku-ios

IOS_DEPLOYMENT_TARGET ?= 18.0

# Get SDK paths dynamically using xcrun
define get_ios_sdk_path
$(shell xcrun --sdk $(1) --show-sdk-path 2>/dev/null)
endef

libwaku-ios-precheck:
ifeq ($(detected_OS),Darwin)
	@command -v xcrun >/dev/null 2>&1 || { echo "Error: Xcode command line tools not installed"; exit 1; }
else
	$(error iOS builds are only supported on macOS)
endif

# Build for iOS architecture
build-libwaku-for-ios-arch:
	IOS_SDK=$(IOS_SDK) IOS_ARCH=$(IOS_ARCH) IOS_SDK_PATH=$(IOS_SDK_PATH) nimble libWakuIOS $(NIM_PARAMS)

# iOS device (arm64)
libwaku-ios-device: IOS_ARCH=arm64
libwaku-ios-device: IOS_SDK=iphoneos
libwaku-ios-device: IOS_SDK_PATH=$(call get_ios_sdk_path,iphoneos)
libwaku-ios-device: | libwaku-ios-precheck build deps
	$(MAKE) build-libwaku-for-ios-arch IOS_ARCH=$(IOS_ARCH) IOS_SDK=$(IOS_SDK) IOS_SDK_PATH=$(IOS_SDK_PATH)

# iOS simulator (arm64 - Apple Silicon Macs)
libwaku-ios-simulator: IOS_ARCH=arm64
libwaku-ios-simulator: IOS_SDK=iphonesimulator
libwaku-ios-simulator: IOS_SDK_PATH=$(call get_ios_sdk_path,iphonesimulator)
libwaku-ios-simulator: | libwaku-ios-precheck build deps
	$(MAKE) build-libwaku-for-ios-arch IOS_ARCH=$(IOS_ARCH) IOS_SDK=$(IOS_SDK) IOS_SDK_PATH=$(IOS_SDK_PATH)

# Build all iOS targets
libwaku-ios:
	$(MAKE) libwaku-ios-device
	$(MAKE) libwaku-ios-simulator

cwaku_example: | build libwaku
	@LIBBACKTRACE_PATH=$$(nimble path libbacktrace 2>/dev/null); \
	NAT_PATH=$$(nimble path nat_traversal 2>/dev/null); \
	echo -e $(BUILD_MSG) "build/$@" && \
		cc -o "build/$@" \
		./examples/cbindings/waku_example.c \
		./examples/cbindings/base64.c \
		-lwaku -Lbuild/ \
		-pthread -ldl -lm \
		-lminiupnpc -L$$NAT_PATH/vendor/miniupnp/miniupnpc/build/ \
		-lnatpmp -L$$NAT_PATH/vendor/libnatpmp-upstream/ \
		$$LIBBACKTRACE_PATH/libbacktrace_wrapper.o \
		$$LIBBACKTRACE_PATH/install/usr/lib/libbacktrace.a

cppwaku_example: | build libwaku
	@LIBBACKTRACE_PATH=$$(nimble path libbacktrace 2>/dev/null); \
	NAT_PATH=$$(nimble path nat_traversal 2>/dev/null); \
	echo -e $(BUILD_MSG) "build/$@" && \
		g++ -o "build/$@" \
		./examples/cpp/waku.cpp \
		./examples/cpp/base64.cpp \
		-lwaku -Lbuild/ \
		-pthread -ldl -lm \
		-lminiupnpc -L$$NAT_PATH/vendor/miniupnp/miniupnpc/build/ \
		-lnatpmp -L$$NAT_PATH/vendor/libnatpmp-upstream/ \
		$$LIBBACKTRACE_PATH/libbacktrace_wrapper.o \
		$$LIBBACKTRACE_PATH/install/usr/lib/libbacktrace.a

nodejswaku: | build deps
		echo -e $(BUILD_MSG) "build/$@" && \
		node-gyp build --directory=examples/nodejs/

###################
# Release Targets #
###################

release-notes:
	docker run \
		-it \
		--rm \
		-v $${PWD}:/opt/sv4git/repo:z \
		-u $(shell id -u) \
		docker.io/wakuorg/sv4git:latest \
			release-notes |\
			sed -E 's@#([0-9]+)@[#\1](https://github.com/waku-org/nwaku/issues/\1)@g'
# I could not get the tool to replace issue ids with links, so using sed for now,
# asked here: https://github.com/bvieira/sv4git/discussions/101
