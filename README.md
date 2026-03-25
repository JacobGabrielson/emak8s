# emak8s

A pure Emacs Lisp Kubernetes client and magit-style cluster browser.

## Philosophy

**No shelling out. No kubectl. No non-Elisp code.**

emak8s talks directly to the Kubernetes API server over HTTPS using
ground-up pure Elisp networking — raw TCP sockets and a from-scratch
TLS 1.3 implementation. The entire stack, from TCP connect through
certificate verification to JSON parsing of API responses, runs inside
Emacs.

## Architecture

```
 emak8s (this repo)
   |
   |-- k8s-api.el          Kubernetes REST client (HTTP/JSON over TLS)
   |-- k8s-resource.el     Resource model: pods, deployments, services, ...
   |-- k8s-browse.el       Magit-style interactive cluster browser
   |-- k8s-diff.el         Resource diffing and change tracking
   |
   +-- elisp-stdlib (private, ../elisp-stdlib)
         |-- socket.el     Python-style TCP/UDP socket API
         +-- tls/           Pure Elisp TLS 1.3 (X25519, ChaCha20, RSA, X.509)
```

### Networking stack

The Kubernetes API server speaks HTTPS. We reach it through:

1. **socket.el** — a Python `socket` module workalike built on
   `make-network-process`. Provides `socket-connect`, `socket-send`,
   `socket-recv`, and friends.

2. **tls/*.el** — a complete TLS 1.3 client (handshake, record layer,
   X25519 key exchange, ChaCha20-Poly1305 / RSA, X.509 certificate
   parsing) layered on top of socket.el.

3. **k8s-api.el** (to be built) — HTTP/1.1 request framing, JSON
   encode/decode, Kubernetes authentication (ServiceAccount tokens,
   kubeconfig client certs), and watch/stream support — all on top of
   the TLS session.

### UI

The interactive browser follows magit's design language:

- **Section-based display** with collapsible headings
- **Single-key commands** for navigation and actions
- **Transient popup menus** for complex operations
- **Real-time updates** via the Kubernetes watch API
- **Context-sensitive actions** on the resource under point

Target views:

| View               | Description                                    |
|--------------------|------------------------------------------------|
| Cluster overview   | Namespaces, node status, resource quotas        |
| Namespace browser  | All resources in a namespace, grouped by kind   |
| Pod detail         | Containers, status, logs, events, exec          |
| Deployment detail  | Replicas, rollout status, revision history      |
| Service detail     | Endpoints, selectors, ingress routes            |
| YAML inspector     | Raw resource YAML with syntax highlighting      |
| Diff view          | Before/after comparison of resource changes     |
| Log viewer         | Streaming container logs with follow mode       |

## Status

Early development. The stdlib networking layer (socket + TLS) is
functional. The Kubernetes client layer is next.

## Requirements

- Emacs 29+ (for `make-network-process` enhancements and native JSON)
- A Kubernetes cluster with API server access
- `elisp-stdlib` on the load path (socket.el + tls/)

## Development cluster

A local microk8s cluster is set up for development and testing. It
includes:

- **bookstore** namespace — multi-tier app (frontend, API with
  sidecar, Redis StatefulSet, Postgres StatefulSet) with ConfigMaps,
  Secrets, Ingress, HPA, NetworkPolicy, PDB, RBAC
- **batch-jobs** namespace — CronJob, parallel Job, DaemonSet
- **networking-demo** namespace — ExternalName service, headless
  service, deny-all + allow-DNS NetworkPolicies
- **kube-system** — dashboard, metrics-server, CoreDNS, Calico, ingress controller

Access the API:

```bash
# Get the API server endpoint and CA cert
sudo microk8s config   # prints a full kubeconfig

# Or talk to it directly
APISERVER=$(sudo microk8s kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
TOKEN=$(sudo microk8s kubectl -n kube-system describe secret microk8s-dashboard-token | grep 'token:' | awk '{print $2}')
```

## License

GPL-3.0 — see [LICENSE](LICENSE).
