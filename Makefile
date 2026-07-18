# Multi-node orchestration for the distributed LargeRDFBench experiment.
# Pick a setup with INVENTORY: inventory-comunica.yml (default), inventory-mixed.yml,
# inventory-qlever.yml. Copy the matching file and fill in your jFed addresses.

INVENTORY ?= inventory-comunica.yml
SETUP := $(patsubst inventory-%.yml,%,$(INVENTORY))
PLAYBOOKS := common.yml client.yml endpoints.yml transfer.yml

# Client wall address (first host of the [client] group), for ssh/run/results/status.
CLIENT := $(shell ansible-inventory -i $(INVENTORY) --list 2>/dev/null | \
	python3 -c 'import sys,json;d=json.load(sys.stdin);h=d["client"]["hosts"][0];print(d["_meta"]["hostvars"][h]["ansible_host"])' 2>/dev/null)

.PHONY: ping check provision common client endpoints status transfer wait-generate auto ssh run run-status results stop

# Per-setup shortcuts: `make comunica-auto`, `make mixed-provision`, `make qlever-results`, ...
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

wait-generate: # Block until the client's data generation finishes
	@echo "waiting for data generation on $(CLIENT)..."
	ssh $(CLIENT) 'while screen -list 2>/dev/null | grep -q generate; do sleep 30; done'
	@echo "data generation finished on $(CLIENT)"

transfer:    # Transfer data -> start endpoints -> sanity check (after generation is done)
	ansible-playbook -i $(INVENTORY) transfer.yml

auto:        # End-to-end: provision -> wait for generation -> transfer -> run
	$(MAKE) provision INVENTORY=$(INVENTORY)
	$(MAKE) wait-generate INVENTORY=$(INVENTORY)
	$(MAKE) transfer INVENTORY=$(INVENTORY)
	$(MAKE) run INVENTORY=$(INVENTORY)

ssh:         # Open a shell on the client
	ssh $(CLIENT)

run:         # Start the benchmark on the client, detached (survives disconnect)
	ssh $(CLIENT) 'cd experiment && screen -dmS bench bash -c "yarn run-all > ~/run.log 2>&1"'
	@echo "benchmark started on $(CLIENT) (screen: bench). Watch: make run-status"

run-status:  # Follow the benchmark log
	ssh $(CLIENT) 'tail -n 40 -f ~/run.log'

results:     # Pull this setup's experiment results from the client
	mkdir -p ./results/$(SETUP)
	scp -r $(CLIENT):'~/experiment/{output,output-adhoc}' ./results/$(SETUP)

stop:        # Stop the endpoint servers (comunica screen + qlever container) and the benchmark screen
	ansible endpoints -i $(INVENTORY) -m shell -a 'screen -S endpoint -X quit' || true
	ansible endpoints -i $(INVENTORY) -m shell -a 'docker rm -f qlever-endpoint' || true
	ssh $(CLIENT) 'screen -S bench -X quit' || true
