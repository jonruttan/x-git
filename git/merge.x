; # x-git -- git on x-lang
;
; ## git/merge.x -- merge and pull, by fast-forward
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; merge [--ff-only] [<commit>] brings the current branch up to a commit
; that has it in its history: the working directory and index move to the
; commit's tree, the branch to the commit, ORIG_HEAD to where it was, and
; the report is git's -- "Updating A..B", "Fast-forward", the diffstat with
; a line a file created or deleted.  A commit already in the branch's
; history is "Already up to date."; with no commit named, the branch's
; upstream is merged.  A merge that needs a merge commit is refused as
; --ff-only refuses it: x-git makes no merge commits yet.
;
; pull [--ff-only] [<remote> [<branch>]] fetches, then merges what
; FETCH_HEAD marks for merging -- the upstream, or the branch named -- the
; same way; diverged histories are refused in pull's words.
;
; A change of the working directory's own in a file the move would write
; stops it, as checkout stops: "Updating" is said, then the files, then
; "Aborting".

(module git/merge)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/refs git-rev-parse git-tree-of)
(import git/stage git-config-get)
(import git/checkout git-checkout-tree!)
(import git/diff git-tree-diffstat)
(import git/remote git-fetch git-ancestor? git-peel git-write-ref! git-current-branch)

(def %sub (prim-ref 'int '-))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))
(def %no-repo (fn (_) (%fatal "not a git repository (or any of the parent directories): .git")))
(def %abbrev (fn (_ sha) (Str8 sub 0 7 sha)))
(def %hints (fn (_ lines) (Str8 join "" (List map (fn (_ l) (Str8 append "hint:" (if (= (Str8 length l) 0) "" " ") l "\n")) lines))))

(def %diverging
  (%hints (list "Diverging branches can't be fast-forwarded, you need to either:" ""
                "\tgit merge --no-ff" "" "or:" "" "\tgit rebase" ""
                "Disable this message with \"git config set advice.diverging false\"")))

(def %pull-diverging
  (%hints (list "You have divergent branches and need to specify how to reconcile them."
                "You can do so by running one of the following commands sometime before"
                "your next pull:" ""
                "  git config pull.rebase false  # merge"
                "  git config pull.rebase true   # rebase"
                "  git config pull.ff only       # fast-forward only" ""
                "You can replace \"git config\" with \"git config --global\" to set a default"
                "preference for all repositories. You can also pass --rebase, --no-rebase,"
                "or --ff-only on the command line to override the configured default per"
                "invocation.")))

; The branch's upstream as this repository tracks it, refs/remotes/R/B,
; or () when it has none.
(def %upstream
  (fn (_ gitdir branch)
    (def section (Str8 append "branch \"" branch "\""))
    (def remote (git-config-get gitdir section "remote"))
    (def merge (git-config-get gitdir section "merge"))
    (if (or (null? remote) (null? merge)) ()
      (Str8 append "refs/remotes/" remote "/"
        (if (Str8 starts? "refs/heads/" merge) (Str8 sub 11 (%sub (Str8 length merge) 11) merge) merge)))))

; HEAD moved to commit `to` from `from`: (ERR OUT STATUS).  diverged is
; what to say when `to` is not ahead of HEAD.
(def %fast-forward!
  (fn (_ wd gitdir from to diverged)
    (def updating (Str8 append "Updating " (%abbrev from) ".." (%abbrev to) "\n"))
    (match
      ((git-ancestor? gitdir to from) (list "" "Already up to date.\n" 0))
      ((not (git-ancestor? gitdir from to)) (list diverged "" 128))
      (#t
        (let ((blocked (git-checkout-tree! wd gitdir to)))
          (if (not (null? blocked))
            (list (Str8 append "error: Your local changes to the following files would be overwritten by merge:\n"
                    (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) blocked))
                    "Please commit your changes or stash them before you merge.\nAborting\n")
                  updating 1)
            (let ((branch (git-current-branch gitdir)))
              (do (File write-all (Str8 append gitdir "/ORIG_HEAD") (Str8 append from "\n"))
                  (if (null? branch)
                    (File write-all (Str8 append gitdir "/HEAD") (Str8 append to "\n"))
                    (git-write-ref! gitdir (Str8 append "refs/heads/" branch) to))
                  (list "" (Str8 append updating "Fast-forward\n"
                             (git-tree-diffstat gitdir (git-tree-of gitdir from) (git-tree-of gitdir to)))
                        0)))))))))

; (ERR OUT STATUS) as a command's answer: the error stream's text, then
; standard output's after it.
(def %answer
  (fn (_ r)
    (if (= (Str8 length (first r)) 0) (list (lit out) (first (rest r)) (first (rest (rest r))))
      (list (lit err) (first r) (first (rest (rest r))) (first (rest r))))))

; --- merge ---

(def git-merge-options
  (Opts declare "git merge" "[--ff-only] [<commit>]" ()
    (list (Opts flag "--ff-only" "Refuse to do anything but fast-forward"))))

(def git-merge
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-merge-options ops))
    (def operands (Opts operands o))
    (def branch (if (null? gitdir) () (git-current-branch gitdir)))
    (def target-name
      (if (null? operands)
        (if (or (null? gitdir) (null? branch)) () (%upstream gitdir branch))
        (first operands)))
    (def target (if (or (null? gitdir) (null? target-name)) () (git-rev-parse gitdir target-name)))
    (match
      ((Opts help? git-merge-options ops) (list (lit out) (Opts usage git-merge-options) 0))
      ((null? gitdir) (%no-repo))
      ((null? target-name) (%fatal "No remote for the current branch."))
      ((null? target) (list (lit err) (Str8 append "merge: " target-name " - not something we can merge\n") 1))
      (#t (%answer (%fast-forward! wd gitdir (git-rev-parse gitdir "HEAD") (git-peel gitdir target)
                     (Str8 append %diverging "fatal: Not possible to fast-forward, aborting.\n")))))))

; --- pull ---

(def git-pull-options
  (Opts declare "git pull" "[--ff-only] [<repository> [<branch>]]" ()
    (list (Opts flag "--ff-only" "Refuse to do anything but fast-forward"))))

(def %no-tracking
  (fn (_ branch)
    (list (lit err)
      (Str8 append "There is no tracking information for the current branch.\n"
        "Please specify which branch you want to merge with.\n"
        "See git-pull(1) for details.\n\n"
        "    git pull <remote> <branch>\n\n"
        "If you wish to set tracking information for this branch you can do so with:\n\n"
        "    git branch --set-upstream-to=origin/<branch> " branch "\n\n")
      1)))

; What FETCH_HEAD marks for merging -- the line for branch when one is
; named -- as its commit, or ().
(def %fetched-for-merge
  (fn (_ gitdir branch)
    (def path (Str8 append gitdir "/FETCH_HEAD"))
    (def lines (if (File exists? path) (List filter (fn (_ l) (> (Str8 length l) 41)) (Str8 split "\n" (File read-all path))) ()))
    (def hit
      (List find
        (fn (_ l)
          (if (null? branch)
            (Str8 starts? "\t" (Str8 sub 40 (%sub (Str8 length l) 40) l))
            (Str8 includes? (Str8 append "\tbranch '" branch "' of ") l)))
        lines))
    (if (null? hit) () (Str8 sub 0 40 hit))))

(def git-pull
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-pull-options ops))
    (def operands (Opts operands o))
    (def branch (if (null? gitdir) () (git-current-branch gitdir)))
    (def named (if (or (null? operands) (null? (rest operands))) () (first (rest operands))))
    (match
      ((Opts help? git-pull-options ops) (list (lit out) (Opts usage git-pull-options) 0))
      ((null? gitdir) (%no-repo))
      ((and (null? named) (or (null? branch) (null? (%upstream gitdir branch)))) (%no-tracking (or branch "<branch>")))
      (#t
        (let ((f (git-fetch wd gitdir (if (null? operands) () (list (first operands))))))
          (if (not (= (first (rest (rest f))) 0)) f
            (let ((target (%fetched-for-merge gitdir named)))
              (if (null? target) (%fatal "No remote for the current branch.")
                (let ((r (%fast-forward! wd gitdir (git-rev-parse gitdir "HEAD") target
                           (if (Opts on? o "--ff-only")
                             (Str8 append %diverging "fatal: Not possible to fast-forward, aborting.\n")
                             (Str8 append %pull-diverging "fatal: Need to specify how to reconcile divergent branches.\n")))))
                  (let ((err (Str8 append (first (rest f)) (first r))))
                    (if (= (Str8 length err) 0) (list (lit out) (first (rest r)) (first (rest (rest r))))
                      (list (lit err) err (first (rest (rest r))) (first (rest r))))))))))))))

(provide git/merge git-merge git-merge-options git-pull git-pull-options)
