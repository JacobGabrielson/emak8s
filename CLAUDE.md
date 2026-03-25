# CLAUDE.md — Project rules for emak8s

## Core constraints

- **Pure Elisp only.** Every line of code in this repo must be Emacs
  Lisp. No C modules, no Python scripts, no shell helpers, no FFI.

- **No shelling out.** Never use `call-process`, `start-process`,
  `shell-command`, `async-shell-command`, or any variant to invoke
  external programs. The entire point of this project is to avoid
  that.

- **No kubectl dependency.** Do not assume kubectl is installed. Do
  not parse kubectl output. Talk to the Kubernetes API server directly
  over HTTPS.

- **No GnuTLS.** Do not use Emacs's built-in GnuTLS bindings
  (`gnutls-boot`, `open-gnutls-stream`, `url-retrieve` over HTTPS,
  etc.). Use the pure Elisp TLS stack from elisp-stdlib instead.

## elisp-stdlib usage

The sibling repo `../elisp-stdlib` provides foundational libraries.
It is fine to `(require 'socket)`, `(require 'tls)`, and any module
under `tls/`. Add its paths to `load-path` — do not vendor/copy files
into this repo.

Available stdlib modules:
- `socket.el` — Python-like TCP/UDP socket API
- `tls/tls.el` — TLS 1.3 entry point (loads the full stack)
  - tls-session, tls-handshake, tls-record, tls-x509, tls-asn1,
    tls-rsa, tls-chacha, tls-sha, tls-x25519, tls-util

## Code style

- Always use `lexical-binding: t` in file headers.
- Use `cl-lib` (cl-defstruct, cl-loop, etc.) — it ships with Emacs.
- Prefix all public symbols with `k8s-` (e.g., `k8s-list-pods`,
  `k8s-browse`).
- Prefix internal/private symbols with `k8s--`.
- Use `defcustom` for user-facing configuration, `defvar` for
  internal state.
- Target Emacs 29+.

## UI conventions

- Follow magit's UI patterns: collapsible sections, single-key
  navigation, transient menus.
- Use `tabulated-list-mode` or a custom major mode derived from
  `special-mode` for read-only views.
- Buffer names: `*k8s:<view>*` (e.g., `*k8s:pods*`,
  `*k8s:cluster*`).

## Development cluster

A local microk8s instance is available for testing:

```bash
sudo microk8s kubectl ...       # run kubectl commands
sudo microk8s config            # get kubeconfig (API endpoint, CA, token)
```

Interesting namespaces to test against:
- `bookstore` — multi-tier app (deployments, statefulsets, services,
  ingress, configmaps, secrets, HPA, PDB, network policies, RBAC)
- `batch-jobs` — cronjob, parallel job, daemonset
- `networking-demo` — ExternalName service, headless service,
  network policies
- `kube-system` — system components (dashboard, metrics, DNS, CNI)

## Testing

Tests should be self-contained Elisp using `ert`. Test files go in a
`test/` directory and are named `test-<module>.el`. Tests may talk to
the local microk8s cluster — that is the whole point.

## What not to do

- Do not add `Makefile`, `Dockerfile`, `shell scripts`, or any
  non-`.el` files (except docs/config).
- Do not use `url.el` or `request.el` — build HTTP on top of the
  stdlib TLS session.
- Do not vendor external Elisp packages. Only depend on things
  shipped with Emacs and on elisp-stdlib.
