; # x-git -- git on x-lang
;
; ## git/http.x -- git's smart http transport
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A service over http or https (gitprotocol-http), spoken through a wire
; as a service on pipes is: the advertisement comes from a GET of
; URL/info/refs?service=git-SERVICE -- its "# service=" packet and flush
; read past -- and each turn of the conversation after it is a POST of
; URL/git-SERVICE.  The service keeps nothing between requests, so each
; POST carries everything said since the advertisement, as git's own
; client sends it: the wants, then every round of haves, the last round
; ending in a flush (more to come) or done.  What is written to the wire
; is held until it is read from again; that read sends it, and goes on
; in the reply.
;
; https would be x-lang's Tls -- the server's certificate checked against
; Mozilla's roots, unless http.sslVerify is false or GIT_SSL_NO_VERIFY is
; set -- but it is refused for now: reading a real server's first reply
; through it, x-git runs out of memory where x-lang's Http alone does
; not.  What went wrong is left in git's words for the command to say,
; through http-refusal.  Fetching only: a push's pack is binary, and
; Http's request body is text.

(module git/http)

(import x/sys/posix Sys)
(import x/type/vector Vector)
(import x/sys/gc Heap)
(import git/wire wire-of-driver wire-pkt wire-line)
(import git/packs git-bytes-make git-bytes-put! git-bytes-region git-bytes-count)
(import git/config git-config-value)

(def %add (prim-ref (lit int) (lit +)))
(def %sub (prim-ref (lit int) (lit -)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))

; What went wrong the last time a service was reached by http, in git's
; words, or ().
(def %refusal ())
(def http-refusal (fn (_) %refusal))

; The last refusal forgotten, when a service is reached any other way.
(def http-forget! (fn (_) (set! %refusal ())))

(def %refuse! (fn (_ text) (do (set! %refusal text) ())))

; x-lang's Http, loaded the first time a service is reached by http and
; not before: it brings Tls, and Tls the compiled engines and the
; toolchain that builds them, which every other x-git process -- each
; service git starts, each command -- would otherwise load, and with
; them pay to compile an engine for a long enough digest.
(def %Http ())
(def %load-http!
  (fn (_)
    (import x/net/http Http)
    (set! %Http Http)))

; A url without its trailing slashes, as git joins paths to it.
(def %base
  (fn (self url) (if (Str8 ends? "/" url) (self (Str8 sub 0 (%sub (Str8 length url) 1) url)) url)))

; Http's options: the certificate unchecked when git is told not to
; check it.
(def %opts
  (fn (_ gitdir)
    (def v (git-config-value gitdir "http.sslVerify"))
    (def env (Sys getenv "GIT_SSL_NO_VERIFY"))
    (if (or (and (not (null? v)) (List any? (fn (_ w) (Str8 ci=? v w)) (list "false" "no" "off" "0")))
            (and (not (null? env)) (> (Str8 length env) 0)))
      (list (list (lit insecure)))
      ())))

; The bytes held as a string.
(def %text
  (fn (_ b)
    (def n (git-bytes-count b))
    (def s (%make-str (if (= n 0) 1 n)))
    (when (> n 0) (%mem-copy (%str->ptr s) (%str->ptr (git-bytes-region b)) n))
    (Str8 sub 0 n s)))

(def %header
  (fn (_ s name) (let ((e (List find (fn (_ kv) (str=? (first kv) name)) (s headers)))) (if (null? e) "" (rest e)))))

; A wire's state: the stream read now, what is written and not yet sent,
; what earlier requests said, sent again first.
(def %stream (fn (_ st) (Vector ref 0 st)))
(def %pending (fn (_ st) (Vector ref 1 st)))
(def %said (fn (_ st) (Vector ref 2 st)))

; A service at url as a wire, its advertisement next to be read; () when
; there is none to be had, the reason left for http-refusal.
(def http-connect
  (fn (_ url service gitdir)
    (set! %refusal ())
    (def base (%base url))
    (def shown (Str8 append base "/"))
    (def opts (%opts gitdir))
    ; an exchange, or () with its failure the refusal; x collects only when
    ; asked, and a TLS handshake leaves its garbage behind, so each
    ; exchange collects once it is open
    (def open
      (fn (_ method path headers body)
        (guard (e (%refuse! (Str8 append "fatal: unable to access '" shown "': " (e msg) "\n")))
          (let ((s (if (null? opts) (%Http open method (Str8 append base path) headers body)
                     (%Http open method (Str8 append base path) headers body opts))))
            (do (Heap collect) s)))))
    (match
      ((Str8 starts? "https://" url)
        (%refuse! (Str8 append "fatal: unable to access '" shown "': https is not yet supported by x-git\n")))
      ((str=? service "receive-pack")
        (%refuse! (Str8 append "fatal: unable to access '" shown "': pushing over http is not supported by x-git\n")))
      (#t
       (do (when (null? %Http) (%load-http!))
           (%advertised (open "GET" (Str8 append "/info/refs?service=git-" service) (list (pair "Pragma" "no-cache")) ())
                        shown service open))))))

; The wire on the advertisement's stream s, or the refusal its status
; calls for.
(def %advertised
  (fn (_ s shown service open)
    (match
      ((null? s) ())
      ((= (s status) 404) (do (%Http close s) (%refuse! (Str8 append "fatal: repository '" shown "' not found\n"))))
      ((= (s status) 401) (do (%Http close s) (%refuse! (Str8 append "fatal: Authentication failed for '" shown "'\n"))))
      ((not (= (s status) 200))
        (do (%Http close s)
            (%refuse! (Str8 append "fatal: unable to access '" shown "': The requested URL returned error: " (Str8 str (s status)) "\n"))))
      ((not (str=? (%header s "content-type") (Str8 append "application/x-git-" service "-advertisement")))
        (do (%Http close s)
            (%refuse! (Str8 append "fatal: unable to access '" shown "': not a smart http server, which x-git needs\n"))))
      (#t
        (let ((st (Vector make 3 ())))
          (do (Vector set! 0 s st)
              (Vector set! 1 (git-bytes-make) st)
              (Vector set! 2 "" st)
              (let ((w (wire-of-driver
                         (fn (_ r at n) (git-bytes-put! (%pending st) (%at (%str->ptr r) at) n))
                         (fn (_ region max)
                           (when (> (git-bytes-count (%pending st)) 0) (%post! st service open))
                           (let ((run (%Http read (%stream st) max)))
                             (if (null? run) 0
                               (do (%mem-copy (%str->ptr region) (%str->ptr (first run)) (rest run)) (rest run)))))
                         (fn (_) (%Http close (%stream st))))))
                ; the advertisement's first packet names the service, a flush after it
                (let ((head (wire-line w)))
                  (if (or (not (pair? head)) (not (Str8 starts? "# service=" (first head))))
                    (do (%Http close (%stream st)) (%refuse! (Str8 append "fatal: unable to access '" shown "': a bad advertisement\n")))
                    (do (wire-pkt w) w))))))))))

; What was written since the last read sent as the next request, after
; all that went before it; its reply the stream read from now.  A request
; that ends in a flush is one round of more to come: what it said is
; said again, the flush aside, at the head of the next.
(def %post!
  (fn (_ st service open)
    (def req (Str8 append (%said st) (%text (%pending st))))
    (%Http close (%stream st))
    (Vector set! 1 (git-bytes-make) st)
    (Vector set! 2 (if (Str8 ends? "0000" req) (Str8 sub 0 (%sub (Str8 length req) 4) req) req) st)
    (def reply
      (open "POST" (Str8 append "/git-" service)
        (list (pair "Content-Type" (Str8 append "application/x-git-" service "-request"))
              (pair "Accept" (Str8 append "application/x-git-" service "-result")))
        req))
    (when (or (null? reply) (not (= (reply status) 200)))
      (Err raise (lit value) (Str8 append "git: the " service " request failed") ()))
    (Vector set! 0 reply st)))

(provide git/http http-connect http-refusal http-forget!)
