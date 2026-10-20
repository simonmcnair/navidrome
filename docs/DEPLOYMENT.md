# Deploying with CI/CD

This explains how changes to this repo reach your host automatically, and how
to set that up once.

## The idea in plain terms

- **CI (continuous integration)** means every change is checked automatically
  before it is accepted. Here, every pull request runs `docker compose config`
  to prove the compose file is valid, and lints the deploy script. A broken
  file shows a red cross on the PR instead of reaching your host.
- **CD (continuous deployment)** means that once a change is merged into
  `main`, a machine applies it to the real host without you logging in.
- **A release** is a named, numbered snapshot of the repo (`v1.0.0`,
  `v1.0.1`, ...). One is created for every merge, so you can always see what
  version is on the host and go back to an earlier one by name.
- **A runner** is the program that does the work for GitHub Actions. GitHub
  provides runners in its cloud, but those can't reach a host on your LAN. So
  you install a **self-hosted runner** on the host itself. It makes an
  outbound connection to GitHub and waits for jobs, which means you open no
  ports and expose no SSH.
- **Health check and rollback**: after deploying, the script checks that every
  container is up (and healthy where it has a healthcheck) and that Navidrome
  and Authentik answer through Traefik. If that fails within 5 minutes, it
  puts back the previous good version, including the exact images that were
  running before, and marks the release as failed.

## What happens on each change

    pull request ──> validate (GitHub's cloud)          ✔ / ✘ shown on the PR
    merge to main ─> validate ─> release vX.Y.Z ─> deploy (your host)
                                                     │
                                                     ├─ healthy: done, vX.Y.Z is live
                                                     └─ unhealthy: roll back to the
                                                        last good release, mark
                                                        vX.Y.Z "failed, rolled back"

The workflow is [.github/workflows/deploy.yml](../.github/workflows/deploy.yml)
and the deploy logic is [scripts/deploy.sh](../scripts/deploy.sh). Secrets
never go through GitHub: they stay in the `.env` file on the host.

## One-time setup on the host

These steps assume a Linux host with Docker and the Compose plugin. If the
host is a NAS appliance (Synology, Unraid, TrueNAS), the runner install in
step 3 differs; the rest is the same.

### 1. Prerequisites

    docker compose version   # Compose v2
    git --version
    curl --version

### 2. A user and a folder for the stack

Create a user for the runner and let it use Docker. Membership of the
`docker` group is equivalent to root on this host, so use this account for
nothing else.

    sudo useradd -m -s /bin/bash gha-runner
    sudo usermod -aG docker gha-runner

Pick the folder the stack lives in. The default is `/opt/navidrome`. If you
already run the stack by hand from another folder, use that folder instead,
so the containers and certificates carry over.

    sudo mkdir -p /opt/navidrome
    sudo chown gha-runner: /opt/navidrome

Put your filled-in `.env` there (see the README, section 1). This is the only
file you manage by hand; the pipeline writes everything else.

    sudo -u gha-runner cp /path/to/your/.env /opt/navidrome/.env
    sudo chmod 600 /opt/navidrome/.env

### 3. Install the runner

On GitHub: the repo, **Settings → Actions → Runners → New self-hosted
runner**, pick **Linux** and your CPU type. GitHub shows download and
`config.sh` commands with a one-time token. Run them as the runner user:

    sudo -iu gha-runner
    mkdir actions-runner && cd actions-runner
    # paste GitHub's download and extract commands here
    ./config.sh --url https://github.com/simonmcnair/navidrome --token <TOKEN> \
      --name navidrome-host --labels navidrome --unattended
    exit

Then install it as a service so it starts on boot:

    cd /home/gha-runner/actions-runner
    sudo ./svc.sh install gha-runner
    sudo ./svc.sh start

The runner now shows as **Idle** under Settings → Actions → Runners. The
`navidrome` label is how the workflow finds this machine.

### 4. Tell the workflow where the stack lives

Only if you used a folder other than `/opt/navidrome`: **Settings → Secrets
and variables → Actions → Variables → New repository variable**, name
`DEPLOY_DIR`, value the folder's path.

### 5. Lock down outside pull requests

This repo is public, and a self-hosted runner will run whatever a workflow
tells it to. A stranger could open a pull request that changes the workflow
to run their own commands on your host. Stop that in **Settings → Actions →
General → Approval for running fork pull request workflows from
contributors**: choose **Require approval for all external contributors**.
Never approve a run from someone you don't know. Making the repo private
removes the risk entirely.

### 6. First deploy

**Actions → Deploy → Run workflow** on `main`. Watch the deploy job's log.
On success the stack is running and a release appears under **Releases**.
Then carry on with the README from section 5 (Authentik setup).

If the first deploy fails there is nothing earlier to roll back to, so the
stack is left as it is and the log shows why.

## Day to day

- Change something on a branch and open a pull request. Wait for the green
  tick, then merge.
- The merge creates the next release and deploys it. If it is unhealthy the
  host goes back to the previous release by itself, the run goes red (GitHub
  emails you), and the release is marked "failed, rolled back".
- After a rollback, `main` still holds the broken change. Fix it in a new pull
  request, or revert the pull request on GitHub, which deploys the old
  version as a new release.
- To put any earlier release back by hand: **Actions → Deploy → Run
  workflow**, and under "Use workflow from" pick its tag.

Where the host's state lives, in `DEPLOY_DIR/.deploy/`:

- `current` is the commit running now.
- `last-good` is the last commit that passed its health check.

## What rollback does not cover

- **Database changes.** When Authentik upgrades, it migrates its PostgreSQL
  database, and running the old version against a migrated database may not
  work. Back up the database before an Authentik upgrade:
  `docker exec authentik-postgres pg_dump -U authentik authentik > authentik.sql`.
- **Changes to `.env`.** They live only on the host, so the pipeline neither
  deploys nor rolls them back. `AUTHENTIK_TAG` is in `.env`, so Authentik
  upgrades are a host edit followed by **Run workflow**.
- **Problems the health check can't see**, such as a wrong Authentik
  provider setting. It proves the services answer, not that login works.
