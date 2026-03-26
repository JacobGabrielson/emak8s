;;; k8s-pods.el --- Interactive pod listing for emak8s -*- lexical-binding: t -*-
;;
;; Provides an interactive buffer showing all pods in the current
;; Kubernetes cluster, inspired by magit's section-based UI.
;;
;; Usage:
;;   M-x k8s-pods

(require 'cl-lib)
(require 'magit-section)
(require 'k8s)

;;; ---------------------------------------------------------------------------
;;; Pod-specific helpers

(defun k8s--pod-phase (pod)
  "Return the phase (Running, Pending, etc.) of POD."
  (cdr (assq 'phase (cdr (assq 'status pod)))))

(defun k8s--pod-ip (pod)
  "Return the pod IP address."
  (cdr (assq 'podIP (cdr (assq 'status pod)))))

(defun k8s--pod-container-statuses (pod)
  "Return the vector of container statuses."
  (cdr (assq 'containerStatuses (cdr (assq 'status pod)))))

(defun k8s--pod-restarts (pod)
  "Return total restart count across all containers."
  (let ((statuses (k8s--pod-container-statuses pod))
        (total 0))
    (when statuses
      (seq-doseq (cs statuses)
        (cl-incf total (or (cdr (assq 'restartCount cs)) 0))))
    total))

(defun k8s--pod-ready-string (pod)
  "Return READY string like 1/2 for POD."
  (let ((statuses (k8s--pod-container-statuses pod)))
    (if statuses
        (let ((total (length statuses))
              (ready 0))
          (seq-doseq (cs statuses)
            (when (eq (cdr (assq 'ready cs)) t)
              (cl-incf ready)))
          (format "%d/%d" ready total))
      "0/0")))

;;; ---------------------------------------------------------------------------
;;; Section inserters

(defun k8s--insert-pod-line (pod)
  "Insert a single pod summary line as a section."
  (let* ((name (k8s--resource-name pod))
         (phase (k8s--pod-phase pod))
         (ready (k8s--pod-ready-string pod))
         (restarts (k8s--pod-restarts pod))
         (age (k8s--age-string (k8s--resource-creation-time pod)))
         (ip (or (k8s--pod-ip pod) "")))
    (magit-insert-section (pod pod t)
      (magit-insert-heading
        (format "  %-42s %-10s %-7s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize (or phase "?") 'font-lock-face (k8s--phase-face phase))
                ready
                (propertize (format "%d" restarts) 'font-lock-face 'k8s-dim)
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize ip 'font-lock-face 'k8s-dim)))
      ;; Collapsible detail body (hidden by default, expand with TAB)
      (k8s--insert-pod-details pod))))

(defun k8s--insert-pod-details (pod)
  "Insert expanded details for POD (containers, node, labels)."
  (let* ((spec (cdr (assq 'spec pod)))
         (node (or (cdr (assq 'nodeName spec)) "?"))
         (labels (k8s--resource-labels pod))
         (statuses (k8s--pod-container-statuses pod)))
    ;; Node
    (insert (propertize (format "    Node:   %s\n" node)
                        'font-lock-face 'k8s-dim))
    ;; Labels
    (when labels
      (insert (propertize "    Labels: " 'font-lock-face 'k8s-dim))
      (let ((first t))
        (dolist (pair labels)
          (unless first (insert (propertize "            " 'font-lock-face 'k8s-dim)))
          (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                              'font-lock-face 'k8s-dim))
          (setq first nil))))
    ;; Containers
    (when statuses
      (insert (propertize "    Containers:\n" 'font-lock-face 'k8s-dim))
      (seq-doseq (cs statuses)
        (let ((cname (cdr (assq 'name cs)))
              (image (cdr (assq 'image cs)))
              (ready (cdr (assq 'ready cs)))
              (rc (or (cdr (assq 'restartCount cs)) 0)))
          (insert (propertize
                   (format "      %-20s %-40s ready=%-5s restarts=%d\n"
                           cname
                           (or image "?")
                           (if (eq ready t) "yes" "no")
                           rc)
                   'font-lock-face 'k8s-dim)))))
    (insert "\n")))

;;; ---------------------------------------------------------------------------
;;; Buffer refresh

(defun k8s--pods-refresh ()
  "Refresh the pods buffer content."
  (let* ((inhibit-read-only t)
         (conn (k8s--ensure-connection))
         (pods (k8s-list-pods conn k8s--namespace))
         (grouped (k8s--group-by-namespace pods)))
    (erase-buffer)
    (magit-insert-section (k8s-pods-root)
      (k8s--insert-header "Pods")
      (insert (propertize
               (format "  %-42s %-10s %-7s %-10s %-6s %s\n"
                       "NAME" "STATUS" "READY" "RESTARTS" "AGE" "IP")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (dolist (group grouped)
        (magit-insert-section (namespace (car group))
          (k8s--insert-namespace-heading (car group) (length (cdr group)))
          (dolist (pod (cdr group))
            (k8s--insert-pod-line pod))
          (insert "\n"))))
    ;; Cascade visibility: creates overlays for hidden sections
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar-keymap k8s-pods-mode-map
  :parent magit-section-mode-map)

(map-keymap (lambda (key def)
              (keymap-set k8s-pods-mode-map (key-description (vector key)) def))
            k8s-common-map)

(define-derived-mode k8s-pods-mode magit-section-mode "K8s:Pods"
  "Major mode for viewing Kubernetes pods.

\\{k8s-pods-mode-map}"
  :interactive nil
  :group 'k8s
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (k8s--pods-refresh))))

;;; ---------------------------------------------------------------------------
;;; Interactive command

;;;###autoload
(defun k8s-pods ()
  "Display all pods in the current Kubernetes cluster."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:pods*")))
    (with-current-buffer buf
      (k8s-pods-mode)
      (k8s--ensure-connection)
      (k8s--pods-refresh))
    (pop-to-buffer buf)))

(provide 'k8s-pods)
;;; k8s-pods.el ends here
