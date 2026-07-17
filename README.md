# benchmark_infrastructure

Ansible that stands up a **14-node jFed Virtual Wall** run of the
[`ask-count-fedx-large-rdf-bench`](https://github.com/shape-federated-queries/ask-count-fedx-large-rdf-bench)
federated-SPARQL benchmark:

- **1 client** — generates the datasets and runs the jbr federation engine (the engine under test).
- **13 endpoints** — each serves one LargeRDFBench dataset as a Comunica HDT SPARQL endpoint.

It provisions every node (disk, internet, toolchain), generates the data on the client, transfers
each HDT to its endpoint, starts the endpoints, and sanity-checks the federation. Data generation and
the benchmark run are detached with `screen`, so **you can close your laptop** while they run.

## 1. Prerequisites

- A jFed experiment swapped in with all 14 nodes on **Ubuntu 20.04**, and its **PEM key** at
  `~/.ssh/ilabt.pem` (`chmod 600`).
- Ansible on your laptop.
- Your **GitHub SSH key in the local agent** (agent-forwarded so the client can clone the private
  experiment repo + submodules):
  ```bash
  ssh-add ~/.ssh/id_ed25519 && ssh-add -l
  ```

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

```bash
cp inventory.yml.example inventory.yml
```

`inventory.yml` is the whole topology (git-ignored, so your addresses never get committed): one
`client` node and 13 `endpoints`, each **named after the dataset it hosts**, with its wall address
and `endpoint_port`. `endpoints.json` (dataset → host + port) is generated from this file and sent to
the client, so the inventory is the single source of truth for addresses. Repo, versions, and toggles
live in `group_vars/all.yml`.

## 4. Run

```bash
ssh-add ~/.ssh/id_ed25519   # GitHub key in the agent
make ping                   # all 14 nodes reachable
make provision              # base all nodes; then client (detached data-gen) ∥ endpoints (comunica)
make status                 # follow data generation on the client (hours)
make transfer               # once generation is done: HDTs -> endpoints, start them, sanity-check
make run                    # start the benchmark on the client, detached
make run-status             # follow the benchmark log
make results                # pull output/ back to ./results
```

`make provision` reboots each node once for disk expansion (the playbook waits for them) and is
re-runnable; NAT is re-applied each run (not reboot-persistent). `make transfer` ends with the
federation sanity check, and `make run` also runs an S1/S2 preflight that aborts the run if the
federation errors or returns nothing.

Results land in `./results` (`combination_0` = COUNT, `combination_1` = ASK); the per-query ad-hoc
answers and planning-time metrics stay in `~/experiment/output-adhoc/` on the client.
