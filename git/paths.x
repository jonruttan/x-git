; # x-git -- git on x-lang
;
; ## git/paths.x -- rm, mv, check-ignore and clean
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; rm [-r] [-f] [--cached] [-q] [--] <path>... takes paths out of the index
; and the working directory, a directory's contents with -r, refusing as
; git does a path it does not track, a directory without -r, and a file
; whose working copy or index entry differs from HEAD unless -f or
; --cached; a directory left empty goes with its files.  mv [-f] [-k] [-v]
; <source>... <destination> renames a file or a directory, or moves
; several into a directory, the index following.  check-ignore [-q] [-v
; [-n]] [--no-index] <pathname>... names the paths .gitignore ignores,
; with -v the pattern that decides, its file and line.  clean [-d] [-f]
; [-n] [-q] [-e <pattern>] [-x | -X] [<pathspec>...] removes the untracked
; files (with -x the ignored too, with -X only those), with -d the
; untracked directories, a repository inside this one only with -f twice;
; nothing without -f or -n while clean.requireForce holds.  The words are
; git's.

(module git/paths)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/objects git-hash git-read-file)
(import git/commands git-fatal git-no-repo git-unknown-option git-strip-slash)
(import git/index git-tree-files)
(import git/refs git-tree-of)
(import git/stage git-index-write! git-read-entries)
(import git/config git-config-value)
(import git/ignore git-ignorer git-ignore-matcher git-ignore-rule-negated? git-ignore-rule-source git-ignore-rule-line
  git-ignore-rule-text)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

; The index entries (PATH MODE SHA SIZE MTIME ...) under a path: the
; entry itself, or every one below it when it names a directory.
(def %entries-under
  (fn (_ index path)
    (List filter (fn (_ e) (or (str=? (first e) path) (Str8 starts? (Str8 append path "/") (first e)))) index)))

; Is a path's working copy the blob its index entry names?
(def %clean?
  (fn (_ wd e)
    (def full (Str8 append wd "/" (first e)))
    (if (not (File exists? full)) #t
      (do (def f (git-read-file full))
          (str=? (git-hash "blob" (first f) 0 (rest f)) (first (rest (rest e))))))))

; Is a path's index entry the blob HEAD holds for it?
(def %staged-as-head?
  (fn (_ head e)
    (def h (List find (fn (_ x) (str=? (first x) (first e))) head))
    (if (null? h) #f (str=? (rest h) (first (rest (rest e)))))))

; A file removed, then each directory above it that it leaves empty, up
; to the working directory.
(def %remove-file!
  (fn (_ wd path)
    (File unlink (Str8 append wd "/" path))
    ((fn (self p)
       (def i (Str8 last-index-of "/" p))
       (if (null? i) ()
         (do (def d (Str8 sub 0 i p))
             (if (null? (File list-dir (Str8 append wd "/" d)))
               (do (File rmdir (Str8 append wd "/" d)) (self d))
               ()))))
     path)))

; --- rm ---

(def git-rm-options
  (Opts declare "git rm" "[-r] [-f | --force] [--cached] [-q | --quiet] [--] <pathspec>..." ()
    (list
      (Opts flag "-r" "Remove the contents of directories too")
      (Opts flag "-f" "--force" "Remove a file whose working copy or index entry differs from HEAD")
      (Opts flag "--cached" "Take the paths out of the index alone, leaving the files")
      (Opts flag "-q" "--quiet" "Name nothing removed"))))

(def git-rm
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-rm-options ops))
    (def specs (List map (fn (_ s) (git-strip-slash s)) (Opts operands o)))
    (match
      ((Opts help? git-rm-options ops) (list (lit out) (Opts usage git-rm-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-rm-options)))
      ((null? gitdir) (git-no-repo))
      ((null? specs) (list (lit err) (Opts usage git-rm-options) 129))
      (#t
        (do
          (def index (git-read-entries gitdir))
          (def missing (List find (fn (_ s) (null? (%entries-under index s))) specs))
          (def dir (List find (fn (_ s) (if (Opts on? o "-r") #f (null? (List find (fn (_ e) (str=? (first e) s)) index)))) specs))
          (match
            ((not (null? missing)) (git-fatal (Str8 append "pathspec '" missing "' did not match any files")))
            ((not (null? dir)) (git-fatal (Str8 append "not removing '" dir "' recursively without -r")))
            (#t
              (do
                (def head (git-tree-files gitdir (git-tree-of gitdir "HEAD")))
                (def entries (List flat-map (fn (_ s) (%entries-under index s)) specs))
                ; A file whose index entry is not HEAD's, or whose working copy
                ; is not its index entry's, stays unless forced or kept.
                (def staged (List filter (fn (_ e) (not (%staged-as-head? head e))) entries))
                (def modified (List filter (fn (_ e) (not (%clean? wd e))) entries))
                (def refusal
                  (fn (_ what es)
                    (list (lit err)
                      (Str8 append "error: the following file" (if (null? (rest es)) " has " "s have ") what ":\n"
                        (Str8 join "" (List map (fn (_ e) (Str8 append "    " (first e) "\n")) es))
                        "(use --cached to keep the file, or -f to force removal)\n")
                      1)))
                (match
                  ((and (not (Opts on? o "-f")) (not (Opts on? o "--cached")) (not (null? staged)))
                    (refusal "changes staged in the index" staged))
                  ((and (not (Opts on? o "-f")) (not (Opts on? o "--cached")) (not (null? modified)))
                    (refusal "local modifications" modified))
                  (#t
                    (do
                      (def gone (List map first entries))
                      (git-index-write! gitdir
                        (List filter (fn (_ e) (not (List any? (fn (_ g) (str=? g (first e))) gone))) index))
                      (if (Opts on? o "--cached") ()
                        (List for-each (fn (_ p) (if (File exists? (Str8 append wd "/" p)) (%remove-file! wd p) ())) gone))
                      (list (lit out)
                        (if (Opts on? o "-q") ""
                          (Str8 join "" (List map (fn (_ p) (Str8 append "rm '" p "'\n"))
                                          (List sort (fn (_ a b) (Str8 <? a b)) gone))))
                        0))))))))))))

; --- mv ---

(def git-mv-options
  (Opts declare "git mv" "[-f | --force] [-k] [-v | --verbose] <source>... <destination>" ()
    (list
      (Opts flag "-f" "--force" "Replace a destination that exists")
      (Opts flag "-k" "Skip a source that cannot be moved, rather than refusing")
      (Opts flag "-v" "--verbose" "Name each move"))))

(def %dir? (fn (_ p) (if (File exists? p) (eq? (File type p) (lit dir)) #f)))

; A directory's files made under another: each file renamed, the
; directories above it made on the way; the emptied directory removed.
(def %make-dirs!
  (fn (_ wd path)
    ((fn (self parts at)
       (if (null? (rest parts)) ()
         (do (def d (Str8 append at (first parts)))
             (if (File exists? (Str8 append wd "/" d)) () (File mkdir (Str8 append wd "/" d)))
             (self (rest parts) (Str8 append d "/")))))
     (Str8 split "/" path) "")))

; One source to one destination path: the moves (FROM . TO) of every
; file, or a refusal (STREAM TEXT STATUS).
(def %plan-move
  (fn (_ wd index src dst force?)
    (def full-src (Str8 append wd "/" src))
    (def full-dst (Str8 append wd "/" dst))
    (def entries (%entries-under index src))
    (def tracked-file? (not (null? (List find (fn (_ e) (str=? (first e) src)) index))))
    (match
      ((not (File exists? full-src)) (git-fatal (Str8 append "bad source, source=" src ", destination=" dst)))
      ((if (%dir? full-src) (null? entries) (not tracked-file?))
        (git-fatal (Str8 append "not under version control, source=" src ", destination=" dst)))
      ((or (str=? src dst) (Str8 starts? (Str8 append src "/") dst))
        (git-fatal (Str8 append "can not move directory into itself, source=" src ", destination=" dst)))
      ((and (File exists? full-dst) (not force?))
        (git-fatal (Str8 append "destination exists, source=" src ", destination=" dst)))
      ((not (File exists? (Str8 append wd "/" (%parent dst))))
        (git-fatal (Str8 append "renaming '" src "' failed: No such file or directory")))
      (#t
        (List map
          (fn (_ e)
            (pair (first e)
              (if (str=? (first e) src) dst
                (Str8 append dst (Str8 sub (Str8 length src) (%sub (Str8 length (first e)) (Str8 length src)) (first e))))))
          entries)))))

(def %parent
  (fn (_ p)
    (def i (Str8 last-index-of "/" p))
    (if (null? i) "." (Str8 sub 0 i p))))

(def git-mv
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-mv-options ops))
    (def operands (List map (fn (_ s) (git-strip-slash s)) (Opts operands o)))
    (match
      ((Opts help? git-mv-options ops) (list (lit out) (Opts usage git-mv-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-mv-options)))
      ((null? gitdir) (git-no-repo))
      ((or (null? operands) (null? (rest operands))) (list (lit err) (Opts usage git-mv-options) 129))
      (#t
        (do
          (def index (git-read-entries gitdir))
          (def dst (List ref (%sub (List length operands) 1) operands))
          (def srcs (List take (%sub (List length operands) 1) operands))
          (def into-dir? (%dir? (Str8 append wd "/" dst)))
          (match
            ((and (not (null? (rest srcs))) (not into-dir?))
              (git-fatal (Str8 append "destination '" dst "' is not a directory")))
            (#t
              (do
                ; each source to its own destination: into the directory by its
                ; last name, or to the one path given
                (def pairs
                  (List map
                    (fn (_ s)
                      (pair s (if into-dir?
                                (do (def i (Str8 last-index-of "/" s))
                                    (Str8 append dst "/" (if (null? i) s (Str8 sub (%add i 1) (%sub (Str8 length s) (%add i 1)) s))))
                                dst)))
                    srcs))
                (def plans
                  (List map (fn (_ p) (pair p (%plan-move wd index (first p) (rest p) (Opts on? o "-f")))) pairs))
                (def refused (List find (fn (_ pl) (not (pair? (first (rest pl))))) plans))
                (if (and (not (null? refused)) (not (Opts on? o "-k")))
                  (rest refused)
                  (do
                    (def moves (List flat-map (fn (_ pl) (if (pair? (first (rest pl))) (rest pl) ())) plans))
                    (List for-each
                      (fn (_ m)
                        (do (%make-dirs! wd (rest m))
                            (if (File exists? (Str8 append wd "/" (rest m))) (File unlink (Str8 append wd "/" (rest m))) ())
                            (File rename (Str8 append wd "/" (first m)) (Str8 append wd "/" (rest m)))))
                      moves)
                    ; a directory moved whole is left behind empty
                    (List for-each
                      (fn (_ pl)
                        (if (and (pair? (first (rest pl))) (%dir? (Str8 append wd "/" (first (first pl)))))
                          (%remove-tree! (Str8 append wd "/" (first (first pl))))
                          ()))
                      plans)
                    (def moved (fn (_ path) (List find (fn (_ m) (str=? (first m) path)) moves)))
                    (def targets (List map rest moves))
                    (git-index-write! gitdir
                      (List map
                        (fn (_ e) (do (def m (moved (first e))) (if (null? m) e (pair (rest m) (rest e)))))
                        ; an entry the destination path had is replaced
                        (List filter (fn (_ e) (or (not (null? (moved (first e))))
                                                   (not (List any? (fn (_ t) (str=? t (first e))) targets))))
                          index)))
                    (list (lit out)
                      (if (Opts on? o "-v")
                        (Str8 join ""
                          (List map (fn (_ pl) (if (pair? (first (rest pl))) (Str8 append "Renaming " (first (first pl)) " to " (rest (first pl)) "\n") ""))
                            plans))
                        "")
                      0)))))))))))

; An empty directory tree removed.
(def %remove-tree!
  (fn (self dir)
    (if (File exists? dir)
      (do (List for-each
            (fn (_ name) (do (def full (Str8 append dir "/" name)) (if (%dir? full) (self full) (File unlink full))))
            (File list-dir dir))
          (File rmdir dir))
      ())))

; --- check-ignore ---

(def git-check-ignore-options
  (Opts declare "git check-ignore" "[<options>] <pathname>..." ()
    (list
      (Opts flag "-q" "--quiet" "Print nothing; the status says whether the path is ignored")
      (Opts flag "-v" "--verbose" "Name the pattern that decides each path")
      (Opts flag "-n" "--non-matching" "With -v, list the paths no pattern matches too")
      (Opts flag "--no-index" "Ask about tracked paths too"))))

; What check-ignore prints for a path and the rule that decided it, ()
; when none did: a line, or nothing.
(def %ignore-line
  (fn (_ path rule verbose? all?)
    (match
      ((not verbose?) (if (null? rule) "" (Str8 append path "\n")))
      ((not (null? rule))
        (Str8 append (git-ignore-rule-source rule) ":" (Str8 str (git-ignore-rule-line rule)) ":"
          (git-ignore-rule-text rule) "\t" path "\n"))
      (all? (Str8 append "::\t" path "\n"))
      (#t ""))))

(def git-check-ignore
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-check-ignore-options ops))
    (def on? (fn (_ f) (Opts on? o f)))
    (def paths (Opts operands o))
    (match
      ((Opts help? git-check-ignore-options ops) (list (lit out) (Opts usage git-check-ignore-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-check-ignore-options)))
      ((null? gitdir) (git-no-repo))
      ((null? paths) (git-fatal "no path specified"))
      ((and (on? "-q") (> (List length paths) 1)) (git-fatal "--quiet is only valid with a single pathname"))
      ((and (on? "-q") (on? "-v")) (git-fatal "cannot have both --quiet and --verbose"))
      ((and (on? "-n") (not (on? "-v"))) (git-fatal "--non-matching is only valid with --verbose"))
      (#t
        (let ((rule-of (git-ignore-matcher wd gitdir))
              (index (if (on? "--no-index") () (git-read-entries gitdir))))
          ; a tracked path, or a directory with one in it, is no question
          ; of ignoring; a negation decides only what -v says
          (let ((found (List map
                         (fn (_ p)
                           (def s (git-strip-slash p))
                           (pair p
                             (if (not (null? (%entries-under index s))) ()
                               (let ((r (rule-of s (%dir? (Str8 append wd "/" s)))))
                                 (if (and (not (null? r)) (git-ignore-rule-negated? r) (not (on? "-v"))) () r)))))
                         paths)))
            (list (lit out)
              (if (on? "-q") ""
                (Str8 join "" (List map (fn (_ f) (%ignore-line (first f) (rest f) (on? "-v") (on? "-n"))) found)))
              (if (List any? (fn (_ f) (not (null? (rest f)))) found) 0 1))))))))

; --- clean ---

(def git-clean-options
  (Opts declare "git clean" "[-d] [-f] [-n] [-q] [-e <pattern>] [-x | -X] [--] [<pathspec>...]" ()
    (list
      (Opts flag "-q" "--quiet" "Do not print the names of what is removed")
      (Opts flag "-n" "--dry-run" "Say what would be removed, and remove nothing")
      (Opts flag "-f" "--force" "Remove; twice, a repository inside this one too")
      (Opts flag "-d" "Remove untracked directories whole")
      (Opts arg "-e" "--exclude" "<pattern>" "Leave what <pattern> matches, as .gitignore would")
      (Opts flag "-x" "Remove the ignored files too")
      (Opts flag "-X" "Remove only the ignored files"))))

; What clean takes, sorted as git sorts it: files by path, and with dirs?
; a directory as "DIR/" when everything in it goes -- under only-ignored?
; when it holds something to go at all.  A file goes when it is
; untracked and wanted? (whether it is ignored) says so; a directory with
; nothing tracked in it is looked into only with dirs?; one that is a
; repository of its own (it holds .git) only with nested?.  in-scope? and
; above? say whether a path is under a pathspec, or a directory a
; pathspec is under.
(def %clean-list
  (fn (_ wd tracked ignored? wanted? dirs? only-ignored? nested? in-scope? above?)
    (def tracked? (fn (_ path) (List any? (fn (_ t) (str=? t path)) tracked)))
    (def tracked-under? (fn (_ path) (List any? (fn (_ t) (Str8 starts? (Str8 append path "/") t)) tracked)))
    ; (ITEMS . WHOLE?), WHOLE? when all of the directory goes
    (def scan
      (fn (self dir prefix)
        (List fold
          (fn (_ acc name)
            (let ((full (Str8 append dir "/" name)) (path (Str8 append prefix name)))
              (let ((partly (fn (_ items) (pair (List append (first acc) items) #f))))
                (match
                  ((str=? name ".git") (partly ()))
                  ((not (or (in-scope? path) (above? path))) (partly ()))
                  ((not (%dir? full))
                    (if (and (not (tracked? path)) (in-scope? path) (wanted? (ignored? path #f)))
                      (pair (List append (first acc) (list path)) (rest acc))
                      (partly ())))
                  ((tracked-under? path) (partly (first (self full (Str8 append path "/")))))
                  ((not dirs?) (partly ()))
                  ((File exists? (Str8 append full "/.git"))
                    (if (and nested? (in-scope? path)) (pair (List append (first acc) (list (Str8 append path "/"))) (rest acc)) (partly ())))
                  (#t
                    (let ((in (self full (Str8 append path "/"))))
                      (if (and (rest in) (in-scope? path) (or (not only-ignored?) (not (null? (first in)))))
                        (pair (List append (first acc) (list (Str8 append path "/"))) (rest acc))
                        (partly (first in)))))))))
          (pair () #t) (File list-dir dir))))
    (List sort (fn (_ a b) (Str8 <? a b)) (first (scan wd "")))))

(def git-clean
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-clean-options ops))
    (def on? (fn (_ f) (Opts on? o f)))
    (def forced (List length (List filter (fn (_ f) (str=? f "-f")) (rest (Assoc entry (lit on) o)))))
    (def specs (List map (fn (_ s) (git-strip-slash s)) (Opts operands o)))
    (def in-scope?
      (fn (_ path) (or (null? specs) (List any? (fn (_ s) (or (str=? s ".") (str=? s path) (Str8 starts? (Str8 append s "/") path))) specs))))
    (def above? (fn (_ path) (List any? (fn (_ s) (Str8 starts? (Str8 append path "/") s)) specs)))
    (def require-force
      (if (null? gitdir) #t
        (let ((v (git-config-value gitdir "clean.requireForce")))
          (if (null? v) #t (not (List any? (fn (_ w) (Str8 ci=? v w)) (list "false" "no" "off" "0")))))))
    (match
      ((Opts help? git-clean-options ops) (list (lit out) (Opts usage git-clean-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-clean-options)))
      ((null? gitdir) (git-no-repo))
      ((and (on? "-x") (on? "-X")) (git-fatal "options '-x' and '-X' cannot be used together"))
      ((and require-force (= forced 0) (not (on? "-n")))
        (git-fatal "clean.requireForce is true and -f not given: refusing to clean"))
      (#t
        (let ((ignored? (git-ignorer wd gitdir (Opts values o "-e")))
              (wanted? (%wanted (on? "-x") (on? "-X"))))
          (let ((gone (%clean-list wd (List map (fn (_ e) (first e)) (git-read-entries gitdir))
                        ignored? wanted? (on? "-d") (on? "-X") (> forced 1) in-scope? above?)))
            (do (unless (on? "-n")
                  (List for-each
                    (fn (_ p)
                      (def full (Str8 append wd "/" (git-strip-slash p)))
                      (if (Str8 ends? "/" p) (%remove-tree! full) (File unlink full)))
                    gone))
                (list (lit out)
                  (if (on? "-q") ""
                    (Str8 join "" (List map (fn (_ p) (Str8 append (if (on? "-n") "Would remove " "Removing ") p "\n")) gone)))
                  0))))))))

; Which files clean takes, by whether each is ignored: -x every one, -X
; only the ignored, otherwise only the rest.
(def %wanted
  (fn (_ all? only-ignored?)
    (match (all? (fn (_ ig) #t)) (only-ignored? (fn (_ ig) ig)) (#t (fn (_ ig) (not ig))))))

(provide git/paths git-rm git-rm-options git-mv git-mv-options git-check-ignore git-check-ignore-options
  git-clean git-clean-options)
