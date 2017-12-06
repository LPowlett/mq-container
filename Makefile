# © Copyright IBM Corporation 2017
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

BUILD_SERVER_CONTAINER=build-server
DOCKER_TAG_ARCH ?= $(shell uname -m)
# By default, all Docker client commands are run inside a Docker container.
# This means that newer features of the client can be used, even with an older daemon.
DOCKER ?= docker
DOCKER_TAG ?= latest-$(DOCKER_TAG_ARCH)
DOCKER_REPO_DEVSERVER ?= mq-devserver
DOCKER_REPO_ADVANCEDSERVER ?= mq-advancedserver
DOCKER_FULL_DEVSERVER = $(DOCKER_REPO_DEVSERVER):$(DOCKER_TAG)
DOCKER_FULL_ADVANCEDSERVER = $(DOCKER_REPO_ADVANCEDSERVER):$(DOCKER_TAG)
# MQ_PACKAGES is the list of MQ packages to install
MQ_PACKAGES ?=ibmmq-server ibmmq-java ibmmq-jre ibmmq-gskit ibmmq-msg-.* ibmmq-samples ibmmq-ams
# MQ_VERSION is the fully qualified MQ version number to build
MQ_VERSION ?= 9.0.4.0
# Archive names for IBM MQ Continuous Delivery Release for Ubuntu
MQ_ARCHIVE_9.0.3.0_ppc64le=CNJR5ML.tar.gz
MQ_ARCHIVE_9.0.3.0_s390x=CNJR6ML.tar.gz
MQ_ARCHIVE_9.0.3.0_x86_64=CNJR7ML.tar.gz
MQ_ARCHIVE_9.0.4.0_ppc64le=CNLE2ML.tar.gz
MQ_ARCHIVE_9.0.4.0_s390x=CNLE3ML.tar.gz
MQ_ARCHIVE_9.0.4.0_x86_64=CNLE4ML.tar.gz
# Archive names for IBM MQ Advanced for Developers for Ubuntu
MQ_ARCHIVE_DEV_9.0.3.0=mqadv_dev903_ubuntu_x86-64.tar.gz
MQ_ARCHIVE_DEV_9.0.4.0=mqadv_dev904_ubuntu_x86-64.tar.gz
MQ_ARCHIVE ?= $(MQ_ARCHIVE_$(MQ_VERSION)_$(DOCKER_TAG_ARCH))
MQ_ARCHIVE_DEV=$(MQ_ARCHIVE_DEV_$(MQ_VERSION))
# Options to `go test` for the Docker tests
TEST_OPTS_DOCKER ?=
# Options to `go test` for the Kubernetes tests
TEST_OPTS_KUBERNETES ?=
TEST_IMAGE ?= $(DOCKER_FULL_ADVANCEDSERVER)
NUM_CPU=$(shell docker info --format "{{ .NCPU }}")

.PHONY: vars
vars:
	echo $(DOCKER_SERVER_VERSION_MAJOR)
	echo $(DOCKER_SERVER_VERSION_MINOR)
	echo $(DOCKER_CLIENT_VERSION_MAJOR)
	echo $(DOCKER_CLIENT_VERSION_MINOR)

.PHONY: default
default: build-devserver test

# Build all components (except incubating ones)
.PHONY: all
all: build-devserver build-advancedserver

.PHONY: devserver
devserver: build-devserver test-devserver

# Build incubating components
.PHONY: incubating
incubating: build-explorer

.PHONY: clean
clean:
	rm -rf ./coverage
	rm -rf ./build
	rm -rf ./deps

downloads/$(MQ_ARCHIVE_DEV):
	$(info $(SPACER)$(shell printf $(TITLE)"Downloading IBM MQ Advanced for Developers"$(END)))
	mkdir -p downloads
	cd downloads; curl -LO https://public.dhe.ibm.com/ibmdl/export/pub/software/websphere/messaging/mqadv/$(MQ_ARCHIVE_DEV)

.PHONY: downloads
downloads: downloads/$(MQ_ARCHIVE_DEV)

.PHONY: deps
deps:
	glide install --strip-vendor

# Vendor Go dependencies for the Docker tests
test/docker/vendor:
	cd test/docker && dep ensure -vendor-only

# Vendor Go dependencies for the Kubernetes tests
test/kubernetes/vendor:
	cd test/docker && dep ensure -vendor-only

.PHONY: build-cov
build-cov:
	mkdir -p build
	cd build; go test -c -covermode=count ../cmd/runmqserver

# Shortcut to just run the unit tests
.PHONY: test-unit
test-unit:
	docker build --target builder --file Dockerfile-server .

.PHONY: test-advancedserver
test-advancedserver: test/docker/vendor
	$(info $(SPACER)$(shell printf $(TITLE)"Test $(DOCKER_FULL_ADVANCEDSERVER) on Docker"$(END)))
	cd test/docker && TEST_IMAGE=$(DOCKER_FULL_ADVANCEDSERVER) go test -parallel $(NUM_CPU) $(TEST_OPTS_DOCKER)

.PHONY: test-devserver
test-devserver: test/docker/vendor
	$(info $(SPACER)$(shell printf $(TITLE)"Test $(DOCKER_FULL_DEVSERVER) on Docker"$(END)))
	cd test/docker && TEST_IMAGE=$(DOCKER_FULL_DEVSERVER) go test -parallel $(NUM_CPU)

.PHONY: test-advancedserver-cover
test-advancedserver-cover: test/docker/vendor
	$(info $(SPACER)$(shell printf $(TITLE)"Test $(DOCKER_REPO_ADVANCEDSERVER) on Docker with code coverage"$(END)))
	rm -f ./coverage/unit*.cov
	# Run unit tests with coverage, for each package under 'internal'
	go list -f '{{.Name}}' ./internal/... | xargs -I {} go test -cover -covermode count -coverprofile ./coverage/unit-{}.cov ./internal/{}
	echo 'mode: count' > ./coverage/unit.cov
	tail -q -n +2 ./coverage/unit-*.cov >> ./coverage/unit.cov
	go tool cover -html=./coverage/unit.cov -o ./coverage/unit.html

	rm -f ./test/docker/coverage/*.cov
	rm -f ./coverage/docker.*
	cd test/docker && TEST_IMAGE=$(DOCKER_REPO_ADVANCEDSERVER):cover go test $(TEST_OPTS_DOCKER)
	echo 'mode: count' > ./coverage/docker.cov
	tail -q -n +2 ./test/docker/coverage/*.cov >> ./coverage/docker.cov
	go tool cover -html=./coverage/docker.cov -o ./coverage/docker.html

	echo 'mode: count' > ./coverage/combined.cov
	tail -q -n +2 ./coverage/unit.cov ./coverage/docker.cov  >> ./coverage/combined.cov
	go tool cover -html=./coverage/combined.cov -o ./coverage/combined.html

.PHONY: test-kubernetes-devserver
test-kubernetes-devserver: test/kubernetes/vendor
	$(call test-kubernetes,$(DOCKER_REPO_DEVSERVER),$(DOCKER_TAG),"../../charts/ibm-mqadvanced-server-dev")

.PHONY: test-kubernetes-advancedserver
test-kubernetes-advancedserver: test/kubernetes/vendor
	$(call test-kubernetes,$(DOCKER_REPO_ADVANCEDSERVER),$(DOCKER_TAG),"../../charts/ibm-mqadvanced-server-prod")

define test-kubernetes
	$(info $(SPACER)$(shell printf $(TITLE)"Test $1:$2 on Kubernetes"$(END)))
	cd test/kubernetes && TEST_REPO=$1 TEST_TAG=$2 TEST_CHART=$3 go test $(TEST_OPTS_KUBERNETES)
endef

define docker-build-mq
	# Create a temporary network to use for the build
	$(DOCKER) network create build
	# Start a web server to host the MQ downloadable (tar.gz) file
	$(DOCKER) run \
	  --rm \
	  --name $(BUILD_SERVER_CONTAINER) \
	  --network build \
	  --network-alias build \
	  --volume "$(realpath ./downloads/)":/usr/share/nginx/html:ro \
	  --detach \
	  nginx:alpine
	# Make sure we have the latest base image
	$(DOCKER) pull ubuntu:16.04
	# Build the new image
	$(DOCKER) build \
	  --tag $1 \
	  --file $2 \
	  --network build \
	  --build-arg MQ_URL=http://build:80/$3 \
	  --label IBM_PRODUCT_ID=$4 \
	  --label IBM_PRODUCT_NAME=$5 \
	  --label IBM_PRODUCT_VERSION=$6 \
	  --build-arg MQ_PACKAGES="$(MQ_PACKAGES)" \
	  . ; $(DOCKER) kill $(BUILD_SERVER_CONTAINER) && $(DOCKER) network rm build
endef

DOCKER_SERVER_VERSION=$(shell docker version --format "{{ .Server.Version }}")
DOCKER_CLIENT_VERSION=$(shell docker version --format "{{ .Client.Version }}")
.PHONY: docker-version
docker-version:
	@test "$(word 1,$(subst ., ,$(DOCKER_CLIENT_VERSION)))" -ge "17" || (echo "Error: Docker client 17.05 or greater is required" && exit 1)
	@test "$(word 2,$(subst ., ,$(DOCKER_CLIENT_VERSION)))" -ge "05" || (echo "Error: Docker client 17.05 or greater is required" && exit 1)
	@test "$(word 1,$(subst ., ,$(DOCKER_SERVER_VERSION)))" -ge "17" || (echo "Error: Docker server 17.05 or greater is required" && exit 1)
	@test "$(word 2,$(subst ., ,$(DOCKER_SERVER_VERSION)))" -ge "05" || (echo "Error: Docker server 17.05 or greater is required" && exit 1)

.PHONY: build-advancedserver
build-advancedserver: downloads/$(MQ_ARCHIVE) docker-version
	$(info $(SPACER)$(shell printf $(TITLE)"Build $(DOCKER_FULL_ADVANCEDSERVER)"$(END)))
	$(call docker-build-mq,$(DOCKER_FULL_ADVANCEDSERVER),Dockerfile-server,$(MQ_ARCHIVE),"4486e8c4cc9146fd9b3ce1f14a2dfc5b","IBM MQ Advanced",$(MQ_VERSION))
	$(DOCKER) tag $(DOCKER_FULL_ADVANCEDSERVER) $(DOCKER_REPO_ADVANCEDSERVER):$(MQ_VERSION)-$(DOCKER_TAG_ARCH)

.PHONY: build-devserver
build-devserver: downloads/$(MQ_ARCHIVE_DEV) docker-version
	@test "$(shell uname -m)" = "x86_64" || (echo "Error: MQ Advanced for Developers is only available for x86_64 architecture" && exit 1)
	$(info $(shell printf $(TITLE)"Build $(DOCKER_FULL_DEVSERVER)"$(END)))
	$(call docker-build-mq,$(DOCKER_FULL_DEVSERVER),Dockerfile-server,$(MQ_ARCHIVE_DEV),"98102d16795c4263ad9ca075190a2d4d","IBM MQ Advanced for Developers (Non-Warranted)",$(MQ_VERSION))
	$(DOCKER) tag $(DOCKER_FULL_DEVSERVER) $(DOCKER_REPO_DEVSERVER):$(MQ_VERSION)-$(DOCKER_TAG_ARCH)

.PHONY: build-advancedserver-cover
build-advancedserver-cover: docker-version
	$(DOCKER) build -t $(DOCKER_REPO_ADVANCEDSERVER):cover -f Dockerfile-server.cover .

# .PHONY: build-web
# build-web: build downloads/CNJR7ML.tar.gz
# 	$(call docker-build-mq,mq-web:latest-$(DOCKER_TAG_ARCH),Dockerfile-mq-web)

.PHONY: build-explorer
build-explorer: downloads/$(MQ_ARCHIVE_DEV)
	$(call docker-build-mq,mq-explorer:latest-$(DOCKER_TAG_ARCH),incubating/mq-explorer/Dockerfile-mq-explorer,$(MQ_ARCHIVE_DEV),"98102d16795c4263ad9ca075190a2d4d","IBM MQ Advanced for Developers (Non-Warranted)",$(MQ_VERSION))

include formatting.mk
