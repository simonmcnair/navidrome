# Traefik + Authentik + Navidrome

This is a self-contained Docker Compose stack for exposing Navidrome securely
through Traefik, using Authentik ForwardAuth and individual Let's Encrypt
certificates obtained with Cloudflare DNS-01.

There are NO wildcard certificates.

Your existing `ghcr.io/hotio/cloudflareddns` container remains separate and
continues to update your Cloudflare DNS record.

## 1. Change only these values

Copy `.env.example` to `.env` (which git ignores), then edit `.env`:

    cp .env.example .env

- `CF_DNS_API_TOKEN` — your existing SWAG Cloudflare DNS-01 API token
- `ACME_EMAIL` — your email address
- `DOMAIN` — e.g. `35.example.com`
- `AUTHENTIK_DOMAIN` — e.g. `auth.example.com` (needs its own DNS record, e.g. a CNAME to `DOMAIN`; Traefik issues its own certificate)
- `NAVIDROME_DATA` — absolute NAS path for Navidrome data
- `MUSIC_PATH` — absolute NAS path containing your music
- `AUTHENTIK_SECRET_KEY` — generate a new random secret
- `PG_PASS` — generate a strong PostgreSQL password
- `AUTHENTIK_BOOTSTRAP_PASSWORD` / `AUTHENTIK_BOOTSTRAP_EMAIL` — your Authentik
  admin (`akadmin`) password and email
- `AUTHENTIK_ADMIN_BIND` — the NAS LAN IP
- `PUID` / `PGID` — the NAS user Navidrome runs as (`id <user>`)
- `PROXY_SUBNET` / `TRAEFIK_PROXY_IP` — leave as is unless the subnet clashes
  with your network

Generate the two Authentik secrets with:

    openssl rand -base64 60 | tr -d '\n'
    openssl rand -base64 36 | tr -d '\n'

Do NOT reuse the Cloudflare token as either of these.

## 2. Cloudflare token

The existing SWAG token can be reused if it has the required permissions:

- Zone:Read
- DNS:Edit

Ideally restrict it to the relevant Cloudflare zone.

Traefik uses the token only for Let's Encrypt DNS-01 certificate issuance.
It does not update your DDNS record and it does not create a Cloudflare Tunnel.

## 3. OPNsense

Forward only:

    TCP 80  -> NAS:80
    TCP 443 -> NAS:443

Do NOT forward:

    TCP 4533
    TCP 9000

Port 9000 is exposed by Docker for LAN Authentik administration only, on the
address in `AUTHENTIK_ADMIN_BIND`. Docker-published ports bypass the NAS's own
firewall, which is why it is bound to one address rather than all of them.

The Authentik UI is also published at `https://AUTHENTIK_DOMAIN` via Traefik
(required for remote login). Enforce MFA on admin accounts.

## 4. Start

From this directory:

    mkdir -p letsencrypt logs
    touch letsencrypt/acme.json
    chmod 600 letsencrypt/acme.json

Then:

    docker compose pull
    docker compose up -d

Check:

    docker compose ps
    docker compose logs -f authentik-server
    docker compose logs -f traefik

## 5. Initial Authentik setup

The admin account is created automatically on first start from
`AUTHENTIK_BOOTSTRAP_PASSWORD` and `AUTHENTIK_BOOTSTRAP_EMAIL`, so the public
initial-setup page can't be used by anyone else to claim it. Those two values
are only read on the very first start; changing them later does nothing.

On your LAN, open:

    http://NAS-IP:9000/

and log in as `akadmin` with that password. Then set up MFA for it, and
ideally create your own admin user and deactivate `akadmin`.

Even so, finish steps 5 and 6 before adding the OPNsense port forwards.

## 6. Create the Navidrome Authentik application

In Authentik:

Applications -> Applications -> Create with Provider

Use:

Application:
    Navidrome

Provider:
    Proxy Provider

Mode:
    Forward auth (single application)

External host:
    https://35.example.com

Assign the provider to the embedded outpost.

Then Applications -> Outposts -> edit the embedded outpost -> Advanced
settings/configuration and set:

    authentik_host: https://auth.example.com

(your `AUTHENTIK_DOMAIN`). Without this the login redirect points at the
app hostname and loops.

The embedded outpost is used by this Compose stack, so no separate outpost
container is required.

Create a group/user binding so only the users you want can access Navidrome.

## 7. Navidrome/Symfonium detail

The Navidrome web UI is protected by Authentik ForwardAuth, and you are logged
in to Navidrome automatically as the user Authentik reports
(`X-authentik-username`), so there is no second login. Navidrome trusts that
header only from Traefik's fixed address (`TRAEFIK_PROXY_IP`). Your Authentik
usernames must match your Navidrome usernames; a new Authentik user who
reaches Navidrome gets a new Navidrome account.

The `/rest/` Subsonic API is NOT behind Authentik: Subsonic clients cannot
follow Authentik's browser redirect flow, so Navidrome's own password is the
only gate there. Two things protect it:

- The `strip-sso-header` middleware removes any `X-authentik-username` header
  a client sends, so nobody can log in through `/rest/` by claiming a
  username. Never remove it from the `navidrome-api` router while SSO is on.
- A Traefik rate limit (50 req/s, burst 100). This is too generous to stop
  password guessing on its own, so use a long random Navidrome password
  (Symfonium stores it; you never type it). For active blocking, point
  CrowdSec or fail2ban at `logs/access.log` and ban IPs with repeated
  Subsonic auth failures.

To put `/rest/` behind Authentik anyway, change the
`navidrome-api.middlewares` label to `authentik@docker` (Symfonium will then
most likely fail to connect).

Navidrome public share links (`/share/`, off by default) will hit the
Authentik login. If you turn sharing on, add a router for `/share/` without
the `authentik@docker` middleware.

Other containers on the `proxy` network can reach Navidrome directly, but
only Traefik's address is trusted for the SSO header.

## 8. Symfonium

Server:

    https://35.example.com

Then use your normal Navidrome username/password.

## 9. Adding other applications

Put the application on the `proxy` Docker network and add Traefik labels.

For a normal HTTPS service, the core labels look like:

    traefik.enable=true
    traefik.docker.network=proxy
    traefik.http.routers.APP.rule=Host(`app.example.com`)
    traefik.http.routers.APP.entrypoints=websecure
    traefik.http.routers.APP.tls=true
    traefik.http.routers.APP.tls.certresolver=cloudflare
    traefik.http.routers.APP.middlewares=authentik@docker

Traefik will obtain a separate certificate for that hostname through DNS-01.
No wildcard is involved.

## 10. Upgrades

Authentik should not use the `latest` tag. This stack pins the version via
`AUTHENTIK_TAG`.

When upgrading Authentik, follow the official release/upgrade documentation
and change `AUTHENTIK_TAG` to the target version. Upgrade server and worker
together.

Before the first start, check `AUTHENTIK_TAG` and the `/media` and
`/templates` volume paths against the official Authentik `docker-compose.yml`
for that version; Authentik has moved paths between releases.

Traefik is pinned to a minor version. Navidrome and the socket proxy use
`latest`; pin them to a specific release tag if you want controlled upgrades.

## Architecture

Internet
  |
  | TCP 443
  v
OPNsense
  |
  v
NAS
  |
  +-- Traefik :443
  |      |
  |      +-- Authentik ForwardAuth (UI) / Authentik UI at AUTHENTIK_DOMAIN
  |      |
  |      +-- Navidrome :4533
  |
  +-- Authentik :9000 (LAN IP only)
  |
  +-- PostgreSQL (Docker internal only)
  |
  +-- existing cloudflareddns (unchanged)

Cloudflare DNS remains DNS-only. No Cloudflare Tunnel is used.
