;;; k8s.el --- Kubernetes UI for Emacs -*- lexical-binding: t -*-
;;
;; Main entry point for emak8s.  Provides shared infrastructure
;; (connection, namespace filtering, faces, helpers) and views for
;; all common Kubernetes resource types.
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
    ("Complete"  'k8s-status-running)
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

(defun k8s--insert-labels (labels indent)
  "Insert LABELS alist with INDENT string prefix."
  (when labels
    (insert (propertize (concat indent "Labels:    ") 'font-lock-face 'k8s-dim))
    (let ((first t)
          (pad (make-string (+ (length indent) 11) ?\s)))
      (dolist (pair labels)
        (unless first (insert (propertize pad 'font-lock-face 'k8s-dim)))
        (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                            'font-lock-face 'k8s-dim))
        (setq first nil)))))

(defun k8s--insert-selector (selector indent)
  "Insert SELECTOR alist with INDENT string prefix."
  (when selector
    (insert (propertize (concat indent "Selector:  ") 'font-lock-face 'k8s-dim))
    (let ((first t)
          (pad (make-string (+ (length indent) 11) ?\s)))
      (dolist (pair selector)
        (unless first (insert (propertize pad 'font-lock-face 'k8s-dim)))
        (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                            'font-lock-face 'k8s-dim))
        (setq first nil)))))

(defun k8s--first-container-image (resource)
  "Return the first container image from a workload RESOURCE spec."
  (let* ((spec (cdr (assq 'spec resource)))
         (tmpl (cdr (assq 'template spec)))
         (pod-spec (cdr (assq 'spec tmpl)))
         (containers (cdr (assq 'containers pod-spec))))
    (when (and containers (> (length containers) 0))
      (cdr (assq 'image (aref containers 0))))))

;;; ---------------------------------------------------------------------------
;;; Resource type registry

(defvar k8s--resource-types nil
  "Alist of (DISPLAY-NAME . COMMAND) for available resource views.")

;;; ---------------------------------------------------------------------------
;;; Company-based popup picker (for dynamic lists like namespaces)

(require 'company)

(defvar-local k8s--picker-candidates nil "Candidates for current picker.")
(defvar-local k8s--picker-callback nil "Callback for current picker.")
(defvar-local k8s--picker-active nil "Non-nil while a picker is open.")

(defun k8s--picker-backend (command &optional arg &rest _ignored)
  "Company backend for k8s popup pickers."
  (interactive (list 'interactive))
  (cl-case command
    (interactive (company-begin-backend 'k8s--picker-backend))
    (prefix (when k8s--picker-active ""))
    (candidates (all-completions (or arg "") k8s--picker-candidates))
    (sorted t)
    (no-cache t)
    (post-completion
     (let ((cb k8s--picker-callback)
           (buf (current-buffer)))
       (k8s--picker-cleanup)
       ;; Undo the text company inserted
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (revert-buffer nil t))))
       (when cb (funcall cb arg))))))

(defun k8s--picker-cleanup ()
  "Restore buffer state after picker closes."
  (setq k8s--picker-active nil
        k8s--picker-candidates nil
        k8s--picker-callback nil)
  (setq buffer-read-only t))

(defun k8s--pick (candidates callback)
  "Show a company dropdown with CANDIDATES, call CALLBACK with selection."
  (setq k8s--picker-candidates candidates
        k8s--picker-callback callback
        k8s--picker-active t)
  ;; Company needs the buffer to be writable
  (setq buffer-read-only nil)
  ;; Restore read-only if user cancels (C-g)
  (add-hook 'company-completion-cancelled-hook #'k8s--picker-cleanup nil t)
  (add-hook 'company-after-completion-hook
            (lambda (&rest _) (remove-hook 'company-completion-cancelled-hook
                                           #'k8s--picker-cleanup t))
            nil t)
  (company-mode 1)
  ;; Defer to let Emacs process the read-only change before company starts
  (run-at-time 0 nil
               (lambda ()
                 (let ((company-minimum-prefix-length 0)
                       (company-backends '(k8s--picker-backend)))
                   (company-complete)))))

;;; ---------------------------------------------------------------------------
;;; Resource switching (transient popup)

(transient-define-prefix k8s-switch-resource ()
  "Switch to a different resource view."
  [["Workloads"
    ("p" "Pods"         k8s-pods)
    ("d" "Deployments"  k8s-deployments)
    ("S" "StatefulSets" k8s-statefulsets)
    ("D" "DaemonSets"   k8s-daemonsets)]
   ["Batch"
    ("j" "Jobs"         k8s-jobs)
    ("c" "CronJobs"     k8s-cronjobs)]
   ["Config & Network"
    ("s" "Services"     k8s-services)
    ("i" "Ingresses"    k8s-ingresses)
    ("m" "ConfigMaps"   k8s-configmaps)
    ("x" "Secrets"      k8s-secrets)]])

;;; ---------------------------------------------------------------------------
;;; Namespace switching (company dropdown)

(defun k8s-set-namespace ()
  "Switch namespace via company dropdown at point."
  (interactive)
  (let* ((conn (k8s--ensure-connection))
         (namespaces (k8s-list-namespaces conn))
         (names (cons "all"
                      (sort (mapcar #'k8s--resource-name
                                    (append namespaces nil))
                            #'string<))))
    (k8s--pick names
              (lambda (choice)
                (setq k8s--namespace
                      (unless (string= choice "all") choice))
                (revert-buffer)))))

;;; ---------------------------------------------------------------------------
;;; Describe resource

(defun k8s--describe-value (value indent)
  "Recursively format VALUE as readable text at INDENT level."
  (cond
   ((null value) (insert "nil\n"))
   ((stringp value) (insert value "\n"))
   ((numberp value) (insert (format "%s\n" value)))
   ((eq value t) (insert "true\n"))
   ((vectorp value)
    (insert "\n")
    (seq-doseq (item (append value nil))
      (insert (make-string indent ?\s) "- ")
      (k8s--describe-value item (+ indent 2))))
   ((and (listp value) (consp (car value)))
    ;; alist
    (insert "\n")
    (dolist (pair value)
      (let ((key (format "%s" (car pair))))
        (insert (make-string indent ?\s)
                (propertize (concat key ": ") 'font-lock-face 'k8s-section-heading))
        (k8s--describe-value (cdr pair) (+ indent 2)))))
   (t (insert (format "%S\n" value)))))

(defun k8s--describe-insert-events (conn ns name)
  "Insert events for resource NAME in NS."
  (let ((events (condition-case nil
                    (k8s-list-events conn ns
                                    (format "involvedObject.name=%s" name))
                  (error nil))))
    (when (and events (> (length events) 0))
      (insert "\n"
              (propertize "Events:\n" 'font-lock-face 'k8s-section-heading))
      (insert (propertize
               (format "  %-8s %-8s %-25s %-10s %s\n"
                       "LAST" "COUNT" "SOURCE" "TYPE" "MESSAGE")
               'font-lock-face 'k8s-dim))
      (seq-doseq (ev (append events nil))
        (let* ((last-time (or (cdr (assq 'lastTimestamp ev)) ""))
               (count (or (cdr (assq 'count ev)) 1))
               (source (cdr (assq 'source ev)))
               (component (or (cdr (assq 'component source)) ""))
               (type (or (cdr (assq 'type ev)) ""))
               (message (or (cdr (assq 'message ev)) "")))
          (insert (format "  %-8s %-8s %-25s %-10s %s\n"
                          (k8s--age-string last-time)
                          count
                          (truncate-string-to-width component 25)
                          (propertize type 'font-lock-face
                                      (if (string= type "Warning")
                                          'k8s-status-failed
                                        'k8s-status-running))
                          message)))))))

(defun k8s-describe ()
  "Describe the resource at point — show full details and events."
  (interactive)
  (let ((section (magit-current-section)))
    (unless (and section (oref section value)
                 (listp (oref section value))
                 (assq 'metadata (oref section value)))
      (user-error "Not on a resource"))
    (let* ((resource (oref section value))
           (meta (cdr (assq 'metadata resource)))
           (name (cdr (assq 'name meta)))
           (ns (or (cdr (assq 'namespace meta)) ""))
           (kind (or (cdr (assq 'kind resource))
                     (symbol-name (oref section type))))
           (conn (k8s--ensure-connection))
           (buf (get-buffer-create
                 (format "*k8s:describe:%s/%s*"
                         (if (string= ns "") "cluster" ns) name))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          ;; Header
          (insert (propertize (format "%s: %s" kind name)
                              'font-lock-face 'k8s-resource-name)
                  "\n")
          (when (not (string= ns ""))
            (insert (propertize "Namespace: " 'font-lock-face 'k8s-dim)
                    ns "\n"))
          (insert "\n")
          ;; Metadata
          (insert (propertize "Metadata:\n" 'font-lock-face 'k8s-section-heading))
          (dolist (key '(name namespace uid creationTimestamp))
            (let ((val (cdr (assq key meta))))
              (when val
                (insert (propertize (format "  %s: " key) 'font-lock-face 'k8s-dim)
                        (format "%s\n" val)))))
          (let ((labels (cdr (assq 'labels meta))))
            (when labels
              (insert (propertize "  labels:\n" 'font-lock-face 'k8s-dim))
              (dolist (pair labels)
                (insert (propertize "    " 'font-lock-face 'k8s-dim)
                        (format "%s: %s\n" (car pair) (cdr pair))))))
          (let ((annotations (cdr (assq 'annotations meta))))
            (when annotations
              (insert (propertize "  annotations:\n" 'font-lock-face 'k8s-dim))
              (dolist (pair annotations)
                (insert (propertize "    " 'font-lock-face 'k8s-dim)
                        (format "%s: %s\n" (car pair) (cdr pair))))))
          ;; Spec
          (let ((spec (cdr (assq 'spec resource))))
            (when spec
              (insert "\n"
                      (propertize "Spec:" 'font-lock-face 'k8s-section-heading))
              (k8s--describe-value spec 2)))
          ;; Status
          (let ((status (cdr (assq 'status resource))))
            (when status
              (insert "\n"
                      (propertize "Status:" 'font-lock-face 'k8s-section-heading))
              (k8s--describe-value status 2)))
          ;; Events
          (when (not (string= ns ""))
            (k8s--describe-insert-events conn ns name)))
        (goto-char (point-min))
        (special-mode)
        (local-set-key "q" #'quit-window)
        (local-set-key "g" (lambda ()
                             (interactive)
                             (k8s-describe))))
      (pop-to-buffer buf))))

;;; ---------------------------------------------------------------------------
;;; Header keymaps for clickable fields

(defvar-keymap k8s--resource-header-map
  "RET"       #'k8s-switch-resource
  "<mouse-1>" #'k8s-switch-resource)

(defvar-keymap k8s--namespace-header-map
  "RET"       #'k8s-set-namespace
  "<mouse-1>" #'k8s-set-namespace)

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
            (propertize resource-type
                        'font-lock-face 'k8s-resource-name
                        'k8s-field 'resource
                        'keymap k8s--resource-header-map
                        'mouse-face 'highlight
                        'help-echo "RET: switch resource type")
            "\n")
    (insert (propertize "Namespace: " 'font-lock-face 'k8s-dim)
            (propertize (or k8s--namespace "all")
                        'font-lock-face (if k8s--namespace
                                            'k8s-namespace
                                          'k8s-dim)
                        'k8s-field 'namespace
                        'keymap k8s--namespace-header-map
                        'mouse-face 'highlight
                        'help-echo "RET: switch namespace")
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
  "RET" #'k8s-dwim-ret
  "d" #'k8s-describe
  "N" #'k8s-set-namespace
  "?" #'k8s-dispatch
  "g" #'revert-buffer
  "q" #'quit-window)

(defun k8s-dwim-ret ()
  "Smart RET: if on a header field, activate it; otherwise toggle section."
  (interactive)
  (let ((field (get-text-property (point) 'k8s-field)))
    (cond
     ((eq field 'resource)
      (call-interactively #'k8s-switch-resource))
     ((eq field 'namespace)
      (call-interactively #'k8s-set-namespace))
     (t
      (call-interactively #'magit-section-toggle)))))

;;; ---------------------------------------------------------------------------
;;; Generic refresh engine

(defun k8s--generic-refresh (resource-type api-fn column-header line-fn)
  "Refresh buffer showing RESOURCE-TYPE.
API-FN fetches items, COLUMN-HEADER is the column titles string,
LINE-FN inserts one item as a section."
  (let* ((inhibit-read-only t)
         (conn (k8s--ensure-connection))
         (items (funcall api-fn conn k8s--namespace))
         (grouped (k8s--group-by-namespace items)))
    (erase-buffer)
    (magit-insert-section (k8s-root)
      (k8s--insert-header resource-type)
      (insert (propertize column-header 'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (dolist (group grouped)
        (magit-insert-section (namespace (car group))
          (k8s--insert-namespace-heading (car group) (length (cdr group)))
          (dolist (item (cdr group))
            (funcall line-fn item))
          (insert "\n"))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; View definition macro

(defmacro k8s--define-view (name docstring api-fn column-header line-fn)
  "Define a resource view named NAME.
Generates: k8s--NAME-refresh, k8s-NAME-mode, k8s-NAME command.
API-FN fetches items, COLUMN-HEADER is the header string,
LINE-FN inserts one item."
  (let* ((namestr (symbol-name name))
         (display (capitalize namestr))
         (refresh-fn (intern (format "k8s--%s-refresh" namestr)))
         (mode-fn (intern (format "k8s-%s-mode" namestr)))
         (mode-map (intern (format "k8s-%s-mode-map" namestr)))
         (cmd-fn (intern (format "k8s-%s" namestr)))
         (buf-name (format "*k8s:%s*" namestr)))
    `(progn
       (defun ,refresh-fn ()
         ,(format "Refresh the %s buffer." namestr)
         (k8s--generic-refresh ,display ,api-fn ,column-header ,line-fn))

       (defvar-keymap ,mode-map
         :parent magit-section-mode-map)
       (map-keymap (lambda (key def)
                     (keymap-set ,mode-map (key-description (vector key)) def))
                   k8s-common-map)

       (define-derived-mode ,mode-fn magit-section-mode
         ,(format "K8s:%s" (capitalize namestr))
         ,docstring
         :interactive nil
         :group 'k8s
         (setq-local revert-buffer-function
                     (lambda (_ignore-auto _noconfirm) (,refresh-fn))))

       (defun ,cmd-fn ()
         ,(format "Display %s in the current Kubernetes cluster." namestr)
         (interactive)
         (let ((buf (get-buffer-create ,buf-name)))
           (with-current-buffer buf
             (,mode-fn)
             (k8s--ensure-connection)
             (,refresh-fn))
           (pop-to-buffer buf)))

       (push (cons ,display #',cmd-fn) k8s--resource-types))))

;;; ---------------------------------------------------------------------------
;;; Transient dispatch

(autoload 'k8s-pods "k8s-pods" nil t)

(transient-define-prefix k8s-dispatch ()
  "Main emak8s command menu."
  [["Workloads"
    ("p" "Pods"         k8s-pods)
    ("d" "Deployments"  k8s-deployments)
    ("S" "StatefulSets" k8s-statefulsets)
    ("D" "DaemonSets"   k8s-daemonsets)]
   ["Batch"
    ("j" "Jobs"         k8s-jobs)
    ("c" "CronJobs"     k8s-cronjobs)]
   ["Config & Network"
    ("s" "Services"     k8s-services)
    ("i" "Ingresses"    k8s-ingresses)
    ("m" "ConfigMaps"   k8s-configmaps)
    ("x" "Secrets"      k8s-secrets)]]
  ["Filter"
   ("N" "Namespace"     k8s-set-namespace)]
  ["Navigate"
   ("g" "Refresh"       revert-buffer)
   ("q" "Quit"          quit-window)])

;;;###autoload
(defun k8s ()
  "Main entry point for emak8s.  Shows pods by default."
  (interactive)
  (k8s-pods))

;; Register pods (defined in k8s-pods.el) in the resource type list
(push '("Pods" . k8s-pods) k8s--resource-types)

;;; =========================================================================
;;; Resource views
;;; =========================================================================

;;; ---------------------------------------------------------------------------
;;; Deployments

(defun k8s--insert-deployment-line (deploy)
  "Insert a deployment summary line."
  (let* ((name (k8s--resource-name deploy))
         (status (cdr (assq 'status deploy)))
         (replicas (or (cdr (assq 'replicas status)) 0))
         (ready (or (cdr (assq 'readyReplicas status)) 0))
         (age (k8s--age-string (k8s--resource-creation-time deploy)))
         (image (or (k8s--first-container-image deploy) "")))
    (magit-insert-section (deployment deploy t)
      (magit-insert-heading
        (format "  %-42s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (format "%d/%d" ready replicas)
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize image 'font-lock-face 'k8s-dim)))
      (let* ((spec (cdr (assq 'spec deploy)))
             (strategy (or (cdr (assq 'type (cdr (assq 'strategy spec)))) "?"))
             (updated (or (cdr (assq 'updatedReplicas status)) 0))
             (available (or (cdr (assq 'availableReplicas status)) 0))
             (selector (cdr (assq 'matchLabels (cdr (assq 'selector spec))))))
        (insert (propertize (format "    Strategy:  %s\n" strategy)
                            'font-lock-face 'k8s-dim))
        (insert (propertize (format "    Replicas:  %d desired, %d updated, %d available\n"
                                    replicas updated available)
                            'font-lock-face 'k8s-dim))
        (k8s--insert-selector selector "    ")
        (k8s--insert-labels (k8s--resource-labels deploy) "    ")
        (insert "\n")))))

(k8s--define-view deployments
  "Major mode for viewing Kubernetes deployments."
  #'k8s-list-deployments
  (format "  %-42s %-10s %-6s %s\n" "NAME" "READY" "AGE" "IMAGE")
  #'k8s--insert-deployment-line)

;;; ---------------------------------------------------------------------------
;;; StatefulSets

(defun k8s--insert-statefulset-line (sts)
  "Insert a statefulset summary line."
  (let* ((name (k8s--resource-name sts))
         (status (cdr (assq 'status sts)))
         (replicas (or (cdr (assq 'replicas status)) 0))
         (ready (or (cdr (assq 'readyReplicas status)) 0))
         (age (k8s--age-string (k8s--resource-creation-time sts)))
         (image (or (k8s--first-container-image sts) "")))
    (magit-insert-section (statefulset sts t)
      (magit-insert-heading
        (format "  %-42s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (format "%d/%d" ready replicas)
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize image 'font-lock-face 'k8s-dim)))
      (let* ((spec (cdr (assq 'spec sts)))
             (policy (or (cdr (assq 'podManagementPolicy spec)) "OrderedReady"))
             (svc-name (cdr (assq 'serviceName spec)))
             (selector (cdr (assq 'matchLabels (cdr (assq 'selector spec))))))
        (insert (propertize (format "    Policy:    %s\n" policy)
                            'font-lock-face 'k8s-dim))
        (when svc-name
          (insert (propertize (format "    Service:   %s\n" svc-name)
                              'font-lock-face 'k8s-dim)))
        (k8s--insert-selector selector "    ")
        (k8s--insert-labels (k8s--resource-labels sts) "    ")
        (insert "\n")))))

(k8s--define-view statefulsets
  "Major mode for viewing Kubernetes statefulsets."
  #'k8s-list-statefulsets
  (format "  %-42s %-10s %-6s %s\n" "NAME" "READY" "AGE" "IMAGE")
  #'k8s--insert-statefulset-line)

;;; ---------------------------------------------------------------------------
;;; DaemonSets

(defun k8s--insert-daemonset-line (ds)
  "Insert a daemonset summary line."
  (let* ((name (k8s--resource-name ds))
         (status (cdr (assq 'status ds)))
         (desired (or (cdr (assq 'desiredNumberScheduled status)) 0))
         (ready (or (cdr (assq 'numberReady status)) 0))
         (available (or (cdr (assq 'numberAvailable status)) 0))
         (age (k8s--age-string (k8s--resource-creation-time ds)))
         (image (or (k8s--first-container-image ds) "")))
    (magit-insert-section (daemonset ds t)
      (magit-insert-heading
        (format "  %-42s %-10s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (format "%d/%d" ready desired)
                (propertize (format "%d" available) 'font-lock-face 'k8s-dim)
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize image 'font-lock-face 'k8s-dim)))
      (let* ((spec (cdr (assq 'spec ds)))
             (selector (cdr (assq 'matchLabels (cdr (assq 'selector spec)))))
             (node-sel (cdr (assq 'nodeSelector
                                  (cdr (assq 'spec
                                             (cdr (assq 'template spec))))))))
        (when node-sel
          (insert (propertize "    NodeSel:   " 'font-lock-face 'k8s-dim))
          (let ((first t))
            (dolist (pair node-sel)
              (unless first (insert (propertize "               " 'font-lock-face 'k8s-dim)))
              (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                                  'font-lock-face 'k8s-dim))
              (setq first nil))))
        (k8s--insert-selector selector "    ")
        (k8s--insert-labels (k8s--resource-labels ds) "    ")
        (insert "\n")))))

(k8s--define-view daemonsets
  "Major mode for viewing Kubernetes daemonsets."
  #'k8s-list-daemonsets
  (format "  %-42s %-10s %-10s %-6s %s\n" "NAME" "READY" "AVAILABLE" "AGE" "IMAGE")
  #'k8s--insert-daemonset-line)

;;; ---------------------------------------------------------------------------
;;; Jobs

(defun k8s--insert-job-line (job)
  "Insert a job summary line."
  (let* ((name (k8s--resource-name job))
         (status (cdr (assq 'status job)))
         (spec (cdr (assq 'spec job)))
         (completions (or (cdr (assq 'completions spec)) 1))
         (succeeded (or (cdr (assq 'succeeded status)) 0))
         (failed (or (cdr (assq 'failed status)) 0))
         (active (or (cdr (assq 'active status)) 0))
         (conditions (cdr (assq 'conditions status)))
         (phase (cond
                 ((and conditions (> (length conditions) 0))
                  (cdr (assq 'type (aref conditions 0))))
                 ((> active 0) "Running")
                 ((= succeeded completions) "Complete")
                 (t "Pending")))
         (age (k8s--age-string (k8s--resource-creation-time job))))
    (magit-insert-section (job job t)
      (magit-insert-heading
        (format "  %-42s %-12s %-10s %-6s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize phase 'font-lock-face (k8s--phase-face phase))
                (format "%d/%d" succeeded completions)
                (propertize age 'font-lock-face 'k8s-dim)))
      (insert (propertize (format "    Active: %d  Succeeded: %d  Failed: %d\n"
                                  active succeeded failed)
                          'font-lock-face 'k8s-dim))
      (k8s--insert-labels (k8s--resource-labels job) "    ")
      (insert "\n"))))

(k8s--define-view jobs
  "Major mode for viewing Kubernetes jobs."
  #'k8s-list-jobs
  (format "  %-42s %-12s %-10s %-6s\n" "NAME" "STATUS" "COMPLETIONS" "AGE")
  #'k8s--insert-job-line)

;;; ---------------------------------------------------------------------------
;;; CronJobs

(defun k8s--insert-cronjob-line (cj)
  "Insert a cronjob summary line."
  (let* ((name (k8s--resource-name cj))
         (spec (cdr (assq 'spec cj)))
         (schedule (or (cdr (assq 'schedule spec)) "?"))
         (suspend (if (eq (cdr (assq 'suspend spec)) t) "True" "False"))
         (status (cdr (assq 'status cj)))
         (active (length (or (cdr (assq 'active status)) [])))
         (last-schedule (cdr (assq 'lastScheduleTime status)))
         (last-age (if last-schedule (k8s--age-string last-schedule) "?")))
    (magit-insert-section (cronjob cj t)
      (magit-insert-heading
        (format "  %-35s %-18s %-10s %-8s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                schedule
                (propertize suspend 'font-lock-face
                            (if (string= suspend "True") 'k8s-status-pending
                              'k8s-dim))
                (propertize (format "%d" active) 'font-lock-face 'k8s-dim)
                (propertize last-age 'font-lock-face 'k8s-dim)))
      (k8s--insert-labels (k8s--resource-labels cj) "    ")
      (insert "\n"))))

(k8s--define-view cronjobs
  "Major mode for viewing Kubernetes cronjobs."
  #'k8s-list-cronjobs
  (format "  %-35s %-18s %-10s %-8s %s\n" "NAME" "SCHEDULE" "SUSPEND" "ACTIVE" "LAST")
  #'k8s--insert-cronjob-line)

;;; ---------------------------------------------------------------------------
;;; Services

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
  "Insert a service summary line."
  (let* ((name (k8s--resource-name svc))
         (spec (cdr (assq 'spec svc)))
         (type (or (cdr (assq 'type spec)) "ClusterIP"))
         (cluster-ip (or (cdr (assq 'clusterIP spec)) ""))
         (ports (k8s--service-ports-string svc))
         (age (k8s--age-string (k8s--resource-creation-time svc))))
    (magit-insert-section (service svc t)
      (magit-insert-heading
        (format "  %-35s %-15s %-18s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize type 'font-lock-face
                            (k8s--phase-face (if (string= type "ClusterIP")
                                                 "Active" type)))
                cluster-ip
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize ports 'font-lock-face 'k8s-dim)))
      (let ((selector (cdr (assq 'selector spec)))
            (external-name (cdr (assq 'externalName spec))))
        (k8s--insert-selector selector "    ")
        (when external-name
          (insert (propertize (format "    External:  %s\n" external-name)
                              'font-lock-face 'k8s-dim)))
        (k8s--insert-labels (k8s--resource-labels svc) "    ")
        (insert "\n")))))

(k8s--define-view services
  "Major mode for viewing Kubernetes services."
  #'k8s-list-services
  (format "  %-35s %-15s %-18s %-6s %s\n" "NAME" "TYPE" "CLUSTER-IP" "AGE" "PORTS")
  #'k8s--insert-service-line)

;;; ---------------------------------------------------------------------------
;;; Ingresses

(defun k8s--insert-ingress-line (ing)
  "Insert an ingress summary line."
  (let* ((name (k8s--resource-name ing))
         (spec (cdr (assq 'spec ing)))
         (status (cdr (assq 'status ing)))
         (rules (cdr (assq 'rules spec)))
         (hosts (if (and rules (> (length rules) 0))
                    (mapconcat
                     (lambda (r) (or (cdr (assq 'host r)) "*"))
                     (append rules nil) ", ")
                  ""))
         (lb (cdr (assq 'ingress (cdr (assq 'loadBalancer status)))))
         (address (if (and lb (> (length lb) 0))
                      (or (cdr (assq 'ip (aref lb 0)))
                          (cdr (assq 'hostname (aref lb 0)))
                          "")
                    ""))
         (class (or (cdr (assq 'ingressClassName spec)) ""))
         (age (k8s--age-string (k8s--resource-creation-time ing))))
    (magit-insert-section (ingress ing t)
      (magit-insert-heading
        (format "  %-35s %-25s %-15s %-10s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize hosts 'font-lock-face 'k8s-dim)
                address
                (propertize class 'font-lock-face 'k8s-dim)
                (propertize age 'font-lock-face 'k8s-dim)))
      ;; Detail: rules
      (when rules
        (seq-doseq (rule (append rules nil))
          (let ((host (or (cdr (assq 'host rule)) "*"))
                (paths (cdr (assq 'paths (cdr (assq 'http rule))))))
            (when paths
              (seq-doseq (path (append paths nil))
                (let* ((p (or (cdr (assq 'path path)) "/"))
                       (backend (cdr (assq 'backend path)))
                       (svc (cdr (assq 'service backend)))
                       (svc-name (or (cdr (assq 'name svc)) "?"))
                       (port-obj (cdr (assq 'port svc)))
                       (port-num (or (cdr (assq 'number port-obj)) "?")))
                  (insert (propertize
                           (format "    %s%s → %s:%s\n" host p svc-name port-num)
                           'font-lock-face 'k8s-dim))))))))
      (k8s--insert-labels (k8s--resource-labels ing) "    ")
      (insert "\n"))))

(k8s--define-view ingresses
  "Major mode for viewing Kubernetes ingresses."
  #'k8s-list-ingresses
  (format "  %-35s %-25s %-15s %-10s %s\n" "NAME" "HOSTS" "ADDRESS" "CLASS" "AGE")
  #'k8s--insert-ingress-line)

;;; ---------------------------------------------------------------------------
;;; ConfigMaps

(defun k8s--insert-configmap-line (cm)
  "Insert a configmap summary line."
  (let* ((name (k8s--resource-name cm))
         (data (cdr (assq 'data cm)))
         (data-count (if data (length data) 0))
         (age (k8s--age-string (k8s--resource-creation-time cm))))
    (magit-insert-section (configmap cm t)
      (magit-insert-heading
        (format "  %-42s %-10s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (format "%d" data-count)
                (propertize age 'font-lock-face 'k8s-dim)))
      ;; Show key names (not values — they can be huge)
      (when data
        (insert (propertize "    Keys: " 'font-lock-face 'k8s-dim))
        (let ((first t))
          (dolist (pair data)
            (unless first (insert (propertize "          " 'font-lock-face 'k8s-dim)))
            (insert (propertize (format "%s\n" (car pair))
                                'font-lock-face 'k8s-dim))
            (setq first nil))))
      (insert "\n"))))

(k8s--define-view configmaps
  "Major mode for viewing Kubernetes configmaps."
  #'k8s-list-configmaps
  (format "  %-42s %-10s %s\n" "NAME" "DATA" "AGE")
  #'k8s--insert-configmap-line)

;;; ---------------------------------------------------------------------------
;;; Secrets

(defun k8s--insert-secret-line (secret)
  "Insert a secret summary line."
  (let* ((name (k8s--resource-name secret))
         (type (or (cdr (assq 'type secret)) "Opaque"))
         (data (cdr (assq 'data secret)))
         (data-count (if data (length data) 0))
         (age (k8s--age-string (k8s--resource-creation-time secret))))
    (magit-insert-section (secret secret t)
      (magit-insert-heading
        (format "  %-35s %-40s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize type 'font-lock-face 'k8s-dim)
                (format "%d" data-count)
                (propertize age 'font-lock-face 'k8s-dim)))
      ;; Show key names only (never values!)
      (when data
        (insert (propertize "    Keys: " 'font-lock-face 'k8s-dim))
        (let ((first t))
          (dolist (pair data)
            (unless first (insert (propertize "          " 'font-lock-face 'k8s-dim)))
            (insert (propertize (format "%s\n" (car pair))
                                'font-lock-face 'k8s-dim))
            (setq first nil))))
      (insert "\n"))))

(k8s--define-view secrets
  "Major mode for viewing Kubernetes secrets."
  #'k8s-list-secrets
  (format "  %-35s %-40s %-6s %s\n" "NAME" "TYPE" "DATA" "AGE")
  #'k8s--insert-secret-line)

;;; ---------------------------------------------------------------------------
;;; Finalize resource type list (reverse so display order matches definition)

(setq k8s--resource-types (nreverse k8s--resource-types))

(provide 'k8s)
;;; k8s.el ends here
