# CLAUDE.md — Project rules for emak8s

## What this project is

A pure Emacs Lisp Kubernetes client and magit-style cluster browser.
Talks directly to the K8s API server over HTTPS — no kubectl, no
shelling out, no non-Elisp code.

## Current state (as of 2026-04-13)

Working features:
- 10 resource views: Pods, Deployments, StatefulSets, DaemonSets,
  Jobs, CronJobs, Services, Ingresses, ConfigMaps, Secrets
- magit-section UI with collapsible sections, transient dispatch
- Live watch via K8s streaming API (w key toggles)
- Pod log tailing with auto-refresh
- Delete resources (d key, with confirmation)
- Describe/inspect any resource (i key)
- Namespace filtering (N key, completing-read)
- Resource type switching (RET on Resource: line, transient popup)

### File layout

```
k8s-config.el    — Kubeconfig YAML parser, cluster/user/context structs
k8s-api.el       — HTTP client (GET/DELETE/text), retry logic, path registry
k8s-watch.el     — Persistent TLS streaming for K8s watch API events
k8s.el           — Shared UI infrastructure, all resource views except pods
k8s-pods.el      — Pods view (extends k8s.el with logs, container details)
reload.el        — Dev helper: byte-compiles + reloads all modules
test/            — ERT tests that hit the live microk8s cluster
```

### Key dependencies (Emacs packages)

- `magit-section` — section-based UI (collapsible, navigable)
- `transient` — popup menus (resource dispatch, ? key)
- `company` — in-buffer dropdown picker (used for some UI elements)
- `cl-lib` — ships with Emacs (cl-defstruct, etc.)

## Core constraints

- **Pure Elisp only.** Every line of code must be Emacs Lisp. No C
  modules, no Python scripts, no shell helpers, no FFI.

- **No shelling out.** Never use `call-process`, `start-process`,
  `shell-command`, or any variant to invoke external programs.

- **No kubectl dependency.** Do not assume kubectl is installed. Talk
  to the Kubernetes API server directly over HTTPS.

- **TLS via GnuTLS shim.** The original goal was pure Elisp TLS, but
  the elisp-stdlib TLS stack is too slow (X25519 takes >60s). The
  accepted workaround is using Emacs's built-in GnuTLS through
  `url-retrieve-synchronously` for regular API calls and
  `open-network-stream :type 'tls` for streaming watches. Everything
  above TLS (HTTP framing, auth, JSON, UI) is pure Elisp.

## Code style

- Always use `lexical-binding: t` in file headers.
- Use `cl-lib` (cl-defstruct, cl-loop, etc.) — ships with Emacs.
- Prefix all public symbols with `k8s-` (e.g., `k8s-list-pods`).
- Prefix internal/private symbols with `k8s--`.
- Use `defcustom` for user-facing configuration, `defvar` for state.
- Target Emacs 29+.

## UI conventions

- Follow magit's UI patterns: collapsible sections, single-key
  navigation, transient menus.
- All resource views derive from `magit-section-mode`.
- Buffer names: `*k8s:<view>*` (e.g., `*k8s:pods*`,
  `*k8s:deployments*`).
- Log buffers: `*k8s:logs:<ns>/<pod>[<container>]*`.
- Describe buffers: `*k8s:describe:<ns>/<name>*`.

### Keybinding conventions

| Key | Action | Scope |
|-----|--------|-------|
| `g` | Refresh (fresh API call) | All views |
| `q` | Quit | All views |
| `w` | Toggle watch (live updates) | All views |
| `d` | Delete resource | All views |
| `i` | Describe/inspect resource | All views |
| `N` | Switch namespace | All views |
| `?` | Transient dispatch menu | All views |
| `TAB` | Expand/collapse section | All views |
| `RET` | Smart action (header fields) or toggle | All views |
| `l` | View pod logs | Pods view only |
| `n/p` | Next/prev section | All views (magit) |

## Architecture patterns

### Adding a new resource type

Use the `k8s--define-view` macro in k8s.el. It generates the mode,
keymap, refresh function, and interactive command. You just provide:
1. A line inserter function (how to render one resource)
2. The API list function
3. Column headers

Add the API list function to k8s-api.el and add the list path to
`k8s--list-api-paths` (for watch support) and
`k8s--resource-api-paths` (for delete support).

### How the watch system works

1. `k8s-watch-start` opens a TLS connection with `open-network-stream`
2. Sends raw HTTP/1.1 GET with `?watch=true&resourceVersion=<V>`
3. Process filter accumulates streaming data, extracts JSON lines
4. Each event (ADDED/MODIFIED/DELETED) updates an in-memory hash table
5. Debounced re-render (0.3s) refreshes the buffer from the table
6. Auto-reconnects with exponential backoff on disconnect

### How API calls work

- `k8s-get` — synchronous GET via `url-retrieve-synchronously`, with
  retry on truncated responses. Returns parsed JSON alist.
- `k8s-delete` — synchronous DELETE via `url-retrieve-synchronously`.
- `k8s-get-text` — synchronous GET returning raw text (for logs).
- All add auth headers (Bearer token) and disable cert verification
  (self-signed cluster certs). Progress messages go to `*Messages*`.

## Development cluster

Local microk8s 1.31 instance. Kubeconfig at `test-kubeconfig.yaml`.

```bash
sudo microk8s kubectl ...       # run kubectl commands
sudo microk8s config            # get kubeconfig
```

Namespaces:
- `bookstore` — multi-tier app (deployments, statefulsets, services,
  ingress, configmaps, secrets, HPA, PDB, network policies, RBAC)
- `batch-jobs` — cronjob, parallel job, daemonset
- `networking-demo` — ExternalName service, headless service
- `playground` — disposable crash-dummy deployment for testing
  delete/restart
- `kube-system` — system components

## Testing

- Use `emacs --script` (NOT `--batch`) to run tests.
- Tests are ERT, in `test/` directory, named `test-<module>.el`.
- Tests hit the live microk8s cluster — that is the whole point.
- First API call after cold start may take 30-60s (TLS handshake).
  Subsequent calls are fast. Tests may flake on cold starts.

```bash
emacs --script test/test-k8s-config.el
emacs --script test/test-k8s-api.el
emacs --script test/test-k8s-pods.el
```

## Development workflow

```bash
# In Emacs:
M-x load-file RET /home/ubuntu/projects/emak8s/reload.el RET
# Then: M-x reload-k8s  (byte-compiles + reloads all modules)
# Then: M-x k8s
```

`reload-k8s` kills all `*k8s:*` buffers, byte-compiles everything,
unloads/reloads all features, and sets `k8s-kubeconfig-path`.

## User preferences

- Don't add Co-Authored-By lines to commits.
- Use `completing-read` for namespace selection.
- Use `transient` for resource type switching.
- Keep responses concise — the user is an expert Elisp developer.

## What not to do

- Do not add `Makefile`, `Dockerfile`, `shell scripts`, or any
  non-`.el` files (except docs/config).
- Do not vendor external Elisp packages.
- Do not use `url.el` for streaming — use `open-network-stream`
  with `:type 'tls` and process filters instead.
- Do not suggest shelling out to kubectl for anything.
