; # x-git -- git on x-lang
;
; ## git/wire.x -- a git service on two pipes, spoken in pkt-lines
;
; @description The transport under fetch and push to another process:
;   the service -- git-upload-pack or git-receive-pack, here or through a
;   shell on another host -- is a child whose standard input and output
;   are pipes, and what crosses them is pkt-line framed (gitprotocol-common):
;   four hex digits of length, counting themselves, then the bytes; 0000
;   is a flush, 0001 a delimiter.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A wire is a vector: 1 the child's pid, 2 the end we write, 3 the end we
; read, 4 the read buffer, 5 its size, 6 and 7 where the unread bytes
; start and end in it, 8 the region each read lands in, 9 a driver or ().
; The child's standard error is ours: git's services say what is wrong
; on it themselves, and git lets them.
;
; A driver stands for the pipes when the service is no child: (SEND!
; RECV! CLOSE!), SEND! of (REGION AT N) taking bytes written, RECV! of
; (REGION MAX) putting up to MAX bytes read in REGION and answering how
; many (0 at the end), CLOSE! of nothing.  An http exchange is one.

(module git/wire)

(import x/sys/file File)
(import x/sys/posix Sys)
(import x/type/vector Vector)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset! (prim-ref (lit ptr) (lit set!)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %str-byte-len (prim-ref (lit str) (lit byte-len)))
(def %oref (prim-ref (lit obj) (lit ref)))
(def %oset! (prim-ref (lit obj) (lit set!)))

(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))
(def %byte (fn (_ p i) (& (%pref p i 1) 255)))

(def %fail (fn (_ what) (Err raise (lit value) (Str8 append "git: " what) ())))

(def %CHUNK 65536)

; --- the child ---

; The command run with its input and output ours: a wire.  The child
; dies on any failure before its exec, as Proc's children do, so no
; second interpreter ever returns into the caller.
(def wire-open
  (fn (_ argv)
    (def i (Sys pipe))
    (def o (Sys pipe))
    (def pid (Sys fork))
    (when (< pid 0) (%fail "cannot fork"))
    (when (= pid 0)
      (guard (e (Sys exit 125))
        (do (Sys dup2 (first i) 0)
            (Sys dup2 (rest o) 1)
            (Sys close (first i)) (Sys close (rest i)) (Sys close (first o)) (Sys close (rest o))
            (Sys exec (first argv) (rest argv))))
      (Sys exit 127))
    (Sys close (first i))
    (Sys close (rest o))
    (%wire pid (rest i) (first o) ())))

(def %wire
  (fn (_ pid out in driver)
    (def w (Vector make 9 0))
    (%oset! w 1 pid)
    (%oset! w 2 out)
    (%oset! w 3 in)
    (%oset! w 4 (%make-str %CHUNK))
    (%oset! w 5 %CHUNK)
    (%oset! w 6 0)
    (%oset! w 7 0)
    (%oset! w 8 (%make-str %CHUNK))
    (%oset! w 9 driver)
    w))

; A wire on descriptors this process already has: a service's own
; standard input and output, with no child behind them.
(def wire-of-fds
  (fn (_ in out) (%wire -1 out in ())))

; A wire through a driver, (SEND! RECV! CLOSE!), with neither pipes nor
; child.
(def wire-of-driver
  (fn (_ send! recv! close!) (%wire -1 -1 -1 (list send! recv! close!))))

(def %driver (fn (_ w) (%oref w 9)))

; Our end of the child's input closed: it reads EOF.
(def wire-close-in!
  (fn (_ w)
    (unless (< (%oref w 2) 0) (do (Sys close (%oref w 2)) (%oset! w 2 -1)))))

; Both ends closed and the child waited for; answers how it ended.  A
; driver's wire closes through its driver, and ends well; no wire at all
; (an http service that could not be reached) is nothing to close.
(def wire-close!
  (fn (_ w)
    (match
      ((null? w) 0)
      ((not (null? (%driver w))) (do ((first (rest (rest (%driver w))))) 0))
      (#t (do (wire-close-in! w)
              (Sys close (%oref w 3))
              (Sys wait (%oref w 1)))))))

; The bytes that come next, outside any packet: what the buffer holds
; unread, or one read's worth when it holds none.  (REGION . N), or ()
; at the end of the input.
(def wire-raw
  (fn (_ w)
    (def n (%sub (%oref w 7) (%oref w 6)))
    (if (if (> n 0) #t (%fill! w 1))
      (let ((k (%sub (%oref w 7) (%oref w 6))))
        (pair (%take! w k) k))
      ())))

; --- reading ---

; At least n unread bytes in the buffer, or #f when the child's output
; ended first.  The unread bytes move to the front when the room after
; them is short; the buffer grows when they would not fit at all.  A read
; takes what room there is after them, up to a chunk: once they are at the
; front, n fitting means some room is left, so each pass reads.  (Moving
; them only when they were already at the front looped forever, a read
; that ended inside a packet leaving the room short of a chunk.)
(def %fill!
  (fn (self w n)
    (def start (%oref w 6))
    (def end (%oref w 7))
    (def room (%sub (%oref w 5) end))
    (match
      ((>= (%sub end start) n) #t)
      ((> n (%oref w 5))
        (do (def cap ((fn (grow c) (if (< c n) (grow (* c 2)) c)) (* (%oref w 5) 2)))
            (def r (%make-str cap))
            (%mem-copy (%str->ptr r) (%at (%str->ptr (%oref w 4)) start) (%sub end start))
            (%oset! w 4 r) (%oset! w 5 cap) (%oset! w 6 0) (%oset! w 7 (%sub end start))
            (self w n)))
      ((and (> start 0) (< room %CHUNK))
        (do (%mem-copy (%str->ptr (%oref w 4)) (%at (%str->ptr (%oref w 4)) start) (%sub end start))
            (%oset! w 6 0) (%oset! w 7 (%sub end start))
            (self w n)))
      (#t
        (let ((got (if (null? (%driver w)) (File read (%oref w 3) (%oref w 8) (if (< room %CHUNK) room %CHUNK))
                     ((first (rest (%driver w))) (%oref w 8) (if (< room %CHUNK) room %CHUNK)))))
          (if (<= got 0) #f
            (do (%mem-copy (%at (%str->ptr (%oref w 4)) end) (%str->ptr (%oref w 8)) got)
                (%oset! w 7 (%add end got))
                (self w n))))))))

; n unread bytes taken: a fresh region holding them, or () at the end of
; the child's output.
(def %take!
  (fn (_ w n)
    (if (not (%fill! w n)) ()
      (let ((r (%make-str (if (= n 0) 1 n))))
        (do (%mem-copy (%str->ptr r) (%at (%str->ptr (%oref w 4)) (%oref w 6)) n)
            (%oset! w 6 (%add (%oref w 6) n))
            r)))))

(def %hex-value
  (fn (_ c)
    (match
      ((and (>= c 48) (<= c 57)) (%sub c 48))
      ((and (>= c 97) (<= c 102)) (%sub c 87))
      ((and (>= c 65) (<= c 70)) (%sub c 55))
      (#t (%fail "a pkt-line length that is not hex")))))

; The next packet: (REGION . N) its bytes, flush for 0000, delim for 0001,
; or () when the child's output ended.
(def wire-pkt
  (fn (_ w)
    (def h (%take! w 4))
    (if (null? h) ()
      (let ((p (%str->ptr h)))
        (let ((len (| (<< (%hex-value (%byte p 0)) 12)
                      (| (<< (%hex-value (%byte p 1)) 8)
                         (| (<< (%hex-value (%byte p 2)) 4) (%hex-value (%byte p 3)))))))
          (match
            ((= len 0) (lit flush))
            ((= len 1) (lit delim))
            ((< len 4) (%fail "a pkt-line shorter than its own length"))
            (#t (let ((r (%take! w (%sub len 4))))
                  (if (null? r) (%fail "the connection ended inside a pkt-line")
                    (pair r (%sub len 4)))))))))))

; The next packet as text, its trailing newline dropped: a string, flush,
; delim or ().  A NUL inside stays in the string; wire-split finds it.
(def wire-line
  (fn (_ w)
    (def pk (wire-pkt w))
    (if (not (pair? pk)) pk
      (let ((n (rest pk)) (p (%str->ptr (first pk))))
        (let ((k (if (and (> n 0) (= (%byte p (%sub n 1)) 10)) (%sub n 1) n)))
          (let ((s (%make-str k)))
            (do (when (> k 0) (%mem-copy (%str->ptr s) p k))
                (pair s k))))))))

; A line's text at the NUL: (BEFORE . AFTER), AFTER () without one.
; The line is (STRING . N) as wire-line answers it.
(def wire-split
  (fn (_ line)
    (def p (%str->ptr (first line)))
    (def n (rest line))
    (def nul ((fn (self i) (match ((>= i n) ()) ((= (%byte p i) 0) i) (#t (self (%add i 1))))) 0))
    (def text (fn (_ start k) (let ((s (%make-str (if (= k 0) 1 k)))) (do (when (> k 0) (%mem-copy (%str->ptr s) (%at p start) k)) (when (= k 0) (%pset! (%str->ptr s) 0 0 1)) s))))
    (if (null? nul) (pair (text 0 n) ())
      (pair (text 0 nul) (text (%add nul 1) (%sub n (%add nul 1)))))))

; --- writing ---

(def %hex-digit (fn (_ v) (if (< v 10) (%add v 48) (%add v 87))))

; n bytes of region r written to fd, every one of them.
(def %write-all!
  (fn (self fd r at n)
    (when (> n 0)
      (let ((w (File write fd (if (= at 0) r (let ((s (%make-str n))) (do (%mem-copy (%str->ptr s) (%at (%str->ptr r) at) n) s))) n)))
        (do (when (<= w 0) (%fail "the connection closed while writing"))
            (self fd r (%add at w) (%sub n w)))))))

; n bytes of region r from at sent on the wire: to the child's input, or
; to its driver.
(def %out!
  (fn (_ w r at n)
    (if (null? (%driver w)) (%write-all! (%oref w 2) r at n) ((first (%driver w)) r at n))))

; n bytes of region r sent as one packet.
(def wire-send-bytes!
  (fn (_ w r n)
    (def len (%add n 4))
    (when (> len 65520) (%fail "a pkt-line longer than 65520 bytes"))
    (def pk (%make-str len))
    (def p (%str->ptr pk))
    (%pset! p 0 (%hex-digit (& (>> len 12) 15)) 1)
    (%pset! p 1 (%hex-digit (& (>> len 8) 15)) 1)
    (%pset! p 2 (%hex-digit (& (>> len 4) 15)) 1)
    (%pset! p 3 (%hex-digit (& len 15)) 1)
    (when (> n 0) (%mem-copy (%at p 4) (%str->ptr r) n))
    (%out! w pk 0 len)))

; A text line sent as one packet, a newline after it, as git sends its
; own.
(def wire-send!
  (fn (_ w text)
    (def s (Str8 append text "\n"))
    (wire-send-bytes! w s (%str-byte-len s))))

(def wire-flush!
  (fn (_ w) (%out! w "0000" 0 4)))

; n bytes of region r sent as they are, outside any packet: a pack.
(def wire-send-raw!
  (fn (_ w r n) (%out! w r 0 n)))

(provide git/wire wire-open wire-of-fds wire-of-driver wire-close! wire-close-in! wire-pkt wire-line wire-split wire-raw
  wire-send! wire-send-bytes! wire-flush! wire-send-raw!)
