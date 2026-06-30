# ComfyUI on RunPod via dstack
#
# Typical first run:
#   make server          # in one terminal — leave it running
#   make register-volume # in another terminal (one-time)
#   make up              # spin up the pod
#   open http://localhost:8188   (ComfyUI; also 8888 Jupyter, 8080 FileBrowser)
#   make down            # tear the pod down when finished

# dstack control-plane server port (default avoids the common 3000 clash)
DSTACK_PORT ?= 3333

# Run name (must match `name:` in comfyui.dstack.yml) and config files
RUN          ?= comfyui
TASK_FILE    ?= comfyui.dstack.yml
VOLUME_FILE  ?= comfyui-volume.dstack.yml
VOLUME_NAME  ?= comfyui-eu-nl-1

.DEFAULT_GOAL := help

.PHONY: help server register-volume up down logs attach ps status volumes volume-delete

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

server: ## Start the dstack server (foreground; leave running). Override port: make server DSTACK_PORT=3333
	dstack server --port $(DSTACK_PORT)

register-volume: ## Register the existing RunPod network volume with dstack (one-time, non-destructive)
	dstack apply -y -f $(VOLUME_FILE)

up: ## Provision the pod and attach (forwards 8188/8888/8080 to localhost)
	dstack apply -y -f $(TASK_FILE)

down: ## Stop and tear down the pod (volume + its data persist)
	dstack stop -y $(RUN)

logs: ## Stream the pod's logs
	dstack logs $(RUN)

attach: ## Re-attach to a running pod (re-establishes port forwarding)
	dstack attach $(RUN)

ps: ## List runs
	dstack ps

status: ## Show detailed status for this run
	dstack ps -v -n 1

volumes: ## List registered volumes
	dstack volume list

volume-delete: ## Deregister the volume from dstack (does NOT delete data on RunPod)
	dstack volume delete -y $(VOLUME_NAME)
