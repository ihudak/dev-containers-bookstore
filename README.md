# AI Sandbox Container Assets (Public Example)

This directory is the repo-ready asset bundle for the Public-flavored AI sandbox container described in [Wiki: Use dev containers for development with AI agents](https://github.com/ihudak/bookstore/wiki/Use-dev-containers-for-development-with-Copilot).

It packages a CLI-only Docker-based workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, and others) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell.

## What is included

- `Dockerfile` builds the image from a configurable set of optional components: AI agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, Gemini CLI), JVM toolchains (OpenJDK 21/25, GraalVM CE 25), cloud CLIs (AWS, Azure, kubectl, GitHub CLI), dev tools (Angular CLI), and Dynatrace CLIs (dtctl, dtmgd). Node.js, git, packet-capture tools, and the non-root sandbox user are always included.
- `sandbox.conf` controls which optional components are built into the image and which credential directories are mounted at runtime.
- `entrypoint.sh` applies either a restricted firewall or a discovery mode at container startup. In both modes it creates the sandbox user and drops to it via `capsh`. Restricted mode drops `NET_ADMIN` and `NET_RAW`; discovery mode drops only `NET_ADMIN` (keeping `NET_RAW` for tcpdump).
- `refresh-ipset-allowlist.sh` resolves the concrete allowlist domains into IPv4 and IPv6 `ipset` sets.
- `capture-blocked-traffic.sh` runs as a background root daemon in restricted mode, logging every blocked outbound destination to `/workspace/.agent-blocked/`.
- `capture-agent-destinations.sh` helps you discover additional AI-agent-related DNS and TLS destinations in discovery mode.
- `allowlist-domains.d/`, `allowlist-proxy-domains.d/`, `allowlist-cidrs.d/` contain per-component allowlist fragments. `runme.sh build` assembles the active fragments into the three `allowlist-*.txt` files that the Dockerfile copies into the image. Each directory also contains a `custom.txt` file that is always included regardless of which components are enabled.
- `runme.sh` is the entry point for building and running the container.

## Usage

Edit `sandbox.conf` to choose which optional components to include, then build the image:

```bash
./runme.sh build
```

`runme.sh build` reads `sandbox.conf`, assembles the three `allowlist-*.txt` files from the matching fragments in `allowlist-*.d/`, and passes a `--build-arg` flag for each component to `docker build`. The generated `allowlist-*.txt` files are gitignored; the `*.d/` fragment directories are the source of truth.

Run in restricted mode with the firewall enabled:

```bash
./runme.sh restricted /path/to/your/repo
```

Run in discovery mode to capture outbound destinations before tightening the allowlist:

```bash
./runme.sh discovery /path/to/your/repo
```

Inside the container, the repository is mounted at `/workspace`.

## Extracting discovery results

After running in discovery mode, reproduce the AI agent interaction you want to observe, then exit the container (`Ctrl+D`). The pcap capture file persists on the host in the `.agent-discovery` directory inside your workspace.

Extract the DNS and TLS hostname lists:

```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/your/repo:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

The container prints this command with the correct path when discovery mode starts. The output lists:

- DNS queries — hostnames the container attempted to resolve.
- TLS SNI hostnames — HTTPS endpoints presented during TLS handshakes.

Add the discovered hostnames to `allowlist-domains.d/custom.txt`, rebuild the image with `./runme.sh build`, and switch to restricted mode.

## Mounting additional repositories

Set `EXTRA_MOUNTS` to a space-separated list of host paths. Append `:ro` or `:rw` to control per-directory access. The default is read-write.

```bash
# backend is the primary workspace; ui is read-write, reference-docs is read-only
SSH_SCOPE_DIR="$HOME/.ssh/myproject" \
EXTRA_MOUNTS="/path/to/myproject-ui /path/to/reference-docs:ro" \
bash ./runme.sh restricted /path/to/myproject-backend
```

Each path is mounted at `/repos/<basename>` inside the container.

## Host configuration mounts

The container automatically mounts the following directories from the host (if they exist) into the sandbox user's home:

Each directory is only mounted when its corresponding component is enabled in `sandbox.conf`. Missing directories are silently skipped.

| Host directory | Container path | Mode | Component |
|---|---|---|---|
| `~/.ssh` (or `SSH_SCOPE_DIR`) | `~/.ssh` | read-only | always |
| `~/.config/gh` | `~/.config/gh` | read-write | `github-cli` or `copilot` |
| `~/.copilot` | `~/.copilot` | read-write | `copilot` |
| `~/.kiro` | `~/.kiro` | read-write | `kiro` |
| `~/.local/share/kiro-cli` | `~/.local/share/kiro-cli` | read-write | `kiro` |
| `~/.claude` | `~/.claude` | read-write | `claude-code` |
| `~/.codex` | `~/.codex` | read-write | `codex` |
| `~/.gemini` | `~/.gemini` | read-write | `gemini` |
| `~/.aws` | `~/.aws` | read-write | `aws-cli` |
| `~/.azure` | `~/.azure` | read-write | `azure-cli` |
| `~/.kube` | `~/.kube` | read-write | `kubectl` |
| `~/.config/dtctl` | `~/.config/dtctl` | read-write | `dtctl` |
| `~/.config/dtmgd` | `~/.config/dtmgd` | read-write | `dtmgd` |

## Reviewing blocked traffic

When running in restricted mode, blocked outbound destinations are logged automatically to `/workspace/.agent-blocked/`. These files persist on the host via the workspace mount.

| File | Purpose |
|------|---------|
| `blocked.log` | Timestamped log of every blocked connection attempt |
| `blocked-domains.txt` | Deduplicated domain list — copy-paste into `allowlist-domains.d/custom.txt` |
| `blocked-ips.txt` | Deduplicated IPs with no known domain — copy-paste into `allowlist-cidrs.d/custom.txt` |

To update the allowlist after a session:

```bash
cat /workspace/.agent-blocked/blocked-domains.txt
# copy the domain lines → paste into allowlist-domains.d/custom.txt
#   (or into the relevant component fragment if you know which component needs them)

cat /workspace/.agent-blocked/blocked-ips.txt
# copy the IP lines → paste into allowlist-cidrs.d/custom.txt
```

Then rebuild the image with `./runme.sh build` and restart the container.

## Security model (restricted mode)

1. **iptables** sets a deny-by-default OUTPUT policy and allows only the allowlisted destinations.
2. **Capability drop**: after iptables is configured, the agent shell is started via `capsh --drop=cap_net_admin,cap_net_raw`, so it cannot modify firewall rules or create raw sockets regardless of file permissions.
3. **Non-root user**: the agent runs as a sandbox user whose username, UID, and GID match the host user that started the container (detected automatically by `runme.sh` via `id -u`, `id -g`, `id -un`, `id -gn`). Override by setting `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP` before running.
4. **Background daemons**: the ipset refresh loop and the blocked-traffic capture daemon are forked before the capability drop and retain their root capabilities to do their jobs.
5. **Self-healing allowlist**: when a blocked IP maps to a domain that is already in `allowlist-domains.txt` or matches a wildcard pattern from `allowlist-proxy-domains.txt`, the daemon adds the IP to the active ipset on the fly. This cannot be exploited by the sandbox user: the internal lookup tables (DNS map, domain caches) are stored in a root-only directory (`/run/agent-blocked-internal`, mode 700) inaccessible to the sandbox shell, and `CAP_NET_RAW` is dropped so DNS responses cannot be spoofed. Set `SELF_HEALING_ENABLED=0` to disable self-healing entirely and use logging-only mode.

Discovery mode runs as the sandbox user with unrestricted egress and `NET_RAW` retained (for tcpdump). It is intended for supervised traffic observation only.

## Allowlist structure

Three `*.d/` directories hold the source-of-truth fragment files. `runme.sh build` assembles them into the `allowlist-*.txt` files that get baked into the image.

| Directory | Controls | Always included | Per-component |
|-----------|----------|-----------------|---------------|
| `allowlist-domains.d/` | Concrete FQDNs resolved to IPs at startup and every 60 s | `base.txt`, `custom.txt` | one file per component |
| `allowlist-proxy-domains.d/` | Wildcard patterns used by the self-healing daemon (e.g. `*.githubcopilot.com`) | `custom.txt` | `github-copilot.txt`, `kiro.txt`, `dynatrace.txt` |
| `allowlist-cidrs.d/` | Literal IP addresses and CIDR ranges added directly to ipset | `base.txt`, `custom.txt` | `github-copilot.txt` |

**Where to put your additions:**

| What you want to add | File to edit |
|----------------------|-------------|
| A domain needed by an enabled component (e.g. a missing Copilot endpoint) | `allowlist-domains.d/<component>.txt` |
| A domain not tied to any component (search engine, internal registry, MCP server) | `allowlist-domains.d/custom.txt` |
| A wildcard pattern for the self-healing daemon | `allowlist-proxy-domains.d/custom.txt` |
| A corporate proxy IP or narrow CIDR | `allowlist-cidrs.d/custom.txt` |

After editing any fragment file, run `./runme.sh build` to regenerate the image.

## Corporate customization points

- Edit `sandbox.conf` to enable only the components your team actually uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints, search engines) to `allowlist-domains.d/custom.txt`.
- If agent traffic must go through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and allow only the proxy IPs in `allowlist-cidrs.d/custom.txt`.
- The sandbox user identity (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP`) is detected automatically from the host user at runtime. No build-time args needed.
- Review the default values in `runme.sh`, especially `IMAGE_NAME` and `SSH_SCOPE_DIR`, before publishing this into a separate repository.

## Important notes

- Plain `iptables` cannot pre-resolve wildcard domains such as `*.githubcopilot.com` or `*.kiro.dev` into IP addresses. The self-healing daemon handles this reactively by auto-allowing IPs whose resolved domains match wildcard patterns in `allowlist-proxy-domains.d/`. An upstream proxy provides proactive enforcement if available.
- The per-component domain fragments are a practical baseline, not a guarantee that every future agent endpoint is covered. Use discovery mode to find gaps.
- The asset set is intentionally CLI-only and does not depend on VS Code dev containers.
- All optional components — including Kiro CLI — are controlled solely by `sandbox.conf`. There is no runtime auto-detection.
