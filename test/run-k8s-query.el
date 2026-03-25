;;; test/run-k8s-query.el --- Interactive test: query microk8s cluster -*- lexical-binding: t -*-
;;
;; Evaluate this file in an interactive Emacs session:
;;   M-x load-file RET test/run-k8s-query.el RET
;;
;; Or from the command line (uses emacsclient which needs a running server):
;;   emacsclient -e '(load-file "test/run-k8s-query.el")'

;; Set up load paths
(let ((project-dir (file-name-directory
                    (or load-file-name buffer-file-name default-directory))))
  (add-to-list 'load-path (expand-file-name ".." project-dir))
  (add-to-list 'load-path (expand-file-name "../../elisp-stdlib" project-dir))
  (add-to-list 'load-path (expand-file-name "../../elisp-stdlib/tls" project-dir)))

(require 'k8s-config)
(require 'k8s-api)

(let* ((kubeconfig (expand-file-name "../test-kubeconfig.yaml"
                                      (file-name-directory
                                       (or load-file-name buffer-file-name))))
       (conn (k8s-connection-open kubeconfig)))
  (message "emak8s: connected to %s:%d (user: %s)"
           (k8s-connection-host conn)
           (k8s-connection-port conn)
           (k8s-user-name (k8s-connection-user conn)))

  ;; List namespaces
  (message "emak8s: querying namespaces...")
  (let ((namespaces (k8s-list-namespaces conn)))
    (message "emak8s: found %d namespaces:" (length namespaces))
    (seq-doseq (ns namespaces)
      (message "  - %s" (cdr (assq 'name (cdr (assq 'metadata ns)))))))

  ;; List pods in bookstore namespace
  (message "\nemak8s: querying pods in bookstore...")
  (let ((pods (k8s-list-pods conn "bookstore")))
    (message "emak8s: found %d pods:" (length pods))
    (seq-doseq (pod pods)
      (let* ((meta (cdr (assq 'metadata pod)))
             (status (cdr (assq 'status pod)))
             (phase (cdr (assq 'phase status))))
        (message "  - %-45s %s"
                 (cdr (assq 'name meta))
                 phase))))

  ;; List services
  (message "\nemak8s: querying services in bookstore...")
  (let ((svcs (k8s-list-services conn "bookstore")))
    (message "emak8s: found %d services:" (length svcs))
    (seq-doseq (svc svcs)
      (let* ((meta (cdr (assq 'metadata svc)))
             (spec (cdr (assq 'spec svc)))
             (type (cdr (assq 'type spec)))
             (cluster-ip (cdr (assq 'clusterIP spec))))
        (message "  - %-30s %-15s %s"
                 (cdr (assq 'name meta))
                 type
                 (or cluster-ip ""))))))

;;; run-k8s-query.el ends here
