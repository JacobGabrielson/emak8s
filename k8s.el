;;; k8s.el --- Kubernetes UI for Emacs -*- lexical-binding: t -*-
;;
;; Main entry point for emak8s.  Provides shared infrastructure
;; (connection, namespace filtering, faces, helpers) and a transient
;; dispatch menu for switching between resource views.
;;
;; Usage:
;;   M-x k8s

(require 'cl-lib)
(require 'magit-section)
(require 'transient)
(require 'k8s-config)
(require 'k8s-api)

;;; ---------------------------------------------------------------------------
;;; Customization

(defgroup k8s nil
  "Kubernetes UI for Emacs."
  :prefix "k8s-"
  :group 'tools)

(defcustom k8s-kubeconfig-path nil
  "Path to the kubeconfig file.
If nil, uses $KUBECONFIG or ~/.kube/config."
  :type '(choice (const nil) string)
  :group 'k8s)

;;; ---------------------------------------------------------------------------
;;; Internal state

(defvar-local k8s--connection nil
  "The `k8s-connection' for the current buffer.")

(defvar-local k8s--namespace nil
  "Current namespace filter.  nil means all namespaces.")

;;; ---------------------------------------------------------------------------
;;; Faces

(defface k8s-section-heading
  '((t :inherit magit-section-heading))
  "Face for section headings."
  :group 'k8s)

(defface k8s-resource-name
  '((t :inherit magit-branch-local))
  "Face for resource names."
  :group 'k8s)

(defface k8s-namespace
  '((t :inherit magit-tag))
  "Face for namespace names."
  :group 'k8s)

(defface k8s-status-running
  '((t :inherit success))
  "Face for Running/Active status."
  :group 'k8s)

(defface k8s-status-pending
  '((t :inherit warning))
  "Face for Pending status."
  :group 'k8s)

(defface k8s-status-failed
  '((t :inherit error))
  "Face for Failed status."
  :group 'k8s)

(defface k8s-status-other
  '((t :inherit shadow))
  "Face for other statuses."
  :group 'k8s)

(defface k8s-dim
  '((t :inherit shadow))
  "Face for secondary information."
  :group 'k8s)

;;; ---------------------------------------------------------------------------
;;; Connection helpers

(defun k8s--resolve-kubeconfig ()
  "Return the kubeconfig path to use."
  (or k8s-kubeconfig-path
      (getenv "KUBECONFIG")
      (expand-file-name "~/.kube/config")))

(defun k8s--ensure-connection ()
  "Return the current buffer's connection, opening one if needed."
  (or k8s--connection
      (setq k8s--connection
            (k8s-connection-open (k8s--resolve-kubeconfig)))))

;;; ---------------------------------------------------------------------------
;;; Shared helpers

(defun k8s--resource-name (resource)
  "Return metadata.name from RESOURCE alist."
  (cdr (assq 'name (cdr (assq 'metadata resource)))))

(defun k8s--resource-namespace (resource)
  "Return metadata.namespace from RESOURCE alist."
  (cdr (assq 'namespace (cdr (assq 'metadata resource)))))

(defun k8s--resource-creation-time (resource)
  "Return metadata.creationTimestamp from RESOURCE."
  (cdr (assq 'creationTimestamp (cdr (assq 'metadata resource)))))

(defun k8s--resource-labels (resource)
  "Return metadata.labels alist from RESOURCE."
  (cdr (assq 'labels (cdr (assq 'metadata resource)))))

(defun k8s--age-string (timestamp)
  "Convert ISO TIMESTAMP to a human-readable age string."
  (if (null timestamp)
      "?"
    (let* ((then (float-time (date-to-time timestamp)))
           (now (float-time))
           (secs (- now then)))
      (cond
       ((< secs 60)       (format "%ds" (truncate secs)))
       ((< secs 3600)     (format "%dm" (truncate (/ secs 60))))
       ((< secs 86400)    (format "%dh" (truncate (/ secs 3600))))
       (t                 (format "%dd" (truncate (/ secs 86400))))))))

(defun k8s--phase-face (phase)
  "Return the face for PHASE string."
  (pcase phase
    ("Running"   'k8s-status-running)
    ("Succeeded" 'k8s-status-running)
    ("Active"    'k8s-status-running)
    ("Bound"     'k8s-status-running)
    ("Available" 'k8s-status-running)
    ("Pending"   'k8s-status-pending)
    ("Failed"    'k8s-status-failed)
    (_           'k8s-status-other)))

(defun k8s--group-by-namespace (resources)
  "Group RESOURCES (a vector) into an alist of (NAMESPACE . LIST)."
  (let ((table (make-hash-table :test 'equal)))
    (seq-doseq (r resources)
      (let ((ns (or (k8s--resource-namespace r) "<cluster>")))
        (puthash ns (cons r (gethash ns table)) table)))
    (let (result)
      (maphash (lambda (ns items)
                 (push (cons ns (nreverse items)) result))
               table)
      (sort result (lambda (a b) (string< (car a) (car b)))))))

;;; ---------------------------------------------------------------------------
;;; Header / namespace display

(defun k8s--insert-header (resource-type)
  "Insert the header with cluster info and current RESOURCE-TYPE."
  (let* ((conn (k8s--ensure-connection))
         (host (k8s-connection-host conn))
         (port (k8s-connection-port conn))
         (user (k8s-user-name (k8s-connection-user conn))))
    (insert (propertize "Cluster:   " 'font-lock-face 'k8s-dim)
            (format "%s:%d" host port)
            "\n")
    (insert (propertize "User:      " 'font-lock-face 'k8s-dim)
            user
            "\n")
    (insert (propertize "Resource:  " 'font-lock-face 'k8s-dim)
            resource-type
            "\n")
    (insert (propertize "Namespace: " 'font-lock-face 'k8s-dim)
            (or k8s--namespace
                (propertize "all" 'font-lock-face 'k8s-dim))
            "\n\n")))

(defun k8s--insert-namespace-heading (ns count)
  "Insert a namespace section heading for NS with COUNT items."
  (magit-insert-heading
    (format "%s (%d)\n"
            (propertize ns 'font-lock-face 'k8s-namespace)
            count)))

;;; ---------------------------------------------------------------------------
;;; Namespace narrowing

(defun k8s-set-namespace (namespace)
  "Filter the current view to NAMESPACE.  Empty string means all."
  (interactive
   (let* ((conn (k8s--ensure-connection))
          (namespaces (k8s-list-namespaces conn))
          (names (cons "all"
                       (sort (mapcar #'k8s--resource-name
                                     (append namespaces nil))
                             #'string<))))
     (list (completing-read "Namespace: " names nil t))))
  (setq k8s--namespace (if (string= namespace "all") nil namespace))
  (revert-buffer))

;;; ---------------------------------------------------------------------------
;;; Shared keymap fragment

(defvar-keymap k8s-common-map
  "N" #'k8s-set-namespace
  "?" #'k8s-dispatch
  "g" #'revert-buffer
  "q" #'quit-window)

;;; ---------------------------------------------------------------------------
;;; Transient dispatch

(autoload 'k8s-pods "k8s-pods" nil t)

(transient-define-prefix k8s-dispatch ()
  "Switch between Kubernetes resource views."
  ["Resource views"
   ("p" "Pods"        k8s-pods)
   ("d" "Deployments" k8s-deployments)
   ("s" "Services"    k8s-services)]
  ["Filter"
   ("N" "Namespace"   k8s-set-namespace)]
  ["Navigate"
   ("g" "Refresh"     revert-buffer)
   ("q" "Quit"        quit-window)])

;;;###autoload
(defun k8s ()
  "Main entry point for emak8s.  Shows pods by default."
  (interactive)
  (k8s-pods))

;;; ---------------------------------------------------------------------------
;;; Deployments view

(defun k8s--deployment-ready-string (deploy)
  "Return READY string like 2/3 for DEPLOY."
  (let* ((status (cdr (assq 'status deploy)))
         (replicas (or (cdr (assq 'replicas status)) 0))
         (ready (or (cdr (assq 'readyReplicas status)) 0)))
    (format "%d/%d" ready replicas)))

(defun k8s--deployment-image (deploy)
  "Return the first container image from DEPLOY spec."
  (let* ((spec (cdr (assq 'spec deploy)))
         (tmpl (cdr (assq 'template spec)))
         (pod-spec (cdr (assq 'spec tmpl)))
         (containers (cdr (assq 'containers pod-spec))))
    (when (and containers (> (length containers) 0))
      (cdr (assq 'image (aref containers 0))))))

(defun k8s--insert-deployment-line (deploy)
  "Insert a single deployment summary line."
  (let* ((name (k8s--resource-name deploy))
         (ready (k8s--deployment-ready-string deploy))
         (age (k8s--age-string (k8s--resource-creation-time deploy)))
         (image (or (k8s--deployment-image deploy) "")))
    (magit-insert-section (deployment deploy t)
      (magit-insert-heading
        (format "  %-42s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                ready
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize image 'font-lock-face 'k8s-dim)))
      ;; Detail body
      (k8s--insert-deployment-details deploy))))

(defun k8s--insert-deployment-details (deploy)
  "Insert expanded details for DEPLOY."
  (let* ((spec (cdr (assq 'spec deploy)))
         (status (cdr (assq 'status deploy)))
         (strategy (or (cdr (assq 'type (cdr (assq 'strategy spec)))) "?"))
         (replicas (or (cdr (assq 'replicas spec)) 0))
         (updated (or (cdr (assq 'updatedReplicas status)) 0))
         (available (or (cdr (assq 'availableReplicas status)) 0))
         (labels (k8s--resource-labels deploy))
         (selector (cdr (assq 'matchLabels (cdr (assq 'selector spec))))))
    (insert (propertize (format "    Strategy:  %s\n" strategy)
                        'font-lock-face 'k8s-dim))
    (insert (propertize (format "    Replicas:  %d desired, %d updated, %d available\n"
                                replicas updated available)
                        'font-lock-face 'k8s-dim))
    (when selector
      (insert (propertize "    Selector:  " 'font-lock-face 'k8s-dim))
      (let ((first t))
        (dolist (pair selector)
          (unless first (insert (propertize "               " 'font-lock-face 'k8s-dim)))
          (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                              'font-lock-face 'k8s-dim))
          (setq first nil))))
    (when labels
      (insert (propertize "    Labels:    " 'font-lock-face 'k8s-dim))
      (let ((first t))
        (dolist (pair labels)
          (unless first (insert (propertize "               " 'font-lock-face 'k8s-dim)))
          (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                              'font-lock-face 'k8s-dim))
          (setq first nil))))
    (insert "\n")))

(defun k8s--deployments-refresh ()
  "Refresh the deployments buffer."
  (let* ((inhibit-read-only t)
         (conn (k8s--ensure-connection))
         (deploys (k8s-list-deployments conn k8s--namespace))
         (grouped (k8s--group-by-namespace deploys)))
    (erase-buffer)
    (magit-insert-section (k8s-deployments-root)
      (k8s--insert-header "Deployments")
      (insert (propertize
               (format "  %-42s %-10s %-6s %s\n"
                       "NAME" "READY" "AGE" "IMAGE")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (dolist (group grouped)
        (magit-insert-section (namespace (car group))
          (k8s--insert-namespace-heading (car group) (length (cdr group)))
          (dolist (deploy (cdr group))
            (k8s--insert-deployment-line deploy))
          (insert "\n"))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

(defvar-keymap k8s-deployments-mode-map
  :parent magit-section-mode-map)

;; Merge shared keys
(map-keymap (lambda (key def)
              (keymap-set k8s-deployments-mode-map (key-description (vector key)) def))
            k8s-common-map)

(define-derived-mode k8s-deployments-mode magit-section-mode "K8s:Deployments"
  "Major mode for viewing Kubernetes deployments."
  :interactive nil
  :group 'k8s
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (k8s--deployments-refresh))))

;;;###autoload
(defun k8s-deployments ()
  "Display deployments in the current Kubernetes cluster."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:deployments*")))
    (with-current-buffer buf
      (k8s-deployments-mode)
      (k8s--ensure-connection)
      (k8s--deployments-refresh))
    (pop-to-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; Services view

(defun k8s--service-type (svc)
  "Return the service type (ClusterIP, NodePort, etc.)."
  (or (cdr (assq 'type (cdr (assq 'spec svc)))) "ClusterIP"))

(defun k8s--service-cluster-ip (svc)
  "Return the cluster IP of SVC."
  (or (cdr (assq 'clusterIP (cdr (assq 'spec svc)))) ""))

(defun k8s--service-ports-string (svc)
  "Return a string summarizing the ports of SVC."
  (let ((ports (cdr (assq 'ports (cdr (assq 'spec svc))))))
    (if (and ports (> (length ports) 0))
        (mapconcat
         (lambda (p)
           (let ((port (cdr (assq 'port p)))
                 (proto (or (cdr (assq 'protocol p)) "TCP"))
                 (target (cdr (assq 'targetPort p)))
                 (node-port (cdr (assq 'nodePort p))))
             (if node-port
                 (format "%s:%s→%s/%s" port node-port target proto)
               (format "%s→%s/%s" port target proto))))
         (append ports nil) ", ")
      "")))

(defun k8s--insert-service-line (svc)
  "Insert a single service summary line."
  (let* ((name (k8s--resource-name svc))
         (type (k8s--service-type svc))
         (cluster-ip (k8s--service-cluster-ip svc))
         (ports (k8s--service-ports-string svc))
         (age (k8s--age-string (k8s--resource-creation-time svc))))
    (magit-insert-section (service svc t)
      (magit-insert-heading
        (format "  %-35s %-15s %-18s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize type 'font-lock-face (k8s--phase-face
                                                  (if (string= type "ClusterIP")
                                                      "Active" type)))
                cluster-ip
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize ports 'font-lock-face 'k8s-dim)))
      ;; Detail body
      (k8s--insert-service-details svc))))

(defun k8s--insert-service-details (svc)
  "Insert expanded details for SVC."
  (let* ((spec (cdr (assq 'spec svc)))
         (selector (cdr (assq 'selector spec)))
         (labels (k8s--resource-labels svc))
         (external-ips (cdr (assq 'externalIPs spec)))
         (external-name (cdr (assq 'externalName spec))))
    (when selector
      (insert (propertize "    Selector:  " 'font-lock-face 'k8s-dim))
      (let ((first t))
        (dolist (pair selector)
          (unless first (insert (propertize "               " 'font-lock-face 'k8s-dim)))
          (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                              'font-lock-face 'k8s-dim))
          (setq first nil))))
    (when external-name
      (insert (propertize (format "    External:  %s\n" external-name)
                          'font-lock-face 'k8s-dim)))
    (when external-ips
      (insert (propertize (format "    ExternalIPs: %s\n"
                                  (mapconcat #'identity
                                             (append external-ips nil) ", "))
                          'font-lock-face 'k8s-dim)))
    (when labels
      (insert (propertize "    Labels:    " 'font-lock-face 'k8s-dim))
      (let ((first t))
        (dolist (pair labels)
          (unless first (insert (propertize "               " 'font-lock-face 'k8s-dim)))
          (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                              'font-lock-face 'k8s-dim))
          (setq first nil))))
    (insert "\n")))

(defun k8s--services-refresh ()
  "Refresh the services buffer."
  (let* ((inhibit-read-only t)
         (conn (k8s--ensure-connection))
         (svcs (k8s-list-services conn k8s--namespace))
         (grouped (k8s--group-by-namespace svcs)))
    (erase-buffer)
    (magit-insert-section (k8s-services-root)
      (k8s--insert-header "Services")
      (insert (propertize
               (format "  %-35s %-15s %-18s %-6s %s\n"
                       "NAME" "TYPE" "CLUSTER-IP" "AGE" "PORTS")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (dolist (group grouped)
        (magit-insert-section (namespace (car group))
          (k8s--insert-namespace-heading (car group) (length (cdr group)))
          (dolist (svc (cdr group))
            (k8s--insert-service-line svc))
          (insert "\n"))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

(defvar-keymap k8s-services-mode-map
  :parent magit-section-mode-map)

(map-keymap (lambda (key def)
              (keymap-set k8s-services-mode-map (key-description (vector key)) def))
            k8s-common-map)

(define-derived-mode k8s-services-mode magit-section-mode "K8s:Services"
  "Major mode for viewing Kubernetes services."
  :interactive nil
  :group 'k8s
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (k8s--services-refresh))))

;;;###autoload
(defun k8s-services ()
  "Display services in the current Kubernetes cluster."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:services*")))
    (with-current-buffer buf
      (k8s-services-mode)
      (k8s--ensure-connection)
      (k8s--services-refresh))
    (pop-to-buffer buf)))

(provide 'k8s)
;;; k8s.el ends here
