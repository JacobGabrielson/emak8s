;;; k8s-config.el --- Kubeconfig parser for emak8s -*- lexical-binding: t -*-
;;
;; Parse Kubernetes configuration files (kubeconfig) into structured
;; Elisp data.  Handles the YAML subset used by kubeconfig: block
;; mappings, block sequences, and scalar values.
;;
;; Usage:
;;   (setq cfg (k8s-config-load "/path/to/kubeconfig"))
;;   (k8s-config-current-context cfg)  ;=> "microk8s"
;;   (k8s-config-resolve-cluster cfg)  ;=> k8s-cluster struct

(require 'cl-lib)

;;; ---------------------------------------------------------------------------
;;; Data model

(cl-defstruct (k8s-config (:constructor k8s-config--new) (:copier nil))
  "Parsed kubeconfig."
  clusters          ; list of k8s-cluster
  users             ; list of k8s-user
  contexts          ; list of k8s-context
  current-context)  ; string

(cl-defstruct (k8s-cluster (:constructor k8s-cluster--new) (:copier nil))
  "A cluster entry from kubeconfig."
  name              ; string
  server            ; string  "https://host:port"
  ca-cert-pem       ; string  decoded PEM text, or nil
  ca-certs)         ; list of tls-certificate (parsed), or nil

(cl-defstruct (k8s-user (:constructor k8s-user--new) (:copier nil))
  "A user entry from kubeconfig."
  name              ; string
  token             ; string  bearer token, or nil
  client-cert-pem   ; string  decoded PEM, or nil
  client-key-pem)   ; string  decoded PEM, or nil

(cl-defstruct (k8s-context (:constructor k8s-context--new) (:copier nil))
  "A context entry from kubeconfig."
  name              ; string
  cluster           ; string  cluster name reference
  user              ; string  user name reference
  namespace)        ; string or nil

;;; ---------------------------------------------------------------------------
;;; YAML subset parser
;;
;; Handles the YAML subset used by kubeconfig files:
;; - Block mappings (key: value with indentation)
;; - Block sequences (- item)
;; - Plain, single-quoted, and double-quoted scalars
;; - {} as empty mapping
;; - Comments and blank lines
;;
;; Returns nested alists (for mappings) and lists (for sequences).

(defun k8s--yaml-parse-string (string)
  "Parse YAML STRING into nested alists/lists.
Only handles the subset of YAML used by kubeconfig files."
  (let* ((lines (k8s--yaml-preprocess (split-string string "\n")))
         (result (k8s--yaml-parse-block lines 0)))
    (car result)))

(defun k8s--yaml-preprocess (lines)
  "Remove blank lines and comment-only lines from LINES."
  (cl-remove-if
   (lambda (line)
     (or (string-match-p "\\`[ \t]*\\'" line)        ; blank
         (string-match-p "\\`[ \t]*#" line)           ; comment
         (string-match-p "\\`---" line)                ; document start
         (string-match-p "\\`\\.\\.\\." line)))        ; document end
   lines))

(defun k8s--yaml-indent (line)
  "Return the indentation level of LINE (number of leading spaces)."
  (if (string-match "\\`\\( *\\)" line)
      (length (match-string 1 line))
    0))

(defun k8s--yaml-parse-block (lines expected-indent)
  "Parse a YAML block at EXPECTED-INDENT from LINES.
Returns (VALUE . REMAINING-LINES)."
  (if (null lines)
      (cons nil nil)
    (let ((line (car lines)))
      (if (string-match "\\`\\( *\\)- " line)
          ;; Sequence
          (k8s--yaml-parse-sequence lines expected-indent)
        ;; Mapping
        (k8s--yaml-parse-mapping lines expected-indent)))))

(defun k8s--yaml-parse-scalar (value-str)
  "Parse a YAML scalar VALUE-STR.
Handles plain, single-quoted, double-quoted strings, and {} / []."
  (cond
   ((or (string= value-str "{}") (string= value-str "[]"))
    nil)
   ((string= value-str "~") nil)
   ((string= value-str "null") nil)
   ((string= value-str "true") t)
   ((string= value-str "false") nil)
   ;; Single-quoted
   ((and (string-prefix-p "'" value-str)
         (string-suffix-p "'" value-str))
    (substring value-str 1 -1))
   ;; Double-quoted
   ((and (string-prefix-p "\"" value-str)
         (string-suffix-p "\"" value-str))
    (substring value-str 1 -1))
   ;; Plain scalar
   (t value-str)))

(defun k8s--yaml-parse-mapping (lines expected-indent)
  "Parse a YAML mapping at EXPECTED-INDENT from LINES.
Returns (ALIST . REMAINING-LINES)."
  (let ((result nil)
        (remaining lines))
    (while (and remaining
                (let ((ind (k8s--yaml-indent (car remaining))))
                  (= ind expected-indent))
                ;; Must look like a key: line, not a sequence item
                (not (string-match-p
                      (format "\\`%s- " (make-string expected-indent ?\s))
                      (car remaining))))
      (let* ((line (car remaining))
             (trimmed (string-trim-left line)))
        (if (string-match "\\`\\([^:]+?\\):\\(?: \\(.*\\)\\)?\\'" trimmed)
            (let ((key (match-string 1 trimmed))
                  (val-str (match-string 2 trimmed)))
              (cond
               ;; key: value  (inline scalar)
               ((and val-str (not (string= val-str "")))
                (push (cons key (k8s--yaml-parse-scalar
                                 (string-trim val-str)))
                      result)
                (setq remaining (cdr remaining)))
               ;; key:  (block follows on next lines)
               (t
                (setq remaining (cdr remaining))
                (let ((next-indent (and remaining
                                        (k8s--yaml-indent (car remaining)))))
                  (if (and next-indent
                           (or (> next-indent expected-indent)
                               ;; Sequence items at same indent belong to key
                               (and (= next-indent expected-indent)
                                    (string-match-p
                                     (format "\\`%s- "
                                             (make-string expected-indent ?\s))
                                     (car remaining)))))
                      (let* ((child-indent next-indent)
                             (parsed (k8s--yaml-parse-block
                                      remaining child-indent)))
                        (push (cons key (car parsed)) result)
                        (setq remaining (cdr parsed)))
                    ;; key: with nothing following at deeper indent → nil
                    (push (cons key nil) result))))))
          ;; Not a key: line — stop
          (setq remaining nil))))
    (cons (nreverse result) remaining)))

(defun k8s--yaml-parse-sequence (lines expected-indent)
  "Parse a YAML sequence at EXPECTED-INDENT from LINES.
Returns (LIST . REMAINING-LINES)."
  (let ((result nil)
        (remaining lines))
    (while (and remaining
                (let* ((line (car remaining))
                       (ind (k8s--yaml-indent line)))
                  (and (= ind expected-indent)
                       (string-match-p
                        (format "\\`%s- " (make-string expected-indent ?\s))
                        line))))
      (let* ((line (car remaining))
             ;; Strip the "- " prefix, keeping content at indent+2
             (after-dash (substring line (+ expected-indent 2)))
             (trimmed (string-trim after-dash)))
        (cond
         ;; "- key: value" — inline mapping start
         ((string-match "\\`\\([^:]+?\\):\\(?: \\(.*\\)\\)?\\'" trimmed)
          ;; Rewrite as a mapping line at indent+2 and parse
          (let* ((synth-line (concat (make-string (+ expected-indent 2) ?\s)
                                     trimmed))
                 (new-lines (cons synth-line (cdr remaining)))
                 (parsed (k8s--yaml-parse-mapping
                          new-lines (+ expected-indent 2))))
            (push (car parsed) result)
            (setq remaining (cdr parsed))))
         ;; "- scalar"
         (t
          (push (k8s--yaml-parse-scalar trimmed) result)
          (setq remaining (cdr remaining))))))
    (cons (nreverse result) remaining)))

;;; ---------------------------------------------------------------------------
;;; Kubeconfig loading

(defun k8s--alist-get (alist &rest keys)
  "Nested alist lookup: (k8s--alist-get data \"foo\" \"bar\")."
  (let ((node alist))
    (dolist (key keys)
      (setq node (cdr (assoc key node))))
    node))

(defun k8s--parse-url (url)
  "Parse URL string into (HOST . PORT).
Handles https://host:port format."
  (when (string-match "\\`https?://\\([^:/]+\\)\\(?::\\([0-9]+\\)\\)?\\'" url)
    (let ((host (match-string 1 url))
          (port (match-string 2 url)))
      (cons host (if port (string-to-number port) 443)))))

(defun k8s--build-cluster (entry)
  "Build a `k8s-cluster' from a parsed kubeconfig cluster ENTRY alist."
  (let* ((name (cdr (assoc "name" entry)))
         (cluster (cdr (assoc "cluster" entry)))
         (server (cdr (assoc "server" cluster)))
         (ca-data (cdr (assoc "certificate-authority-data" cluster)))
         (ca-file (cdr (assoc "certificate-authority" cluster)))
         (ca-pem (cond
                  (ca-data (base64-decode-string ca-data))
                  (ca-file (with-temp-buffer
                             (insert-file-contents-literally ca-file)
                             (buffer-string)))))
         (ca-certs nil))  ; parsed certs — populated lazily if needed
    (k8s-cluster--new
     :name name
     :server server
     :ca-cert-pem ca-pem
     :ca-certs ca-certs)))

(defun k8s--build-user (entry)
  "Build a `k8s-user' from a parsed kubeconfig user ENTRY alist."
  (let* ((name (cdr (assoc "name" entry)))
         (user (cdr (assoc "user" entry)))
         (token (cdr (assoc "token" user)))
         (cert-data (cdr (assoc "client-certificate-data" user)))
         (key-data (cdr (assoc "client-key-data" user)))
         (cert-pem (when cert-data (base64-decode-string cert-data)))
         (key-pem (when key-data (base64-decode-string key-data))))
    (k8s-user--new
     :name name
     :token token
     :client-cert-pem cert-pem
     :client-key-pem key-pem)))

(defun k8s--build-context (entry)
  "Build a `k8s-context' from a parsed kubeconfig context ENTRY alist."
  (let* ((name (cdr (assoc "name" entry)))
         (ctx (cdr (assoc "context" entry))))
    (k8s-context--new
     :name name
     :cluster (cdr (assoc "cluster" ctx))
     :user (cdr (assoc "user" ctx))
     :namespace (cdr (assoc "namespace" ctx)))))

(defun k8s-config-load (path)
  "Load and parse a kubeconfig file at PATH.
Returns a `k8s-config' struct."
  (let* ((yaml-str (with-temp-buffer
                     (insert-file-contents-literally path)
                     (decode-coding-string (buffer-string) 'utf-8)))
         (data (k8s--yaml-parse-string yaml-str))
         (clusters (mapcar #'k8s--build-cluster
                           (cdr (assoc "clusters" data))))
         (users (mapcar #'k8s--build-user
                        (cdr (assoc "users" data))))
         (contexts (mapcar #'k8s--build-context
                           (cdr (assoc "contexts" data))))
         (current (cdr (assoc "current-context" data))))
    (k8s-config--new
     :clusters clusters
     :users users
     :contexts contexts
     :current-context current)))

;;; ---------------------------------------------------------------------------
;;; Lookup helpers

(defun k8s-config-get-context (config name)
  "Find the context named NAME in CONFIG."
  (cl-find name (k8s-config-contexts config)
           :key #'k8s-context-name :test #'string=))

(defun k8s-config-get-cluster (config name)
  "Find the cluster named NAME in CONFIG."
  (cl-find name (k8s-config-clusters config)
           :key #'k8s-cluster-name :test #'string=))

(defun k8s-config-get-user (config name)
  "Find the user named NAME in CONFIG."
  (cl-find name (k8s-config-users config)
           :key #'k8s-user-name :test #'string=))

(defun k8s-config-resolve-context (config)
  "Return the current context struct from CONFIG."
  (k8s-config-get-context config (k8s-config-current-context config)))

(defun k8s-config-resolve-cluster (config)
  "Return the cluster struct for CONFIG's current context."
  (let ((ctx (k8s-config-resolve-context config)))
    (k8s-config-get-cluster config (k8s-context-cluster ctx))))

(defun k8s-config-resolve-user (config)
  "Return the user struct for CONFIG's current context."
  (let ((ctx (k8s-config-resolve-context config)))
    (k8s-config-get-user config (k8s-context-user ctx))))

(provide 'k8s-config)
;;; k8s-config.el ends here
