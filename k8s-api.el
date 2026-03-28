;;; k8s-api.el --- Pure Elisp Kubernetes API client -*- lexical-binding: t -*-
;;
;; Talks to the Kubernetes API server over HTTPS.  Everything above the
;; TLS layer is pure Elisp: kubeconfig parsing, auth, JSON handling,
;; resource helpers.
;;
;; TLS transport: currently uses Emacs's built-in GnuTLS via `url.el'
;; because the pure Elisp TLS stack (elisp-stdlib) is too slow for
;; practical use — X25519 key exchange takes >60s due to Emacs bignum
;; performance.  Once the stdlib gains faster field arithmetic (or we
;; use Emacs's native bignums more effectively), switch to
;; `tls-session-open'.
;;
;; Usage:
;;   (setq conn (k8s-connection-open "/path/to/kubeconfig"))
;;   (k8s-get conn "/api/v1/namespaces")

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'url-http)
(require 'gnutls)
(require 'k8s-config)

;;; ---------------------------------------------------------------------------
;;; Connection struct

(cl-defstruct (k8s-connection (:constructor k8s-connection--new) (:copier nil))
  "Connection parameters for a Kubernetes API server."
  config            ; k8s-config
  cluster           ; k8s-cluster
  user              ; k8s-user
  server            ; string "https://host:port"
  host              ; string
  port              ; integer
  ca-file)          ; temp file path for the CA cert, or nil

;;; ---------------------------------------------------------------------------
;;; K8s API

(defun k8s-connection-open (kubeconfig-path)
  "Open a connection to the K8s cluster defined in KUBECONFIG-PATH.
Returns a `k8s-connection' struct."
  (let* ((config (k8s-config-load kubeconfig-path))
         (cluster (k8s-config-resolve-cluster config))
         (user (k8s-config-resolve-user config))
         (server (k8s-cluster-server cluster))
         (host-port (k8s--parse-url server))
         ;; Write CA cert to temp file and add to GnuTLS trust store
         (ca-pem (k8s-cluster-ca-cert-pem cluster))
         (ca-file (when ca-pem
                    (let ((f (make-temp-file "k8s-ca-" nil ".pem")))
                      (with-temp-file f
                        (set-buffer-multibyte nil)
                        (insert ca-pem))
                      (cl-pushnew f gnutls-trustfiles :test #'string=)
                      f))))
    (k8s-connection--new
     :config config
     :cluster cluster
     :user user
     :server server
     :host (car host-port)
     :port (cdr host-port)
     :ca-file ca-file)))

(defun k8s--do-get (url)
  "Perform a single GET to URL, return parsed JSON or nil on failure."
  (let ((buf (url-retrieve-synchronously url t nil 60)))
    (when buf
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (when (re-search-forward "\n\n" nil t)
              (condition-case nil
                  (let* ((json-object-type 'alist)
                         (json-array-type 'vector)
                         (json-key-type 'symbol))
                    (json-read))
                (json-end-of-file nil))))
        (kill-buffer buf)))))

(defun k8s-get (conn path)
  "Perform a GET request to PATH on the K8s API via CONN.
Returns the parsed JSON response as an alist.
Retries once on transient failures (truncated response, timeout)."
  (let* ((server (k8s-connection-server conn))
         (url (concat server path))
         (user (k8s-connection-user conn))
         ;; Set auth headers
         (url-request-extra-headers
          (append
           (when (k8s-user-token user)
             (list (cons "Authorization"
                         (format "Bearer %s" (k8s-user-token user)))))
           '(("Accept" . "application/json")
             ("User-Agent" . "emak8s/0.1"))))
         ;; Disable cert verification for self-signed cluster certs
         (gnutls-verify-error nil)
         (network-security-level 'low)
         (url-http-attempt-keepalives nil)
         (url-gateway-method 'native))
    (or (k8s--do-get url)
        ;; Retry once on failure
        (k8s--do-get url)
        (error "K8s API request failed: %s" path))))

(defun k8s-get-text (conn path)
  "Perform a GET request to PATH on the K8s API via CONN.
Returns the raw response body as a string (for non-JSON endpoints like logs)."
  (let* ((server (k8s-connection-server conn))
         (url (concat server path))
         (user (k8s-connection-user conn))
         (url-request-extra-headers
          (append
           (when (k8s-user-token user)
             (list (cons "Authorization"
                         (format "Bearer %s" (k8s-user-token user)))))
           '(("Accept" . "text/plain")
             ("User-Agent" . "emak8s/0.1"))))
         (gnutls-verify-error nil)
         (network-security-level 'low)
         (url-http-attempt-keepalives nil)
         (url-gateway-method 'native)
         (buf (url-retrieve-synchronously url t nil 60)))
    (when buf
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (when (re-search-forward "\n\n" nil t)
              (buffer-substring-no-properties (point) (point-max))))
        (kill-buffer buf)))))

(defun k8s-pod-logs (conn namespace name &optional tail-lines container)
  "Fetch logs for pod NAME in NAMESPACE via CONN.
Returns log text as a string.  TAIL-LINES limits to last N lines.
CONTAINER specifies which container (required for multi-container pods)."
  (let* ((params (list (format "tailLines=%d" (or tail-lines 100))))
         (_ (when container
              (push (format "container=%s" container) params)))
         (query (mapconcat #'identity params "&"))
         (path (format "/api/v1/namespaces/%s/pods/%s/log?%s"
                       namespace name query)))
    (or (k8s-get-text conn path) "")))

;;; ---------------------------------------------------------------------------
;;; Convenience functions

(defun k8s-list-namespaces (conn)
  "List all namespaces via CONN.  Returns a vector of namespace alists."
  (cdr (assq 'items (k8s-get conn "/api/v1/namespaces"))))

(defun k8s-list-pods (conn &optional namespace)
  "List pods via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/pods" namespace)
                "/api/v1/pods")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-deployments (conn &optional namespace)
  "List deployments via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/deployments" namespace)
                "/apis/apps/v1/deployments")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-services (conn &optional namespace)
  "List services via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/services" namespace)
                "/api/v1/services")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-statefulsets (conn &optional namespace)
  "List statefulsets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/statefulsets" namespace)
                "/apis/apps/v1/statefulsets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-daemonsets (conn &optional namespace)
  "List daemonsets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/daemonsets" namespace)
                "/apis/apps/v1/daemonsets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-jobs (conn &optional namespace)
  "List jobs via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/batch/v1/namespaces/%s/jobs" namespace)
                "/apis/batch/v1/jobs")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-cronjobs (conn &optional namespace)
  "List cronjobs via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/batch/v1/namespaces/%s/cronjobs" namespace)
                "/apis/batch/v1/cronjobs")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-configmaps (conn &optional namespace)
  "List configmaps via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/configmaps" namespace)
                "/api/v1/configmaps")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-secrets (conn &optional namespace)
  "List secrets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/secrets" namespace)
                "/api/v1/secrets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-ingresses (conn &optional namespace)
  "List ingresses via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/networking.k8s.io/v1/namespaces/%s/ingresses"
                          namespace)
                "/apis/networking.k8s.io/v1/ingresses")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-get-resource (conn path)
  "GET a single resource at PATH via CONN."
  (k8s-get conn path))

;;; ---------------------------------------------------------------------------
;;; Error condition

(define-error 'k8s-api-error "Kubernetes API error")

(provide 'k8s-api)
;;; k8s-api.el ends here
