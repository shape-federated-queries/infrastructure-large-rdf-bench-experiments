# benchmark_infrastructure

Ansible that stands up **14-node jFed Virtual Wall** runs of the
[`ask-count-fedx-large-rdf-bench`](https://github.com/shape-federated-queries/ask-count-fedx-large-rdf-bench)
federated-SPARQL benchmark:

- **1 client** — generates the datasets and runs the jbr federation engine (the engine under test).
- **13 endpoints** — each serves one LargeRDFBench dataset as a SPARQL endpoint, using either
  **Comunica HDT** or **QLever** (per endpoint, chosen in the inventory).

Every endpoint answers SPARQL at `http://<host>:3002/sparql` regardless of engine, so the federation
never has to know which is behind a URL.

## Three setups

The engine of each endpoint is set per host (`endpoint_engine`) in three inventory files:

| Setup | Inventory | Endpoints |
|-------|-----------|-----------|
| **comunica** | `inventory-comunica.yml` | all 13 Comunica HDT |
| **mixed** | `inventory-mixed.yml` | QLever for the 5 hard datasets (Affymetrix, DBPedia-Subset, LinkedTCGA-A/E/M), Comunica for the other 8 |
| **qlever** | `inventory-qlever.yml` | all 13 QLever |

Each setup is its own jFed experiment (its own 14 nodes). They are independent, so you can run them
in parallel. Data generation is duplicated per client, which is free in wall-clock when the setups
run concurrently, and keeps every transfer on the experiment's fast internal LAN.

## 1. Prerequisites

- A jFed experiment swapped in with all 14 nodes on **Ubuntu 20.04**, and its **PEM key** at
  `~/.ssh/ilabt.pem` (`chmod 600`).
- Ansible on your laptop.
- Your **GitHub SSH key in the local agent** (agent-forwarded so the client can clone the private
  experiment repo + submodules):
  ```bash
  ssh-add ~/.ssh/id_ed25519 && ssh-add -l
  ```

Docker is installed automatically on QLever endpoints (and on the client); you don't set it up.

## 2. SSH config

jFed uses your login key for SSH (dumped to a throwaway file under `~/.jFed/tmp/`). Copy it once:

```bash
cp "$(ls -t ~/.jFed/tmp/sshKeyUsr*.pem | head -1)" ~/.ssh/ilabt.pem && chmod 600 ~/.ssh/ilabt.pem
```

Add to `~/.ssh/config`. The wildcard matches any Virtual Wall node, so you never edit it on a
swap-in. `ssh-rsa` is re-enabled because some node images only offer SHA-1 host keys:

```sshconfig
Host wall-bastion
    HostName bastion.ilabt.imec.be
    User fffbrtamuge
    IdentityFile ~/.ssh/ilabt.pem

Host *.wall2.ilabt.iminds.be
    User brtamuge
    IdentityFile ~/.ssh/ilabt.pem
    ProxyJump wall-bastion
    ForwardAgent yes
    ServerAliveInterval 120
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
```

## 3. Configure

For each setup you run, edit the wall addresses in its inventory file (`inventory-comunica.yml`,
`inventory-mixed.yml`, `inventory-qlever.yml`). Each is the whole topology for its experiment: one
`client` node and 13 `endpoints`, each **named after the dataset it hosts**, with its wall address,
`endpoint_port`, and `endpoint_engine`. `endpoints.json` (dataset → host + port) is generated from
this file and sent to the client, so the inventory is the single source of truth for addresses.
Repo, versions, engine defaults, and QLever memory/timeout knobs live in `group_vars/all.yml`.

## 4. Run

Every target takes the setup either as `INVENTORY=inventory-<setup>.yml` or via the `make
<setup>-<target>` shortcut. Examples below use the shortcuts.

The one-shot path per setup:

```bash
ssh-add ~/.ssh/id_ed25519       # GitHub key in the agent
make comunica-ping              # all 14 nodes reachable
make comunica-auto              # provision -> wait for data-gen -> transfer -> run (detached)
make comunica-run-status        # follow the benchmark log
make comunica-results           # pull output/ to ./results/comunica
```

Swap `comunica-` for `mixed-` or `qlever-` (run them in parallel from separate shells). Or drive
the steps individually:

```bash
make provision INVENTORY=inventory-qlever.yml   # base nodes; client (data-gen) ∥ endpoints (docker + qlever)
make status    INVENTORY=inventory-qlever.yml   # follow data generation on the client (hours)
make transfer  INVENTORY=inventory-qlever.yml   # RDF/HDT -> endpoints, build/start them, sanity-check
make run       INVENTORY=inventory-qlever.yml   # start the benchmark, detached
make stop      INVENTORY=inventory-qlever.yml   # stop endpoint servers + benchmark
```

`make provision` reboots each node once for disk expansion (the playbook waits) and is re-runnable;
NAT is re-applied each run (not reboot-persistent). Comunica endpoints receive the HDT (+ index);
QLever endpoints receive the raw RDF file and build their index on the node (the big datasets take a
while). `make transfer` ends with the federation sanity check, and `make run` also runs an S1/S2
preflight that aborts the run if the federation errors or returns nothing.

Results land in `./results/<setup>` (`combination_0` = COUNT, `combination_1` = ASK); the per-query
ad-hoc answers and planning-time metrics stay in `~/experiment/output-adhoc/` on the client.
