; # x-git -- git on x-lang
;
; ## git/serve.x -- upload-pack and receive-pack, the services
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The far end of git's pack protocol (gitprotocol-pack, version 0), as git
; runs it: a client starts `upload-pack DIR` or `receive-pack DIR` with its
; standard input and output on pipes -- a shell here for file://, or ssh on
; another host -- and the conversation is on them.
;
; upload-pack advertises the repository's refs and serves a fetch: it takes
; the wants, answers the haves as git does when no multi_ack is asked (the
; first common one acked, NAK on a flush until there is one), and sends the
; objects the client lacks as one pack, on side band 1 when it asked, with
; the annotated tags of what is sent when it asked for include-tag.
;
; receive-pack advertises the refs and takes a push: the commands, the pack
; (read entry by entry, since a pack says how many entries it holds, not
; how long it is), then each ref moved or refused in receive-pack's words --
; HEAD's branch is not deleted, and a non-bare repository's checked-out
; branch is not updated -- and the report sent back.

(module git/serve)

(import x/sys/file File)
(import x/sys/posix Sys)
(import git/clone git-source-gitdir)
(import git/objects git-object-read git-object-text)
(import git/refs git-ref-read)
(import git/repo git-refs-under git-unpack-ref!)
(import git/packs git-pack-bytes git-pack-index! git-pack-scan git-pack-count
  git-bytes-make git-bytes-put! git-bytes-region git-bytes-count)
(import git/remote git-advertised git-objects-to-send git-has-object? git-write-ref!
  git-current-branch git-deny-current)
(import git/wire wire-of-fds wire-line wire-split wire-raw wire-send! wire-send-bytes! wire-flush!
  wire-send-raw! wire-send-split!)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %pset! (prim-ref (lit ptr) (lit set!)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %str-byte-len (prim-ref (lit str) (lit byte-len)))

(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))

(def %ZERO "0000000000000000000000000000000000000000")

(def %member? (fn (_ s l) (List any? (fn (_ x) (str=? x s)) l)))

; --- the service's own ends ---

; The client's standard input onto fd 0: the platform keeps it on fd 3
; while fd 0 carries x's program text.  When fd 3 is not open, fd 0 is
; already the client.
(def %stdio-wire
  (fn (_)
    (when (>= (Sys dup2 3 0) 0) (Sys close 3))
    (wire-of-fds 0 1)))

(def %say (fn (_ text) (File write 2 text (%str-byte-len text))))

; The repository a service was started on, as enter_repo finds one: the
; directory, DIR.git, or DIR/.git; () when none.
(def %service-gitdir
  (fn (_ wd dir)
    (def full (if (Str8 starts? "/" dir) dir (Str8 append wd "/" dir)))
    (or (git-source-gitdir full) (git-source-gitdir (Str8 append full ".git")))))

(def %not-a-repo
  (fn (_ dir)
    (list (lit err) (Str8 append "fatal: '" dir "' does not appear to be a git repository\n") 128)))

; The refs advertised, (NAME . SHA) each, the capabilities on the first;
; with none, the line git sends for an empty repository.
(def %advertise!
  (fn (_ w refs caps)
    (if (null? refs)
      (wire-send-split! w (Str8 append %ZERO " capabilities^{}") caps)
      (do (wire-send-split! w (Str8 append (rest (first refs)) " " (first (first refs))) caps)
          (List for-each (fn (_ e) (wire-send! w (Str8 append (rest e) " " (first e)))) (rest refs))))
    (wire-flush! w)))

; n bytes of region r on side band `band`, in packets of git's largest.
(def %band!
  (fn (_ w band r n)
    ((fn (self at)
       (when (< at n)
         (let ((k (if (> (%sub n at) 65515) 65515 (%sub n at))))
           (let ((pk (%make-str (%add k 1))))
             (do (%pset! (%str->ptr pk) 0 band 1)
                 (%mem-copy (%at (%str->ptr pk) 1) (%at (%str->ptr r) at) k)
                 (wire-send-bytes! w pk (%add k 1))
                 (self (%add at k)))))))
     0)))

; The words after the first line's NUL, as a list.
(def %caps-of
  (fn (_ line)
    (def sp (wire-split line))
    (if (null? (rest sp)) () (List filter (fn (_ c) (> (Str8 length c) 0)) (Str8 split " " (rest sp))))))

; --- upload-pack ---

(def %upload-caps "thin-pack side-band-64k ofs-delta no-progress include-tag")

; The wants, read to the flush: (SHAS . CAPS), or () when the client
; said nothing more.
(def %read-wants
  (fn (_ w)
    ((fn (self shas caps)
       (def l (wire-line w))
       (match
         ((null? l) (if (null? shas) () (pair (List reverse shas) caps)))
         ((not (pair? l)) (if (null? shas) () (pair (List reverse shas) caps)))
         ; a fetch's first want carries the capabilities after a space
         ((Str8 starts? "want " (first l))
           (self (pair (Str8 sub 5 40 (first l)) shas)
                 (if (null? shas) (List filter (fn (_ c) (> (Str8 length c) 0)) (List drop 2 (Str8 split " " (first l)))) caps)))
         (#t (self shas caps))))
     () ())))

; The haves answered, as git answers them with no multi_ack: the first
; one this repository has is acked, a flush before there is one is
; NAKed, done ends it.  Answers the common commits, or #f when the
; client went away.
(def %negotiate!
  (fn (_ w gitdir)
    ((fn (self common)
       (def l (wire-line w))
       (match
         ((null? l) #f)
         ((not (pair? l)) (do (when (null? common) (wire-send! w "NAK")) (self common)))
         ((Str8 starts? "have " (first l))
           (let ((sha (Str8 sub 5 40 (first l))))
             (if (git-has-object? gitdir sha)
               (do (when (null? common) (wire-send! w (Str8 append "ACK " sha)))
                   (self (pair sha common)))
               (self common))))
         ((str=? (first l) "done") (do (when (null? common) (wire-send! w "NAK")) common))
         (#t (self common))))
     ())))

; Annotated tags whose object is among those sent and that the pack does
; not already carry: (SHA . OBJ) each.
(def %included-tags
  (fn (_ gitdir sent)
    (def names (List map first sent))
    (List flat-map
      (fn (_ t)
        (def sha (git-ref-read gitdir (Str8 append "refs/tags/" t)))
        (def o (if (null? sha) () (git-object-read gitdir sha)))
        (if (and (not (null? o)) (str=? (first o) "tag") (not (%member? sha names))
                 (%member? (Str8 sub 7 40 (git-object-text o)) names))
          (list (pair sha o))
          ()))
      (git-refs-under gitdir "refs/tags/"))))

(def git-upload-pack
  (fn (_ wd gitdir ops)
    (def dir (if (null? ops) "." (List last ops)))
    (def g (%service-gitdir wd dir))
    (if (null? g) (%not-a-repo dir)
      (do
        (def w (%stdio-wire))
        (def refs (git-advertised g))
        (def head (Str8 trim (File read-all (Str8 append g "/HEAD"))))
        (def symref
          (if (and (Str8 starts? "ref: " head) (not (null? (git-ref-read g "HEAD"))))
            (Str8 append " symref=HEAD:" (Str8 sub 5 (%sub (Str8 length head) 5) head)) ""))
        (%advertise! w refs (Str8 append %upload-caps symref " agent=x-git"))
        (def req (%read-wants w))
        (if (null? req) (list (lit out) "" 0)
          (let ((common (%negotiate! w g)))
            (if (eq? common #f) (list (lit out) "" 0)
              (let ((found (git-objects-to-send g (first req) common)))
                (let ((all (if (%member? "include-tag" (rest req))
                             (List append (first found) (%included-tags g (first found))) (first found))))
                  (let ((pack (git-pack-bytes all (if (%member? "thin-pack" (rest req)) (rest found) ())
                                (%member? "ofs-delta" (rest req)))))
                    (do (if (%member? "side-band-64k" (rest req))
                          (do (%band! w 1 (first pack) (rest pack)) (wire-flush! w))
                          (wire-send-raw! w (first pack) (rest pack)))
                        (list (lit out) "" 0))))))))))))

; --- receive-pack ---

(def %receive-caps "report-status delete-refs side-band-64k ofs-delta agent=x-git")

; The commands, read to the flush: (COMMANDS . CAPS), each command
; (OLD NEW NAME); () when the client sent none.
(def %read-commands
  (fn (_ w)
    ((fn (self cmds caps)
       (def l (wire-line w))
       (if (not (pair? l)) (if (null? cmds) () (pair (List reverse cmds) caps))
         (let ((text (first (wire-split l))))
           (let ((parts (Str8 split " " text)))
             (if (< (List length parts) 3) (self cmds caps)
               (self (pair (list (first parts) (List ref 1 parts) (List ref 2 parts)) cmds)
                     (if (null? cmds) (%caps-of l) caps)))))))
     () ())))

; The pack that follows the commands, read until its last entry and its
; checksum have come: (REGION . N).
(def %read-pack!
  (fn (_ w)
    (def b (git-bytes-make))
    ((fn (self count i off)
       (def got (wire-raw w))
       (when (null? got) (Err raise (lit value) "the pack ended early" ()))
       (git-bytes-put! b (%str->ptr (first got)) (rest got))
       (def n (git-bytes-count b))
       (def r (git-bytes-region b))
       (def c (if (and (null? count) (>= n 12)) (git-pack-count r) count))
       (if (null? c) (self c i off)
         (let ((s (git-pack-scan r n c i off)))
           (if (and (= (first s) c) (>= n (%add (rest s) 20)))
             (pair r (%add (rest s) 20))
             (self c (first s) (rest s))))))
     () 0 12)))

; One command carried out: (MESSAGES . REASON), REASON () when the ref
; moved, MESSAGES the receive-pack errors said on the way.
(def %apply!
  (fn (_ g c bare?)
    (def old (first c))
    (def new (first (rest c)))
    (def name (first (rest (rest c))))
    (def head-ref (let ((b (git-current-branch g))) (if (null? b) () (Str8 append "refs/heads/" b))))
    (def now (git-ref-read g name))
    (match
      ((not (Str8 starts? "refs/" name)) (pair "" "funny refname"))
      ((and (not (null? now)) (not (str=? now old)) (not (str=? old %ZERO))) (pair "" "failed to update ref"))
      ((str=? new %ZERO)
        (if (and (not (null? head-ref)) (str=? name head-ref))
          (pair (Str8 append
                  "error: By default, deleting the current branch is denied, because the next\n"
                  "'git clone' won't result in any file checked out, causing confusion.\n"
                  "\n"
                  "You can set 'receive.denyDeleteCurrent' configuration variable to\n"
                  "'warn' or 'ignore' in the remote repository to allow deleting the\n"
                  "current branch, with or without a warning message.\n"
                  "\n"
                  "To squelch this message, you can set it to 'refuse'.\n"
                  "error: refusing to delete the current branch: " name "\n")
                "deletion of the current branch prohibited")
          (do (let ((path (Str8 append g "/" name))) (when (File exists? path) (File unlink path)))
              (git-unpack-ref! g name)
              (pair "" ()))))
      ((not (git-has-object? g new)) (pair "" "missing necessary objects"))
      ((and (not bare?) (not (null? head-ref)) (str=? name head-ref))
        (pair (git-deny-current (Str8 sub 11 (%sub (Str8 length name) 11) name)) "branch is currently checked out"))
      (#t (do (git-write-ref! g name new) (pair "" ()))))))

; The report as pkt-lines, flush and all, in one region: (REGION . N).
(def %report-bytes
  (fn (_ lines)
    (def b (git-bytes-make))
    (List for-each
      (fn (_ l)
        (def s (Str8 append l "\n"))
        (def n (%add (%str-byte-len s) 4))
        (def h (Str8 append (if (< n 16) "000" (if (< n 256) "00" (if (< n 4096) "0" ""))) (%hex n)))
        (git-bytes-put! b (%str->ptr h) 4)
        (git-bytes-put! b (%str->ptr s) (%str-byte-len s)))
      lines)
    (git-bytes-put! b (%str->ptr "0000") 4)
    (pair (git-bytes-region b) (git-bytes-count b))))

(def %hex
  (fn (self n)
    (def d (fn (_ v) (Str8 sub v 1 "0123456789abcdef")))
    (if (< n 16) (d n) (Str8 append (self (>> n 4)) (d (& n 15))))))

(def git-receive-pack
  (fn (_ wd gitdir ops)
    (def dir (if (null? ops) "." (List last ops)))
    (def g (%service-gitdir wd dir))
    (if (null? g) (%not-a-repo dir)
      (do
        (def w (%stdio-wire))
        (%advertise! w (List map (fn (_ n) (pair n (git-ref-read g n)))
                         (List map (fn (_ n) (Str8 append "refs/" n)) (git-refs-under g "refs/")))
          %receive-caps)
        (def req (%read-commands w))
        (if (null? req) (list (lit out) "" 0)
          (let ((cmds (first req)) (caps (rest req)))
            (let ((unpack
                    (if (List all? (fn (_ c) (str=? (first (rest c)) %ZERO)) cmds) "ok"
                      (guard (e (Str8 append "error " (e msg)))
                        (let ((pack (%read-pack! w)))
                          (do (unless (= (git-pack-count (first pack)) 0)
                                (git-pack-index! g (first pack) (rest pack) (fn (_ sha) (git-object-read g sha))))
                              "ok")))))
                  (bare? (not (Str8 ends? "/.git" g))))
              (let ((results (List map (fn (_ c) (if (str=? unpack "ok") (%apply! g c bare?) (pair "" "unpacker error"))) cmds)))
                (let ((said (Str8 join "" (List map first results)))
                      (lines (pair (Str8 append "unpack " unpack)
                                   (List map (fn (_ c r) (if (null? (rest r)) (Str8 append "ok " (first (rest (rest c))))
                                                            (Str8 append "ng " (first (rest (rest c))) " " (rest r))))
                                     cmds results)))
                      (band? (%member? "side-band-64k" caps)))
                  (do (unless (= (Str8 length said) 0)
                        (if band? (%band! w 2 said (%str-byte-len said)) (%say said)))
                      (when (%member? "report-status" caps)
                        (let ((rep (%report-bytes lines)))
                          (if band? (%band! w 1 (first rep) (rest rep)) (wire-send-raw! w (first rep) (rest rep)))))
                      (when band? (wire-flush! w))
                      (list (lit out) "" 0)))))))))))

(provide git/serve git-upload-pack git-receive-pack)
