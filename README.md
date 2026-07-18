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

Every target takes the setup via the `make <setup>-<target>` shortcut (or explicitly with
`INVENTORY=inventory-<setup>.yml`). Run the steps **one at a time** — each command runs and returns;
the long waits (generation, benchmark) happen **detached on the client**, so you never sit on a
blocking command for hours. Swap `comunica-` for `mixed-`/`qlever-` and run setups in parallel from
separate shells.

```bash
ssh-add ~/.ssh/id_ed25519     # GitHub key in the agent (client clones the private repo)

make comunica-ping            # 💻 open, ~seconds  — all 14 nodes reachable
make comunica-provision       # 💻 open, ~20-30 min — base nodes (one reboot each), set up endpoints,
                              #                       and kick off data generation DETACHED on the client
#   → generation now runs on its own (hours). ✅ CLOSE THE LAPTOP.

make comunica-progress        # 💻 open, ~seconds  — snapshot; repeat until generation has finished
make comunica-transfer        # 💻 open, minutes   — ship data to endpoints + start them (qlever also
                              #                       builds its index on-node), ends with a sanity check
make comunica-run             # 💻 open, ~seconds  — pull latest code, launch the benchmark DETACHED
#   → benchmark now runs on its own (hours). ✅ CLOSE THE LAPTOP.

make comunica-progress        # 💻 open, ~seconds  — snapshot generation + benchmark logs
make comunica-run-status      # 💻 open (blocks)   — live-follow the benchmark log (Ctrl-C to stop)
make comunica-results         # 💻 open, minutes   — pull output/ to ./results/comunica when done
make comunica-stop            # stop endpoint servers + benchmark
```

### When can I close the laptop?

Data generation and the benchmark run inside `screen` **on the client**, so they survive you closing
the laptop. The Ansible steps (`provision`, `transfer`) run **on your laptop** and must stay open
until they return — but they are bounded (tens of minutes), never hours.

| After you run… | Laptop can close? | Why |
|---|---|---|
| `provision` (once it returns) | ✅ yes | generation runs detached on the client (the long wait) |
| `transfer` (while it runs) | ❌ no | Ansible drives it from your laptop (bounded) |
| `run` (once it returns) | ✅ yes | benchmark runs detached on the client (the long wait) |
| `provision` / `transfer` (while running) | ❌ no | closing kills the laptop-side Ansible |

Rule of thumb: **you only ever hold the laptop open for `provision` and `transfer`** (short, bounded).
The two multi-hour phases — generation and the benchmark — are always safe to close through; come back
and check with `make <setup>-progress`.

### Checking progress

- `make <setup>-progress` — **non-blocking snapshot** of the generation + benchmark logs. Runs,
  prints, returns. Use this to poll; nothing to leave open. **Safe to close right after.**
- `make <setup>-status` / `make <setup>-run-status` — **live follow** (`tail -f`) of the generation
  / benchmark log. These *block* to stream new lines, but they don't hold any work — hit `Ctrl-C`
  and close whenever you like; the run keeps going on the client.

Concretely: after `make <setup>-provision` returns you may close immediately, then reopen later and
`make <setup>-progress` to see if generation finished. After `make <setup>-run` returns the benchmark
is detached — close, and reopen only to `progress` / `results`.

`make provision` reboots each node once for disk expansion (the playbook waits) and is re-runnable;
NAT is re-applied each run (not reboot-persistent). Comunica endpoints receive the HDT (+ index);
QLever endpoints receive the raw RDF file and build their index on the node (the big datasets take a
while). `make run` pulls the latest experiment code first, then runs an S1/S2 preflight that aborts
if the federation errors or returns nothing.

Results land in `./results/<setup>` (`combination_0` = COUNT, `combination_1` = ASK); the per-query
ad-hoc answers and planning-time metrics stay in `~/experiment/output-adhoc/` on the client.
