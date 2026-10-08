; # x-git -- git on x-lang
;
; ## git/history.x -- ls-tree and log
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The commands that show what the object store holds: a tree's entries,
; and the commits reachable from a revision, newest first.  Each takes the
; repository, the working directory and its arguments and answers (STREAM
; TEXT STATUS), as git/commands.x's do; the layout is git's own.

(module git/history)

(import x/sys/opts Opts)
(import x/sys/date Date)
(import git/objects git-object-read git-tree-entries git-object-text)
(import git/refs git-tree-of git-commit-of git-headers)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

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

(def %mode-type
  (fn (_ mode)
    (match ((str=? mode "40000") "tree") ((str=? mode "160000") "commit") (#t "blob"))))

; --- ls-tree ---

(def git-ls-tree-options
  (Opts declare "git ls-tree" "[-r] [-t] [-l] [--name-only] <tree-ish> [<path>...]" ()
    (list
      (Opts flag "-r" "Recurse into subtrees")
      (Opts flag "-t" "Show trees when recursing")
      (Opts flag "-l" "--long" "Show the object size of blobs")
      (Opts flag "--name-only" "List only filenames"))))

; One entry's line: the mode padded to six digits, the type, the name in
; hex, with -l the size right-aligned in seven columns ("-" for a tree),
; a tab, the path; with --name-only the path alone.
(def %entry-line
  (fn (_ gitdir e path long? names?)
    (def type (%mode-type (first e)))
    (def sha (first (rest (rest e))))
    (if names? (Str8 append path "\n")
      (Str8 append (Str8 pad-left 6 #\0 (first e)) " " type " " sha
        (if long?
          (Str8 append " "
            (Str8 pad-left 7 #\space
              (if (str=? type "blob")
                (let ((o (git-object-read gitdir sha))) (if (null? o) "-" (Str8 str (first (rest o)))))
                "-")))
          "")
        "\t" path "\n"))))

; The lines for a tree, its entries at prefix; a tree entry recursed into
; with -r, and listed too with -t.
(def %tree-lines
  (fn (self gitdir tree prefix recurse? trees? long? names?)
    (def o (git-object-read gitdir tree))
    (if (or (null? o) (not (str=? (first o) "tree"))) ()
      (List flat-map
        (fn (_ e)
          (let ((path (Str8 append prefix (first (rest e))))
                (sub? (str=? (first e) "40000")))
            (if (and sub? recurse?)
              (List append
                (if trees? (list (%entry-line gitdir e path long? names?)) ())
                (self gitdir (first (rest (rest e))) (Str8 append path "/") recurse? trees? long? names?))
              (list (%entry-line gitdir e path long? names?)))))
        (git-tree-entries o)))))

; The lines for one path operand: the entry it names; the contents of the
; tree it names when it ends in "/", or when -r recurses into it; nothing
; when there is no such entry, as git prints nothing.
(def %path-lines
  (fn (_ gitdir tree path recurse? trees? long? names?)
    (def all (%tree-lines gitdir tree "" #t #t long? names?))
    (def dir? (Str8 ends? "/" path))
    (def bare (if dir? (Str8 sub 0 (%sub (Str8 length path) 1) path) path))
    (def name-of (fn (_ line) (let ((i (Str8 index-of "\t" line)))
                               (Str8 trim (if (null? i) line (Str8 sub (%add i 1) (%sub (Str8 length line) (%add i 1)) line))))))
    ; the lines under bare/: all of them with -r, else the direct ones
    (def under
      (List filter
        (fn (_ l)
          (let ((n (name-of l)))
            (and (Str8 starts? (Str8 append bare "/") n)
                 (or recurse?
                     (null? (Str8 index-of "/" (Str8 sub (%add (Str8 length bare) 1) (%sub (Str8 length n) (%add (Str8 length bare) 1)) n)))))))
        all))
    (def own (List filter (fn (_ l) (str=? (name-of l) bare)) all))
    (match
      (dir? under)
      ((and recurse? (not (null? under))) (if trees? (List append own under) under))
      (#t own))))

(def git-ls-tree
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-ls-tree-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-ls-tree-options ops) (list (lit out) (Opts usage git-ls-tree-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-ls-tree-options)))
      ((null? operands) (list (lit err) (Opts usage git-ls-tree-options) 129))
      ((null? gitdir) (%no-repo))
      (#t
        (let ((tree (git-tree-of gitdir (first operands))))
          (if (null? tree) (%fatal (Str8 append "Not a valid object name " (first operands)))
            (let ((recurse? (Opts on? o "-r")) (trees? (Opts on? o "-t"))
                  (long? (Opts on? o "-l")) (names? (Opts on? o "--name-only")))
              (list (lit out)
                (Str8 join ""
                  (if (null? (rest operands))
                    (%tree-lines gitdir tree "" recurse? trees? long? names?)
                    (List flat-map (fn (_ p) (%path-lines gitdir tree p recurse? trees? long? names?)) (rest operands))))
                0))))))))

; --- log ---

(def git-log-options
  (Opts declare "git log" "[--oneline] [-n <number>] [<revision>]" ()
    (list
      (Opts flag "--oneline" "One line a commit: the abbreviated name and the subject")
      (Opts arg "-n" "--max-count" "<number>" "Show at most <number> commits"))))

(def %month-names
  (list "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))
(def %day-names (list "Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"))

(def %two (fn (_ n) (Str8 pad-left 2 #\0 (Str8 str n))))

; An author or committer line's tail -- `EPOCH +HHMM` -- as git's default
; date: the civil time in that very offset, `Wed Oct 7 22:34:56 2026 -0400`.
(def %git-date
  (fn (_ epoch zone)
    (def sign (if (Str8 starts? "-" zone) -1 1))
    (def hh (%str->number (Str8 sub 1 2 zone) 10))
    (def mm (%str->number (Str8 sub 3 2 zone) 10))
    (def d (Date from-unix (%add epoch (* sign (%add (* hh 3600) (* mm 60))))))
    (def g (fn (_ k) (Assoc get k d)))
    (Str8 append
      (List ref (g (lit wday)) %day-names) " "
      (List ref (%sub (g (lit month)) 1) %month-names) " "
      (Str8 str (g (lit day))) " "
      (%two (g (lit hour))) ":" (%two (g (lit minute))) ":" (%two (g (lit second))) " "
      (Str8 str (g (lit year))) " " zone)))

; `NAME <EMAIL> EPOCH ZONE` taken apart: (WHO EPOCH ZONE), WHO the name
; and address as written.
(def %ident
  (fn (_ line)
    (def gt (Str8 last-index-of ">" line))
    (def who (Str8 sub 0 (%add gt 1) line))
    (def tail (Str8 split " " (Str8 trim (Str8 sub (%add gt 1) (%sub (Str8 length line) (%add gt 1)) line))))
    (list who (%str->number (first tail) 10) (first (rest tail)))))

; A commit's message: the text after the header's blank line, trailing
; blank lines dropped.
(def %message
  (fn (_ gitdir sha)
    (def text (git-object-text (git-object-read gitdir sha)))
    (def i (Str8 index-of "\n\n" text))
    (def body (if (null? i) "" (Str8 sub (%add i 2) (%sub (Str8 length text) (%add i 2)) text)))
    ((fn (self lines)
       (if (and (not (null? lines)) (= (Str8 length (List last lines)) 0))
         (self (List take (%sub (List length lines) 1) lines))
         lines))
     (Str8 split "\n" body))))

; One commit as `git log` prints it.
(def %commit-text
  (fn (_ gitdir sha)
    (def hs (git-headers gitdir sha))
    (def parents (List filter (fn (_ kv) (str=? (first kv) "parent")) hs))
    (def author (%ident (rest (List find (fn (_ kv) (str=? (first kv) "author")) hs))))
    (Str8 append
      "commit " sha "\n"
      (if (> (List length parents) 1)
        (Str8 append "Merge: " (Str8 join " " (List map (fn (_ p) (Str8 sub 0 7 (rest p))) parents)) "\n")
        "")
      "Author: " (first author) "\n"
      "Date:   " (%git-date (first (rest author)) (first (rest (rest author)))) "\n"
      "\n"
      (Str8 join "" (List map (fn (_ l) (Str8 append "    " l "\n")) (%message gitdir sha))))))

(def %oneline-text
  (fn (_ gitdir sha)
    (def msg (%message gitdir sha))
    (Str8 append (Str8 sub 0 7 sha) " " (if (null? msg) "" (first msg)) "\n")))

; A committer's epoch, to order the walk.
(def %commit-time
  (fn (_ gitdir sha)
    (def e (List find (fn (_ kv) (str=? (first kv) "committer")) (git-headers gitdir sha)))
    (if (null? e) 0 (first (rest (%ident (rest e)))))))

; The commits reachable from sha, newest committer time first, each once;
; at most limit of them (() for all).
(def %walk
  (fn (_ gitdir sha limit)
    (def insert
      (fn (self item pending)
        (match
          ((null? pending) (list item))
          ((>= (first item) (first (first pending))) (pair item pending))
          (#t (pair (first pending) (self item (rest pending)))))))
    ((fn (self pending seen out n)
       (match
         ((null? pending) (List reverse out))
         ((if (null? limit) #f (>= n limit)) (List reverse out))
         (#t
           (let ((cur (rest (first pending))))
             (if (List any? (fn (_ s) (str=? s cur)) seen)
               (self (rest pending) seen out n)
               (let ((parents (List filter (fn (_ kv) (str=? (first kv) "parent")) (git-headers gitdir cur))))
                 (self
                   (List fold (fn (_ acc p) (insert (pair (%commit-time gitdir (rest p)) (rest p)) acc))
                     (rest pending) parents)
                   (pair cur seen) (pair cur out) (%add n 1))))))))
     (list (pair (%commit-time gitdir sha) sha)) () () 0)))

(def git-log
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-log-options ops))
    (def operands (Opts operands o))
    (def limit (let ((v (Opts value o "-n" ()))) (if (null? v) () (%str->number v 10))))
    (match
      ((Opts help? git-log-options ops) (list (lit out) (Opts usage git-log-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-log-options)))
      ((null? gitdir) (%no-repo))
      (#t
        (let ((rev (if (null? operands) "HEAD" (first operands))))
          (let ((sha (git-commit-of gitdir rev)))
            (match
              ((null? sha)
                (list (lit err)
                  (Str8 join "\n"
                    (list (Str8 append "fatal: ambiguous argument '" rev "': unknown revision or path not in the working tree.")
                          "Use '--' to separate paths from revisions, like this:"
                          "'git <command> [<revision>...] -- [<file>...]'"
                          ""))
                  128))
              (#t
                (let ((commits (%walk gitdir sha limit)))
                  (list (lit out)
                    (if (Opts on? o "--oneline")
                      (Str8 join "" (List map (fn (_ c) (%oneline-text gitdir c)) commits))
                      (Str8 join "\n" (List map (fn (_ c) (%commit-text gitdir c)) commits)))
                    0))))))))))

(provide git/history git-ls-tree git-ls-tree-options git-log git-log-options)
