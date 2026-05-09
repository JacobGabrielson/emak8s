;;; reload.el --- Reload all emak8s modules -*- lexical-binding: t -*-
;;
;; First time:  M-x load-file RET <path-to>/reload.el RET
;; After that:  M-x reload-k8s

(defconst reload-k8s--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing reload.el (and the emak8s sources).")

(add-to-list 'load-path reload-k8s--dir)
(add-to-list 'load-path (expand-file-name "../elisp-stdlib" reload-k8s--dir))
(add-to-list 'load-path (expand-file-name "../elisp-stdlib/tls" reload-k8s--dir))
(setq k8s-kubeconfig-path (expand-file-name "test-kubeconfig.yaml" reload-k8s--dir))

(defun reload-k8s ()
  "Unload and reload all emak8s modules."
  (interactive)
  ;; Kill all k8s buffers (stops watches, timers, etc.)
  (dolist (buf (buffer-list))
    (when (string-prefix-p "*k8s:" (buffer-name buf))
      (kill-buffer buf)))
  (dolist (feat '(k8s-pods k8s k8s-watch k8s-api k8s-config))
    (when (featurep feat) (unload-feature feat t)))
  ;; Byte-compile everything
  (dolist (file '("k8s-config.el" "k8s-api.el" "k8s-watch.el" "k8s.el" "k8s-pods.el"))
    (byte-compile-file (expand-file-name file reload-k8s--dir)))
  (load "k8s-config")
  (load "k8s-api")
  (load "k8s-watch")
  (load "k8s")
  (load "k8s-pods")
  (setq k8s-kubeconfig-path (expand-file-name "test-kubeconfig.yaml" reload-k8s--dir))
  (message "emak8s reloaded (byte-compiled)"))



(reload-k8s)
;;; reload.el ends here
