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

(defun k8s-get (conn path)
  "Perform a GET request to PATH on the K8s API via CONN.
Returns the parsed JSON response as an alist."
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
    (with-current-buffer (url-retrieve-synchronously url t nil 60)
      (goto-char (point-min))
      ;; Skip HTTP headers
      (re-search-forward "\n\n" nil t)
      ;; Parse JSON
      (let* ((json-object-type 'alist)
             (json-array-type 'vector)
             (json-key-type 'symbol)
             (body (json-read)))
        (kill-buffer)
        body))))

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

(defun k8s-get-resource (conn path)
  "GET a single resource at PATH via CONN."
  (k8s-get conn path))

;;; ---------------------------------------------------------------------------
;;; Error condition

(define-error 'k8s-api-error "Kubernetes API error")

(provide 'k8s-api)
;;; k8s-api.el ends here
