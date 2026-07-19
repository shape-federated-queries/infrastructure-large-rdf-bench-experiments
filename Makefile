# Multi-node orchestration for the distributed LargeRDFBench experiment.
# Pick a setup with INVENTORY: inventory-comunica.yml (default), inventory-mixed.yml,
# inventory-qlever.yml. Copy the matching file and fill in your jFed addresses.

INVENTORY ?= inventory-comunica.yml
SETUP := $(patsubst inventory-%.yml,%,$(INVENTORY))
NODE_HEAP_MB ?= 18432
PLAYBOOKS := common.yml client.yml endpoints.yml transfer.yml

# Client wall address (first host of the [client] group), for ssh/run/results/status.
CLIENT := $(shell ansible-inventory -i $(INVENTORY) --list 2>/dev/null | \
	python3 -c 'import sys,json;d=json.load(sys.stdin);h=d["client"]["hosts"][0];print(d["_meta"]["hostvars"][h]["ansible_host"])' 2>/dev/null)

.PHONY: ping check provision common client endpoints status transfer ssh deploy run run-status progress results stop

# Per-setup shortcuts: `make comunica-provision`, `make mixed-run`, `make qlever-results`, ...
comunica-%:
	@$(MAKE) $* INVENTORY=inventory-comunica.yml
mixed-%:
	@$(MAKE) $* INVENTORY=inventory-mixed.yml
qlever-%:
	@$(MAKE) $* INVENTORY=inventory-qlever.yml

ping:        # Reachability of all nodes (bastion + agent + PEM)
	ansible all -i $(INVENTORY) -m ping

check:       # Syntax-check every playbook
	@for pb in $(PLAYBOOKS); do ansible-playbook -i $(INVENTORY) --syntax-check $$pb; done

provision:   # Base all nodes, then client (detached generation) + endpoints concurrently
	ansible-playbook -i $(INVENTORY) common.yml
	ansible-playbook -i $(INVENTORY) client.yml & p1=$$!; ansible-playbook -i $(INVENTORY) endpoints.yml & p2=$$!; wait $$p1 && wait $$p2

common:      # Base provisioning on all nodes
	ansible-playbook -i $(INVENTORY) common.yml

client:      # Provision the client + kick off data generation (detached)
	ansible-playbook -i $(INVENTORY) client.yml

endpoints:   # Set up the endpoint nodes for their engine (comunica / qlever)
	ansible-playbook -i $(INVENTORY) endpoints.yml

status:      # Follow the client's data-generation log
	ssh $(CLIENT) 'tail -n 40 -f ~/generate.log'

transfer:    # Transfer data -> start endpoints -> sanity check (after generation is done)
	ansible-playbook -i $(INVENTORY) transfer.yml

ssh:         # Open a shell on the client
	ssh $(CLIENT)

deploy:      # Redeploy latest experiment code on the client (no reprovision)
	ssh $(CLIENT) 'cd experiment && git pull --ff-only && yarn install --frozen-lockfile'

run: deploy  # Redeploy latest, then start the benchmark on the client, detached
	ssh $(CLIENT) 'cd experiment && screen -dmS bench bash -c "NODE_HEAP_MB=$(NODE_HEAP_MB) yarn run-all > ~/run.log 2>&1"'
	@echo "benchmark started on $(CLIENT) (screen: bench, node heap $(NODE_HEAP_MB)MB). Watch: make run-status"

run-status:  # Follow the benchmark log
	ssh $(CLIENT) 'tail -n 40 -f ~/run.log'

progress:    # Non-following snapshot of this setup's generation + benchmark logs
	@echo "== $(SETUP): data generation =="; ssh $(CLIENT) 'tail -n 15 ~/generate.log 2>/dev/null || echo "(none yet)"'
	@echo "== $(SETUP): benchmark =="; ssh $(CLIENT) 'tail -n 15 ~/run.log 2>/dev/null || echo "(none yet)"'

results:     # Pull this setup's experiment results from the client
	mkdir -p ./results/$(SETUP)
	scp -r $(CLIENT):'~/experiment/{output,output-adhoc}' ./results/$(SETUP)

stop:        # Stop the endpoint servers (comunica screen + qlever container) and the benchmark screen
	ansible endpoints -i $(INVENTORY) -m shell -a 'screen -S endpoint -X quit 2>/dev/null || true'
	ansible endpoints -i $(INVENTORY) -m shell -a 'command -v docker >/dev/null && docker rm -f qlever-endpoint || true'
	ssh $(CLIENT) 'screen -S bench -X quit 2>/dev/null || true'
