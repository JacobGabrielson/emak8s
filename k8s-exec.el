;;; k8s-exec.el --- Pure-Elisp WebSocket exec for Kubernetes -*- lexical-binding: t -*-
;;
;; Run a command inside a Kubernetes pod via the API server's WebSocket
;; exec endpoint, with no kubectl and no shelling out.  Implements just
;; enough of RFC 6455 (client side, masked) and the v4.channel.k8s.io
;; subprotocol for one-shot synchronous execs.
;;
;; Usage:
;;   (let ((conn (k8s-connection-open k8s-kubeconfig-path)))
;;     (k8s-exec conn "default" "mypod" nil '("ls" "-la" "/")))
;;
;; CONTAINER may be nil for single-container pods.  Returns a
;; `k8s-exec-result' struct with raw unibyte STDOUT and STDERR plus the
;; remote process's EXIT-CODE, STATUS, and MESSAGE.

(require 'cl-lib)
(require 'json)
(require 'url-util)
(require 'k8s-config)
(require 'k8s-api)

;;; ---------------------------------------------------------------------------
;;; Result struct

(cl-defstruct (k8s-exec-result
               (:constructor k8s-exec-result--new)
               (:copier nil))
  stdout                  ; unibyte string
  stderr                  ; unibyte string
  exit-code               ; integer, or nil if unparseable
  status                  ; "Success" / "Failure" / nil
  message)                ; failure message, or nil

;;; ---------------------------------------------------------------------------
;;; WebSocket primitives (RFC 6455, client side)

(defconst k8s-exec--ws-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "Magic GUID used to derive Sec-WebSocket-Accept from Sec-WebSocket-Key.")

(defun k8s-exec--random-bytes (n)
  "Return N random bytes as a unibyte string."
  (apply #'unibyte-string (cl-loop repeat n collect (random 256))))

(defun k8s-exec--ws-key ()
  "Return a fresh Sec-WebSocket-Key value (base64 of 16 random bytes)."
  (base64-encode-string (k8s-exec--random-bytes 16) t))

(defun k8s-exec--ws-accept (key)
  "Return the Sec-WebSocket-Accept value the server should send for KEY."
  (base64-encode-string
   (secure-hash 'sha1 (concat key k8s-exec--ws-guid) nil nil t)
   t))

(defun k8s-exec--mask (payload mask)
  "Return PAYLOAD XOR'd with 4-byte MASK (a unibyte string)."
  (apply #'unibyte-string
         (cl-loop for i below (length payload)
                  collect (logxor (aref payload i)
                                  (aref mask (mod i 4))))))

(defun k8s-exec--encode-frame (opcode payload)
  "Encode a single WebSocket frame from client to server.
FIN bit is set, payload is masked per RFC 6455."
  (let* ((mask (k8s-exec--random-bytes 4))
         (masked (k8s-exec--mask payload mask))
         (len (length payload))
         (header
          (cond
           ((< len 126)
            (unibyte-string (logior #x80 opcode)
                            (logior #x80 len)))
           ((< len 65536)
            (unibyte-string (logior #x80 opcode)
                            (logior #x80 126)
                            (logand (ash len -8) #xFF)
                            (logand len #xFF)))
           (t
            (apply #'unibyte-string
                   (logior #x80 opcode)
                   (logior #x80 127)
                   (cl-loop for i from 7 downto 0
                            collect (logand (ash len (* -8 i)) #xFF)))))))
    (concat header mask masked)))

(defun k8s-exec--parse-frame (data start)
  "Try to parse one WebSocket frame from DATA starting at START.
Return (FIN OPCODE PAYLOAD END-POS) on success, nil if incomplete."
  (let ((len (length data)))
    (catch 'incomplete
      (unless (>= len (+ start 2)) (throw 'incomplete nil))
      (let* ((b0 (aref data start))
             (b1 (aref data (1+ start)))
             (fin (/= (logand b0 #x80) 0))
             (opcode (logand b0 #x0F))
             (masked (/= (logand b1 #x80) 0))
             (raw-len (logand b1 #x7F))
             (pos (+ start 2))
             payload-len)
        (cond
         ((< raw-len 126)
          (setq payload-len raw-len))
         ((= raw-len 126)
          (unless (>= len (+ pos 2)) (throw 'incomplete nil))
          (setq payload-len (+ (ash (aref data pos) 8)
                               (aref data (1+ pos))))
          (setq pos (+ pos 2)))
         (t
          (unless (>= len (+ pos 8)) (throw 'incomplete nil))
          (setq payload-len 0)
          (dotimes (i 8)
            (setq payload-len (+ (ash payload-len 8) (aref data (+ pos i)))))
          (setq pos (+ pos 8))))
        (let (mask)
          (when masked
            (unless (>= len (+ pos 4)) (throw 'incomplete nil))
            (setq mask (substring data pos (+ pos 4)))
            (setq pos (+ pos 4)))
          (unless (>= len (+ pos payload-len)) (throw 'incomplete nil))
          (let ((payload (substring data pos (+ pos payload-len))))
            (when masked
              (setq payload (k8s-exec--mask payload mask)))
            (list fin opcode payload (+ pos payload-len))))))))

;;; ---------------------------------------------------------------------------
;;; K8s exec channel demux (v4.channel.k8s.io)
;;
;; Each frame's payload[0] is the channel:
;;   0  stdin (we never receive)
;;   1  stdout
;;   2  stderr
;;   3  error (JSON v1.Status sent when the remote process exits)
;;   4  resize (we don't use)

(cl-defstruct (k8s-exec--session
               (:constructor k8s-exec--session-new)
               (:copier nil))
  process
  raw                ; accumulated unibyte bytes from process
  headers-done       ; non-nil after HTTP/1.1 101 \r\n\r\n consumed
  status-code        ; HTTP status from handshake reply
  stdout-chunks      ; list of unibyte strings, reverse order
  stderr-chunks
  error-payload      ; raw JSON string from channel 3
  done-p)            ; t when close frame received or peer closed

(defun k8s-exec--handle-frame (sess opcode payload)
  "Dispatch a single WebSocket frame for SESS."
  (cond
   ;; Close frame
   ((= opcode #x8)
    (setf (k8s-exec--session-done-p sess) t))
   ;; Ping — echo as pong
   ((= opcode #x9)
    (process-send-string (k8s-exec--session-process sess)
                         (k8s-exec--encode-frame #xA payload)))
   ;; Pong — ignore
   ((= opcode #xA) nil)
   ;; Binary (the only data frame k8s sends)
   ((= opcode #x2)
    (when (> (length payload) 0)
      (let ((channel (aref payload 0))
            (body (substring payload 1)))
        (cond
         ((= channel 1)
          (push body (k8s-exec--session-stdout-chunks sess)))
         ((= channel 2)
          (push body (k8s-exec--session-stderr-chunks sess)))
         ((= channel 3)
          (setf (k8s-exec--session-error-payload sess)
                (concat (or (k8s-exec--session-error-payload sess) "") body)))))))))

(defun k8s-exec--filter (sess _proc data)
  "Process filter: feed DATA into SESS's parser."
  (setf (k8s-exec--session-raw sess)
        (concat (k8s-exec--session-raw sess) data))
  ;; Consume HTTP handshake response headers if not yet done.
  (unless (k8s-exec--session-headers-done sess)
    (let* ((raw (k8s-exec--session-raw sess))
           (sep (string-search "\r\n\r\n" raw)))
      (when sep
        (let ((headers (substring raw 0 sep)))
          (when (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\)" headers)
            (setf (k8s-exec--session-status-code sess)
                  (string-to-number (match-string 1 headers)))))
        (setf (k8s-exec--session-raw sess)
              (substring (k8s-exec--session-raw sess) (+ sep 4)))
        (setf (k8s-exec--session-headers-done sess) t))))
  ;; Then parse as many WebSocket frames as possible from the remainder.
  (when (k8s-exec--session-headers-done sess)
    (let ((pos 0)
          (raw (k8s-exec--session-raw sess))
          stop)
      (while (not stop)
        (let ((parsed (k8s-exec--parse-frame raw pos)))
          (if (null parsed)
              (setq stop t)
            (cl-destructuring-bind (_fin opcode payload end) parsed
              (k8s-exec--handle-frame sess opcode payload)
              (setq pos end)))))
      (setf (k8s-exec--session-raw sess) (substring raw pos)))))

(defun k8s-exec--sentinel (sess _proc _event)
  "Process sentinel: mark session done when peer closes."
  (setf (k8s-exec--session-done-p sess) t))

;;; ---------------------------------------------------------------------------
;;; Public API

(defcustom k8s-exec-default-timeout 10
  "Default timeout in seconds for a `k8s-exec' call."
  :type 'number
  :group 'k8s)

(defun k8s-exec--build-path (ns pod container command)
  "Build the K8s exec URL path with query params."
  (let ((cmd-params
         (mapconcat (lambda (arg)
                      (concat "command=" (url-hexify-string arg)))
                    command "&"))
        (container-param
         (if container
             (concat "&container=" (url-hexify-string container))
           "")))
    (format "/api/v1/namespaces/%s/pods/%s/exec?%s%s&stdout=true&stderr=true"
            (url-hexify-string ns)
            (url-hexify-string pod)
            cmd-params
            container-param)))

(defun k8s-exec (conn ns pod container command &optional timeout)
  "Run COMMAND inside POD in NS via CONN, returning a `k8s-exec-result'.
COMMAND is a list of strings (no shell interpolation).
CONTAINER may be nil for single-container pods.
TIMEOUT is in seconds (default `k8s-exec-default-timeout').
Signals an error if the connection or WebSocket handshake fails."
  (unless command
    (error "k8s-exec: command must be a non-empty list of strings"))
  (let* ((host (k8s-connection-host conn))
         (port (k8s-connection-port conn))
         (path (k8s-exec--build-path ns pod container command))
         (cert-file (k8s-connection-client-cert-file conn))
         (key-file (k8s-connection-client-key-file conn))
         (token (k8s-user-token (k8s-connection-user conn)))
         (ws-key (k8s-exec--ws-key))
         (gnutls-verify-error nil)
         (gnutls-algorithm-priority k8s-tls-priority)
         (buf (generate-new-buffer " *k8s-exec*"))
         (proc (apply #'open-network-stream "k8s-exec" buf host port
                      :type 'tls
                      (when (and cert-file key-file)
                        (list :client-certificate
                              (list key-file cert-file)))))
         (sess (k8s-exec--session-new
                :process proc
                :raw ""
                :stdout-chunks nil
                :stderr-chunks nil)))
    (unless proc
      (kill-buffer buf)
      (error "k8s-exec: failed to connect to %s:%d" host port))
    (set-process-coding-system proc 'binary 'binary)
    (set-process-query-on-exit-flag proc nil)
    (set-process-filter proc (lambda (p d) (k8s-exec--filter sess p d)))
    (set-process-sentinel proc (lambda (p e) (k8s-exec--sentinel sess p e)))
    ;; Send the WebSocket upgrade handshake (plain HTTP, not framed).
    (let ((req (concat
                (format "GET %s HTTP/1.1\r\n" path)
                (format "Host: %s:%d\r\n" host port)
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                (format "Sec-WebSocket-Key: %s\r\n" ws-key)
                "Sec-WebSocket-Version: 13\r\n"
                "Sec-WebSocket-Protocol: v4.channel.k8s.io\r\n"
                (when token
                  (format "Authorization: Bearer %s\r\n" token))
                "User-Agent: emak8s/0.1\r\n"
                "\r\n")))
      (process-send-string proc req))
    ;; Spin until the session ends or we hit the timeout.
    (let ((deadline (+ (float-time) (or timeout k8s-exec-default-timeout))))
      (while (and (not (k8s-exec--session-done-p sess))
                  (process-live-p proc)
                  (< (float-time) deadline))
        (accept-process-output proc 0.1)))
    (ignore-errors (delete-process proc))
    (ignore-errors (kill-buffer buf))
    (let* ((status-code (k8s-exec--session-status-code sess))
           (stdout (apply #'concat
                          (nreverse (k8s-exec--session-stdout-chunks sess))))
           (stderr (apply #'concat
                          (nreverse (k8s-exec--session-stderr-chunks sess))))
           (err-payload (k8s-exec--session-error-payload sess))
           (err-json (and err-payload
                          (ignore-errors
                            (let ((json-object-type 'alist)
                                  (json-array-type 'vector)
                                  (json-key-type 'symbol))
                              (json-read-from-string err-payload)))))
           (status (cdr (assq 'status err-json)))
           (message (cdr (assq 'message err-json)))
           (exit-code
            (when err-json
              (let* ((details (cdr (assq 'details err-json)))
                     (causes (cdr (assq 'causes details))))
                (cl-loop for c across (or causes [])
                         thereis (and (equal (cdr (assq 'reason c)) "ExitCode")
                                      (string-to-number
                                       (or (cdr (assq 'message c)) ""))))))))
      (unless (k8s-exec--session-headers-done sess)
        (error "k8s-exec: connection closed before handshake completed"))
      (when (and status-code (/= status-code 101))
        (error "k8s-exec: handshake failed (HTTP %d): %s"
               status-code (or stderr stdout "")))
      (k8s-exec-result--new
       :stdout stdout
       :stderr stderr
       :exit-code (cond (exit-code exit-code)
                        ((equal status "Success") 0)
                        (t nil))
       :status status
       :message message))))

(provide 'k8s-exec)
;;; k8s-exec.el ends here
