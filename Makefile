PLAYBOOK ?= playbook.yaml
# Node hostname is read from inventory.ini (the single place you update per swap-in).
NODE := $(shell grep -oE '[a-z0-9.-]+\.wall2\.ilabt\.iminds\.be' inventory.ini 2>/dev/null | head -1)

.PHONY: ping check provision ssh results

ping:       # Check the node is reachable (bastion + agent + PEM)
	ansible all -m ping

check:      # Syntax-check the playbook
	ansible-playbook --syntax-check $(PLAYBOOK)

provision:  # Provision the node (deps, docker, node/yarn, go, sop, clone, yarn install)
	ansible-playbook $(PLAYBOOK)

ssh:        # SSH into the node (via the wildcard host in ~/.ssh/config)
	ssh $(NODE)

results:    # Copy experiment results from the node to ./results
	scp -o ProxyJump=wall-bastion -i ~/.ssh/ilabt.pem -r \
		$(NODE):'~/experiment/output' ./results
