;;; k8s-watch.el --- K8s API watch (streaming events) -*- lexical-binding: t -*-
;;
;; Opens a persistent TLS connection to the K8s API server and streams
;; watch events (ADDED/MODIFIED/DELETED) for a given resource path.
;; Uses open-network-stream with GnuTLS for TLS, and raw HTTP/1.1
;; with chunked transfer encoding parsing.

(require 'cl-lib)
(require 'json)
(require 'network-stream)
(require 'k8s-config)
(require 'k8s-api)

;;; ---------------------------------------------------------------------------
;;; Watch struct

(cl-defstruct (k8s-watch (:constructor k8s-watch--new) (:copier nil))
  conn               ; k8s-connection
  path               ; API path (e.g., "/api/v1/pods")
  resource-version   ; string — resume point
  process            ; network process
  proc-buffer        ; hidden buffer for process output
  callback           ; (lambda (type object) ...) for each event
  active             ; non-nil while watch should be running
  retry-count        ; consecutive reconnection attempts
  retry-timer        ; pending reconnection timer
  ;; Parser state
  headers-done       ; non-nil after HTTP headers are consumed
  chunk-buf          ; accumulated raw data (undecoded chunks)
  body-buf)          ; accumulated decoded body (for JSON line splitting)

;;; ---------------------------------------------------------------------------
;;; Chunked encoding parser

(defun k8s-watch--strip-headers (data)
  "Strip HTTP headers from DATA.  Return body after \\r\\n\\r\\n, or nil if incomplete."
  (let ((sep (string-search "\r\n\r\n" data)))
    (when sep
      (let ((headers (substring data 0 sep)))
        ;; Check for non-200 status
        (when (string-match "^HTTP/[0-9.]+ \\([0-9]+\\)" headers)
          (let ((status (string-to-number (match-string 1 headers))))
            (unless (= status 200)
              (message "emak8s watch: HTTP %d" status))))
        (substring data (+ sep 4))))))

(defun k8s-watch--decode-chunks (raw)
  "Decode chunked transfer encoding from RAW data.
Returns (DECODED-BODY . REMAINING-RAW).
REMAINING-RAW is unprocessed data (incomplete chunk)."
  (let ((decoded "")
        (pos 0)
        (len (length raw)))
    (catch 'done
      (while (< pos len)
        ;; Read chunk size line (hex digits terminated by \r\n)
        (let ((crlf (string-search "\r\n" raw pos)))
          (unless crlf
            (throw 'done (cons decoded (substring raw pos))))
          (let* ((size-str (string-trim (substring raw pos crlf)))
                 (chunk-size (condition-case nil
                                 (string-to-number size-str 16)
                               (error 0))))
            (when (= chunk-size 0)
              ;; Terminal chunk or empty size
              (throw 'done (cons decoded
                                 (if (string= size-str "0")
                                     ""
                                   (substring raw pos)))))
            (let ((data-start (+ crlf 2))
                  (data-end (+ crlf 2 chunk-size)))
              ;; Need full chunk + trailing \r\n
              (when (> (+ data-end 2) len)
                (throw 'done (cons decoded (substring raw pos))))
              (setq decoded (concat decoded
                                    (substring raw data-start data-end)))
              (setq pos (+ data-end 2)))))))
    (cons decoded "")))

(defun k8s-watch--parse-json-lines (data)
  "Split DATA on newlines and parse each complete line as JSON.
Returns (EVENTS . REMAINING) where EVENTS is a list of (TYPE . OBJECT)
and REMAINING is the incomplete trailing line."
  (let ((events nil)
        (lines (split-string data "\n"))
        (remaining ""))
    ;; Last element is either "" (data ended with \n) or an incomplete line
    (setq remaining (car (last lines)))
    (setq lines (butlast lines))
    (dolist (line lines)
      (let ((trimmed (string-trim line)))
        ;; Only parse lines that look like JSON objects
        (when (and (> (length trimmed) 0)
                   (eq (aref trimmed 0) ?{))
          (condition-case err
              (let* ((json-object-type 'alist)
                     (json-array-type 'vector)
                     (json-key-type 'symbol)
                     (obj (json-read-from-string trimmed))
                     (type (cdr (assq 'type obj)))
                     (object (cdr (assq 'object obj))))
                (when (and type object)
                  (push (cons type object) events)))
            (json-end-of-file nil)  ; incomplete JSON, will retry
            (error
             (message "emak8s watch: parse error: %s" err))))))
    (cons (nreverse events) remaining)))

;;; ---------------------------------------------------------------------------
;;; Process filter
;;
;; Strategy: accumulate all data in chunk-buf.  Strip HTTP headers
;; once.  Then scan for complete JSON lines (lines starting with `{`
;; and ending with `\n`) — this skips chunk framing (hex sizes, \r\n)
;; without needing a stateful chunk decoder.

(defun k8s-watch--filter (watch _proc data)
  "Process filter: accumulate DATA and dispatch complete JSON events."
  (setf (k8s-watch-chunk-buf watch)
        (concat (or (k8s-watch-chunk-buf watch) "") data))
  ;; Strip HTTP headers on first data
  (unless (k8s-watch-headers-done watch)
    (let ((body (k8s-watch--strip-headers (k8s-watch-chunk-buf watch))))
      (when body
        (setf (k8s-watch-headers-done watch) t)
        (setf (k8s-watch-chunk-buf watch) body)
        (setf (k8s-watch-retry-count watch) 0))))
  ;; Extract and dispatch JSON lines
  (when (k8s-watch-headers-done watch)
    (k8s-watch--extract-events watch)))

(defun k8s-watch--extract-events (watch)
  "Scan chunk-buf for complete JSON lines and dispatch them."
  (let ((buf (k8s-watch-chunk-buf watch))
        (start 0)
        (dispatched nil))
    ;; Find each complete line that starts with {
    (while (let ((brace (string-search "{" buf start)))
             (when brace
               (let ((eol (string-search "\n" buf brace)))
                 (when eol
                   (let ((line (substring buf brace eol)))
                     (condition-case nil
                         (let* ((json-object-type 'alist)
                                (json-array-type 'vector)
                                (json-key-type 'symbol)
                                (obj (json-read-from-string line))
                                (type (cdr (assq 'type obj)))
                                (object (cdr (assq 'object obj))))
                           (when (and type object)
                             ;; Update resourceVersion
                             (let ((rv (cdr (assq 'resourceVersion
                                                  (cdr (assq 'metadata object))))))
                               (when rv
                                 (setf (k8s-watch-resource-version watch) rv)))
                             ;; Dispatch
                             (when (k8s-watch-callback watch)
                               (condition-case err
                                   (funcall (k8s-watch-callback watch) type object)
                                 (error
                                  (message "emak8s watch callback error: %s" err))))
                             (setq dispatched t)))
                       (json-end-of-file nil)  ; incomplete JSON
                       (error nil)))
                   (setq start (1+ eol))
                   t)))))
    ;; Keep only unprocessed data
    (setf (k8s-watch-chunk-buf watch)
          (if (> start 0)
              (substring buf start)
            buf))))

;;; ---------------------------------------------------------------------------
;;; Process sentinel (disconnection handling)

(defun k8s-watch--sentinel (watch _proc event)
  "Handle watch process disconnection."
  (message "emak8s watch: %s" (string-trim event))
  (when (k8s-watch-active watch)
    (k8s-watch--reconnect watch)))

(defun k8s-watch--reconnect (watch)
  "Reconnect a dropped watch with exponential backoff."
  (let* ((count (k8s-watch-retry-count watch))
         (delay (min 30 (expt 2 (min count 5)))))
    (setf (k8s-watch-retry-count watch) (1+ count))
    (message "emak8s watch: reconnecting in %ds (attempt %d)..." delay (1+ count))
    (setf (k8s-watch-retry-timer watch)
          (run-at-time delay nil #'k8s-watch--do-reconnect watch))))

(defun k8s-watch--do-reconnect (watch)
  "Perform the actual reconnection for WATCH."
  (when (k8s-watch-active watch)
    ;; Clean up old process
    (when (k8s-watch-process watch)
      (ignore-errors (delete-process (k8s-watch-process watch))))
    (when (k8s-watch-proc-buffer watch)
      (ignore-errors (kill-buffer (k8s-watch-proc-buffer watch))))
    ;; Reset parser state
    (setf (k8s-watch-headers-done watch) nil)
    (setf (k8s-watch-chunk-buf watch) nil)
    (setf (k8s-watch-body-buf watch) nil)
    ;; Reconnect
    (condition-case err
        (k8s-watch--connect watch)
      (error
       (message "emak8s watch: reconnect failed: %s" err)
       (k8s-watch--reconnect watch)))))

;;; ---------------------------------------------------------------------------
;;; Connection setup

(defun k8s-watch--connect (watch)
  "Open TLS connection and send HTTP request for WATCH."
  (let* ((conn (k8s-watch-conn watch))
         (host (k8s-connection-host conn))
         (port (k8s-connection-port conn))
         (token (k8s-user-token (k8s-connection-user conn)))
         (path (k8s-watch-path watch))
         (rv (k8s-watch-resource-version watch))
         (query (if rv
                    (format "%s?watch=true&resourceVersion=%s"
                            path rv)
                  (format "%s?watch=true" path)))
         (buf (generate-new-buffer " *k8s-watch*"))
         (gnutls-verify-error nil)
         (proc (open-network-stream "k8s-watch" buf host port
                                    :type 'tls)))
    (unless proc
      (kill-buffer buf)
      (error "Failed to connect to %s:%d" host port))
    (setf (k8s-watch-process watch) proc)
    (setf (k8s-watch-proc-buffer watch) buf)
    (set-process-coding-system proc 'binary 'binary)
    (set-process-query-on-exit-flag proc nil)
    ;; Set up filter and sentinel with watch closed over
    (set-process-filter proc
                        (lambda (p data)
                          (k8s-watch--filter watch p data)))
    (set-process-sentinel proc
                          (lambda (p event)
                            (k8s-watch--sentinel watch p event)))
    ;; Send HTTP request
    (let ((request (format (concat "GET %s HTTP/1.1\r\n"
                                   "Host: %s:%d\r\n"
                                   "Authorization: Bearer %s\r\n"
                                   "Accept: application/json\r\n"
                                   "User-Agent: emak8s/0.1\r\n"
                                   "\r\n")
                           query host port token)))
      (process-send-string proc request))
    (message "emak8s watch: connected to %s" path)
    watch))

;;; ---------------------------------------------------------------------------
;;; Public API

(defun k8s-watch-start (conn path resource-version callback)
  "Start watching PATH on the K8s API via CONN.
RESOURCE-VERSION is the starting point (from a previous LIST).
CALLBACK is called with (TYPE OBJECT) for each event.
Returns a `k8s-watch' struct."
  (let ((watch (k8s-watch--new
                :conn conn
                :path path
                :resource-version resource-version
                :callback callback
                :active t
                :retry-count 0)))
    (k8s-watch--connect watch)
    watch))

(defun k8s-watch-stop (watch)
  "Stop WATCH and clean up resources."
  (when watch
    (setf (k8s-watch-active watch) nil)
    (when (k8s-watch-retry-timer watch)
      (cancel-timer (k8s-watch-retry-timer watch))
      (setf (k8s-watch-retry-timer watch) nil))
    (when (k8s-watch-process watch)
      (ignore-errors (delete-process (k8s-watch-process watch)))
      (setf (k8s-watch-process watch) nil))
    (when (k8s-watch-proc-buffer watch)
      (ignore-errors (kill-buffer (k8s-watch-proc-buffer watch)))
      (setf (k8s-watch-proc-buffer watch) nil))))

(defun k8s-watch-active-p (watch)
  "Return non-nil if WATCH is active."
  (and watch (k8s-watch-active watch)))

(provide 'k8s-watch)
;;; k8s-watch.el ends here
