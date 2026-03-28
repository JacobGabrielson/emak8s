;;; reload.el --- Reload all emak8s modules -*- lexical-binding: t -*-
;;
;; First time:  M-x load-file RET /home/ubuntu/projects/emak8s/reload.el RET
;; After that:  M-x reload-k8s

(add-to-list 'load-path "/home/ubuntu/projects/emak8s")
(add-to-list 'load-path "/home/ubuntu/projects/elisp-stdlib")
(add-to-list 'load-path "/home/ubuntu/projects/elisp-stdlib/tls")
(setq k8s-kubeconfig-path "/home/ubuntu/projects/emak8s/test-kubeconfig.yaml")

(defun reload-k8s ()
  "Unload and reload all emak8s modules."
  (interactive)
  (dolist (feat '(k8s-pods k8s k8s-api k8s-config))
    (when (featurep feat) (unload-feature feat t)))
  (load "k8s-config")
  (load "k8s-api")
  (load "k8s")
  (load "k8s-pods")
  (setq k8s-kubeconfig-path "/home/ubuntu/projects/emak8s/test-kubeconfig.yaml")
  (message "emak8s reloaded"))

(reload-k8s)
;;; reload.el ends here
