; # x-git -- git on x-lang
;
; ## git/reflog.x -- the reflog
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Each move of a ref appended to .git/logs/REF as git appends it:
; `OLD NEW NAME <EMAIL> EPOCH +HHMM<TAB>MESSAGE`, the committer's identity,
; the message's whitespace squeezed to single spaces.  A ref is logged when
; its log exists, or when core.logAllRefUpdates says to: by default (true
; unless the repository is bare) HEAD, refs/heads/, refs/remotes/ and
; refs/notes/; with `always`, every ref.  A move of the branch HEAD names
; is logged for HEAD too.

(module git/reflog)

(import x/sys/file File)
(import git/config git-config-value)
(import git/ident git-signature)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %str-byte-len (prim-ref (lit str) (lit byte-len)))

(def %zero "0000000000000000000000000000000000000000")

(def %log-path (fn (_ gitdir ref) (Str8 append gitdir "/logs/" ref)))

; The directories above a log made, as the ref's are.
(def %log-dirs!
  (fn (_ gitdir ref)
    (def logs (Str8 append gitdir "/logs"))
    (unless (File exists? logs) (File mkdir logs))
    ((fn (self parts at)
       (unless (null? (rest parts))
         (do (def d (Str8 append at "/" (first parts)))
             (unless (File exists? d) (File mkdir d))
             (self (rest parts) d))))
     (Str8 split "/" ref) (Str8 append gitdir "/logs"))))

(def %space? (fn (_ c) (or (str=? c " ") (str=? c "\t") (str=? c "\n") (str=? c "\r") (str=? c "\v") (str=? c "\f"))))

; A message as copy_reflog_msg keeps it: leading whitespace gone, each run
; of it one space, none trailing.
(def %squeeze
  (fn (_ msg)
    (def n (Str8 length msg))
    (def out
      ((fn (self i was acc)
         (if (>= i n) acc
           (let ((c (Str8 sub i 1 msg)))
             (match
               ((and was (%space? c)) (self (%add i 1) #t acc))
               ((%space? c) (self (%add i 1) #t (pair " " acc)))
               (#t (self (%add i 1) #f (pair c acc)))))))
       0 #t ()))
    (def trimmed (if (and (not (null? out)) (str=? (first out) " ")) (rest out) out))
    (Str8 join "" (List reverse trimmed))))

; core.logAllRefUpdates: (lit always), #t or #f; unset, #t unless bare.
(def %log-all
  (fn (_ gitdir)
    (def v (git-config-value gitdir "core.logAllRefUpdates"))
    (def lower (if (null? v) () (Str8 downcase v)))
    (match
      ((null? lower)
        (let ((bare (git-config-value gitdir "core.bare")))
          (not (and (not (null? bare)) (List any? (fn (_ t) (str=? t (Str8 downcase bare))) (list "true" "yes" "on" "1"))))))
      ((str=? lower "always") (lit always))
      (#t (List any? (fn (_ t) (str=? t lower)) (list "true" "yes" "on" "1"))))))

(def %logged?
  (fn (_ gitdir ref)
    (or (File exists? (%log-path gitdir ref))
        (let ((all (%log-all gitdir)))
          (match
            ((eq? all (lit always)) #t)
            ((not all) #f)
            (#t (or (str=? ref "HEAD")
                    (List any? (fn (_ p) (Str8 starts? p ref)) (list "refs/heads/" "refs/remotes/" "refs/notes/")))))))))

; One line appended to ref's log, when it is logged and the committer is
; known.  old () for a ref that did not exist.
(def git-reflog-append!
  (fn (_ gitdir ref old new msg)
    (def who (git-signature gitdir "COMMITTER"))
    (when (and (not (null? who)) (%logged? gitdir ref))
      (do (%log-dirs! gitdir ref)
          (def line (Str8 append (if (null? old) %zero old) " " (if (null? new) %zero new) " " who "\t" (%squeeze msg) "\n"))
          (def fd (File open (%log-path gitdir ref) (list (lit wronly) (lit creat) (lit append)) 420))
          (when (>= fd 0)
            (do (File write fd line (%str-byte-len line))
                (File close fd)))))))

; The branch HEAD names, as its ref (refs/heads/...), or () when detached.
(def %head-ref
  (fn (_ gitdir)
    (def path (Str8 append gitdir "/HEAD"))
    (def h (if (File exists? path) (Str8 trim (File read-all path)) ""))
    (if (Str8 starts? "ref: " h) (Str8 sub 5 (%sub (Str8 length h) 5) h) ())))

; A ref's move logged, and HEAD's too when HEAD names that ref.  As git's
; files backend does, a ref left where it was is not logged, but HEAD's
; entry for it is.
(def git-ref-log!
  (fn (_ gitdir ref old new msg)
    (unless (and (not (str=? ref "HEAD")) (not (null? old)) (str=? old new))
      (git-reflog-append! gitdir ref old new msg))
    (let ((h (%head-ref gitdir)))
      (when (and (not (str=? ref "HEAD")) (not (null? h)) (str=? h ref))
        (git-reflog-append! gitdir "HEAD" old new msg)))))

; A ref's log, newest first: ((OLD NEW WHO MESSAGE) ...); () when it has none.
(def git-reflog-entries
  (fn (_ gitdir ref)
    (def path (%log-path gitdir ref))
    (if (not (File exists? path)) ()
      (List reverse
        (List flat-map
          (fn (_ l)
            (if (< (Str8 length l) 83) ()
              (let ((tab (Str8 index-of "\t" l)))
                (list (list (Str8 sub 0 40 l) (Str8 sub 41 40 l)
                            (Str8 sub 82 (%sub (if (null? tab) (Str8 length l) tab) 82) l)
                            (if (null? tab) "" (Str8 sub (%add tab 1) (%sub (Str8 length l) (%add tab 1)) l)))))))
          (Str8 split "\n" (File read-all path)))))))

; A deleted ref's log removed with it.
(def git-reflog-delete!
  (fn (_ gitdir ref)
    (def path (%log-path gitdir ref))
    (when (File exists? path) (File unlink path))))

(provide git/reflog git-reflog-append! git-ref-log! git-reflog-entries git-reflog-delete!)
