# emak8s

A pure Emacs Lisp Kubernetes client and magit-style cluster browser.

## Philosophy

**No shelling out. No kubectl. No non-Elisp code.**

emak8s talks directly to the Kubernetes API server over HTTPS. All
kubeconfig parsing, HTTP request framing, JSON handling, and UI
rendering is pure Elisp. TLS is provided by Emacs's built-in GnuTLS
support (requires Emacs compiled with GnuTLS, which is the default).

## What it does

`M-x k8s` opens a magit-style buffer showing your cluster's pods.
From there:

| Key | Action |
|-----|--------|
| `?` | Dispatch menu (all resource types) |
| `RET` on Resource: | Switch resource type (transient popup) |
| `RET` on Namespace: | Switch namespace |
| `N` | Switch namespace |
| `w` | Toggle live watch (auto-updates via K8s watch API) |
| `TAB` | Expand/collapse resource details |
| `d` | Delete resource (with confirmation) |
| `i` | Describe resource (full spec, status, events) |
| `l` | View pod logs (live tailing, multi-container) |
| `g` | Refresh |
| `q` | Quit |

### Resource views

10 resource types, each with tailored column layouts and expandable
details:

- **Workloads**: Pods, Deployments, StatefulSets, DaemonSets
- **Batch**: Jobs, CronJobs
- **Config & Network**: Services, Ingresses, ConfigMaps, Secrets

### Live updates

Press `w` to start a watch. emak8s opens a persistent streaming
connection to the K8s API and updates the display in real-time as
resources change — pod status transitions, deployments rolling out,
etc. The mode-line shows `[W]` when connected.

### Pod logs

Press `l` on a pod to tail its logs. Auto-refreshes every 2 seconds.
For multi-container pods, prompts for which container. `f` toggles
follow mode, `g` refreshes, `G` fetches full logs.

## Architecture

```
 emak8s (this repo)
   |
   |-- k8s-config.el       Kubeconfig parser (YAML subset)
   |-- k8s-api.el          K8s REST client (GET/DELETE, retry, streaming)
   |-- k8s-watch.el        Watch API (persistent TLS, chunked HTTP, event dispatch)
   |-- k8s.el              Shared UI, all resource views, transient dispatch
   |-- k8s-pods.el         Pods view (extends k8s.el with logs, container details)
   |
   +-- elisp-stdlib (../elisp-stdlib)
         |-- socket.el     Python-style TCP/UDP socket API
         +-- tls/          Pure Elisp TLS 1.3 (unused — too slow, see below)
```

### Networking

- **HTTP/JSON**: `url-retrieve-synchronously` (Emacs built-in) for
  regular API calls. Raw HTTP/1.1 over `open-network-stream` for
  streaming watches.
- **TLS**: Emacs's built-in GnuTLS bindings. The sibling repo has a
  pure Elisp TLS 1.3 stack but X25519 key exchange takes >60s in
  Emacs due to bignum dispatch overhead, so it's not practical yet.
- **JSON**: Emacs built-in `json.el`.

### UI

Built on `magit-section` for collapsible sections, `transient` for
popup menus, and `company` for in-buffer dropdowns. All views derive
from `magit-section-mode`.

## Requirements

- Emacs 29+ compiled with GnuTLS support (the default)
- `magit-section`, `transient`, `company` packages
- A Kubernetes cluster with API server access
- A kubeconfig file (set `k8s-kubeconfig-path` or `$KUBECONFIG`)

## Quick start

```elisp
;; Add to load-path
(add-to-list 'load-path "/path/to/emak8s")
(add-to-list 'load-path "/path/to/elisp-stdlib")
(setq k8s-kubeconfig-path "/path/to/kubeconfig")
(require 'k8s-pods)

;; Then:
;;   M-x k8s
```

Or use the included `reload.el` for development:

```
M-x load-file RET /path/to/emak8s/reload.el RET
M-x k8s
```

## Testing

Tests use ERT and talk to a real cluster:

```bash
emacs --script test/test-k8s-config.el   # YAML parser, kubeconfig loading
emacs --script test/test-k8s-api.el      # API calls against live cluster
emacs --script test/test-k8s-pods.el     # UI views, namespace filtering
```

## License

GPL-3.0 — see [LICENSE](LICENSE).
