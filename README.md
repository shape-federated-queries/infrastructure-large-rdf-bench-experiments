# benchmark_infrastructure

Ansible that provisions a **jFed Virtual Wall** node so the
[`ask-count-fedx-large-rdf-bench`](https://github.com/shape-federated-queries/ask-count-fedx-large-rdf-bench)
experiment is ready to run. It expands the disk, enables outbound internet, installs the toolchain
(Docker, Node/Yarn, Go, `sop`, `screen`, build tools), clones the repo with submodules, and runs
`yarn install`. **You then SSH in and run the benchmark yourself** (it can take days — run it inside
`screen` so you can close your laptop).

## 1. Prerequisites

- A jFed experiment swapped in with your node, and its **PEM key** at `~/.ssh/ilabt.pem` (`chmod 600`).
- Ansible on your laptop.
- Your **GitHub SSH key in the local agent** (agent-forwarded to clone the private repo + submodules):
  ```bash
  ssh-add ~/.ssh/id_ed25519 && ssh-add -l
  ```

## 2. SSH config (so plain SSH and Zed can reach the node)

jFed uses your **login key** for SSH (it keeps dumping it to a throwaway file under `~/.jFed/tmp/`).
Copy it once to a stable path:

```bash
cp "$(ls -t ~/.jFed/tmp/sshKeyUsr*.pem | head -1)" ~/.ssh/ilabt.pem && chmod 600 ~/.ssh/ilabt.pem
```

Add to `~/.ssh/config` (the given one-liner turned into hosts; `ProxyJump` == the original
`-oProxyCommand="ssh … -W %h:%p"`). The wildcard matches **any** Virtual Wall node, so you never edit
this when the node changes on a swap-in — just connect with the node's full hostname:

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
    ForwardX11 yes
    ServerAliveInterval 120
```

Check it: `ssh n061-07a.wall2.ilabt.iminds.be` (your node). In **Zed**:
`zed ssh://n061-07a.wall2.ilabt.iminds.be/home/brtamuge/experiment` (or *projects: open remote* → enter the
full hostname). Zed downloads a remote server on first connect, so run the playbook (or at least enable
NAT) first, otherwise it hangs with no internet.

## 3. Configure

```bash
cp inventory.ini.example inventory.ini   # edit the node hostname / user / PEM
```

Connection settings live in `inventory.ini`; everything else (repo, versions, toggles) in
`group_vars/all.yml`. Keep the four connection values in sync between the two.

## 4. Provision

```bash
ssh-add ~/.ssh/id_ed25519   # GitHub key in the agent
make ping                   # verify connectivity
make provision              # run the playbook (reboots once for disk expansion)
```

Re-runnable. NAT is re-applied each run (not reboot-persistent).

## 5. Run the benchmark (manual, on the node)

```bash
make ssh                                # or: ssh <your-node>.wall2.ilabt.iminds.be
screen -S bench                         # so it survives disconnects
cd experiment
make -C data/benchmark pipeline         # generate data (download → clean → HDT): the long part
yarn run-all                            # run the experiment (COUNT + ASK)
# detach: Ctrl-A then D   |   reattach: screen -r bench
```

Results land in `~/experiment/output/` (`combination_0`=count, `combination_1`=ask) and
`~/experiment/output-adhoc/`. Pull them back with `make results`.
