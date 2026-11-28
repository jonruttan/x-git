; # x-git -- git on x-lang
;
; ## lib/git/history.x -- ls-tree and log
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
(import git/opts git-opts-parse)
(import x/sys/date Date)
(import x/sys/file File)
(import git/objects git-object-read git-tree-entries git-object-text git-mode-type)
(import git/commands git-fatal git-no-repo git-unknown-option)
(import git/refs git-tree-of git-commit-of git-headers git-rev-parse git-rev-path-missing git-rev-trouble git-log-ref
  git-previous-branch)
(import git/reflog git-reflog-entries)
(import git/diff git-tree-patch git-tree-forms)
(import git/quote git-quote-path)

(import x/core/doors int+ int-)

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
    (def type (git-mode-type (first e)))
    (def sha (first (rest (rest e))))
    (if names? (Str8 append (git-quote-path path) "\n")
      (Str8 append (Str8 pad-left 6 #\0 (first e)) " " type " " sha
        (if long?
          (Str8 append " "
            (Str8 pad-left 7 #\space
              (if (str=? type "blob")
                (let ((o (git-object-read gitdir sha))) (if (null? o) "-" (Str8 str (first (rest o)))))
                "-")))
          "")
        "\t" (git-quote-path path) "\n"))))

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
    (def bare (if dir? (Str8 sub 0 (int- (Str8 length path) 1) path) path))
    (def name-of (fn (_ line) (let ((i (Str8 index-of "\t" line)))
                               (Str8 trim (if (null? i) line (Str8 sub (int+ i 1) (int- (Str8 length line) (int+ i 1)) line))))))
    ; the lines under bare/: all of them with -r, else the direct ones
    (def under
      (List filter
        (fn (_ l)
          (let ((n (name-of l)))
            (and (Str8 starts? (Str8 append bare "/") n)
                 (or recurse?
                     (null? (Str8 index-of "/" (Str8 sub (int+ (Str8 length bare) 1) (int- (Str8 length n) (int+ (Str8 length bare) 1)) n)))))))
        all))
    (def own (List filter (fn (_ l) (str=? (name-of l) bare)) all))
    (match
      (dir? under)
      ((and recurse? (not (null? under))) (if trees? (List append own under) under))
      (#t own))))

(def git-ls-tree
  (fn (_ wd gitdir ops)
    (def o (git-opts-parse git-ls-tree-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-ls-tree-options ops) (list (lit out) (Opts usage git-ls-tree-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-ls-tree-options)))
      ((null? operands) (list (lit err) (Opts usage git-ls-tree-options) 129))
      ((null? gitdir) (git-no-repo))
      (#t
        (let ((tree (git-tree-of gitdir (first operands))))
          (if (null? tree) (git-fatal (Str8 append "Not a valid object name " (first operands)))
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
  (Opts declare "git log" "[-s] [-p] [--stat] [--numstat] [--raw] [--name-only | --name-status] [--oneline | --format=<format>] [-<number> | -n <number>] [<revision>]" ()
    (list
      (Opts flag "--oneline" "One line a commit: the abbreviated name and the subject")
      (Opts arg "--format" "<format>" "A commit as the format says")
      (Opts arg "--pretty" "<format>" "oneline, short, medium, full, fuller, format:<format> or tformat:<format>")
      (Opts arg "-n" "--max-count" "<number>" "Show at most <number> commits; -<number> the same")
      (Opts flag "-s" "--no-patch" "No change drawn, of what is asked before it")
      (Opts flag "-p" "--patch" "Each commit's change against its first parent; a merge's not drawn")
      (Opts flag "--stat" "Each commit's change as a row a file and the summary")
      (Opts flag "--raw" "Each commit's change as a line a file: both modes, both blobs, the letter, the name")
      (Opts flag "--numstat" "Each commit's lines added and removed a file, as numbers, and its name")
      (Opts flag "--name-only" "Only the names of the files each commit changed")
      (Opts flag "--name-status" "The names of the files each commit changed, each after its change's letter"))))

; git's -<number>, spelled as -n <number>, up to a --.
(def %counts
  (fn (_ ops)
    (def count? (fn (_ op) (and (< 1 (Str8 length op)) (Str8 starts? "-" op)
                                 (List all? (fn (_ i) (let ((c (Str8 sub i 1 op))) (and (Str8 <? "/" c) (Str8 <? c ":"))))
                                   (List range 1 (Str8 length op))))))
    ((fn (self ops)
       (match
         ((null? ops) ())
         ((str=? (first ops) "--") ops)
         ((count? (first ops)) (pair "-n" (pair (Str8 sub 1 (int- (Str8 length (first ops)) 1) (first ops)) (self (rest ops)))))
         (#t (pair (first ops) (self (rest ops))))))
     ops)))

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
    (def d (Date from-unix (int+ epoch (* sign (int+ (* hh 3600) (* mm 60))))))
    (def g (fn (_ k) (Assoc get k d)))
    (Str8 append
      (List ref (g (lit wday)) %day-names) " "
      (List ref (int- (g (lit month)) 1) %month-names) " "
      (Str8 str (g (lit day))) " "
      (%two (g (lit hour))) ":" (%two (g (lit minute))) ":" (%two (g (lit second))) " "
      (Str8 str (g (lit year))) " " zone)))

; `NAME <EMAIL> EPOCH ZONE` taken apart: (WHO EPOCH ZONE), WHO the name
; and address as written.
(def %ident
  (fn (_ line)
    (def gt (Str8 last-index-of ">" line))
    (def who (Str8 sub 0 (int+ gt 1) line))
    (def tail (Str8 split " " (Str8 trim (Str8 sub (int+ gt 1) (int- (Str8 length line) (int+ gt 1)) line))))
    (list who (%str->number (first tail) 10) (first (rest tail)))))

; An author or committer line's date as git prints it by default, for the
; commands that report a commit they made.
(def git-ident-date
  (fn (_ line) (let ((id (%ident line))) (%git-date (first (rest id)) (first (rest (rest id)))))))

; A commit's message: the text after the header's blank line, trailing
; blank lines dropped.
(def %message
  (fn (_ gitdir sha)
    (def text (git-object-text (git-object-read gitdir sha)))
    (def i (Str8 index-of "\n\n" text))
    (def body (if (null? i) "" (Str8 sub (int+ i 2) (int- (Str8 length text) (int+ i 2)) text)))
    ((fn (self lines)
       (if (and (not (null? lines)) (= (Str8 length (List last lines)) 0))
         (self (List take (int- (List length lines) 1) lines))
         lines))
     (Str8 split "\n" body))))

; One commit as `git log` prints it in one of git's built-in forms: kind
; medium (the default), short, full or fuller.
(def %commit-text
  (fn (_ gitdir sha kind)
    (def hs (git-headers gitdir sha))
    (def parents (List filter (fn (_ kv) (str=? (first kv) "parent")) hs))
    (def person (fn (_ k) (%ident (rest (List find (fn (_ kv) (str=? (first kv) k)) hs)))))
    (def date (fn (_ id) (%git-date (first (rest id)) (first (rest (rest id))))))
    (def author (person "author"))
    (def committer (person "committer"))
    (def message (%message gitdir sha))
    (Str8 append
      "commit " sha "\n"
      (if (> (List length parents) 1)
        (Str8 append "Merge: " (Str8 join " " (List map (fn (_ p) (Str8 sub 0 7 (rest p))) parents)) "\n")
        "")
      (match
        ((eq? kind (lit short)) (Str8 append "Author: " (first author) "\n"))
        ((eq? kind (lit full)) (Str8 append "Author: " (first author) "\n" "Commit: " (first committer) "\n"))
        ((eq? kind (lit fuller))
          (Str8 append "Author:     " (first author) "\n" "AuthorDate: " (date author) "\n"
                       "Commit:     " (first committer) "\n" "CommitDate: " (date committer) "\n"))
        (#t (Str8 append "Author: " (first author) "\n" "Date:   " (date author) "\n")))
      "\n"
      (Str8 join ""
        (List map (fn (_ l) (Str8 append "    " l "\n"))
          ; short: the subject's lines alone
          (if (not (eq? kind (lit short))) message
            ((fn (self ls) (if (or (null? ls) (= (Str8 length (Str8 trim (first ls))) 0)) () (pair (first ls) (self (rest ls)))))
             message)))))))

; --oneline's line: the abbreviated name and the subject.
(def %oneline-text
  (fn (_ gitdir sha)
    (Str8 append (Str8 sub 0 7 sha) " " (first (%subject-body (%raw-message gitdir sha))) "\n")))

; --pretty=oneline's: the full name and the subject.
(def %line-text
  (fn (_ gitdir sha)
    (Str8 append sha " " (first (%subject-body (%raw-message gitdir sha))) "\n")))

; A committer's epoch, to order the walk.
(def %commit-time
  (fn (_ gitdir sha)
    (def e (List find (fn (_ kv) (str=? (first kv) "committer")) (git-headers gitdir sha)))
    (if (null? e) 0 (first (rest (%ident (rest e)))))))

; The commits reachable from the shas starts but not from those in
; excluded, newest committer time first, each once, as git walks them; at
; most limit of them (() for all).
(def %walk
  (fn (_ gitdir starts excluded limit)
    (def insert
      (fn (self item pending)
        (match
          ((null? pending) (list item))
          ; newer first; among equals, the first queued first, as git's queue keeps them
          ((> (first item) (first (first pending))) (pair item pending))
          (#t (pair (first pending) (self item (rest pending)))))))
    (def queue (fn (_ pending sha) (insert (pair (%commit-time gitdir sha) sha) pending)))
    (def known? (fn (_ sha l) (List any? (fn (_ s) (str=? s sha)) l)))
    ((fn (self pending seen out n)
       (match
         ((null? pending) (List reverse out))
         ((if (null? limit) #f (>= n limit)) (List reverse out))
         (#t
           (let ((cur (rest (first pending))))
             (if (or (known? cur seen) (known? cur excluded))
               (self (rest pending) seen out n)
               (let ((parents (List filter (fn (_ kv) (str=? (first kv) "parent")) (git-headers gitdir cur))))
                 (self (List fold (fn (_ acc p) (queue acc (rest p))) (rest pending) parents)
                   (pair cur seen) (pair cur out) (int+ n 1))))))))
     (List fold queue () starts) () () 0)))

; The commits revisions name, as git's revision walk lists them: those
; reachable from the shas in starts and from none in ends, newest first.
(def git-rev-walk
  (fn (_ gitdir starts ends)
    (%walk gitdir starts (if (null? ends) () (%walk gitdir ends () ())) ())))

(def git-log
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-log-options (%counts ops)))
    (def operands (Opts operands o))
    ; the last count given
    (def limit (let ((vs (Opts values o "-n"))) (if (null? vs) () (%str->number (List last vs) 10))))
    (def pretty (%pretty o))
    (def drawing (%drawing ops))
    (def patch? (first (rest drawing)))
    (def forms (first (rest (rest drawing))))
    (match
      ((Opts help? git-log-options ops) (list (lit out) (Opts usage git-log-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-log-options)))
      ((null? gitdir) (git-no-repo))
      ((eq? (first pretty) (lit bad)) (%bad-pretty pretty))
      ((not (null? (%drawing-refusal drawing))) (%drawing-refusal drawing))
      (#t
        (let ((rev (if (null? operands) "HEAD" (first operands))))
          (let ((sha (git-commit-of gitdir rev)))
            (match
              ((and (null? sha) (not (null? (git-rev-trouble gitdir rev))))
                (git-fatal (git-rev-trouble gitdir rev)))
              ((null? sha)
                (list (lit err)
                  (Str8 join "\n"
                    (list (Str8 append "fatal: ambiguous argument '" rev "': unknown revision or path not in the working tree.")
                          "Use '--' to separate paths from revisions, like this:"
                          "'git <command> [<revision>...] -- [<file>...]'"
                          ""))
                  128))
              (#t
                (let ((commits (%walk gitdir (list sha) () limit)))
                  (list (lit out)
                    (Str8 join (if (%apart? pretty) "\n" "") (List map (fn (_ c) (%show-commit gitdir c pretty patch? forms #f)) commits))
                    0))))))))))

; --- show ---

(def git-show-options
  (Opts declare "git show" "[-s] [-p] [--stat] [--numstat] [--raw] [--name-only | --name-status] [--oneline | --format=<format>] [<object>...]" ()
    (list
      (Opts flag "-s" "--no-patch" "No change drawn, of what is asked before it")
      (Opts flag "-p" "--patch" "The patch, as without another form; with them, all")
      (Opts flag "--stat" "The change as a row a file and the summary")
      (Opts flag "--raw" "The change as a line a file: both modes, both blobs, the letter, the name")
      (Opts flag "--numstat" "Lines added and removed a file, as numbers, and its name")
      (Opts flag "--name-only" "Only the names of the files changed")
      (Opts flag "--name-status" "The names of the files changed, each after its change's letter")
      (Opts flag "--oneline" "One line a commit: the abbreviated name and the subject")
      (Opts arg "--format" "<format>" "A commit as the format says")
      (Opts arg "--pretty" "<format>" "oneline, short, medium, full, fuller, format:<format> or tformat:<format>"))))

; An object's text after its header's blank line: a commit's or a tag's
; message as written.
(def %raw-message
  (fn (_ gitdir sha)
    (def text (git-object-text (git-object-read gitdir sha)))
    (def i (Str8 index-of "\n\n" text))
    (if (null? i) "" (Str8 sub (int+ i 2) (int- (Str8 length text) (int+ i 2)) text))))

; A message's subject -- its first paragraph's lines joined by spaces --
; and its body, what follows the blank lines after: (SUBJECT . BODY).
(def %subject-body
  (fn (_ raw)
    (def blank? (fn (_ l) (= (Str8 length (Str8 trim l)) 0)))
    (def para
      ((fn (self ls acc) (if (or (null? ls) (blank? (first ls))) (pair (List reverse acc) ls) (self (rest ls) (pair (first ls) acc))))
       (Str8 split "\n" raw) ()))
    (def after ((fn (self ls) (if (and (not (null? ls)) (blank? (first ls))) (self (rest ls)) ls)) (rest para)))
    (pair (Str8 join " " (first para)) (Str8 join "\n" after))))

; A user format for a commit: git's placeholders for its names, its
; people, their dates and its message; any other %x as written.
(def %expand
  (fn (_ gitdir sha fmt)
    (def hs (git-headers gitdir sha))
    (def header (fn (_ k) (let ((e (List find (fn (_ kv) (str=? (first kv) k)) hs))) (if (null? e) "" (rest e)))))
    (def parents (List map rest (List filter (fn (_ kv) (str=? (first kv) "parent")) hs)))
    (def person
      (fn (_ k)
        (def id (%ident (header k)))
        (def who (first id))
        (def lt (Str8 index-of " <" who))
        (list (if (null? lt) who (Str8 sub 0 lt who))
              (if (null? lt) "" (Str8 sub (int+ lt 2) (int- (Str8 length who) (int+ lt 3)) who))
              (%git-date (first (rest id)) (first (rest (rest id)))))))
    (def raw (%raw-message gitdir sha))
    (def sb (%subject-body raw))
    (def n (Str8 length fmt))
    (def one
      (fn (_ code)
        (match
          ((str=? code "H") sha) ((str=? code "h") (Str8 sub 0 7 sha))
          ((str=? code "T") (header "tree")) ((str=? code "t") (Str8 sub 0 7 (header "tree")))
          ((str=? code "P") (Str8 join " " parents)) ((str=? code "p") (Str8 join " " (List map (fn (_ p) (Str8 sub 0 7 p)) parents)))
          ((str=? code "s") (first sb)) ((str=? code "b") (rest sb)) ((str=? code "B") raw)
          ((str=? code "an") (first (person "author"))) ((str=? code "ae") (first (rest (person "author"))))
          ((str=? code "ad") (first (rest (rest (person "author")))))
          ((str=? code "cn") (first (person "committer"))) ((str=? code "ce") (first (rest (person "committer"))))
          ((str=? code "cd") (first (rest (rest (person "committer")))))
          ((str=? code "n") "\n") ((str=? code "%") "%")
          (#t ()))))
    ((fn (self i acc)
       (match
         ((>= i n) (Str8 join "" (List reverse acc)))
         ((str=? (Str8 sub i 1 fmt) "%")
           (let ((two (if (<= (int+ i 3) n) (one (Str8 sub (int+ i 1) 2 fmt)) ()))
                 (single (if (< (int+ i 1) n) (one (Str8 sub (int+ i 1) 1 fmt)) ())))
             (match
               ((not (null? two)) (self (int+ i 3) (pair two acc)))
               ((not (null? single)) (self (int+ i 2) (pair single acc)))
               (#t (self (int+ i 1) (pair "%" acc))))))
         (#t (self (int+ i 1) (pair (Str8 sub i 1 fmt) acc)))))
     0 ())))

; How commits are shown, from --format or --pretty, which git reads
; alike, the last given: (KIND . FORMAT), KIND one of git's built-in
; forms -- medium (the default), short, full, fuller, or line for
; oneline -- or oneline for --oneline; or format (format:) or tformat
; (tformat:, or a format with a % in it, or none) with its FORMAT; or
; (bad . SPEC) for a spec git has no form for.
(def %pretty
  (fn (_ o)
    (def given (List append (Opts values o "--pretty") (Opts values o "--format")))
    (def spec (if (null? given) () (List last given)))
    (def after (fn (_ prefix s) (Str8 sub (Str8 length prefix) (int- (Str8 length s) (Str8 length prefix)) s)))
    (match
      ((null? spec) (pair (if (Opts on? o "--oneline") (lit oneline) (lit medium)) ()))
      ((str=? spec "oneline") (pair (lit line) ()))
      ((str=? spec "short") (pair (lit short) ()))
      ((str=? spec "medium") (pair (lit medium) ()))
      ((str=? spec "full") (pair (lit full) ()))
      ((str=? spec "fuller") (pair (lit fuller) ()))
      ((Str8 starts? "format:" spec) (pair (lit format) (after "format:" spec)))
      ((Str8 starts? "tformat:" spec) (pair (lit tformat) (after "tformat:" spec)))
      ((or (str=? spec "") (not (null? (Str8 index-of "%" spec)))) (pair (lit tformat) spec))
      (#t (pair (lit bad) spec)))))

; A user format of nothing, which git draws as nothing, no newline after.
(def %empty-format?
  (fn (_ pretty)
    (and (or (eq? (first pretty) (lit format)) (eq? (first pretty) (lit tformat))) (str=? (rest pretty) ""))))

(def %bad-pretty (fn (_ pretty) (git-fatal (Str8 append "invalid --pretty format: " (rest pretty)))))

; A commit's header in the pretty form, as log and show print it.
(def %pretty-text
  (fn (_ gitdir sha pretty)
    (def kind (first pretty))
    (match
      ((eq? kind (lit oneline)) (%oneline-text gitdir sha))
      ((eq? kind (lit line)) (%line-text gitdir sha))
      ((%empty-format? pretty) "")
      ((eq? kind (lit tformat)) (Str8 append (%expand gitdir sha (rest pretty)) "\n"))
      ((eq? kind (lit format)) (%expand gitdir sha (rest pretty)))
      (#t (%commit-text gitdir sha kind)))))

; Whether commits shown one after another are set apart: by a blank line
; in git's forms of several lines, by a newline under format:, which ends
; none of its own.
(def %apart? (fn (_ pretty) (not (List any? (fn (_ k) (eq? k (first pretty))) (list (lit oneline) (lit line) (lit tformat))))))

; How a change is asked to be drawn, the options read in order as git
; reads them, up to a `--`: -s (--no-patch) clears what came before it,
; and a form after it is drawn still.  (QUIET? PATCH? FORMS): whether a
; -s was given, whether the patch stands, and the other forms, as diff's
; flags.
(def %form-flags (list "--raw" "--numstat" "--stat" "--name-only" "--name-status"))
(def %drawing
  (fn (_ ops)
    (def one-of? (fn (_ s l) (List any? (fn (_ x) (str=? x s)) l)))
    (let go ((os ops) (quiet? #f) (patch? #f) (forms ()))
      (match
        ((or (null? os) (str=? (first os) "--"))
          (list quiet? patch? (List filter (fn (_ f) (one-of? f forms)) %form-flags)))
        ((one-of? (first os) (list "-s" "--no-patch")) (go (rest os) #t #f ()))
        ((one-of? (first os) (list "-p" "--patch")) (go (rest os) quiet? #t forms))
        ((one-of? (first os) %form-flags) (go (rest os) quiet? patch? (pair (first os) forms)))
        (#t (go (rest os) quiet? patch? forms))))))

; The refusal of forms that cannot be drawn together: both name forms,
; or either after a -s; () when there is none.
(def %drawing-refusal
  (fn (_ d)
    (def forms (first (rest (rest d))))
    (def has? (fn (_ f) (List any? (fn (_ x) (str=? x f)) forms)))
    (if (or (and (has? "--name-only") (has? "--name-status"))
            (and (first d) (or (has? "--name-only") (has? "--name-status"))))
      (git-fatal "options '--name-only', '--name-status', '--check', and '-s' cannot be used together")
      ())))

; A commit as show prints it: its header in the pretty form, then its
; change against its first parent -- the --raw lines, the --numstat, the
; --stat, the patch, as asked, or --name-only or --name-status in place
; of them all -- after the separator git puts there: a blank line, or
; `---` when the stat and the patch are both drawn; none in a form of
; one line or an empty format.  A blank line between the lines before
; the patch and the patch.  A merge's patch is its combined diff, which
; is not drawn, nor its raw lines or names: the header and the blank
; line git ends it with, and its --numstat and --stat against its first
; parent.  log draws no change for a merge at all (merges? #f).
(def %show-commit
  (fn (_ gitdir sha pretty patch? forms merges?)
    (def kind (first pretty))
    (def parents (List map rest (List filter (fn (_ kv) (str=? (first kv) "parent")) (git-headers gitdir sha))))
    (def merge? (< 1 (List length parents)))
    (def on? (fn (_ f) (List any? (fn (_ x) (str=? x f)) forms)))
    (def names? (or (on? "--name-only") (on? "--name-status")))
    (def stat? (and (on? "--stat") (not names?)))
    ; what a merge draws: its counts against its first parent
    (def drawn (List filter (fn (_ f) (or (not merge?) (str=? f "--numstat") (str=? f "--stat"))) forms))
    (def head (%pretty-text gitdir sha pretty))
    (def gap (if (or (eq? kind (lit oneline)) (eq? kind (lit line)) (%empty-format? pretty)) "" "\n"))
    (def old (if (null? parents) () (git-tree-of gitdir (first parents))))
    (def new (git-tree-of gitdir sha))
    (def lead (if (null? drawn) "" (git-tree-forms gitdir old new drawn)))
    (def patch (if (and patch? (not merge?) (not names?)) (git-tree-patch gitdir old new #f) ""))
    (def none? (fn (_ s) (= (Str8 length s) 0)))
    (match
      ((and (not patch?) (null? forms)) head)
      ((and (not merges?) merge?) head)
      ((and merge? (null? drawn)) (Str8 append head gap))
      ((and (none? lead) (none? patch)) head)
      (#t (Str8 append head
            (if (and patch? stat? (not merge?) (not (str=? gap ""))) "---\n" gap)
            lead (if (or (none? lead) (none? patch)) "" "\n") patch)))))

; A tag as show prints it: its name, its tagger and date, its message
; and the blank line after it.
(def %show-tag
  (fn (_ gitdir sha)
    (def hs (git-headers gitdir sha))
    (def get (fn (_ k) (let ((e (List find (fn (_ kv) (str=? (first kv) k)) hs))) (if (null? e) "" (rest e)))))
    (def tagger (%ident (get "tagger")))
    (Str8 append "tag " (get "tag") "\n"
      "Tagger: " (first tagger) "\n"
      "Date:   " (%git-date (first (rest tagger)) (first (rest (rest tagger)))) "\n\n"
      (%raw-message gitdir sha) "\n")))

; A tree as show prints it: `tree NAME`, then its entries' names, a
; subtree's with a slash.
(def %show-tree
  (fn (_ gitdir sha name)
    (Str8 append "tree " name "\n\n"
      (Str8 join ""
        (List map (fn (_ e) (Str8 append (first (rest e)) (if (str=? (first e) "40000") "/" "") "\n"))
          (git-tree-entries (git-object-read gitdir sha)))))))

(def git-show
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-show-options ops))
    (def names (if (null? (Opts operands o)) (list "HEAD") (Opts operands o)))
    (def drawing (%drawing ops))
    (def forms (first (rest (rest drawing))))
    ; the patch, unless something else was asked for, or nothing (-s)
    (def patch? (or (first (rest drawing)) (and (not (first drawing)) (null? forms))))
    (def pretty (%pretty o))
    (match
      ((Opts help? git-show-options ops) (list (lit out) (Opts usage git-show-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-show-options)))
      ((null? gitdir) (git-no-repo))
      ((eq? (first pretty) (lit bad)) (%bad-pretty pretty))
      ((not (null? (%drawing-refusal drawing))) (%drawing-refusal drawing))
      (#t
        ; each name resolved once, all before anything is shown
        (let ((shas (List map (fn (_ n) (git-rev-parse gitdir n)) names)))
        (let ((bad (let ((b (List find (fn (_ p) (null? (rest p))) (List map pair names shas)))) (if (null? b) () (first b)))))
          (if (not (null? bad))
            (let ((base (git-rev-path-missing gitdir bad)))
              (match
                ((not (null? (git-rev-trouble gitdir bad))) (git-fatal (git-rev-trouble gitdir bad)))
                ((not (null? base))
                  (git-fatal (Str8 append "path '" (Str8 sub (int+ (Str8 length base) 1) (int- (Str8 length bad) (int+ (Str8 length base) 1)) bad)
                            "' does not exist in '" base "'")))
                (#t
                  (list (lit err)
                    (Str8 join "\n"
                      (list (Str8 append "fatal: ambiguous argument '" bad "': unknown revision or path not in the working tree.")
                            "Use '--' to separate paths from revisions, like this:"
                            "'git <command> [<revision>...] -- [<file>...]'"
                            ""))
                    128))))
            ; each object in turn; a commit after a commit set apart, by a
            ; blank line when shown in full, as log sets them, by a newline
            ; under format:, which ends none of its own
            ((fn (self ns acc after-commit?)
               (if (null? ns) (list (lit out) (Str8 join "" (List reverse acc)) 0)
                 (let ((sha (rest (first ns))))
                   (let ((type (first (git-object-read gitdir sha)))
                         (sep (if (and after-commit? (%apart? pretty)) "\n" "")))
                     (match
                       ((str=? type "commit")
                         (self (rest ns) (pair (Str8 append sep (%show-commit gitdir sha pretty patch? forms #t)) acc) #t))
                       ((str=? type "tag")
                         (let ((target (git-commit-of gitdir sha)))
                           (self (rest ns)
                                 (pair (Str8 append sep (%show-tag gitdir sha)
                                         (if (null? target) "" (%show-commit gitdir target pretty patch? forms #t)))
                                       acc)
                                 (not (null? target)))))
                       ((str=? type "tree") (self (rest ns) (pair (%show-tree gitdir sha (first (first ns))) acc) #f))
                       (#t (self (rest ns) (pair (git-object-text (git-object-read gitdir sha)) acc) #f)))))))
             (List map pair names shas) () #f))))))))

; --- reflog ---

(def git-reflog-options
  (Opts declare "git reflog" "[show] [-n <number>] [<ref>...] | exists <ref>" ()
    (list (Opts arg "-n" "--max-count" "<number>" "Show at most <number> entries"))))

; One ref's log as `git reflog show` prints it, newest first, a line an
; entry: the commit it moved to, NAME@{N}, and the message.
(def %reflog-lines
  (fn (_ gitdir name ref)
    (def entries (git-reflog-entries gitdir ref))
    ((fn (self es i acc)
       (if (null? es) (List reverse acc)
         (let ((e (first es)))
           (self (rest es) (int+ i 1)
             (pair (Str8 append (Str8 sub 0 7 (first (rest e))) " " name "@{" (Str8 str i) "}: " (first (rest (rest (rest e)))) "\n") acc)))))
     entries 0 ())))

(def git-reflog
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-reflog-options ops))
    (def operands (Opts operands o))
    (def sub (if (and (not (null? operands)) (or (str=? (first operands) "show") (str=? (first operands) "exists"))) (first operands) "show"))
    (def names (if (and (not (null? operands)) (str=? (first operands) sub)) (rest operands) operands))
    (def limit (let ((v (Opts value o "-n" ()))) (if (null? v) () (%str->number v 10))))
    ; the lines gathered, the first -n of them
    (def shown
      (fn (_ acc)
        (def lines (List reverse acc))
        (Str8 join "" (if (or (null? limit) (> limit (List length lines))) lines (List take limit lines)))))
    ; @{-N} stands for the branch it names
    (def named (fn (_ n) (if (Str8 starts? "@{-" n) (or (git-previous-branch gitdir n) n) n)))
    (match
      ((Opts help? git-reflog-options ops) (list (lit out) (Opts usage git-reflog-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-reflog-options)))
      ((null? gitdir) (git-no-repo))
      ; exists takes the ref's full name
      ((str=? sub "exists")
        (if (or (null? names) (not (null? (rest names)))) (list (lit err) (Opts usage git-reflog-options) 129)
          (list (lit out) "" (if (File exists? (Str8 append gitdir "/logs/" (first names))) 0 1))))
      (#t
        ((fn (self ns acc)
           (if (null? ns) (list (lit out) (shown acc) 0)
             (let ((name (named (first ns))))
             (let ((ref (git-log-ref gitdir name)))
               (match
                 ((not (null? ref)) (self (rest ns) (List append (List reverse (%reflog-lines gitdir name ref)) acc)))
                 ; a name that resolves but has no log shows nothing
                 ((not (null? (git-rev-parse gitdir name))) (self (rest ns) acc))
                 (#t
                   (list (lit err)
                     (Str8 join "\n"
                       (list (Str8 append "fatal: ambiguous argument '" (first ns) "': unknown revision or path not in the working tree.")
                             "Use '--' to separate paths from revisions, like this:"
                             "'git <command> [<revision>...] -- [<file>...]'"
                             ""))
                     128
                     "")))))))
         (if (null? names) (list "HEAD") names) ())))))

(provide git/history git-ls-tree git-ls-tree-options git-log git-log-options git-show git-show-options git-ident-date git-rev-walk
  git-reflog git-reflog-options)
