; # x-git -- git on x-lang
;
; ## git/stage.x -- the index written: add and commit
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; add writes blobs for the files named and the index that lists them, as
; git/index.x reads it: version 2, the entries in name order, the stat
; fields a file's size, mode and modification time with the rest zero
; (git treats such an entry as one to re-check, and finds it clean), and
; the file's own SHA-1 last.  commit builds the trees the index describes,
; writes the commit with the identity .git/config holds and the clock's
; time in the local offset, moves the branch HEAD names, and prints what
; git prints: the branch and the new name, how many files changed and by
; how many lines, and the modes created or deleted.

(module git/stage)

(import x/sys/opts Opts)
(import x/sys/file File)
(import x/sys/posix Sys)
(import x/sys/date Date)
(import x/codec/sha1 Sha1)
(import x/codec/hex Hex)
(import git/objects git-hash git-object-write! git-object-read git-object-text git-read-file git-write-file!)
(import git/refs git-ref-read git-rev-parse git-tree-of git-commit-of)
(import git/index git-index-read git-status-lists git-tree-files git-untracked git-long-status)
(import git/diff git-commit-summary)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %mul (prim-ref 'int '*))
(def %pset! (prim-ref (lit ptr) (lit set!)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %str-byte-len (prim-ref (lit str) (lit byte-len)))

(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))
(def %no-repo
  (fn (_) (%fatal "not a git repository (or any of the parent directories): .git")))
(def %unknown-option
  (fn (_ w usage)
    (def n (Str8 length w))
    (list (lit err)
      (Str8 append
        (if (Str8 starts? "--" w)
          (Str8 append "error: unknown option `" (Str8 sub 2 (- n 2) w))
          (Str8 append "error: unknown switch `" (Str8 sub 1 (- n 1) w)))
        "'\n" usage)
      129)))

; --- bytes ---

(def %put-u32!
  (fn (_ p i v)
    (%pset! p i (& (>> v 24) 255) 1)
    (%pset! p (%add i 1) (& (>> v 16) 255) 1)
    (%pset! p (%add i 2) (& (>> v 8) 255) 1)
    (%pset! p (%add i 3) (& v 255) 1)))

; A hex name's 20 raw bytes written at i of p.
(def %put-sha!
  (fn (_ p i hex)
    ((fn (self k l) (unless (null? l) (do (%pset! p (%add i k) (first l) 1) (self (%add k 1) (rest l)))))
     0 (Hex decode-bytes hex))))

(def %put-str!
  (fn (_ p i s)
    (def n (%str-byte-len s))
    (when (> n 0) (%mem-copy (%at p i) (%str->ptr s) n))
    n))

; --- the index written ---

; A file's mode as git records it: 100755 when any execute bit is set,
; else 100644.
(def %file-mode
  (fn (_ stat)
    (if (= (& (Assoc get (lit mode) stat) 73) 0) 33188 33261)))

; Entries (PATH MODE-NUMBER SHA SIZE MTIME) to the index file's bytes:
; (REGION . N).
(def %index-bytes
  (fn (_ entries)
    (def sizes (List map (fn (_ e) (& (%add (%add 62 (%str-byte-len (first e))) 8) (~ 7))) entries))
    (def total (%add (%add 12 (List fold (fn (_ a b) (%add a b)) 0 sizes)) 20))
    (def r (%make-str total))
    (def p (%str->ptr r))
    (%put-str! p 0 "DIRC")
    (%put-u32! p 4 2)
    (%put-u32! p 8 (List length entries))
    ((fn (self es i)
       (unless (null? es)
         (let ((e (first es)))
           (do (%put-u32! p i (first (rest (rest (rest (rest e))))))          ; ctime: the mtime
               (%put-u32! p (%add i 4) 0)
               (%put-u32! p (%add i 8) (first (rest (rest (rest (rest e))))))  ; mtime
               (%put-u32! p (%add i 12) 0)
               (%put-u32! p (%add i 16) 0)                                    ; dev
               (%put-u32! p (%add i 20) 0)                                    ; ino
               (%put-u32! p (%add i 24) (first (rest e)))                     ; mode
               (%put-u32! p (%add i 28) 0)                                    ; uid
               (%put-u32! p (%add i 32) 0)                                    ; gid
               (%put-u32! p (%add i 36) (first (rest (rest (rest e)))))        ; size
               (%put-sha! p (%add i 40) (first (rest (rest e))))
               (%pset! p (%add i 60) (>> (%str-byte-len (first e)) 8) 1)
               (%pset! p (%add i 61) (& (%str-byte-len (first e)) 255) 1)
               (%put-str! p (%add i 62) (first e))
               ; the name's NUL and the padding to eight: a fresh region is
               ; not zeroed, and git reads the name to its NUL
               (let ((next (%add i (& (%add (%add 62 (%str-byte-len (first e))) 8) (~ 7)))))
                 (do ((fn (zero j) (when (< j next) (do (%pset! p j 0 1) (zero (%add j 1)))))
                      (%add (%add i 62) (%str-byte-len (first e))))
                     (self (rest es) next)))))))
     entries 12)
    (%put-sha! p (%sub total 20) (Sha1 hex-n r (%sub total 20)))
    (pair r total)))

; The index written from entries, replacing what is there.
(def %index-write!
  (fn (_ gitdir entries)
    (def b (%index-bytes (List sort (fn (_ a b) (Str8 <? (first a) (first b))) entries)))
    (git-write-file! (Str8 append gitdir "/index") (first b) (rest b))
    (File chmod (Str8 append gitdir "/index") 420)
    ()))

; An index entry for the file at path (relative to wd), its blob written.
(def %entry-for
  (fn (_ wd gitdir path)
    (def full (Str8 append wd "/" path))
    (def st (File stat full))
    (def f (git-read-file full))
    (list path (%file-mode st) (git-object-write! gitdir "blob" (first f) 0 (rest f))
          (rest f) (Assoc get (lit mtime) st))))

; The read index's entries in the written shape: the mode text back to a
; number.
(def %read-entries
  (fn (_ gitdir)
    (List map
      (fn (_ e) (list (first e) (%str->number (first (rest e)) 8) (first (rest (rest e)))
                      (first (rest (rest (rest (rest e))))) (first (rest (rest (rest (rest (rest e))))))))
      (git-index-read gitdir))))

; Every file under a directory, by path from prefix; .git skipped.
(def %files-under
  (fn (self dir prefix)
    (List flat-map
      (fn (_ name)
        (let ((full (Str8 append dir "/" name)) (path (Str8 append prefix name)))
          (match
            ((str=? name ".git") ())
            ((eq? (File type full) (lit dir)) (self full (Str8 append path "/")))
            (#t (list path)))))
      (File list-dir dir))))

(def %strip-slash
  (fn (_ s) (if (and (> (Str8 length s) 1) (Str8 ends? "/" s)) (Str8 sub 0 (%sub (Str8 length s) 1) s) s)))

; --- add ---

(def git-add-options
  (Opts declare "git add" "[-A | --all] [--] <pathspec>..." ()
    (list
      (Opts flag "-A" "--all" "Stage every change in the working tree: additions, modifications, removals"))))

(def git-add
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-add-options ops))
    (def specs (List map (fn (_ s) (%strip-slash s)) (Opts operands o)))
    (match
      ((Opts help? git-add-options ops) (list (lit out) (Opts usage git-add-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-add-options)))
      ((null? gitdir) (%no-repo))
      ((and (null? specs) (not (Opts on? o "-A")))
        (list (lit out) "Nothing specified, nothing added.\nhint: Maybe you wanted to say 'git add .'?\n" 0))
      (#t
        (let ((index (%read-entries gitdir)))
          (let ((tracked (List map (fn (_ e) (first e)) index)))
            ; the paths each spec names: a file, every file under a directory,
            ; or a tracked path now gone (its removal is what is staged);
            ; nothing at all is the refusal
            (let ((missing (List find
                             (fn (_ s)
                               (and (not (str=? s "."))
                                    (not (File exists? (Str8 append wd "/" s)))
                                    (not (List any? (fn (_ t) (or (str=? t s) (Str8 starts? (Str8 append s "/") t))) tracked))))
                             specs)))
              (if (not (null? missing))
                (%fatal (Str8 append "pathspec '" missing "' did not match any files"))
                (let ((all? (or (Opts on? o "-A") (List any? (fn (_ s) (str=? s ".")) specs))))
                  (let ((named
                          (if all?
                            (List append tracked (git-untracked wd tracked))
                            (List flat-map
                              (fn (_ s)
                                (let ((full (Str8 append wd "/" s)))
                                  (match
                                    ((not (File exists? full))
                                      (List filter (fn (_ t) (or (str=? t s) (Str8 starts? (Str8 append s "/") t))) tracked))
                                    ((eq? (File type full) (lit dir))
                                      (List append (%files-under full (Str8 append s "/"))
                                        (List filter (fn (_ t) (Str8 starts? (Str8 append s "/") t)) tracked)))
                                    (#t (list s)))))
                              specs))))
                    ; a path named twice is one; a directory listed as DIR/ by the
                    ; untracked walk is its files
                    (let ((paths (List flat-map
                                   (fn (_ p)
                                     (if (Str8 ends? "/" p)
                                       (%files-under (Str8 append wd "/" (%strip-slash p)) p)
                                       (list p)))
                                   ((fn (self ps acc) (if (null? ps) (List reverse acc)
                                                        (self (rest ps) (if (List any? (fn (_ a) (str=? a (first ps))) acc) acc (pair (first ps) acc)))))
                                    named ()))))
                      (let ((kept (List filter (fn (_ e) (not (List any? (fn (_ p) (str=? p (first e))) paths))) index))
                            (fresh (List flat-map
                                     (fn (_ p) (if (File exists? (Str8 append wd "/" p)) (list (%entry-for wd gitdir p)) ()))
                                     paths)))
                        (do (%index-write! gitdir (List append kept fresh))
                            (list (lit out) "" 0))))))))))))))

; --- commit ---

; A value of .git/config: the first `KEY = VALUE` under `[SECTION]`, or ().
(def %config-get
  (fn (_ gitdir section key)
    (def path (Str8 append gitdir "/config"))
    (if (not (File exists? path)) ()
      ((fn (self lines in?)
         (if (null? lines) ()
           (let ((l (Str8 trim (first lines))))
             (match
               ((Str8 starts? "[" l) (self (rest lines) (str=? l (Str8 append "[" section "]"))))
               ((and in? (not (null? (Str8 index-of "=" l))))
                 (let ((i (Str8 index-of "=" l)))
                   (if (str=? (Str8 trim (Str8 sub 0 i l)) key)
                     (Str8 trim (Str8 sub (%add i 1) (%sub (Str8 length l) (%add i 1)) l))
                     (self (rest lines) in?))))
               (#t (self (rest lines) in?))))))
       (Str8 split "\n" (File read-all path)) #f))))

; git's tree order: names compared as bytes, a subtree's with "/" after it.
(def %tree-name<?
  (fn (_ a b)
    (Str8 <? (if (str=? (first a) "40000") (Str8 append (first (rest a)) "/") (first (rest a)))
             (if (str=? (first b) "40000") (Str8 append (first (rest b)) "/") (first (rest b))))))

; A tree object written from index entries whose paths begin with prefix,
; subtrees first; answers its name.  Entries are (PATH MODE-NUMBER SHA ...).
(def %write-tree!
  (fn (self gitdir entries prefix)
    (def plen (Str8 length prefix))
    (def here (List filter (fn (_ e) (Str8 starts? prefix (first e))) entries))
    ; the direct names: a file's, or a subdirectory's first component
    (def names
      ((fn (walk es acc)
         (if (null? es) (List reverse acc)
           (let ((rel (Str8 sub plen (%sub (Str8 length (first (first es))) plen) (first (first es)))))
             (let ((i (Str8 index-of "/" rel)))
               (let ((item (if (null? i)
                             (list (%cvt-mode (first (rest (first es)))) rel (first (rest (rest (first es)))))
                             (list "40000" (Str8 sub 0 i rel) ()))))
                 (walk (rest es)
                   (if (List any? (fn (_ a) (str=? (first (rest a)) (first (rest item)))) acc) acc (pair item acc))))))))
       here ()))
    (def resolved
      (List map
        (fn (_ item)
          (if (str=? (first item) "40000")
            (list "40000" (first (rest item)) (self gitdir entries (Str8 append prefix (first (rest item)) "/")))
            item))
        names))
    (def sorted (List sort %tree-name<? resolved))
    (def size (List fold (fn (_ a it) (%add a (%add (%add (%add (Str8 length (first it)) 1) (%add (Str8 length (first (rest it))) 1)) 20))) 0 sorted))
    (def r (%make-str (if (= size 0) 1 size)))
    (def p (%str->ptr r))
    ((fn (walk its i)
       (unless (null? its)
         (let ((it (first its)))
           (let ((j (%add i (%put-str! p i (first it)))))
             (do (%pset! p j 32 1)
                 (let ((k (%add (%add j 1) (%put-str! p (%add j 1) (first (rest it))))))
                   (do (%pset! p k 0 1)
                       (%put-sha! p (%add k 1) (first (rest (rest it))))
                       (walk (rest its) (%add k 21)))))))))
     sorted 0)
    (git-object-write! gitdir "tree" r 0 size)))

; A mode number as a tree spells it: 100644, 100755, 120000.
(def %cvt-mode
  (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 8)))

; The clock's time as a commit records it: `EPOCH +HHMM`.
(def %timestamp
  (fn (_)
    (def now (Sys now))
    (def off (Assoc get (lit offset) (Date local now)))
    (def a (if (< off 0) (%sub 0 off) off))
    (Str8 append (Str8 str now) " " (if (< off 0) "-" "+")
      (Str8 pad-left 2 #\0 (Str8 str (%int-div a 3600)))
      (Str8 pad-left 2 #\0 (Str8 str (%int-div (%int-mod a 3600) 60))))))

(def %int-div (prim-ref (lit int) (lit /)))
(def %int-mod (prim-ref (lit int) (lit %)))

(def git-commit-options
  (Opts declare "git commit" "-m <message> [-q]" ()
    (list
      (Opts arg "-m" "--message" "<message>" "The commit message")
      (Opts flag "-q" "--quiet" "Print nothing on success"))))

(def %identity-unknown
  (list (lit err)
    (Str8 join "\n"
      (list "Author identity unknown" "" "*** Please tell me who you are." "" "Run" ""
            "  git config --global user.email \"you@example.com\""
            "  git config --global user.name \"Your Name\"" ""
            "to set your account's default identity."
            "Omit --global to set the identity only in this repository." ""
            "fatal: unable to auto-detect email address" ""))
    128))

(def git-commit
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-commit-options ops))
    (def msg (Opts value o "-m" ()))
    (match
      ((Opts help? git-commit-options ops) (list (lit out) (Opts usage git-commit-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-commit-options)))
      ((null? gitdir) (%no-repo))
      ((null? msg) (%fatal "no message given: this git takes -m <message>"))
      (#t
        (let ((name (%config-get gitdir "user" "name")) (email (%config-get gitdir "user" "email")))
          (if (or (null? name) (null? email)) %identity-unknown
            (let ((entries (%read-entries gitdir))
                  (parent (git-commit-of gitdir "HEAD"))
                  (head (Str8 trim (File read-all (Str8 append gitdir "/HEAD")))))
              (let ((tree (%write-tree! gitdir entries ""))
                    (parent-tree (if (null? parent) () (git-tree-of gitdir parent))))
                (if (and (not (null? parent-tree)) (str=? tree parent-tree))
                  (list (lit out) (git-long-status gitdir (git-status-lists wd gitdir)) 1)
                  (let ((when (%timestamp))
                        (text (Str8 append msg (if (Str8 ends? "\n" msg) "" "\n"))))
                    (let ((body (Str8 append "tree " tree "\n"
                                  (if (null? parent) "" (Str8 append "parent " parent "\n"))
                                  "author " name " <" email "> " when "\n"
                                  "committer " name " <" email "> " when "\n"
                                  "\n" text)))
                      (let ((sha (git-object-write! gitdir "commit" body 0 (%str-byte-len body)))
                            (branch (if (Str8 starts? "ref: refs/heads/" head) (Str8 sub 16 (%sub (Str8 length head) 16) head) ())))
                        (do (git-write-file! (if (null? branch) (Str8 append gitdir "/HEAD") (Str8 append gitdir "/" (Str8 sub 5 (%sub (Str8 length head) 5) head)))
                              (Str8 append sha "\n") 41)
                            (if (Opts on? o "-q") (list (lit out) "" 0)
                              (list (lit out)
                                (Str8 append
                                  "[" (if (null? branch) "detached HEAD" branch) (if (null? parent) " (root-commit) " " ") (Str8 sub 0 7 sha) "] "
                                  (first (Str8 split "\n" text)) "\n"
                                  (git-commit-summary gitdir (git-tree-files gitdir parent-tree) (git-tree-files gitdir tree)))
                                0)))))))))))))))

; The index written from entries (PATH MODE-NUMBER SHA SIZE MTIME), for
; checkout, which sets it to a tree.
(def git-index-write!
  (fn (_ gitdir entries) (%index-write! gitdir entries)))

(provide git/stage git-add git-add-options git-commit git-commit-options git-index-write!)
