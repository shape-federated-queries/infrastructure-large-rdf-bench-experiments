# Multi-node orchestration for the distributed LargeRDFBench experiment.
# Copy inventory.yml.example -> inventory.yml and fill in your jFed addresses.

INVENTORY ?= inventory.yml
PLAYBOOKS := common.yml client.yml endpoints.yml transfer.yml

# Client wall address (first host of the [client] group), for ssh/run/results/status.
CLIENT := $(shell ansible-inventory -i $(INVENTORY) --list 2>/dev/null | \
	python3 -c 'import sys,json;d=json.load(sys.stdin);h=d["client"]["hosts"][0];print(d["_meta"]["hostvars"][h]["ansible_host"])' 2>/dev/null)

.PHONY: ping check provision common client endpoints status transfer ssh run run-status results stop

ping:        # Reachability of all nodes (bastion + agent + PEM)
	ansible all -m ping

check:       # Syntax-check every playbook
	@for pb in $(PLAYBOOKS); do ansible-playbook --syntax-check $$pb; done

provision:   # Base all nodes, then client (detached generation) + endpoints concurrently
	ansible-playbook common.yml
	ansible-playbook client.yml & p1=$$!; ansible-playbook endpoints.yml & p2=$$!; wait $$p1 && wait $$p2

common:      # Base provisioning on all nodes
	ansible-playbook common.yml

client:      # Provision the client + kick off data generation (detached)
	ansible-playbook client.yml

endpoints:   # Install comunica on the endpoint nodes
	ansible-playbook endpoints.yml

status:      # Follow the client's data-generation log
	ssh $(CLIENT) 'tail -n 40 -f ~/generate.log'

transfer:    # Transfer HDTs -> start endpoints -> sanity check (after generation is done)
	ansible-playbook transfer.yml

ssh:         # Open a shell on the client
	ssh $(CLIENT)

run:         # Start the benchmark on the client, detached (survives disconnect)
	ssh $(CLIENT) 'cd experiment && screen -dmS bench bash -c "DISTRIBUTED=1 yarn run-all > ~/run.log 2>&1"'
	@echo "benchmark started on $(CLIENT) (screen: bench). Watch: make run-status"

run-status:  # Follow the benchmark log
	ssh $(CLIENT) 'tail -n 40 -f ~/run.log'

results:     # Pull the experiment output from the client
	scp -r $(CLIENT):'~/experiment/output' ./results

stop:        # Stop the endpoint servers and any benchmark screen
	ansible endpoints -m shell -a 'screen -S endpoint -X quit' || true
	ssh $(CLIENT) 'screen -S bench -X quit' || true
