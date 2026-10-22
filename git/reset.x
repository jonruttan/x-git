; # x-git -- git on x-lang
;
; ## git/reset.x -- reset
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; git reset: the branch HEAD names, or HEAD itself when it is detached,
; moved to a commit (HEAD when none is named), ORIG_HEAD left at where
; it was; then, by its mode, nothing more (--soft), the index set to the
; commit's tree (--mixed, the default), or the index and the working
; directory both (--hard), a merge in progress given up with them.  With
; paths, only those paths' index entries are set from the commit, and
; HEAD stays.  What it prints is git's: the working directory's own
; changes left after a mixed reset, the commit a hard one lands on.

(module git/reset)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/objects git-object-read git-object-text)
(import git/refs git-rev-parse git-commit-of git-tree-of)
(import git/index git-status-lists)
(import git/stage git-read-entries git-index-write! git-merge-state-clear!)
(import git/checkout git-write-blob! git-remove-file! git-entry-of)
(import git/remote git-write-ref! git-current-branch)
(import git/threeway git-tree-flat)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))
(def %no-repo (fn (_) (%fatal "not a git repository (or any of the parent directories): .git")))
(def %member? (fn (_ s l) (List any? (fn (_ x) (str=? x s)) l)))

(def %ambiguous
  (fn (_ rev)
    (list (lit err)
      (Str8 join "\n"
        (list (Str8 append "fatal: ambiguous argument '" rev "': unknown revision or path not in the working tree.")
              "Use '--' to separate paths from revisions, like this:"
              "'git <command> [<revision>...] -- [<file>...]'"
              ""))
      128)))

(def git-reset-options
  (Opts declare "git reset" "[--soft | --mixed | --hard] [-q] [<commit>] [[--] <pathspec>...]" ()
    (list
      (Opts flag "--soft" "Move HEAD only")
      (Opts flag "--mixed" "Move HEAD and set the index (the default)")
      (Opts flag "--hard" "Move HEAD and set the index and the working directory")
      (Opts flag "-q" "--quiet" "Print nothing but errors"))))

; A commit's files, (PATH MODE SHA) each.
(def %files (fn (_ gitdir commit) (git-tree-flat gitdir (git-tree-of gitdir commit) "")))

(def %mode-number (fn (_ text) (%str->number text 8)))

; A commit's subject: its message's first line.
(def %subject
  (fn (_ gitdir sha)
    (def text (git-object-text (git-object-read gitdir sha)))
    (def i (Str8 index-of "\n\n" text))
    (if (null? i) "" (first (Str8 split "\n" (Str8 sub (%add i 2) (%sub (Str8 length text) (%add i 2)) text))))))

; Does a path fall under a pathspec: the path itself, or a directory
; holding it?
(def %under?
  (fn (_ path specs)
    (List any? (fn (_ s) (or (str=? path s) (str=? s ".") (Str8 starts? (Str8 append s "/") path))) specs)))

; The index's entries for files, those a path keeps the same kept as
; they are, the rest new; a path in conflict left behind.
(def %entries-for
  (fn (_ old files)
    (List map
      (fn (_ f)
        (def kept (List find (fn (_ e) (and (str=? (first e) (first f)) (null? (rest (rest (rest (rest (rest e))))))
                                            (str=? (first (rest (rest e))) (first (rest (rest f))))
                                            (= (first (rest e)) (%mode-number (first (rest f))))))
                    old))
        (if (null? kept) (list (first f) (%mode-number (first (rest f))) (first (rest (rest f))) 0 0) kept))
      files)))

; What a mixed reset says: the working directory's changes the index
; does not have, or nothing.
(def %unstaged
  (fn (_ wd gitdir)
    (def changes (first (rest (git-status-lists wd gitdir))))
    (if (null? changes) ""
      (Str8 append "Unstaged changes after reset:\n"
        (Str8 join "" (List map (fn (_ c) (Str8 append (first c) "\t" (rest c) "\n")) changes))))))

; HEAD moved to sha: its branch, or HEAD itself when detached; ORIG_HEAD
; left at where it was.
(def %move-head!
  (fn (_ gitdir sha)
    (def old (git-rev-parse gitdir "HEAD"))
    (unless (null? old) (File write-all (Str8 append gitdir "/ORIG_HEAD") (Str8 append old "\n")))
    (def branch (git-current-branch gitdir))
    (if (null? branch)
      (File write-all (Str8 append gitdir "/HEAD") (Str8 append sha "\n"))
      (git-write-ref! gitdir (Str8 append "refs/heads/" branch) sha))))

; The index and the working directory set to a commit's files: what is
; tracked now and the commit lacks taken out, the rest written.
(def %hard!
  (fn (_ wd gitdir sha)
    (def target (%files gitdir sha))
    (def tracked
      (List append (List map first (git-read-entries gitdir)) (List map first (%files gitdir "HEAD"))))
    (def wanted (List map first target))
    (List for-each (fn (_ p) (unless (%member? p wanted) (git-remove-file! wd p))) tracked)
    (List for-each (fn (_ t) (git-write-blob! wd gitdir (first t) (first (rest (rest t))) (first (rest t)))) target)
    (git-index-write! gitdir (List map (fn (_ t) (git-entry-of wd (first t) (first (rest (rest t))) (first (rest t)))) target))))

(def git-reset
  (fn (_ wd gitdir ops)
    ; a "--" ends the options; after it are paths alone
    (def cut ((fn (self l k) (match ((null? l) ()) ((str=? (first l) "--") k) (#t (self (rest l) (%add k 1))))) ops 0))
    (def before (if (null? cut) ops (List take cut ops)))
    (def after (if (null? cut) () (List drop (%add cut 1) ops)))
    (def o (Opts parse git-reset-options before))
    (def operands (Opts operands o))
    (def quiet? (Opts on? o "-q"))
    (def mode (match ((Opts on? o "--hard") "hard") ((Opts on? o "--soft") "soft") (#t "mixed")))
    (match
      ((Opts help? git-reset-options ops) (list (lit out) (Opts usage git-reset-options) 0))
      ((not (null? (Opts unknown o)))
        (list (lit err) (Str8 append "error: unknown option `" (Str8 sub 2 (%sub (Str8 length (Opts unknown o)) 2) (Opts unknown o)) "'\n"
                          (Opts usage git-reset-options)) 129))
      ((null? gitdir) (%no-repo))
      (#t
        ; the commit and the paths: after a "--", the one operand before it
        ; is the commit; without one, the first operand is when it names
        ; a commit, and every operand after is a path in the working
        ; directory
        (let ((plan
                (match
                  ((not (null? cut))
                    (if (null? operands) (list "HEAD" after)
                      (if (null? (git-commit-of gitdir (first operands))) (list (lit bad-tree) (first operands))
                        (list (first operands) (List append (rest operands) after)))))
                  ((null? operands) (list "HEAD" ()))
                  ((not (null? (git-commit-of gitdir (first operands)))) (list (first operands) (rest operands)))
                  (#t (list "HEAD" operands)))))
          (let ((rev (first plan)) (paths (first (rest plan))))
            (match
              ((eq? rev (lit bad-tree)) (%fatal (Str8 append "Failed to resolve '" (first (rest plan)) "' as a valid tree.")))
              ; a word that is no commit must be a path that is there
              ((and (null? cut) (not (null? paths))
                    (List find (fn (_ p) (not (File exists? (Str8 append wd "/" p)))) paths))
                (%ambiguous (List find (fn (_ p) (not (File exists? (Str8 append wd "/" p)))) paths)))
              ((and (not (null? paths)) (str=? mode "hard")) (%fatal "Cannot do hard reset with paths."))
              ((and (not (null? paths)) (str=? mode "soft")) (%fatal "Cannot do soft reset with paths."))
              ((null? (git-commit-of gitdir rev)) (%ambiguous rev))
              ; paths: their entries set from the commit, HEAD where it is
              ((not (null? paths))
                (let ((old (git-read-entries gitdir)) (files (List filter (fn (_ f) (%under? (first f) paths)) (%files gitdir rev))))
                  (do (git-index-write! gitdir
                        (List append (List filter (fn (_ e) (not (%under? (first e) paths))) old) (%entries-for old files)))
                      (let ((said (if quiet? "" (%unstaged wd gitdir)))
                            (warned (if (Opts on? o "--mixed") "warning: --mixed with paths is deprecated; use 'git reset -- <paths>' instead.\n" "")))
                        (if (= (Str8 length warned) 0) (list (lit out) said 0) (list (lit err) warned 0 said))))))
              ((and (str=? mode "soft") (File exists? (Str8 append gitdir "/MERGE_HEAD")))
                (%fatal "Cannot do a soft reset in the middle of a merge."))
              (#t
                (let ((sha (git-commit-of gitdir rev)))
                  (match
                    ((str=? mode "soft") (do (%move-head! gitdir sha) (list (lit out) "" 0)))
                    ((str=? mode "hard")
                      (do (%hard! wd gitdir sha)
                          (%move-head! gitdir sha)
                          (git-merge-state-clear! gitdir)
                          (list (lit out) (if quiet? "" (Str8 append "HEAD is now at " (Str8 sub 0 7 sha) " " (%subject gitdir sha) "\n")) 0)))
                    (#t
                      (do (git-index-write! gitdir (%entries-for (git-read-entries gitdir) (%files gitdir sha)))
                          (%move-head! gitdir sha)
                          (git-merge-state-clear! gitdir)
                          (list (lit out) (if quiet? "" (%unstaged wd gitdir)) 0))))))))))))))

(provide git/reset git-reset git-reset-options)
