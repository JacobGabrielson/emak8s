;;; test/test-k8s-config.el --- Tests for k8s-config.el -*- lexical-binding: t -*-

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

;;; ---------------------------------------------------------------------------
;;; YAML parser tests

(ert-deftest k8s-yaml-simple-mapping ()
  "Parse a simple key-value mapping."
  (let ((result (k8s--yaml-parse-string "foo: bar\nbaz: quux\n")))
    (should (equal (cdr (assoc "foo" result)) "bar"))
    (should (equal (cdr (assoc "baz" result)) "quux"))))

(ert-deftest k8s-yaml-nested-mapping ()
  "Parse a nested mapping."
  (let ((result (k8s--yaml-parse-string
                 "outer:\n  inner: value\n  other: thing\n")))
    (should (equal (k8s--alist-get result "outer" "inner") "value"))
    (should (equal (k8s--alist-get result "outer" "other") "thing"))))

(ert-deftest k8s-yaml-sequence ()
  "Parse a simple sequence."
  (let ((result (k8s--yaml-parse-string
                 "items:\n- alpha\n- beta\n- gamma\n")))
    (should (equal (cdr (assoc "items" result))
                   '("alpha" "beta" "gamma")))))

(ert-deftest k8s-yaml-sequence-of-mappings ()
  "Parse a sequence of mappings (kubeconfig-style)."
  (let ((result (k8s--yaml-parse-string
                 (concat "things:\n"
                         "- name: first\n"
                         "  value: one\n"
                         "- name: second\n"
                         "  value: two\n"))))
    (let ((things (cdr (assoc "things" result))))
      (should (= (length things) 2))
      (should (equal (cdr (assoc "name" (car things))) "first"))
      (should (equal (cdr (assoc "value" (car things))) "one"))
      (should (equal (cdr (assoc "name" (cadr things))) "second"))
      (should (equal (cdr (assoc "value" (cadr things))) "two")))))

(ert-deftest k8s-yaml-empty-mapping ()
  "Parse {} as nil."
  (let ((result (k8s--yaml-parse-string "preferences: {}\n")))
    (should (null (cdr (assoc "preferences" result))))))

(ert-deftest k8s-yaml-kubeconfig-structure ()
  "Parse a minimal kubeconfig-like YAML structure."
  (let ((result (k8s--yaml-parse-string
                 (concat "apiVersion: v1\n"
                         "kind: Config\n"
                         "current-context: test\n"
                         "clusters:\n"
                         "- cluster:\n"
                         "    server: https://127.0.0.1:6443\n"
                         "  name: my-cluster\n"
                         "contexts:\n"
                         "- context:\n"
                         "    cluster: my-cluster\n"
                         "    user: admin\n"
                         "  name: test\n"
                         "users:\n"
                         "- name: admin\n"
                         "  user:\n"
                         "    token: abc123\n"))))
    (should (equal (cdr (assoc "apiVersion" result)) "v1"))
    (should (equal (cdr (assoc "current-context" result)) "test"))
    ;; Check cluster
    (let* ((clusters (cdr (assoc "clusters" result)))
           (c0 (car clusters)))
      (should (equal (cdr (assoc "name" c0)) "my-cluster"))
      (should (equal (k8s--alist-get c0 "cluster" "server")
                     "https://127.0.0.1:6443")))
    ;; Check context
    (let* ((contexts (cdr (assoc "contexts" result)))
           (ctx (car contexts)))
      (should (equal (k8s--alist-get ctx "context" "cluster") "my-cluster"))
      (should (equal (k8s--alist-get ctx "context" "user") "admin")))
    ;; Check user
    (let* ((users (cdr (assoc "users" result)))
           (u0 (car users)))
      (should (equal (cdr (assoc "name" u0)) "admin"))
      (should (equal (k8s--alist-get u0 "user" "token") "abc123")))))

;;; ---------------------------------------------------------------------------
;;; URL parser tests

(ert-deftest k8s-parse-url-with-port ()
  "Parse URL with explicit port."
  (let ((result (k8s--parse-url "https://127.0.0.1:16443")))
    (should (equal (car result) "127.0.0.1"))
    (should (= (cdr result) 16443))))

(ert-deftest k8s-parse-url-default-port ()
  "Parse URL with default HTTPS port."
  (let ((result (k8s--parse-url "https://k8s.example.com")))
    (should (equal (car result) "k8s.example.com"))
    (should (= (cdr result) 443))))

;;; ---------------------------------------------------------------------------
;;; Kubeconfig loading tests (requires test-kubeconfig.yaml)

(defvar k8s-test-project-dir
  (or (and load-file-name
           (file-name-directory
            (directory-file-name
             (file-name-directory load-file-name))))
      (and buffer-file-name
           (file-name-directory
            (directory-file-name
             (file-name-directory buffer-file-name))))
      default-directory)
  "Project root directory for tests.")

(ert-deftest k8s-config-load-real ()
  "Load the real microk8s test kubeconfig."
  (let* ((kubeconfig (expand-file-name "test-kubeconfig.yaml"
                                        k8s-test-project-dir)))
    (when (file-exists-p kubeconfig)
      (let ((cfg (k8s-config-load kubeconfig)))
        ;; Current context
        (should (equal (k8s-config-current-context cfg) "microk8s"))
        ;; Cluster
        (let ((cluster (k8s-config-resolve-cluster cfg)))
          (should cluster)
          (should (equal (k8s-cluster-name cluster) "microk8s-cluster"))
          (should (string-prefix-p "https://" (k8s-cluster-server cluster)))
          (should (k8s-cluster-ca-cert-pem cluster))
          (should (k8s-cluster-ca-certs cluster))
          (should (>= (length (k8s-cluster-ca-certs cluster)) 1)))
        ;; User
        (let ((user (k8s-config-resolve-user cfg)))
          (should user)
          (should (equal (k8s-user-name user) "emak8s-admin"))
          (should (k8s-user-token user)))
        ;; Context
        (let ((ctx (k8s-config-resolve-context cfg)))
          (should ctx)
          (should (equal (k8s-context-cluster ctx) "microk8s-cluster"))
          (should (equal (k8s-context-user ctx) "emak8s-admin")))))))

(provide 'test-k8s-config)
;;; test-k8s-config.el ends here
