;;; test/test-k8s-api.el --- Tests for k8s-api.el -*- lexical-binding: t -*-

(require 'ert)

;; Set up load paths
(let ((project-dir (file-name-directory
                    (directory-file-name
                     (file-name-directory
                      (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path project-dir)
  (add-to-list 'load-path (expand-file-name "../elisp-stdlib" project-dir))
  (add-to-list 'load-path (expand-file-name "../elisp-stdlib/tls" project-dir)))

(require 'k8s-config)
(require 'k8s-api)

;;; ---------------------------------------------------------------------------
;;; Helpers

(defvar k8s-test-project-dir
  (file-name-directory
   (directory-file-name
    (file-name-directory
     (or load-file-name buffer-file-name default-directory))))
  "Project root directory for tests.")

(defvar k8s-test-kubeconfig
  (expand-file-name "test-kubeconfig.yaml" k8s-test-project-dir)
  "Path to the test kubeconfig file.")

(defun k8s-test-conn ()
  "Open a connection to the test cluster."
  (k8s-connection-open k8s-test-kubeconfig))

;;; ---------------------------------------------------------------------------
;;; Connection tests

(ert-deftest k8s-api-connection-open ()
  "Opening a connection parses kubeconfig and sets host/port."
  (let ((conn (k8s-test-conn)))
    (should (k8s-connection-p conn))
    (should (equal (k8s-connection-host conn) "127.0.0.1"))
    (should (= (k8s-connection-port conn) 16443))
    (should (k8s-connection-user conn))
    (should (k8s-user-token (k8s-connection-user conn)))))

;;; ---------------------------------------------------------------------------
;;; API request tests (hit real microk8s)

(ert-deftest k8s-api-list-namespaces ()
  "List namespaces from the cluster."
  (let* ((conn (k8s-test-conn))
         (namespaces (k8s-list-namespaces conn)))
    (should (> (length namespaces) 0))
    ;; kube-system always exists
    (let ((names (mapcar (lambda (ns)
                           (cdr (assq 'name (cdr (assq 'metadata ns)))))
                         namespaces)))
      (should (member "kube-system" names))
      (should (member "bookstore" names)))))

(ert-deftest k8s-api-list-pods-all ()
  "List all pods across all namespaces."
  (let* ((conn (k8s-test-conn))
         (pods (k8s-list-pods conn)))
    (should (> (length pods) 0))
    ;; Every item should have metadata.name and status.phase
    (seq-doseq (pod pods)
      (should (cdr (assq 'name (cdr (assq 'metadata pod)))))
      (should (cdr (assq 'phase (cdr (assq 'status pod))))))))

(ert-deftest k8s-api-list-pods-namespace ()
  "List pods in a specific namespace."
  (let* ((conn (k8s-test-conn))
         (pods (k8s-list-pods conn "bookstore")))
    (should (> (length pods) 0))
    ;; All pods should be in the bookstore namespace
    (seq-doseq (pod pods)
      (should (equal "bookstore"
                     (cdr (assq 'namespace (cdr (assq 'metadata pod)))))))))

(ert-deftest k8s-api-list-running-pods ()
  "List all running pods across the cluster."
  (let* ((conn (k8s-test-conn))
         (all-pods (k8s-list-pods conn))
         (running (seq-filter
                   (lambda (pod)
                     (equal "Running"
                            (cdr (assq 'phase (cdr (assq 'status pod))))))
                   all-pods)))
    (should (> (length running) 0))
    ;; Print what we found
    (message "Running pods (%d):" (length running))
    (seq-doseq (pod running)
      (let* ((meta (cdr (assq 'metadata pod)))
             (ns   (cdr (assq 'namespace meta)))
             (name (cdr (assq 'name meta))))
        (message "  %s/%s" ns name)))
    ;; We know bookstore has running pods
    (let ((bookstore-running
           (seq-filter
            (lambda (pod)
              (equal "bookstore"
                     (cdr (assq 'namespace (cdr (assq 'metadata pod))))))
            running)))
      (should (>= (length bookstore-running) 4)))))

;;; ---------------------------------------------------------------------------
;;; Run tests

(let ((ert-quiet t))
  (ert-run-tests-batch-and-exit))
;;; test-k8s-api.el ends here
