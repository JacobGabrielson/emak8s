;;; test/test-k8s-pods.el --- Tests for k8s-pods.el -*- lexical-binding: t -*-

(require 'ert)

;; Set up load paths
(let ((project-dir (file-name-directory
                    (directory-file-name
                     (file-name-directory
                      (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path project-dir)
  (add-to-list 'load-path (expand-file-name "../elisp-stdlib" project-dir))
  (add-to-list 'load-path (expand-file-name "../elisp-stdlib/tls" project-dir)))

;; magit-section and its deps
(dolist (dir '("magit-section-20260101.1850"
               "cond-let-20260201.1500"
               "llama-20260301.1253"
               "dash-20260221.1346"
               "transient-20260305.2144"
               "with-editor-20260301.1317"))
  (add-to-list 'load-path
               (expand-file-name dir (expand-file-name "~/.emacs.d/elpa"))))

(require 'k8s-pods)

;;; ---------------------------------------------------------------------------

(defvar k8s-test-project-dir
  (file-name-directory
   (directory-file-name
    (file-name-directory
     (or load-file-name buffer-file-name default-directory))))
  "Project root directory for tests.")

(defvar k8s-test-kubeconfig
  (expand-file-name "test-kubeconfig.yaml" k8s-test-project-dir)
  "Path to the test kubeconfig file.")

;;; ---------------------------------------------------------------------------
;;; Tests

(ert-deftest k8s-pods-buffer-creation ()
  "k8s-pods creates a *k8s:pods* buffer in k8s-pods-mode."
  (let ((k8s-kubeconfig-path k8s-test-kubeconfig))
    (k8s-pods)
    (should (get-buffer "*k8s:pods*"))
    (with-current-buffer "*k8s:pods*"
      (should (eq major-mode 'k8s-pods-mode))
      (should buffer-read-only)
      (should k8s--connection))))

(ert-deftest k8s-pods-buffer-has-content ()
  "The pods buffer should contain pod names and namespace headings."
  (let ((k8s-kubeconfig-path k8s-test-kubeconfig))
    (k8s-pods)
    (with-current-buffer "*k8s:pods*"
      (let ((content (buffer-string)))
        ;; Should have cluster info
        (should (string-match-p "127\\.0\\.0\\.1:16443" content))
        ;; Should have namespace headings
        (should (string-match-p "bookstore" content))
        (should (string-match-p "kube-system" content))
        ;; Should have pod names
        (should (string-match-p "postgres-0" content))
        (should (string-match-p "coredns" content))
        ;; Should have status column
        (should (string-match-p "Running" content))
        ;; Print it for inspection
        (message "\n%s" content)))))

(ert-deftest k8s-pods-refresh ()
  "Pressing g refreshes the buffer."
  (let ((k8s-kubeconfig-path k8s-test-kubeconfig))
    (k8s-pods)
    (with-current-buffer "*k8s:pods*"
      (revert-buffer)
      ;; After refresh, buffer should still have content
      (should (> (buffer-size) 100))
      ;; Should still have pods
      (should (string-match-p "Running" (buffer-string))))))

(ert-deftest k8s-pods-namespace-filter ()
  "Namespace filtering restricts pods to one namespace."
  (let ((k8s-kubeconfig-path k8s-test-kubeconfig))
    (k8s-pods)
    (with-current-buffer "*k8s:pods*"
      ;; Filter to bookstore
      (setq k8s--namespace "bookstore")
      (revert-buffer)
      (let ((content (buffer-string)))
        (should (string-match-p "bookstore" content))
        (should-not (string-match-p "kube-system" content))
        (should (string-match-p "Namespace: bookstore" content)))
      ;; Clear filter
      (setq k8s--namespace nil)
      (revert-buffer)
      (should (string-match-p "kube-system" (buffer-string))))))

(ert-deftest k8s-deployments-buffer ()
  "k8s-deployments creates a deployments buffer."
  (let ((k8s-kubeconfig-path k8s-test-kubeconfig))
    (k8s-deployments)
    (should (get-buffer "*k8s:deployments*"))
    (with-current-buffer "*k8s:deployments*"
      (should (eq major-mode 'k8s-deployments-mode))
      (let ((content (buffer-string)))
        (should (string-match-p "Deployments" content))
        (should (string-match-p "bookstore" content))
        (message "\n%s" content)))))

(ert-deftest k8s-services-buffer ()
  "k8s-services creates a services buffer."
  (let ((k8s-kubeconfig-path k8s-test-kubeconfig))
    (k8s-services)
    (should (get-buffer "*k8s:services*"))
    (with-current-buffer "*k8s:services*"
      (should (eq major-mode 'k8s-services-mode))
      (let ((content (buffer-string)))
        (should (string-match-p "Services" content))
        (should (string-match-p "ClusterIP" content))
        (message "\n%s" content)))))

;;; ---------------------------------------------------------------------------
;;; Run tests

(let ((ert-quiet t))
  (ert-run-tests-batch-and-exit))
;;; test-k8s-pods.el ends here
