# ComfyUI on RunPod via dstack
#
# First-time setup:
#   make image-build     # build & push the custom image (once; and when entrypoint.sh changes)
#   make server          # terminal 1 — leave running
#   make fleet           # register the instance pool (once)
#   make up              # provision the pod (uploads snapshot/workflows/config) + attach
#   open http://localhost:8188   (ComfyUI; also 8888 Jupyter, 8080 FileBrowser)
#   make down            # tear the pod down when finished
#
# Day-to-day: edit pod/snapshot.json, pod/workflows, or pod/user, then `make up`.
# No image rebuild needed for those — only when entrypoint.sh changes.

# Custom image (must match `image:` in comfyui.dstack.yml). RunPod is x86_64.
IMAGE        ?= ghcr.io/andyhite/comfyui-runpod
TAG          ?= latest
PLATFORM     ?= linux/amd64

# dstack control-plane server (port default avoids the common 3000 clash).
DSTACK_PORT  ?= 3333
# Raise the `files:` upload cap so larger workflow/config sets are allowed.
UPLOAD_LIMIT ?= 104857600  # 100 MB

# Run/fleet/config names and files.
RUN          ?= comfyui
TASK_FILE    ?= comfyui.dstack.yml
FLEET_FILE   ?= comfyui-fleet.dstack.yml

COMFY_DIR    := /workspace/runpod-slim/ComfyUI
CM_CLI       := $(COMFY_DIR)/custom_nodes/ComfyUI-Manager/cm-cli.py

.DEFAULT_GOAL := help

.PHONY: help image-build server fleet up down logs attach ps status snapshot-help

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

image-build: ## Build & push the custom image for linux/amd64 (needs `docker login ghcr.io`)
	docker buildx build --platform $(PLATFORM) -t $(IMAGE):$(TAG) --push .

server: ## Start the dstack server (foreground; leave running). Override: make server DSTACK_PORT=3333
	DSTACK_SERVER_CODE_UPLOAD_LIMIT=$(UPLOAD_LIMIT) dstack server --port $(DSTACK_PORT)

fleet: ## Register/refresh the instance pool (one-time; re-run after editing the fleet)
	dstack apply -y -f $(FLEET_FILE)

up: ## Provision the pod + attach (uploads snapshot/workflows/config via files:)
	dstack apply -y -f $(TASK_FILE)

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

snapshot-help: ## How to generate pod/snapshot.json from a running pod
	@echo "1. make up, then SSH/Jupyter into the pod (or use the ComfyUI-Manager UI)."
	@echo "2. Install the custom nodes you want via ComfyUI-Manager."
	@echo "3. Export the snapshot on the pod:"
	@echo "     COMFYUI_PATH=$(COMFY_DIR) python3.12 $(CM_CLI) \\"
	@echo "       save-snapshot --output /workspace/snapshot.json"
	@echo "4. Download /workspace/snapshot.json (FileBrowser :8080 or Jupyter :8888)"
	@echo "   to ./pod/snapshot.json here, then commit. Next 'make up' applies it."
