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
(import git/index git-index-read git-status-lists git-tree-files git-untracked-with git-long-status)
(import git/ignore git-ignorer)
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

; An entry's stage: 0, or the 1, 2 or 3 of a path a merge left in
; conflict (the base, ours, theirs), carried as the sixth item.
(def %entry-stage
  (fn (_ e) (if (null? (rest (rest (rest (rest (rest e)))))) 0 (first (rest (rest (rest (rest (rest e)))))))))

; Entries (PATH MODE-NUMBER SHA SIZE MTIME [STAGE]) to the index file's
; bytes: (REGION . N).
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
               ; the flags: the stage in bits 12-13, the name's length below
               (%pset! p (%add i 60) (| (<< (%entry-stage e) 4) (>> (%str-byte-len (first e)) 8)) 1)
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
    (def b (%index-bytes
             (List sort (fn (_ a b) (if (str=? (first a) (first b)) (< (%entry-stage a) (%entry-stage b)) (Str8 <? (first a) (first b))))
               entries)))
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
; number, the stage last.
(def %read-entries
  (fn (_ gitdir)
    (List map
      (fn (_ e) (list (first e) (%str->number (first (rest e)) 8) (first (rest (rest e)))
                      (first (rest (rest (rest (rest e))))) (first (rest (rest (rest (rest (rest e))))))
                      (first (rest (rest (rest e))))))
      (git-index-read gitdir))))

; Every file under a directory, by path from prefix; .git skipped, and
; what ignored? says to.
(def %files-under
  (fn (self dir prefix ignored?)
    (List flat-map
      (fn (_ name)
        (let ((full (Str8 append dir "/" name)) (path (Str8 append prefix name)))
          (match
            ((str=? name ".git") ())
            ((eq? (File type full) (lit dir))
              (if (ignored? path #t) () (self full (Str8 append path "/") ignored?)))
            ((ignored? path #f) ())
            (#t (list path)))))
      (File list-dir dir))))

(def %strip-slash
  (fn (_ s) (if (and (> (Str8 length s) 1) (Str8 ends? "/" s)) (Str8 sub 0 (%sub (Str8 length s) 1) s) s)))

; --- add ---

(def git-add-options
  (Opts declare "git add" "[-A | --all] [-f | --force] [--] <pathspec>..." ()
    (list
      (Opts flag "-A" "--all" "Stage every change in the working tree: additions, modifications, removals")
      (Opts flag "-f" "--force" "Add a path .gitignore says to leave"))))

; What git says of a path named outright that .gitignore covers.
(def %ignored-refusal
  (fn (_ paths)
    (list (lit err)
      (Str8 append "The following paths are ignored by one of your .gitignore files:\n"
        (Str8 join "" (List map (fn (_ p) (Str8 append p "\n")) paths))
        "hint: Use -f if you really want to add them.\n"
        "hint: Disable this message with \"git config set advice.addIgnoredFile false\"\n")
      1)))

(def git-add
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-add-options ops))
    (def specs (List map (fn (_ s) (%strip-slash s)) (Opts operands o)))
    ; with -f nothing is ignored
    (def ignored?
      (if (or (null? gitdir) (Opts on? o "-f")) (fn (_ path dir?) #f) (git-ignorer wd gitdir)))
    (def refused
      (List filter
        (fn (_ s)
          (if (str=? s ".") #f
            (do (def full (Str8 append wd "/" s))
                (if (File exists? full) (ignored? s (eq? (File type full) (lit dir))) #f))))
        specs))
    (match
      ((Opts help? git-add-options ops) (list (lit out) (Opts usage git-add-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-add-options)))
      ((null? gitdir) (%no-repo))
      ((and (null? specs) (not (Opts on? o "-A")))
        (list (lit out) "Nothing specified, nothing added.\nhint: Maybe you wanted to say 'git add .'?\n" 0))
      ((not (null? refused)) (%ignored-refusal refused))
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
                            (List append tracked (git-untracked-with wd tracked ignored?))
                            (List flat-map
                              (fn (_ s)
                                (let ((full (Str8 append wd "/" s)))
                                  (match
                                    ((not (File exists? full))
                                      (List filter (fn (_ t) (or (str=? t s) (Str8 starts? (Str8 append s "/") t))) tracked))
                                    ((eq? (File type full) (lit dir))
                                      (List append (%files-under full (Str8 append s "/") ignored?)
                                        (List filter (fn (_ t) (Str8 starts? (Str8 append s "/") t)) tracked)))
                                    (#t (list s)))))
                              specs))))
                    ; a path named twice is one; a directory listed as DIR/ by the
                    ; untracked walk is its files
                    (let ((paths (List flat-map
                                   (fn (_ p)
                                     (if (Str8 ends? "/" p)
                                       (%files-under (Str8 append wd "/" (%strip-slash p)) p ignored?)
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
                   ; a variable's name is matched ignoring case, as git does
                   (if (Str8 ci=? (Str8 trim (Str8 sub 0 i l)) key)
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

; --- who and when ---

; Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil).
(def %floor-div (fn (_ a b) (if (>= a 0) (%int-div a b) (%sub 0 (%int-div (%sub (%sub b 1) a) b)))))
(def %days-from-civil
  (fn (_ y m d)
    (def y2 (if (<= m 2) (%sub y 1) y))
    (def era (%floor-div y2 400))
    (def yoe (%sub y2 (%mul era 400)))
    (def doy (%add (%int-div (%add (%mul 153 (if (> m 2) (%sub m 3) (%add m 9))) 2) 5) (%sub d 1)))
    (def doe (%add (%sub (%add (%mul yoe 365) (%int-div yoe 4)) (%int-div yoe 100)) doy))
    (%sub (%add (%mul era 146097) doe) 719468)))

(def %digits (fn (_ s start n) (%str->number (Str8 sub start n s) 10)))

; A date as git takes one from GIT_AUTHOR_DATE or GIT_COMMITTER_DATE, as
; a commit records it, `EPOCH +HHMM`: the raw form `EPOCH +HHMM` (or
; `@EPOCH`), or ISO 8601, `YYYY-MM-DDTHH:MM:SS` then Z, +HH:MM or +HHMM.
; () for a form not read here.
(def %parse-date
  (fn (_ s)
    (def t (Str8 trim s))
    (def raw (if (Str8 starts? "@" t) (Str8 sub 1 (%sub (Str8 length t) 1) t) t))
    (def parts (Str8 split " " raw))
    (match
      ((and (>= (Str8 length t) 19) (str=? (Str8 sub 4 1 t) "-") (str=? (Str8 sub 10 1 t) "T"))
        (let ((zone (Str8 sub 19 (%sub (Str8 length t) 19) t)))
          (let ((sign (if (Str8 starts? "-" zone) -1 1))
                (zdigits (Str8 join "" (Str8 split ":" (if (or (= (Str8 length zone) 0) (str=? zone "Z")) "+0000" zone)))))
            (let ((zh (%digits zdigits 1 2)) (zm (%digits zdigits 3 2)))
              (let ((offset (%mul sign (%add (%mul zh 3600) (%mul zm 60))))
                    (local (%add (%mul (%days-from-civil (%digits t 0 4) (%digits t 5 2) (%digits t 8 2)) 86400)
                                 (%add (%mul (%digits t 11 2) 3600) (%add (%mul (%digits t 14 2) 60) (%digits t 17 2))))))
                (Str8 append (Str8 str (%sub local offset)) " " (if (< sign 0) "-" "+")
                  (Str8 pad-left 2 #\0 (Str8 str zh)) (Str8 pad-left 2 #\0 (Str8 str zm))))))))
      ((and (not (null? parts)) (> (Str8 length (first parts)) 0)
            (List all? (fn (_ i) (let ((c (Str8 sub i 1 (first parts)))) (and (Str8 >=? c "0") (Str8 <=? c "9"))))
              (List range 0 (Str8 length (first parts)))))
        (Str8 append (first parts) " " (if (null? (rest parts)) "+0000" (first (rest parts)))))
      (#t ()))))

(def %env (fn (_ name) (let ((v (Sys getenv name))) (if (or (null? v) (= (Str8 length v) 0)) () v))))

; A role's `NAME <EMAIL> WHEN`, role AUTHOR or COMMITTER: the name and the
; email from GIT_<ROLE>_NAME and _EMAIL, else user.name and user.email;
; the time from GIT_<ROLE>_DATE, else the clock.  () when there is no
; name or no email.
(def %signature
  (fn (_ gitdir role)
    (def name (or (%env (Str8 append "GIT_" role "_NAME")) (%config-get gitdir "user" "name")))
    (def email (or (%env (Str8 append "GIT_" role "_EMAIL")) (%config-get gitdir "user" "email")))
    (def date (let ((d (%env (Str8 append "GIT_" role "_DATE")))) (if (null? d) () (%parse-date d))))
    (if (or (null? name) (null? email)) ()
      (Str8 append name " <" email "> " (if (null? date) (%timestamp) date)))))

; A commit object written: its tree, its parents, its message, the author
; and committer as git finds them.  Answers its name, or () when the
; identity is unknown.
(def git-commit-write!
  (fn (_ gitdir tree parents message)
    (def author (%signature gitdir "AUTHOR"))
    (def committer (%signature gitdir "COMMITTER"))
    (if (or (null? author) (null? committer)) ()
      (let ((body (Str8 append "tree " tree "\n"
                    (Str8 join "" (List map (fn (_ p) (Str8 append "parent " p "\n")) parents))
                    "author " author "\n"
                    "committer " committer "\n"
                    "\n" message (if (Str8 ends? "\n" message) "" "\n"))))
        (git-object-write! gitdir "commit" body 0 (%str-byte-len body))))))

; The merge in progress: the commits MERGE_HEAD names, or () when none.
(def %merge-heads
  (fn (_ gitdir)
    (def path (Str8 append gitdir "/MERGE_HEAD"))
    (if (not (File exists? path)) ()
      (List filter (fn (_ l) (= (Str8 length l) 40)) (Str8 split "\n" (File read-all path))))))

; The files a merge in progress leaves, removed once it is concluded or
; abandoned.
(def git-merge-state-clear!
  (fn (_ gitdir)
    (List for-each
      (fn (_ f) (let ((p (Str8 append gitdir "/" f))) (when (File exists? p) (File unlink p))))
      (list "MERGE_HEAD" "MERGE_MSG" "MERGE_MODE" "AUTO_MERGE"))))

(def git-commit-options
  (Opts declare "git commit" "-m <message> [-q] [--no-edit]" ()
    (list
      (Opts arg "-m" "--message" "<message>" "The commit message")
      (Opts flag "-q" "--quiet" "Print nothing on success")
      (Opts flag "--no-edit" "Take the message a merge in progress left, unedited"))))

(def %unmerged-refusal
  (fn (_ paths)
    (list (lit err)
      (Str8 append "error: Committing is not possible because you have unmerged files.\n"
        "hint: Fix them up in the work tree, and then use 'git add/rm <file>'\n"
        "hint: as appropriate to mark resolution and make a commit.\n"
        "fatal: Exiting because of an unresolved conflict.\n")
      128
      (Str8 join "" (List map (fn (_ p) (Str8 append "U\t" p "\n")) paths)))))

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
    (def merging (if (null? gitdir) () (%merge-heads gitdir)))
    (def merge-msg-path (if (null? gitdir) () (Str8 append gitdir "/MERGE_MSG")))
    ; a merge in progress concludes with the message it left, as --no-edit takes it
    (def msg (or (Opts value o "-m" ())
                 (if (and (not (null? merging)) (File exists? merge-msg-path)) (File read-all merge-msg-path) ())))
    (def entries (if (null? gitdir) () (%read-entries gitdir)))
    (def unmerged
      ((fn (self es acc)
         (if (null? es) (List reverse acc)
           (self (rest es)
             (if (and (> (%entry-stage (first es)) 0) (not (List any? (fn (_ p) (str=? p (first (first es)))) acc)))
               (pair (first (first es)) acc) acc))))
       entries ()))
    (match
      ((Opts help? git-commit-options ops) (list (lit out) (Opts usage git-commit-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-commit-options)))
      ((null? gitdir) (%no-repo))
      ((not (null? unmerged)) (%unmerged-refusal unmerged))
      ((null? msg) (%fatal "no message given: this git takes -m <message>"))
      ((null? (%signature gitdir "COMMITTER")) %identity-unknown)
      (#t
        (let ((parent (git-commit-of gitdir "HEAD"))
              (head (Str8 trim (File read-all (Str8 append gitdir "/HEAD")))))
          (let ((tree (%write-tree! gitdir entries ""))
                (parent-tree (if (null? parent) () (git-tree-of gitdir parent))))
            ; a merge commit may record the tree it had; any other must change it
            (if (and (null? merging) (not (null? parent-tree)) (str=? tree parent-tree))
              (list (lit out) (git-long-status gitdir (git-status-lists wd gitdir)) 1)
              (let ((sha (git-commit-write! gitdir tree (List append (if (null? parent) () (list parent)) merging) msg))
                    (branch (if (Str8 starts? "ref: refs/heads/" head) (Str8 sub 16 (%sub (Str8 length head) 16) head) ())))
                (do (git-write-file! (if (null? branch) (Str8 append gitdir "/HEAD") (Str8 append gitdir "/" (Str8 sub 5 (%sub (Str8 length head) 5) head)))
                      (Str8 append sha "\n") 41)
                    (git-merge-state-clear! gitdir)
                    (if (Opts on? o "-q") (list (lit out) "" 0)
                      (list (lit out)
                        (Str8 append
                          "[" (if (null? branch) "detached HEAD" branch) (if (null? parent) " (root-commit) " " ") (Str8 sub 0 7 sha) "] "
                          (first (Str8 split "\n" msg)) "\n"
                          ; a merge commit's line says what it is and nothing more
                          (if (null? merging) (git-commit-summary gitdir (git-tree-files gitdir parent-tree) (git-tree-files gitdir tree)) ""))
                        0)))))))))))

; The index written from entries (PATH MODE-NUMBER SHA SIZE MTIME), for
; checkout, which sets it to a tree.
(def git-index-write!
  (fn (_ gitdir entries) (%index-write! gitdir entries)))

; A value of .git/config, for the modules that read the remotes and the
; branches' upstreams: SECTION is `user` or `remote "origin"`, say.
(def git-config-get
  (fn (_ gitdir section key) (%config-get gitdir section key)))

; The index's entries in the shape git-index-write! takes, for the
; commands that change the index: (PATH MODE-NUMBER SHA SIZE MTIME).
(def git-read-entries
  (fn (_ gitdir) (%read-entries gitdir)))

; A tree written from index entries (PATH MODE-NUMBER SHA ...); its name.
(def git-write-tree! (fn (_ gitdir entries) (%write-tree! gitdir entries "")))

(provide git/stage git-add git-add-options git-commit git-commit-options git-index-write!
  git-config-get git-read-entries git-commit-write! git-write-tree! git-merge-state-clear!)
