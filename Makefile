INI_FILE := nodes.ini

WORKER_NODES := $(shell awk '/^\[worker\]/ {found=1; next} /^\[/ {found=0} found && NF {print $$1}' $(INI_FILE))
CONTROL_PLANE_NODES := $(shell awk '/^\[control-plane\]/ {found=1; next} /^\[/ {found=0} found && NF {print $$1}' $(INI_FILE))

TALOSCONFIG := manifests/talosconfig

ifeq (, $(shell command -v talosctl))
$(error "Talosctl is not installed. Please install it to proceed.")
endif

GREEN := \033[32m
NC := \033[0m

.PHONY: all secrets config configure apply-control-plane apply-workers bootstrap kube-config

help:
	@printf "$(GREEN)Available targets:$(NC)\n"
	@printf "  %-22s %s\n" "all"                 "Run full setup (secrets, config, configure, apply, bootstrap, kubeconfig)"
	@printf "  %-22s %s\n" "secrets"             "Generate Talos secrets"
	@printf "  %-22s %s\n" "disks"               "Check available disks on all nodes"
	@printf "  %-22s %s\n" "config"              "Generate Talos config files"
	@printf "  %-22s %s\n" "apply-control-plane" "Apply config to control-plane nodes"
	@printf "  %-22s %s\n" "apply-workers"       "Apply config to worker nodes"
	@printf "  %-22s %s\n" "configure"           "Configure talosctl to talk to the first control-plane node"
	@printf "  %-22s %s\n" "bootstrap"           "Bootstrap Kubernetes control plane"
	@printf "  %-22s %s\n" "kube-config"         "Generate kubeconfig for kubectl"
	@printf "  %-22s %s\n" "status"              "Show Talos machine status"
	@printf "  %-22s %s\n" "clean"               "Remove generated manifests and secrets"
	@printf "  %-22s %s\n" "reboot"              "Reboot all nodes"
	@printf "  %-22s %s\n" "reset"               "Wipe all nodes (destructive!). Use CONFIRM=YES"
	@printf "  %-22s %s\n" "reset-prompt"        "Interactive confirmation before wipe"


all: secrets config configure apply-control-plane apply-workers bootstrap kube-config

secrets:
	@echo "$(GREEN)Generating secrets$(NC)"
	@talosctl gen secrets --force -o secrets.yaml

disks:
	@echo "$(GREEN)Checking disks on all control-plane and worker nodes$(NC)"
	@for node in $(CONTROL_PLANE_NODES) $(WORKER_NODES); do \
		echo "$(GREEN)Checking disks on node $$node$(NC)"; \
		talosctl --insecure --nodes=$$node --endpoints=$$node --talosconfig $(TALOSCONFIG) get disks; \
		echo ""; \
	done

config:
	@echo "$(GREEN)Generating configuration files$(NC)"
	@talosctl gen config geron https://$(word 1, $(CONTROL_PLANE_NODES)):6443 \
		--with-secrets secrets.yaml \
		--config-patch @patch/all.yaml \
		--config-patch-worker @patch/worker.yaml \
		--config-patch-control-plane @patch/control-plane.yaml \
		--output-dir manifests \
		--force
	@talosctl config endpoint $(word 1, $(CONTROL_PLANE_NODES)) --talosconfig $(TALOSCONFIG)

apply-control-plane:
	@echo "$(GREEN)Applying configuration to control-plane nodes$(NC)"
	@for node in $(CONTROL_PLANE_NODES); do \
		echo "$(GREEN)Applying config to control-plane node $$node$(NC)"; \
		talosctl apply-config --insecure --talosconfig $(TALOSCONFIG) --nodes=$$node --file=manifests/controlplane.yaml; \
	done

apply-workers:
	@echo "$(GREEN)Applying configuration to worker nodes$(NC)"
	@for node in $(WORKER_NODES); do \
		echo "$(GREEN)Applying config to worker node $$node$(NC)"; \
		talosctl apply-config --insecure --talosconfig $(TALOSCONFIG) --nodes=$$node --file=manifests/worker.yaml; \
	done

configure:
	@echo "$(GREEN)Configuring Talos client for first control-plane node$(NC)"
	@talosctl config endpoint $(word 1, $(CONTROL_PLANE_NODES)) --talosconfig=$(TALOSCONFIG)
	@talosctl config node $(word 1, $(CONTROL_PLANE_NODES)) --talosconfig=$(TALOSCONFIG)

bootstrap:
	@echo "$(GREEN)Bootstrapping Kubernetes control plane$(NC)"
	@talosctl --talosconfig=$(TALOSCONFIG) bootstrap

kube-config:
	@echo "$(GREEN)Generating kubeconfig$(NC)"
	@talosctl --talosconfig=$(TALOSCONFIG) kubeconfig manifests/config

status:
	@echo "$(GREEN)Control-plane health check$(NC)"
	@for node in $(CONTROL_PLANE_NODES); do \
		echo "$(GREEN)Node: $$node$(NC)"; \
		talosctl --talosconfig=$(TALOSCONFIG) --nodes=$$node health; \
		echo ""; \
	done
	@echo "$(GREEN)Check Kubernetes node status via kubectl$(NC)"
	@kubectl --kubeconfig manifests/config get nodes -o wide

clean:
	@echo "$(GREEN)Cleaning up manifests$(NC)"
	@rm -rf manifests/secrets.yaml

reboot:
	@echo "$(GREEN)Rebooting all nodes$(NC)"
	@talosctl --talosconfig=$(TALOSCONFIG) reboot $(foreach node,$(CONTROL_PLANE_NODES) $(WORKER_NODES),--nodes=$(node))

reset:
	@echo "$(GREEN)Wiping all nodes$(NC)"
	@if [ "$(CONFIRM)" != "YES" ]; then \
		echo "This action is DESTRUCTIVE and will WIPE all nodes."; \
		echo "To proceed, run: make reset CONFIRM=YES"; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory _do-reset

reset-prompt:
	@echo "This action is DESTRUCTIVE and will WIPE all nodes."
	@printf "Type exactly 'geron-reset' to continue: "; \
	read ans; \
	if [ "$$ans" != "geron-reset" ]; then \
		echo "Aborted."; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory CONFIRM=YES _do-reset

_do-reset:
	@talosctl --talosconfig=$(TALOSCONFIG) reset --graceful=false $(foreach node,$(CONTROL_PLANE_NODES) $(WORKER_NODES),--nodes=$(node))
