# ComfyUI on RunPod via dstack
#
# First-time setup:
#   make image-build     # build & push the custom image (once; and when entrypoint.sh or the ComfyUI pin changes)
#   make server          # terminal 1 — leave running
#   make fleet           # register the instance pool (once)
#   make up              # provision the pod + attach (RTX5090, fast/pricier)
#   make up-cheap        # ...or provision on whatever Blackwell GPU is cheapest
#   open http://localhost:8188   (ComfyUI; also 8888 Jupyter, 8080 FileBrowser)
#   make down            # tear the pod down when finished
#
# Day-to-day: install models/nodes on the running pod (ComfyUI-Manager). They
# mirror to R2 automatically; workflows + config + inputs + outputs persist to
# R2 too. An image rebuild is only needed when entrypoint.sh or the ComfyUI pin
# changes.

# Custom image (must match `image:` in comfyui.dstack.yml). RunPod is x86_64.
IMAGE        ?= ghcr.io/andyhite/comfyui-runpod
TAG          ?= latest
PLATFORM     ?= linux/amd64
# Each build is also pushed as :<git commit> (`-dirty` with uncommitted changes)
# so a bad image can be rolled back: point `image:` at an earlier commit's tag.
GIT_TAG      := $(shell git describe --always --dirty --abbrev=12 2>/dev/null)

# ComfyUI release to bake in. Empty = the Dockerfile's `ARG COMFYUI_VERSION`
# default, which is the one place the current pin lives.
COMFYUI_VERSION ?=
BUILD_ARGS   := $(if $(COMFYUI_VERSION),--build-arg COMFYUI_VERSION=$(COMFYUI_VERSION))

# dstack control-plane server (port default avoids the common 3000 clash).
DSTACK_PORT  ?= 3333
UPLOAD_LIMIT ?= 104857600  # 100 MB (dstack code-upload cap; no payload is uploaded now)

# Run/fleet/config names and files. `make up` applies TASK_FILE as written
# (pinned to RTX5090 — fastest, ~$0.99/hr); `make up-cheap` applies the same file
# with its GPU list swapped for CHEAP_GPU, the whole under-cap Blackwell menu, so
# dstack takes whichever is cheapest (usually RTXPRO4000, ~$0.57/hr, slower).
# comfyui-fleet.dstack.yml's gpu spec must stay a superset of both.
RUN          ?= comfyui
TASK_FILE    ?= comfyui.dstack.yml
FLEET_FILE   ?= comfyui-fleet.dstack.yml
CHEAP_GPU    ?= RTXPRO4000,RTXPRO4500,RTX5090,RTXPRO5000:24GB..

.DEFAULT_GOAL := help

R2_BUCKET    ?= comfyui

.PHONY: help image-build server fleet up up-cheap down logs attach ps status \
        panel test r2-bucket secrets-help

COMFYUI_URL  ?= http://localhost:8188

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

image-build: ## Build & push the custom image for linux/amd64 (`docker login ghcr.io` first; COMFYUI_VERSION=vX.Y.Z repins ComfyUI)
	docker buildx build --platform $(PLATFORM) $(BUILD_ARGS) -t $(IMAGE):$(TAG) \
		$(if $(GIT_TAG),-t $(IMAGE):$(GIT_TAG)) --push .

server: ## Start the dstack server (foreground; leave running). Override: make server DSTACK_PORT=3333
	DSTACK_SERVER_CODE_UPLOAD_LIMIT=$(UPLOAD_LIMIT) dstack server --port $(DSTACK_PORT)

fleet: ## Register/refresh the instance pool (one-time; re-run after editing the fleet)
	dstack apply -y -f $(FLEET_FILE)

up: ## Provision the pod on the pinned RTX5090 (fast, ~$0.99/hr). Override file: make up TASK_FILE=...
	dstack apply -y -f $(TASK_FILE)

up-cheap: ## Provision the pod on whichever Blackwell GPU is cheapest right now (usually RTXPRO4000, ~$0.57/hr, slower)
	dstack apply -y -f $(TASK_FILE) --gpu $(CHEAP_GPU)

down: ## Stop and tear down the pod
	dstack stop -y $(RUN)

logs: ## Stream the pod's logs
	dstack logs $(RUN)

attach: ## Re-attach to a running pod (re-establishes port forwarding)
	dstack attach $(RUN)

ps: ## List runs
	dstack ps

status: ## Show detailed status for this run
	dstack ps -v -n 1

panel: ## Start the comfyui-mcp panel orchestrator (attaches to the running ComfyUI)
	npx -y comfyui-mcp connect $(COMFYUI_URL)

test: ## Run the entrypoint tests and shellcheck
	bash tests/watch_sync_test.sh
	shellcheck entrypoint.sh tests/*.sh

r2-bucket: ## Create the R2 bucket for the directory mirror (one-time)
	npx -y wrangler@latest r2 bucket create $(R2_BUCKET)

secrets-help: ## Show the dstack secrets to set (HF + R2)
	@echo "dstack secret set HF_TOKEN <hugging-face token>   # accept Klein-9B license too"
	@echo "dstack secret set R2_ACCOUNT_ID <cloudflare account id>"
	@echo "dstack secret set R2_ACCESS_KEY_ID <r2 access key id>"
	@echo "dstack secret set R2_SECRET_ACCESS_KEY <r2 secret access key>"
	@echo
	@echo "All four must exist: dstack terminates a run whose config references an unset secret."
	@echo
	@echo "Account id: npx wrangler whoami   |   Create the R2 API token at:"
	@echo "  Cloudflare dashboard -> R2 -> Manage R2 API Tokens -> Create API token"
	@echo "  -> Object Read & Write (scope to the '$(R2_BUCKET)' bucket)."

