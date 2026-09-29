# crest-web

Caddy reverse proxy for `*.crest.internal` and a private container registry, running on `caterpi`.

```
*.crest.internal (router dnsmasq wildcard → caterpi)
        ↓
  Caddy (caddy-docker-proxy)          services/caddy/      ports 80/443, TLS from our root CA
        ↓
  crest-web Docker network            compose.yaml
  ├── registry.crest.internal         services/registry/
  └── any other service on the network, in this repo or another
```

[caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) reads Docker labels to route each subdomain to its container, so there's no central config to maintain.

## Repo layout

```
compose.yaml                      # Project name, network, include list — always run compose from here
.env.example                      # Registry login — copy to .env
services/caddy/compose.yaml       # Caddy
services/caddy/pki/make-root.sh   # Generates the root CA (root.key + root.crt, gitignored)
services/caddy/pki/ca.cnf         # OpenSSL settings for the root CA
services/registry/compose.yaml    # Registry
data/<service>/                   # Runtime data for each service (gitignored)
```

## Deploy on caterpi

**Prerequisites:**
- Docker with Compose 2.20 or later (`docker compose version`).
- The router's wildcard DNS (see [Router DNS](#router-dns)).

**1. Clone onto the USB SSD.** All data lives inside the checkout, so keep it off the SD card.

```sh
git clone <repo-url> /mnt/data/crest-web
cd /mnt/data/crest-web
```

**2. Create the root CA.** Moving from the old setup? See [Migrating from the old setup](#migrating-from-the-old-setup) first; you may want to keep the existing root instead.

```sh
services/caddy/pki/make-root.sh
```

This writes `root.key` and `root.crt` to `services/caddy/pki/` and prints the root's fingerprint. It refuses to overwrite an existing root. **Back up `root.key` somewhere safe.** Anyone holding it can issue certificates your clients trust, and losing it means re-trusting every client.

**3. Configure the registry login.**

```sh
docker run --rm -it caddy:2 caddy hash-password    # prints a bcrypt hash
cp .env.example .env
$EDITOR .env                                        # REGISTRY_USER and REGISTRY_PASSWORD_HASH (keep the single quotes)
```

**4. Start the stack.**

```sh
mkdir -p data/caddy data/registry    # create them yourself, or Docker creates them owned by root
docker compose config -q             # validate
docker compose up -d
```

**5. Check it.**

```sh
docker compose ps                                              # registry becomes "healthy" within ~30 s
docker compose logs caddy | grep -A20 registry.crest.internal  # generated Caddyfile: basic_auth, reverse_proxy, tls internal
curl -sI --cacert services/caddy/pki/root.crt https://registry.crest.internal/v2/ | head -1   # expect 401
```

**6. Trust the root on each client.** See [Trusting the root CA](#trusting-the-root-ca).

### Router DNS

On the GL-MT6000:
1. Reserve a static IP for `caterpi` under **Clients → caterpi → IP Reservation**.
2. In LuCI, under **Network → DHCP and DNS → General Settings → Addresses**, add the entry below, then save and apply:

```
/.crest.internal/<caterpi-static-ip>
```

### Migrating from the old setup

The old setup ran Caddy from a single `compose.yaml`, with its data in the Docker volume `crest-web_caddy-data`. The project name is the same, so `docker compose up -d` from the new checkout replaces the old Caddy container in place. You don't need to stop anything first.

**Keep the existing root CA (recommended if clients already trust it).** Skip `make-root.sh` and copy the root out of the old volume instead. No client needs changing. The old root has no name constraints, unlike one from `make-root.sh`.

```sh
docker run --rm -v crest-web_caddy-data:/data -v "$PWD/services/caddy/pki:/out" alpine sh -c \
  "cp /data/caddy/pki/authorities/local/root.crt /data/caddy/pki/authorities/local/root.key /out/ \
   && chown $(id -u):$(id -g) /out/root.* && chmod 600 /out/root.key"
```

Then:
- If `up` warns about orphan containers (for example an old whoami), rerun it with `--remove-orphans`.
- Once everything works and `root.key` is backed up, delete the old volume: `docker volume rm crest-web_caddy-data`.

## Trusting the root CA

Copy the root certificate from caterpi:

```sh
scp caterpi.crest.internal:/mnt/data/crest-web/services/caddy/pki/root.crt crest-root.crt
```

**Ubuntu / Debian**
```sh
sudo cp crest-root.crt /usr/local/share/ca-certificates/crest-root.crt
sudo update-ca-certificates
```

**macOS**
```sh
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain crest-root.crt
```

**Windows** (PowerShell as Administrator)
```powershell
Import-Certificate -FilePath crest-root.crt -CertStoreLocation Cert:\LocalMachine\Root
```

**Firefox** uses its own store. Import `crest-root.crt` via **Settings → Privacy & Security → View Certificates → Authorities → Import**.

**Docker** (to push to or pull from the registry) needs one of these:
- Install the root in the system store as above, then `sudo systemctl restart docker`.
- Or trust it for the registry only:
  ```sh
  sudo mkdir -p /etc/docker/certs.d/registry.crest.internal
  sudo cp crest-root.crt /etc/docker/certs.d/registry.crest.internal/ca.crt
  ```

**Podman** uses the system store, or `/etc/containers/certs.d/registry.crest.internal/ca.crt`.

**k3s / containerd** reads it from `/etc/rancher/k3s/registries.yaml`:
```yaml
configs:
  registry.crest.internal:
    tls:
      ca_file: /etc/ssl/certs/crest-root.crt
    auth:
      username: <user>
      password: <password>
```

## Registry

A private OCI registry ([CNCF Distribution](https://distribution.github.io/distribution/), `registry:3`) at `https://registry.crest.internal`.
- **Access:** Caddy handles TLS and the login (`basic_auth`), and the registry port isn't published.
- **Storage:** images live in `data/registry/`.
- **Speed:** all traffic goes through the Pi, so large images are limited by its network and the SSD.

```sh
docker login registry.crest.internal
docker tag my-image registry.crest.internal/my-image:1.0
docker push registry.crest.internal/my-image:1.0
```

**Freeing disk space:** deleting a tag doesn't free space by itself.
1. Delete the manifest, for example with [`regctl`](https://github.com/regclient/regclient):
   ```sh
   regctl tag rm registry.crest.internal/my-image:old
   ```
2. Run garbage collection on caterpi, ideally with pushes paused:
   ```sh
   docker compose exec registry registry garbage-collect --delete-untagged /etc/distribution/config.yml
   ```

## Adding a service

**Requirements:** the service joins the `crest-web` network and has the three Caddy labels:

```yaml
services:
  my-service:
    image: my-image
    restart: unless-stopped
    networks:
      - crest-web
    labels:
      caddy: my-service.crest.internal
      caddy.reverse_proxy: "{{upstreams <port>}}"
      caddy.tls: internal

networks:
  crest-web:
    external: true
```

**In this repo:**
1. Save the template as `services/<service>/compose.yaml`, **without the final `networks:` block**. The top-level `compose.yaml` defines the network.
2. Add `- services/<service>/compose.yaml` to `include:` in the top-level `compose.yaml`.
3. For persistent data, bind-mount `../../data/<service>`.

**In another repo:** use the template as-is, and start this stack first.

**For plain HTTP** (no certificate needed on clients), use `caddy: http://my-service.crest.internal` and drop the `caddy.tls` label.

Caddy picks up new containers automatically, with no reload needed.

## Operations

**What's stored where.** None of this is in git, so `git clean -x` or a fresh clone won't have it. **Never run `git clean -x` in the checkout on caterpi.**

| Path | Holds | If lost |
|---|---|---|
| `services/caddy/pki/root.key`, `root.crt` | Root CA | Every client must trust a new root. **Back up the key.** |
| `data/registry/` | Registry images | All pushed images are gone. |
| `data/caddy/` | Caddy's intermediate CA and issued certificates | Harmless: regenerated from the root on start. |

**Root expiry.** The root is valid for 10 years (`openssl x509 -in services/caddy/pki/root.crt -noout -enddate`). Caddy renews its intermediate and site certificates automatically.

**Replacing the root.** Caddy keeps its stored intermediate even after the root changes. So after replacing `root.key`/`root.crt`, clear its CA state:
```sh
docker compose stop caddy && rm -rf data/caddy/pki data/caddy/certificates && docker compose start caddy
```

**Name constraints.** A root from `make-root.sh` is only valid for `crest.internal` and its subdomains, never for other domains or IP addresses. OpenSSL enforces this, but support varies between clients, so still guard the key.

**Running compose.** Always run `docker compose` from the repo root. The service files reference the `crest-web` network without defining it, so they don't work on their own with `-f`.

**`docker compose down`** also removes the `crest-web` network. It can't while containers from other repos are attached, and those can't start again until this stack is back up.
