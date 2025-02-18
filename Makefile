REGISTRY_NAME?=docker.io/hashicorp
IMAGE_NAME=vault-csi-provider
# VERSION defines the next version to build/release
VERSION?=1.0.0
IMAGE_TAG=$(REGISTRY_NAME)/$(IMAGE_NAME):$(VERSION)
IMAGE_TAG_LATEST=$(REGISTRY_NAME)/$(IMAGE_NAME):latest
# https://reproducible-builds.org/docs/source-date-epoch/
DATE_FMT=+%Y-%m-%d-%H:%M
SOURCE_DATE_EPOCH ?= $(shell git log -1 --pretty=%ct)
ifdef SOURCE_DATE_EPOCH
  BUILD_DATE ?= $(shell date -u -d "@$(SOURCE_DATE_EPOCH)" $(DATE_FMT) 2>/dev/null || date -u -r "$(SOURCE_DATE_EPOCH)" $(DATE_FMT) 2>/dev/null || date -u $(DATE_FMT))
else
    BUILD_DATE ?= $(shell date $(DATE_FMT))
endif
PKG=github.com/hashicorp/vault-csi-provider/internal/version
LDFLAGS?="-buildid= -s -w -X '$(PKG).BuildVersion=$(VERSION)' \
	-X '$(PKG).BuildDate=$(BUILD_DATE)' \
	-X '$(PKG).GoVersion=$(shell go version)'"
K8S_VERSION?=v1.22.2
CSI_DRIVER_VERSION=1.0.0
VAULT_HELM_VERSION=0.16.1
CI_TEST_ARGS?=

.PHONY: default build test lint image e2e-container e2e-setup e2e-teardown e2e-test mod setup-kind version promote-staging-manifest

GO111MODULE?=on
export GO111MODULE

default: test

lint:
	golangci-lint run -v --concurrency 2 \
		--disable-all \
		--timeout 10m \
		--enable gofmt \
		--enable gosimple \
		--enable govet \
		--enable errcheck \
		--enable ineffassign \
		--enable unused

build:
	CGO_ENABLED=0 go build \
		-trimpath \
		-mod=readonly \
		-modcacherw \
		-ldflags $(LDFLAGS) \
		-o dist/ \
		.

test:
	gotestsum --format=short-verbose $(CI_TEST_ARGS)

image:
	docker build \
		--target dev \
		--no-cache \
		--tag $(IMAGE_TAG) \
		.

e2e-container:
	REGISTRY_NAME="e2e" VERSION="latest" make image
	kind load docker-image e2e/vault-csi-provider:latest

setup-kind:
	kind create cluster --image kindest/node:${K8S_VERSION}

e2e-setup:
	kubectl create namespace csi
	helm install secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts/secrets-store-csi-driver-$(CSI_DRIVER_VERSION).tgz?raw=true \
		--wait --timeout=5m \
		--namespace=csi \
		--set linux.image.pullPolicy="IfNotPresent" \
		--set syncSecret.enabled=true
	helm install vault-bootstrap test/bats/configs/vault \
		--namespace=csi
	helm install vault https://github.com/hashicorp/vault-helm/archive/v$(VAULT_HELM_VERSION).tar.gz \
		--wait --timeout=5m \
		--namespace=csi \
		--values=test/bats/configs/vault/vault.values.yaml
	kubectl wait --namespace=csi --for=condition=Ready --timeout=5m pod -l app.kubernetes.io/name=vault
	kubectl exec -i --namespace=csi vault-0 -- /bin/sh /mnt/bootstrap/bootstrap.sh
	kubectl wait --namespace=csi --for=condition=Ready --timeout=5m pod -l app.kubernetes.io/name=vault-csi-provider

e2e-teardown:
	helm uninstall --namespace=csi vault || true
	helm uninstall --namespace=csi vault-bootstrap || true
	helm uninstall --namespace=csi secrets-store-csi-driver || true
	kubectl delete --ignore-not-found namespace csi

e2e-test:
	bats test/bats/provider.bats

mod:
	@go mod tidy

promote-staging-manifest: #promote staging manifests to release dir
	@rm -rf deployment
	@cp -r manifest_staging/deployment .

version:
	@echo $(VERSION)
