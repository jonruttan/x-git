; # x-git -- git on x-lang
;
; ## tests/http-server.x -- git http-backend served over http, for 30-http
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Run as `x -f tests/http-server.x` with HT_ROOT the directory of
; repositories to serve and HT_DIR a directory of its own: it listens on
; 127.0.0.1 at a port the kernel picks, writes that port to HT_DIR/port
; and its pid to HT_DIR/pid, and answers each request in turn by running
; `git http-backend` as a CGI program -- the request in its environment,
; its body on its input -- and sending back what the backend wrote, with
; the backend's Status: as the status line.  It serves until killed.

(import x/sys/socket)
(import x/sys/file)
(import x/sys/proc)

(def %root (Sys getenv "HT_ROOT"))
(def %dir (Sys getenv "HT_DIR"))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %ptr (prim-ref (lit str) (lit ->ptr)))
(def %make (prim-ref (lit str) (lit make)))
(def %copy (prim-ref (lit mem) (lit copy)))
(def %at (fn (_ p off) ((prim-ref (lit int) (lit ->ptr)) (+ ((prim-ref (lit ptr) (lit ->int)) p) off))))

; A growing buffer: (REGION . COUNT) in a vector's two slots.
(def %buf (fn (_) (let ((v (Vector make 2 0))) (do (Vector set! 0 (%make 65536) v) (Vector set! 1 0 v) v))))
(def %put!
  (fn (_ b p n)
    (def have (Vector ref 1 b))
    (def cap (Str8 length (Vector ref 0 b)))
    (when (> (+ have n) cap)
      (let ((r (%make (* 2 (+ have n)))))
        (do (%copy (%ptr r) (%ptr (Vector ref 0 b)) have) (Vector set! 0 r b))))
    (%copy (%at (%ptr (Vector ref 0 b)) have) p n)
    (Vector set! 1 (+ have n) b)))

; Where "\r\n\r\n" starts in the buffer, or ().
(def %blank
  (fn (_ b)
    (def p (%ptr (Vector ref 0 b)))
    (def n (Vector ref 1 b))
    ((fn (self i)
       (match ((> (+ i 4) n) ())
              ((and (= (%pref p i 1) 13) (= (%pref p (+ i 1) 1) 10) (= (%pref p (+ i 2) 1) 13) (= (%pref p (+ i 3) 1) 10)) i)
              (#t (self (+ i 1)))))
     0)))

(def %text (fn (_ b k) (let ((s (%make (+ k 1)))) (do (%copy (%ptr s) (%ptr (Vector ref 0 b)) k) (Str8 sub 0 k s)))))

; k bytes from at of the buffer written to path.
(def %write-out
  (fn (_ b at k path)
    (def fd (File open path (list (lit wronly) (lit creat) (lit trunc)) 420))
    (when (> k 0)
      (let ((s (%make k))) (do (%copy (%ptr s) (%at (%ptr (Vector ref 0 b)) at) k) (File write fd s k))))
    (File close fd)))

; A file's bytes into a buffer.
(def %read-in
  (fn (_ path)
    (def b (%buf))
    (def fd (File open path (lit rdonly)))
    (def chunk (%make 65536))
    ((fn (self) (let ((got (File read fd chunk 65536))) (when (> got 0) (do (%put! b (%ptr chunk) got) (self))))))
    (File close fd)
    b))

; One connection answered.
(def %serve
  (fn (_ c)
    (def b (%buf))
    (def head-end
      ((fn (self)
         (let ((at (%blank b)))
           (if (not (null? at)) at
             (let ((run (Socket recv-run c 65536)))
               (if (null? run) () (do (%put! b (%ptr (first run)) (rest run)) (self)))))))))
    (def lines (Str8 split "\r\n" (%text b head-end)))
    (def words (Str8 split " " (first lines)))
    (def target (first (rest words)))
    (def q (Str8 index-of "?" target))
    (def header
      (fn (_ name)
        (let ((l (List find (fn (_ l) (Str8 starts? (Str8 append name ":") (Str8 downcase l))) (rest lines))))
          (if (null? l) "" (Str8 trim (Str8 sub (+ (Str8 length name) 1) (- (Str8 length l) (+ (Str8 length name) 1)) l))))))
    (def want (let ((cl (header "content-length"))) (if (= (Str8 length cl) 0) 0 (%str->number cl 10))))
    ((fn (self)
       (when (< (Vector ref 1 b) (+ head-end 4 want))
         (let ((run (Socket recv-run c 65536))) (unless (null? run) (do (%put! b (%ptr (first run)) (rest run)) (self)))))))
    (%write-out b (+ head-end 4) want (Str8 append %dir "/body"))
    (List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
      (list (pair "GIT_PROJECT_ROOT" %root) (pair "GIT_HTTP_EXPORT_ALL" "1")
            (pair "REQUEST_METHOD" (first words))
            (pair "PATH_INFO" (if (null? q) target (Str8 sub 0 q target)))
            (pair "QUERY_STRING" (if (null? q) "" (Str8 sub (+ q 1) (- (Str8 length target) (+ q 1)) target)))
            (pair "CONTENT_TYPE" (header "content-type")) (pair "CONTENT_LENGTH" (Str8 str want))))
    (Proc run! (list "/bin/sh" "-c" "exec git http-backend < \"$0/body\" > \"$0/out\"" %dir))
    (def out (%read-in (Str8 append %dir "/out")))
    (def cgi-end (%blank out))
    (def cgi (Str8 split "\r\n" (%text out cgi-end)))
    (def status (List find (fn (_ l) (Str8 starts? "Status:" l)) cgi))
    (def n (- (Vector ref 1 out) (+ cgi-end 4)))
    (Socket send c
      (Str8 append "HTTP/1.1 " (if (null? status) "200 OK" (Str8 trim (Str8 sub 7 (- (Str8 length status) 7) status))) "\r\n"
        (Str8 join "" (List map (fn (_ l) (Str8 append l "\r\n")) (List filter (fn (_ l) (not (Str8 starts? "Status:" l))) cgi)))
        "Content-Length: " (Str8 str n) "\r\nConnection: close\r\n\r\n"))
    (when (> n 0)
      (let ((s (%make n))) (do (%copy (%ptr s) (%at (%ptr (Vector ref 0 out)) (+ cgi-end 4)) n) (Socket send-run c s n))))
    (Socket close c)))

(def %listen (Socket tcp-listen-on "127.0.0.1" 0))
(File write-all (Str8 append %dir "/pid") (Str8 str (Sys getpid)))
(File write-all (Str8 append %dir "/port") (Str8 str (Socket local-port %listen)))
((fn (self)
   (do (guard (e (File write-all (Str8 append %dir "/error") (Str8 str (e msg)))) (%serve (Socket accept %listen)))
       (Heap collect)
       (self))))
