;;; k8s-fs.el --- Read-only pod filesystem access -*- lexical-binding: t -*-
;;
;; Filesystem operations on Kubernetes pods, layered on `k8s-exec'.
;; Pods are assumed to have a POSIX-ish userland: `sh', `find', `stat',
;; `readlink', `cat'.  Both busybox and GNU coreutils are supported;
;; the exec scripts use only the common subset of `stat -c' format
;; codes that both implement (no GNU-only options like
;; `--time-style' or `--quoting-style').
;;
;; Public API:
;;   (k8s-fs-list conn ns pod container path)
;;   (k8s-fs-cat  conn ns pod container path &optional max-bytes)
;;   (k8s-fs-stat conn ns pod container path)
;;
;; CONTAINER may be nil for single-container pods.  All `path' values
;; are absolute paths inside the pod.

(require 'cl-lib)
(require 'k8s-exec)

;;; ---------------------------------------------------------------------------
;;; Entry struct

(cl-defstruct (k8s-fs-entry (:constructor k8s-fs-entry--new) (:copier nil))
  name           ; string — basename for `k8s-fs-list', full path for stat
  type           ; symbol — file directory symlink fifo socket block char unknown
  mode-string    ; string — "rwxr-xr-x", 9 chars (no leading type)
  nlink          ; integer
  owner          ; string
  group          ; string
  size           ; integer (bytes)
  mtime          ; integer (unix epoch seconds)
  link-target)   ; string or nil

;;; ---------------------------------------------------------------------------
;;; Customization

(defcustom k8s-fs-max-cat-bytes (* 5 1024 1024)
  "Refuse to read files larger than this many bytes via `k8s-fs-cat'.
The UI layer should prompt the user if they want to override."
  :type 'integer
  :group 'k8s)

;;; ---------------------------------------------------------------------------
;;; Parsing helpers

(defconst k8s-fs--stat-type-alist
  '(("regular file"           . file)
    ("regular empty file"     . file)
    ("directory"              . directory)
    ("symbolic link"          . symlink)
    ("socket"                 . socket)
    ("fifo"                   . fifo)
    ("block special file"     . block)
    ("character special file" . char))
  "Map `stat -c %F' file-type strings to entry type symbols.")

(defun k8s-fs--type-from-stat (s)
  "Return the entry type symbol for `stat -c %F' string S."
  (or (cdr (assoc s k8s-fs--stat-type-alist)) 'unknown))

(defun k8s-fs--octal-to-rwx (mode)
  "Convert numeric MODE (low 9 bits) to a 9-char rwx string.
Setuid/setgid/sticky bits are not represented; rare for browsing."
  (let ((chars "rwxrwxrwx")
        (out (make-string 9 ?-)))
    (dotimes (i 9)
      (when (/= 0 (logand mode (ash 1 (- 8 i))))
        (aset out i (aref chars i))))
    out))

(defun k8s-fs--parse-line (line full-name)
  "Parse one stat-output LINE into a `k8s-fs-entry'.
LINE has tab-separated fields: TYPE PERMS SIZE MTIME OWNER GROUP NLINK NAME LINK.
If FULL-NAME is non-nil keep the path as-is; otherwise reduce to basename."
  (let ((parts (split-string line "\t")))
    (unless (>= (length parts) 9)
      (error "k8s-fs: malformed entry line: %S" line))
    (let* ((type (k8s-fs--type-from-stat (nth 0 parts)))
           (mode (k8s-fs--octal-to-rwx (string-to-number (nth 1 parts) 8)))
           (size (string-to-number (nth 2 parts)))
           (mtime (string-to-number (nth 3 parts)))
           (owner (nth 4 parts))
           (group (nth 5 parts))
           (nlink (string-to-number (nth 6 parts)))
           (path (nth 7 parts))
           (link (nth 8 parts))
           (name (if full-name path (file-name-nondirectory path))))
      (k8s-fs-entry--new
       :name name
       :type type
       :mode-string mode
       :nlink nlink
       :owner owner
       :group group
       :size size
       :mtime mtime
       :link-target (and (eq type 'symlink) (> (length link) 0) link)))))

;;; ---------------------------------------------------------------------------
;;; Shell scripts (POSIX, run via `sh -c')

(defconst k8s-fs--stat-format
  "%F\t%a\t%s\t%Y\t%U\t%G\t%h\t%n"
  "`stat -c' format: TYPE PERMS SIZE MTIME OWNER GROUP NLINK NAME.
Real tab characters (busybox `stat' does not interpret \\t escapes
in single-quoted format strings, only GNU stat does).")

(defconst k8s-fs--list-script
  (concat "[ -d \"$1\" ] || { echo \"k8s-fs: not a directory: $1\" >&2; exit 1; }; "
          "find \"$1\" -mindepth 1 -maxdepth 1 | while IFS= read -r f; do "
          ;; printf interprets \t and \n in its format string, so we
          ;; want literal backslash-t / backslash-n there.
          "out=$(stat -c '" k8s-fs--stat-format "' -- \"$f\") || continue; "
          "link=$(if [ -L \"$f\" ]; then readlink -- \"$f\"; fi); "
          "printf '%s\\t%s\\n' \"$out\" \"$link\"; "
          "done")
  "Sh script to list one directory's entries with metadata.
Output: one line per entry, tab-separated:
  TYPE PERMS SIZE MTIME OWNER GROUP NLINK NAME LINK-TARGET
LINK-TARGET is empty for non-symlinks.  Filenames with embedded
newlines or tabs are not supported (extremely rare in practice).
The leading bare `find' verifies the directory exists so we propagate
the failure cleanly; a missing dir would otherwise yield empty output
and a misleading exit-0 status.")

(defconst k8s-fs--stat-script
  (concat "out=$(stat -c '" k8s-fs--stat-format "' -- \"$1\") || exit; "
          "link=$(if [ -L \"$1\" ]; then readlink -- \"$1\"; fi); "
          "printf '%s\\t%s\\n' \"$out\" \"$link\"")
  "Sh script for `k8s-fs-stat': same line format as `k8s-fs--list-script'.
Propagates stat failure (e.g. file not found) via `|| exit'.")

;;; ---------------------------------------------------------------------------
;;; Exec wrapper

(defun k8s-fs--require-success (r context)
  "Signal an error if exec result R isn't success.  CONTEXT prefixes the message."
  (let ((exit (k8s-exec-result-exit-code r))
        (status (k8s-exec-result-status r))
        (stderr (k8s-exec-result-stderr r))
        (msg (k8s-exec-result-message r)))
    (unless (or (eq exit 0)
                (and (null exit) (equal status "Success")))
      (error "k8s-fs: %s failed (exit=%S): %s"
             context exit
             (or (and stderr (> (length stderr) 0)
                      (string-trim stderr))
                 msg
                 status
                 "unknown error")))))

;;; ---------------------------------------------------------------------------
;;; Public API

(defun k8s-fs-list (conn ns pod container path)
  "Return entries in directory PATH inside POD/CONTAINER.
Result is a list of `k8s-fs-entry' (excluding . and ..).
Order follows `find' (typically alphabetical or directory-traversal
order; the UI layer should sort if it cares)."
  (let* ((r (k8s-exec conn ns pod container
                      (list "sh" "-c" k8s-fs--list-script "_" path))))
    (k8s-fs--require-success r (format "list %s" path))
    (let ((lines (split-string
                  (decode-coding-string (k8s-exec-result-stdout r) 'utf-8)
                  "\n" t)))
      (mapcar (lambda (l) (k8s-fs--parse-line l nil)) lines))))

(defun k8s-fs-stat (conn ns pod container path)
  "Return a `k8s-fs-entry' describing PATH inside POD/CONTAINER."
  (let* ((r (k8s-exec conn ns pod container
                      (list "sh" "-c" k8s-fs--stat-script "_" path))))
    (k8s-fs--require-success r (format "stat %s" path))
    (let* ((raw (decode-coding-string (k8s-exec-result-stdout r) 'utf-8))
           ;; Strip only trailing newlines — `string-trim' would also eat
           ;; the trailing tab + empty link-target field.
           (line (replace-regexp-in-string "\n+\\'" "" raw)))
      (k8s-fs--parse-line line t))))

(defun k8s-fs-cat (conn ns pod container path &optional max-bytes)
  "Return the contents of regular file PATH inside POD/CONTAINER.
Refuses to read files larger than MAX-BYTES (default `k8s-fs-max-cat-bytes').
Returns the raw bytes (unibyte string); the caller is responsible for decoding."
  (let* ((cap (or max-bytes k8s-fs-max-cat-bytes))
         (entry (k8s-fs-stat conn ns pod container path)))
    (unless (eq (k8s-fs-entry-type entry) 'file)
      (error "k8s-fs-cat: %s is a %s, not a regular file"
             path (k8s-fs-entry-type entry)))
    (when (> (k8s-fs-entry-size entry) cap)
      (error "k8s-fs-cat: %s is %d bytes (cap %d) — pass MAX-BYTES to override"
             path (k8s-fs-entry-size entry) cap))
    (let ((r (k8s-exec conn ns pod container (list "cat" "--" path))))
      (k8s-fs--require-success r (format "cat %s" path))
      (k8s-exec-result-stdout r))))

(provide 'k8s-fs)
;;; k8s-fs.el ends here
