; # x-git -- git on x-lang
;
; ## git/protocol.x -- the client side of git's pack protocol
;
; @description What a fetch says to git-upload-pack (gitprotocol-pack,
;   version 0, the one every git speaks): the service advertises its refs
;   and capabilities; the client wants tips, says what it has in rounds
;   of thirty-two until the service has found enough in common or is
;   ready, says done, and takes the pack on side band 1.  The service
;   runs where the url says: for file:// it is a child here, which is
;   also what a shell on another host would run.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)

(module git/protocol)

(import git/wire wire-open wire-close! wire-pkt wire-line wire-split wire-send! wire-flush!)
(import git/packs git-bytes-make git-bytes-put! git-bytes-region git-bytes-count)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))

(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))
(def %byte (fn (_ p i) (& (%pref p i 1) 255)))

(def %fail (fn (_ what) (Err raise (lit value) (Str8 append "git: " what) ())))

; What this client asks of upload-pack: detailed acks, the pack on side
; band 1 in 64K packets, deltas by offset, no progress on band 2, and
; the annotated tags of what is sent.
(def %fetch-caps "multi_ack_detailed side-band-64k ofs-delta no-progress include-tag agent=x-git")

; --- the url ---

; A url this module serves: file:// for now.
(def proto-url?
  (fn (_ url) (if (null? url) #f (Str8 starts? "file://" url))))

(def %url-path
  (fn (_ url) (Str8 sub 7 (%sub (Str8 length url) 7) url)))

; The service opened for a url: a wire to git-upload-pack or
; git-receive-pack on the repository the url names.
(def proto-connect
  (fn (_ url service)
    (wire-open (list "git" service (%url-path url)))))

; --- the advertisement ---

; "SHA NAME" as (NAME . SHA).
(def %ref-entry
  (fn (_ text)
    (when (< (Str8 length text) 42) (%fail (Str8 append "a ref line too short: " text)))
    (pair (Str8 sub 41 (%sub (Str8 length text) 41) text) (Str8 sub 0 40 text))))

; A text line, or a remote error raised in git's words.
(def %text-line
  (fn (_ w)
    (def l (wire-line w))
    (when (and (pair? l) (Str8 starts? "ERR " (first l)))
      (%fail (Str8 append "remote error: " (Str8 sub 4 (%sub (rest l) 4) (first l)))))
    l))

; What the service advertises, read to its flush: (REFS CAPS), REFS each
; (NAME . SHA) in the service's order with a peeled tag as "NAME^{}" after
; its tag, CAPS the capability words.  () when the service said nothing,
; as git-upload-pack does on a path that is no repository.
(def proto-advertise
  (fn (_ w)
    (def l (%text-line w))
    (match
      ((null? l) ())
      ((not (pair? l)) (list () ()))
      (#t
        (let ((sp (wire-split l)))
          (let ((caps (if (null? (rest sp)) () (List filter (fn (_ c) (> (Str8 length c) 0)) (Str8 split " " (rest sp)))))
                (entry (%ref-entry (first sp))))
            (let ((more ((fn (self acc)
                           (let ((l2 (%text-line w)))
                             (if (pair? l2) (self (pair (%ref-entry (first l2)) acc)) (List reverse acc))))
                         ())))
              (list (List filter (fn (_ e) (not (str=? (first e) "capabilities^{}"))) (pair entry more))
                    caps))))))))

; The value a parameterized capability carries, "symref=HEAD:refs/heads/main"
; answering "refs/heads/main" for "symref=HEAD:"; () when absent.
(def proto-cap
  (fn (_ caps prefix)
    (def hit (List find (fn (_ c) (Str8 starts? prefix c)) caps))
    (if (null? hit) () (Str8 sub (Str8 length prefix) (%sub (Str8 length hit) (Str8 length prefix)) hit))))

(def %has-cap? (fn (_ caps name) (List any? (fn (_ c) (str=? c name)) caps)))

; --- negotiation ---

(def %member? (fn (_ s l) (List any? (fn (_ x) (str=? x s)) l)))

; The acks after a flush, read to the NAK: (COMMON . READY?), COMMON the
; commits acked common.
(def %acks
  (fn (self w common ready?)
    (def l (%text-line w))
    (match
      ((null? l) (%fail "the connection ended during negotiation"))
      ((not (pair? l)) (self w common ready?))
      ((str=? (first l) "NAK") (pair common ready?))
      ((Str8 starts? "ACK " (first l))
        (let ((sha (Str8 sub 4 40 (first l)))
              (status (if (> (rest l) 45) (Str8 sub 45 (%sub (rest l) 45) (first l)) "")))
          (self w (if (%member? sha common) common (pair sha common))
                (if (str=? status "ready") #t ready?))))
      (#t (%fail (Str8 append "an unexpected reply during negotiation: " (first l)))))))

; The pack after done: the acks skipped, band 1 gathered to the flush,
; band 3 raised.  Answers (REGION . N).
(def %receive-pack!
  (fn (_ w)
    (def b (git-bytes-make))
    ((fn (self)
       (def pk (wire-pkt w))
       (match
         ((null? pk) (%fail "the connection ended before the pack did"))
         ((eq? pk (lit flush)) (pair (git-bytes-region b) (git-bytes-count b)))
         ((eq? pk (lit delim)) (self))
         (#t
           (let ((p (%str->ptr (first pk))) (n (rest pk)))
             (let ((band (if (> n 0) (%byte p 0) 0)))
               (match
                 ((= band 1) (do (git-bytes-put! b (%at p 1) (%sub n 1)) (self)))
                 ((= band 2) (self))
                 ((= band 3) (%fail (Str8 append "remote error: " (Str8 sub 1 (%sub n 1) (first pk)))))
                 (#t (self))))))))
     ())))

; The haves sent in rounds: tips first, then their parents, breadth
; first, up to thirty-two a round; a commit the service acked common is
; not walked past.  Done when the service is ready, when there is
; nothing left to say, or after 256 haves none of which it had.
(def %negotiate!
  (fn (_ w tips parents)
    ((fn (self queue seen common unacked)
       ; the round's haves: the next thirty-two of the queue not yet sent
       ; and not known common
       (def round
         ((fn (take q k acc)
            (if (or (null? q) (= k 0)) (pair (List reverse acc) q)
              (if (or (%member? (first q) seen) (%member? (first q) common))
                (take (rest q) k acc)
                (take (rest q) (%sub k 1) (pair (first q) acc)))))
          queue 32 ()))
       (def haves (first round))
       (List for-each (fn (_ sha) (wire-send! w (Str8 append "have " sha))) haves)
       (def seen2 (List append haves seen))
       ; what the round's commits lead to, queued after what is left
       (def next
         (List append (rest round) (List flat-map (fn (_ sha) (parents sha)) haves)))
       (if (or (null? haves) (null? next))
         (wire-send! w "done")
         (do (wire-flush! w)
             (let ((a (%acks w common #f)))
               (let ((common2 (first a))
                     (unacked2 (if (= (List length (first a)) (List length common)) (%add unacked (List length haves)) 0)))
                 (if (or (rest a) (>= unacked2 256))
                   (wire-send! w "done")
                   (self next seen2 common2 unacked2)))))))
     tips () () 0)))

; The objects behind wants fetched from the service on w, which has
; advertised: () when nothing is wanted, else (REGION . N) the pack.
; tips are the commits this repository has, parents answers a commit's
; parents, () for one it does not have.
(def proto-fetch!
  (fn (_ w wants tips parents)
    (if (null? wants) (do (wire-flush! w) ())
      (do (wire-send! w (Str8 append "want " (first wants) " " %fetch-caps))
          (List for-each (fn (_ sha) (wire-send! w (Str8 append "want " sha))) (rest wants))
          (wire-flush! w)
          (%negotiate! w tips parents)
          (%receive-pack! w)))))

; What git prints after a service that said nothing: the service has said
; why on its own standard error.
(def proto-cannot-read
  (Str8 append "fatal: Could not read from remote repository.\n\n"
    "Please make sure you have the correct access rights\n"
    "and the repository exists.\n"))

(provide git/protocol proto-url? proto-connect proto-advertise proto-cap proto-fetch! proto-cannot-read)
