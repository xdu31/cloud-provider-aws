# Copyright 2022 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

SHELL := /bin/bash
GOOS ?= $(shell go env GOOS)
GOARCH ?= $(shell go env GOARCH)
GOPROXY ?= $(shell go env GOPROXY)
GIT_VERSION := $(shell git describe --dirty --tags --match='v*')
VERSION ?= $(GIT_VERSION)
IMAGE_REPOSITORY ?= amazon/cloud-controller-manager
IMAGE ?= $(IMAGE_REPOSITORY):$(VERSION)
OUTPUT ?= $(shell pwd)/_output
INSTALL_PATH ?= $(OUTPUT)/bin
LDFLAGS ?= -w -s -X k8s.io/component-base/version.gitVersion=$(VERSION)

CHECKSUM_FILE ?= $(OUTPUT)/bin/cloud-provider-aws_$(VERSION)_checksums.txt

# Architectures for binary builds
BIN_ARCH_LINUX ?= amd64 arm64
BIN_ARCH_WINDOWS ?= amd64

ALL_LINUX_ACCM_BIN_TARGETS = $(foreach arch,$(BIN_ARCH_LINUX),$(OUTPUT)/bin/aws-cloud-controller-manager_$(VERSION)_linux_$(arch))
ALL_WINDOWS_ACCM_BIN_TARGETS = $(foreach arch,$(BIN_ARCH_WINDOWS),$(OUTPUT)/bin/aws-cloud-controller-manager_$(VERSION)_windows_$(arch).exe)
ALL_ACCM_BIN_TARGETS = $(ALL_LINUX_ACCM_BIN_TARGETS) $(ALL_WINDOWS_ACCM_BIN_TARGETS)

ALL_LINUX_ECP_BIN_TARGETS = $(foreach arch,$(BIN_ARCH_LINUX),$(OUTPUT)/bin/ecr-credential-provider_$(VERSION)_linux_$(arch))
ALL_WINDOWS_ECP_BIN_TARGETS = $(foreach arch,$(BIN_ARCH_WINDOWS),$(OUTPUT)/bin/ecr-credential-provider_$(VERSION)_windows_$(arch).exe)
ALL_ECP_BIN_TARGETS = $(ALL_LINUX_ECP_BIN_TARGETS) $(ALL_WINDOWS_ECP_BIN_TARGETS)

ALL_BIN_TARGETS = $(ALL_ACCM_BIN_TARGETS) $(ALL_ECP_BIN_TARGETS)

.PHONY: bin
bin:
ifeq ($(GOOS),windows)
	$(MAKE) $(OUTPUT)/bin/aws-cloud-controller-manager.exe
	$(MAKE) $(OUTPUT)/bin/ecr-credential-provider.exe
else
	$(MAKE) $(OUTPUT)/bin/aws-cloud-controller-manager
	$(MAKE) $(OUTPUT)/bin/ecr-credential-provider
endif

# Function checksum
# Parameters:
# 1: Target file on which to perform checksum
# 2: Checksum file to append the result
# Note: the blank line at the end of the function is required.
define checksum
sha256sum $(1) | sed 's|./||' >> $(2)

endef

.PHONY: checksums
checksums: $(CHECKSUM_FILE)

$(CHECKSUM_FILE): build-all-bins
	rm -f $(CHECKSUM_FILE)
	@echo $(ALL_BIN_TARGETS)
	$(foreach target,$(ALL_BIN_TARGETS),$(call checksum,$(target),$(CHECKSUM_FILE)))

$(OUTPUT)/bin/%:
ifneq ($(findstring ecr-credential-provider,$@),)
	GO111MODULE=on CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) GOPROXY=$(GOPROXY) go build \
		-trimpath \
		-ldflags="$(LDFLAGS)" \
		-o=$@ \
		cmd/aws-cloud-controller-manager/*.go
else
	GO111MODULE=on CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) GOPROXY=$(GOPROXY) go build \
		-trimpath \
		-ldflags="$(LDFLAGS)" \
		-o=$@ \
		cmd/ecr-credential-provider/*.go
endif

# Function build-bin
# Parameters:
# 1. Target Application
# 2: Target OS
# 3: Target architecture
# 4: Target file extension
# Note: the blank line at the end of the function is required.
define build-bin
$(MAKE) $(1)_$(VERSION)_$(2)_$(3)$(4) GOOS=$(2) GOARCH=$(3)

endef

.PHONY: build-all-bins
build-all-bins:
	$(foreach arch,$(BIN_ARCH_LINUX),$(call build-bin,$(OUTPUT)/bin/aws-cloud-controller-manager,linux,$(arch),))
	$(foreach arch,$(BIN_ARCH_WINDOWS),$(call build-bin,$(OUTPUT)/bin/aws-cloud-controller-manager,windows,$(arch),.exe))
	$(foreach arch,$(BIN_ARCH_LINUX),$(call build-bin,$(OUTPUT)/bin/ecr-credential-provider,linux,$(arch),))
	$(foreach arch,$(BIN_ARCH_WINDOWS),$(call build-bin,$(OUTPUT)/bin/ecr-credential-provider,windows,$(arch),.exe))

.PHONY: docker-build-amd64
docker-build-amd64:
	docker buildx build --output=type=docker \
		--build-arg VERSION=$(VERSION) \
		--build-arg GOPROXY=$(GOPROXY) \
		--platform linux/amd64 \
		--tag $(IMAGE) .

.PHONY: docker-build-arm64
docker-build-arm64:
	docker buildx build --output=type=docker \
		--build-arg VERSION=$(VERSION) \
		--build-arg GOPROXY=$(GOPROXY) \
		--platform linux/arm64 \
		--tag $(IMAGE) .

.PHONY: docker-build
docker-build:
	docker buildx build --output=type=registry \
		--build-arg LDFLAGS="$(LDFLAGS)" \
		--build-arg GOPROXY=$(GOPROXY) \
		--platform linux/amd64,linux/arm64 \
		--tag $(IMAGE) .

.PHONY: ko
ko:
	hack/install-ko.sh

.PHONY: ko-build
ko-build: ko
	KO_DOCKER_REPO="$(IMAGE_REPOSITORY)" GOFLAGS="-ldflags=-X=k8s.io/component-base/version.gitVersion=$(VERSION)" ko build --tags ${VERSION}  --platform=linux/amd64,linux/arm64 --bare ./cmd/aws-cloud-controller-manager/

.PHONY: e2e.test
e2e.test:
	pushd tests/e2e > /dev/null && \
		go test -c && popd
	mv tests/e2e/e2e.test e2e.test

.PHONY: check
check: verify-fmt verify-lint vet

.PHONY: test
test:
	go test -count=1 -race -v $(shell go list ./...)

.PHONY: verify-fmt
verify-fmt:
	./hack/verify-gofmt.sh

.PHONY: verify-lint
verify-lint:
	which golint 2>&1 >/dev/null || go install golang.org/x/lint/golint@latest
	golint -set_exit_status $(shell go list ./...)

.PHONY: verify-codegen
verify-codegen:
	./hack/verify-codegen.sh

.PHONY: vet
vet:
	go vet ./...

.PHONY: update-fmt
update-fmt:
	./hack/update-gofmt.sh

.PHONY: docs
docs:
	./hack/build-gitbooks.sh

.PHONY: publish-docs
publish-docs:
	./hack/publish-docs.sh

.PHONY: kops-example
kops-example:
	./hack/kops-example.sh

.PHONY: test-e2e
test-e2e: e2e.test docker-build-amd64 install-e2e-tools
	AWS_REGION=us-west-2 \
	TEST_PATH=./tests/e2e/... \
	BUILD_IMAGE=$(IMAGE) \
	BUILD_VERSION=$(VERSION) \
	INSTALL_PATH=$(INSTALL_PATH) \
	GINKGO_FOCUS="\[cloud-provider-aws-e2e\]" \
	./hack/e2e/run.sh

# Use `make install-e2e-tools KOPS_ROOT=<local-kops-installation>`
# to skip the kops download, test local changes to the kubetest2-kops
# deployer, etc.
.PHONY: install-e2e-tools
install-e2e-tools:
	mkdir -p $(INSTALL_PATH)
	INSTALL_PATH=$(INSTALL_PATH) \
	./hack/install-e2e-tools.sh

.PHONY: print-image-tag
print-image-tag:
	@echo $(IMAGE)
