;;; init-emak8s.el --- Load emak8s into a running Emacs -*- lexical-binding: t -*-
;;
;; M-x load-file RET /home/ubuntu/projects/emak8s/init-emak8s.el RET
;; M-x k8s-pods RET

(add-to-list 'load-path "/home/ubuntu/projects/emak8s")
(add-to-list 'load-path "/home/ubuntu/projects/elisp-stdlib")
(add-to-list 'load-path "/home/ubuntu/projects/elisp-stdlib/tls")
(setq k8s-kubeconfig-path "/home/ubuntu/projects/emak8s/test-kubeconfig.yaml")
(require 'k8s-pods)

;;; init-emak8s.el ends here
