(defpackage :docker/request
  (:use :common-lisp)
  (:import-from :chunga)
  (:import-from :flexi-streams)
  (:import-from :yason)
  (:export #:request
           #:request-json
           #:query-string))

(in-package :docker/request)

(defun uncamel-case (string)
  "Convert a camelCase string into a dashed string."
  (declare (string string))
  (with-output-to-string (out)
    (with-input-from-string (in string)
      (loop
         for ch = (read-char in nil)
         while ch
         do (progn
              (write-char (char-upcase ch) out)
              (let ((next (peek-char nil in nil)))
                (when (and (characterp next) (upper-case-p next))
                  (write-char #\- out))))))))


(defun string-to-keyword (string)
  "Make a Lisp keyword from a camelCased string."
  (declare (string string))
  (intern (uncamel-case string) "KEYWORD"))



(define-condition docker-condition ()
  nil)

(define-condition docker-error (docker-condition error)
  nil)


;;;; Basic HTTP Client on Unix Domain Sockets
;;;
;;; It would be nice to use a real HTTP client as
;;; Drakma. Unfortunately, as far as I know it does not support Unix
;;; Domain Sockets. It would be great if Drakma to be refactored so it
;;; can operate on streams too so we could use it here.
;;; 

(defvar *crlf*
  (coerce #(#\return #\newline) 'string))

(defvar *docker-socket-pathname*
  "/var/run/docker.sock")

(defun open-docker-stream (&optional (pathname *docker-socket-pathname*))
  "Connect to the docker daemon and return a bidirectional
flexi-stream, which can be used to write and read from the daemon."

  ;; This function is implementation-dependant, because usocket does
  ;; not support Unix Domain Sockets. Is there any portability layer
  ;; for it?
  #-sbcl (error "Only SBCL is supported at the moment.")
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-connect socket pathname)
    (let ((raw-stream (sb-bsd-sockets:socket-make-stream
                       socket
                       :input
                       t :output t
                       :element-type '(unsigned-byte 8))))
      (flex:make-flexi-stream raw-stream :external-format :utf-8))))


(define-condition docker-protocol-error (docker-error)
  ((url
    :initarg :url
    :reader docker-protocol-error-url)
   (method
    :initarg :method
    :reader docker-protocol-error-method)
   (status-code
    :initarg :status-code
    :reader docker-protocol-error-status-code)
   (reason
    :initarg :reason
    :reader docker-protocol-error-reason))
  (:report
   (lambda (condition stream)
     (format stream "~a: ~a"
             (docker-protocol-error-status-code condition)
             (docker-protocol-error-reason condition)))))


;;; If it is non-NIL, the communication with the Docker daemon will be
;;; logged into the standard output.
(defvar *debug-protocol* nil)

;;; Like `read-line', but it trims trailing CR and LF character as
;;; well as support for logging for debugging purposes.
(defun read-line* (stream &optional (eof-error-p t))
  (let ((line (string-right-trim *crlf* (read-line stream eof-error-p))))
    (when *debug-protocol*
      (format t "~a~%" line))
    line))

;;; Like `format', but support logging for debugging purposes.
(defun format* (stream fmt &rest args)
  (when *debug-protocol*
    (format t "~?~%" fmt args))
  (apply #'format stream fmt args))

;;; Write a CR and a LF character to STREAM.
(defun write-crlf (stream)
  (write-string *crlf* stream))

(defun format-line* (stream fmt &rest args)
  (apply #'format* stream fmt args)
  (write-crlf stream))


(defun transfer-coding (headers)
  (let ((value (cdr (assoc :transfer-encoding headers))))
    (when value
      (subseq value 0 (or (position #\; value) (length value))))))

;;; Check if STREAM is a input binary stream.
(defun binary-input-stream-p (stream)
  (and (input-stream-p stream)
       (equal (stream-element-type stream) '(unsigned-byte 8))))

(defun parse-status-line (line)
  ;; HTTP-Version SP Status-Code SP Reason-Phrase CRLF
  (let* ((sp1 (position #\space line))
         (sp2 (position #\space line :start (1+ sp1))))
    (list (subseq line 0 sp1)
          (parse-integer (subseq line (1+ sp1) sp2))
          (subseq line (1+ sp2)))))


(defun request (url &key (method :get) content content-type)
  "Request a resource an Docker Remote API end-point.

It returns a stream as primary value and a associative list of HTTP
headers and values as strings."
  (let ((stream (open-docker-stream)))
    ;; Request resource
    (format* stream "~a ~a HTTP/1.1" method url)

    (when content-type
      (format-line* stream "Content-Type: ~a" content-type))

    (etypecase content
      (null)
      (string
       (format-line* stream "Content-Length: ~d" (length content)))
      (stream
       (unless (binary-input-stream-p content)
         (error "~S must be a binary input stream." content))
       (let ((content-length (and (typep content 'file-stream)
                                  (file-length content))))
         (if content-length
             (format-line* stream "Content-Length: ~d" content-length)
             (progn
               (format-line* stream "Transfer-Encoding: chunked")
               (setq content (chunga:make-chunked-stream content))
               (setf (chunga:chunked-stream-input-chunking-p content) t))))))

    (write-crlf stream)
    (write-crlf stream)
    (finish-output stream)

    ;; Send the request body
    (etypecase content
      (null)
      (string
       (write-string content stream))
      (stream
       (uiop/stream:copy-stream-to-stream content stream :element-type '(unsigned-byte 8))))
    

    ;; Process response
    (let ((status-line (read-line* stream)))
      (destructuring-bind (http-version status-code reason)
          (parse-status-line status-line)
        (unless (string= http-version "HTTP/1.1")
          (error "Protocol ~a is not supported." http-version))
        (unless (<= 200 status-code 299)
          (error 'docker-protocol-error
                 :method method
                 :url url
                 :status-code status-code
                 :reason reason))

        (let* ((headers (chunga:read-http-headers stream (and *debug-protocol* *standard-output*)))
               (transfer-coding (transfer-coding headers))
               (content-stream
                (when (/= status-code 204)
                  (let ((chunked (chunga:make-chunked-stream stream)))
                    (when (equalp transfer-coding "chunked")
                      (setf (chunga:chunked-stream-input-chunking-p chunked) t))
                    (flex:make-flexi-stream chunked :external-format :utf-8)))))

          (values content-stream headers))))))



(defun request-json (url &rest args &key &allow-other-keys)
  (multiple-value-bind (stream headers)
      (apply #'request url args)
    (declare (ignorable headers))
    (when stream
      (with-open-stream (stream stream)
        (yason:parse stream
                     :object-key-fn #'string-to-keyword
                     :object-as :plist)))))


(defun query-string (&rest plist)
  (with-output-to-string (out)
    (let ((plist (loop
                    for (x y) on plist by #'cddr
                    unless (null y)
                    collect x
                    collect y)))
      (when plist
        (destructuring-bind (attr value &rest others) plist
          (declare (ignore others))
          (format out "?~a=~a" attr value)))
      (loop
         for (attr value) on (cddr plist) by #'cddr
         do (format out "&~a=~a" attr value)))))