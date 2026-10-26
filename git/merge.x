; # x-git -- git on x-lang
;
; ## git/merge.x -- merge and pull
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; merge [--ff-only] [<commit>] brings the current branch up to a commit.
; One that has the branch in its history is a fast-forward: the working
; directory and index move to its tree, the branch to it, ORIG_HEAD to
; where it was, and the report is git's -- "Updating A..B",
; "Fast-forward", the diffstat with a line a file created or deleted.  A
; commit already in the branch's history is "Already up to date."; with
; no commit named, the branch's upstream is merged.
;
; Histories that have diverged are merged from their merge base
; (git/threeway): with no conflict, into a merge commit of two parents,
; "Merge made by the 'ort' strategy." and the diffstat; with conflicts,
; into the working directory and index -- the files marked, the stages
; 1, 2 and 3 of each path in conflict, MERGE_HEAD and MERGE_MSG left for
; commit to conclude it -- "Automatic merge failed".  --ff-only refuses
; them instead; merge --abort puts the working directory and index back
; to HEAD.
;
; pull [--ff-only | --no-rebase] [<remote> [<branch>]] fetches, then
; merges what FETCH_HEAD marks for merging -- the upstream, or the branch
; named -- the same way; diverged histories are merged when --no-rebase
; or pull.rebase=false says to, and refused in pull's words otherwise.
;
; A change of the working directory's own in a file the merge would
; write stops it, in git's words.

(module git/merge)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/objects git-object-write!)
(import git/commands git-fatal git-no-repo)
(import git/refs git-rev-parse git-tree-of git-ref-read)
(import git/index git-status-lists)
(import git/stage git-read-entries git-index-write! git-write-tree! git-commit-write! git-merge-state-clear!)
(import git/config git-config-value)
(import git/checkout git-checkout-tree! git-write-blob! git-remove-file! git-entry-of)
(import git/diff git-tree-diffstat)
(import git/remote git-fetch git-ancestor? git-peel git-write-ref! git-current-branch)
(import git/threeway git-merge-base-files git-merge-trees git-tree-flat)

(def %sub (prim-ref 'int '-))

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
    (def remote (git-config-value gitdir (Str8 append "branch." branch ".remote")))
    (def merge (git-config-value gitdir (Str8 append "branch." branch ".merge")))
    (if (or (null? remote) (null? merge)) ()
      (Str8 append "refs/remotes/" remote "/"
        (if (Str8 starts? "refs/heads/" merge) (Str8 sub 11 (%sub (Str8 length merge) 11) merge) merge)))))

; HEAD moved to commit `to` from `from`: (ERR OUT STATUS).  diverged
; answers the same when `to` is not ahead of HEAD: the refusal, or the
; merge.
(def %fast-forward!
  (fn (_ wd gitdir from to diverged)
    (def updating (Str8 append "Updating " (%abbrev from) ".." (%abbrev to) "\n"))
    (match
      ((git-ancestor? gitdir to from) (list "" "Already up to date.\n" 0))
      ((not (git-ancestor? gitdir from to)) (diverged))
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

; --- the merge commit ---

(def %refusal (fn (_ text) (fn (_) (list text "" 128))))

(def %str-byte-len (prim-ref (lit str) (lit byte-len)))
(def %mode-number (fn (_ text) (%str->number text 8)))

; A merge's message, as git words it for what is merged: a local branch,
; a remote-tracking branch, a tag or a commit; " into BRANCH" after it
; unless the branch is main or master.
(def %merge-message
  (fn (_ gitdir name branch)
    (Str8 append
      (match
        ((not (null? (git-ref-read gitdir (Str8 append "refs/heads/" name)))) (Str8 append "Merge branch '" name "'"))
        ((not (null? (git-ref-read gitdir (Str8 append "refs/remotes/" name)))) (Str8 append "Merge remote-tracking branch '" name "'"))
        ((not (null? (git-ref-read gitdir (Str8 append "refs/tags/" name)))) (Str8 append "Merge tag '" name "'"))
        (#t (Str8 append "Merge commit '" name "'")))
      (%into branch))))

(def %into
  (fn (_ branch) (if (or (null? branch) (str=? branch "main") (str=? branch "master")) "" (Str8 append " into " branch))))

; The paths with changes of their own, staged or not.
(def %dirty
  (fn (_ wd gitdir)
    (def lists (git-status-lists wd gitdir))
    (List append (List map rest (first lists)) (List map rest (first (rest lists))))))

; HEAD and commit `theirs` merged from their merge base -- or, when they
; have several, from those merged into one -- into a merge commit, or
; into the working directory and index with the conflicts marked and
; MERGE_HEAD left to conclude it: (ERR OUT STATUS).  name2 is what the
; conflict markers call theirs.
(def %merge-three!
  (fn (_ wd gitdir head theirs message name2)
    (def write-blob (fn (_ text) (git-object-write! gitdir "blob" text 0 (%str-byte-len text))))
    (def base-files (git-merge-base-files gitdir head theirs write-blob))
    (if (eq? base-files #f) (list "fatal: refusing to merge unrelated histories\n" "" 128)
      (let ((placed (git-merge-place! wd gitdir head base-files (git-tree-flat gitdir (git-tree-of gitdir theirs) "") name2)))
        (if (eq? (first placed) (lit blocked))
          (list (Str8 append "error: Your local changes to the following files would be overwritten by merge:\n"
                  (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) (rest placed)))
                  "Please commit your changes or stash them before you merge.\nAborting\nMerge with strategy ort failed.\n")
                "" 2)
          (%conclude-merge! gitdir head theirs placed message))))))

; HEAD's files and theirs merged from base's into the working directory
; and index, as merge and revert merge them: (placed RESULTS MESSAGES
; CONFLICTED STOPPED?), the conflicts marked in the files and staged,
; ORIG_HEAD left at head; or (blocked PATH ...) and nothing touched, when
; the working directory's own changes are in the way.  name2 is what the
; conflict markers call theirs.
(def git-merge-place!
  (fn (_ wd gitdir head base-files theirs-files name2)
    (def write-blob (fn (_ text) (git-object-write! gitdir "blob" text 0 (%str-byte-len text))))
    (def ours-files (git-tree-flat gitdir (git-tree-of gitdir head) ""))
    (def r (git-merge-trees base-files ours-files theirs-files "HEAD" name2 (%dir-renames-mode gitdir) 7 gitdir write-blob))
    (def results (first r))
    (def ours-of (fn (_ path) (List find (fn (_ f) (str=? (first f) path)) ours-files)))
    ; the paths the merge changes from what HEAD has
    (def touched
      (List map first
        (List filter
          (fn (_ x)
            (let ((o (ours-of (first x))))
              (match
                ((eq? (first (rest x)) (lit gone)) (not (null? o)))
                ((eq? (first (rest x)) (lit clean))
                  (or (null? o) (not (str=? (first (rest (rest (rest x)))) (first (rest (rest o)))))
                      (not (str=? (first (rest (rest x))) (first (rest o))))))
                (#t #t))))
          results)))
    (def blocked (List filter (fn (_ p) (List any? (fn (_ t) (str=? t p)) touched)) (%dirty wd gitdir)))
    (if (not (null? blocked)) (pair (lit blocked) (List sort (fn (_ a b) (Str8 <? a b)) blocked))
      (do (%place! wd gitdir head results touched)
          (list (lit placed) results (first (rest r))
                (List map first (List filter (fn (_ x) (eq? (first (rest x)) (lit conflict))) results))
                (first (rest (rest r))))))))

; merge.directoryRenames: "conflict" when unset, as git takes it, and
; git's other spellings of true and false read as those.
(def %dir-renames-mode
  (fn (_ gitdir)
    (def v (git-config-value gitdir "merge.directoryRenames"))
    (match
      ((null? v) "conflict")
      ((List any? (fn (_ w) (Str8 ci=? v w)) (list "true" "yes" "on" "1")) "true")
      ((List any? (fn (_ w) (Str8 ci=? v w)) (list "false" "no" "off" "0")) "false")
      (#t "conflict"))))

; The merge's results put in place: each touched path written or
; removed, the index set, ORIG_HEAD left at head.
(def %place!
  (fn (_ wd gitdir head results touched)
    (def touched? (fn (_ p) (List any? (fn (_ t) (str=? t p)) touched)))
    (def kept (List filter (fn (_ e) (not (touched? (first e)))) (git-read-entries gitdir)))
    (def fresh
      (List flat-map
        (fn (_ x)
          (def path (first x))
          (match
            ((not (touched? path)) ())
            ((eq? (first (rest x)) (lit gone)) (do (git-remove-file! wd path) ()))
            ((eq? (first (rest x)) (lit clean))
              (do (git-write-blob! wd gitdir path (first (rest (rest (rest x)))) (first (rest (rest x))))
                  (list (git-entry-of wd path (first (rest (rest (rest x)))) (first (rest (rest x)))))))
            (#t
              (let ((stages (first (rest (rest x)))) (work (first (rest (rest (rest x))))))
                (do (unless (null? work)
                      (let ((mode (first (rest (or (List find (fn (_ s) (= (first s) 2)) stages) (List find (fn (_ s) (= (first s) 3)) stages))))))
                        (let ((sha (git-object-write! gitdir "blob" work 0 (%str-byte-len work))))
                          (git-write-blob! wd gitdir path sha mode))))
                    (List map (fn (_ s) (list path (%mode-number (first (rest s))) (first (rest (rest s))) 0 0 (first s))) stages))))))
        results))
    (git-index-write! gitdir (List append kept fresh))
    (File write-all (Str8 append gitdir "/ORIG_HEAD") (Str8 append head "\n"))))

; A merge placed: a merge commit made, or the conflicts left with
; MERGE_HEAD -- left too when the merge stopped with none.
(def %conclude-merge!
  (fn (_ gitdir head theirs placed message)
    (def results (first (rest placed)))
    (def conflicted (first (rest (rest (rest placed)))))
    (def stopped? (first (rest (rest (rest (rest placed))))))
    (def said (Str8 join "" (first (rest (rest placed)))))
    (if (or stopped? (not (null? conflicted)))
      (do (File write-all (Str8 append gitdir "/MERGE_HEAD") (Str8 append theirs "\n"))
          (File write-all (Str8 append gitdir "/MERGE_MODE") "")
          (File write-all (Str8 append gitdir "/MERGE_MSG")
            (Str8 append message "\n\n# Conflicts:\n" (Str8 join "" (List map (fn (_ p) (Str8 append "#\t" p "\n")) conflicted))))
          (list "" (Str8 append said "Automatic merge failed; fix conflicts and then commit the result.\n") 1))
      (let ((tree (git-write-tree! gitdir
                    (List map (fn (_ x) (list (first x) (%mode-number (first (rest (rest x)))) (first (rest (rest (rest x))))))
                      (List filter (fn (_ x) (eq? (first (rest x)) (lit clean))) results)))))
        (let ((sha (git-commit-write! gitdir tree (list head theirs) message)))
          (if (null? sha) (list "fatal: unable to auto-detect email address\n" said 128)
            (let ((branch (git-current-branch gitdir)))
              (do (if (null? branch)
                    (File write-all (Str8 append gitdir "/HEAD") (Str8 append sha "\n"))
                    (git-write-ref! gitdir (Str8 append "refs/heads/" branch) sha))
                  (list "" (Str8 append said "Merge made by the 'ort' strategy.\n"
                             (git-tree-diffstat gitdir (git-tree-of gitdir head) tree))
                        0)))))))))

; merge --abort: the working directory and index set back to HEAD, the
; merge's files gone.
(def %abort!
  (fn (_ wd gitdir)
    (if (not (File exists? (Str8 append gitdir "/MERGE_HEAD")))
      (list "fatal: There is no merge to abort (MERGE_HEAD missing).\n" "" 128)
      (do (git-restore-head! wd gitdir)
          (git-merge-state-clear! gitdir)
          (list "" "" 0)))))

; The working directory and index set back to HEAD's files: what the
; index holds and HEAD lacks taken out, HEAD's written.  For merge's and
; revert's --abort.
(def git-restore-head!
  (fn (_ wd gitdir)
    (def files (git-tree-flat gitdir (git-tree-of gitdir "HEAD") ""))
    (List for-each
      (fn (_ e) (unless (List any? (fn (_ f) (str=? (first f) (first e))) files) (git-remove-file! wd (first e))))
      (git-read-entries gitdir))
    (git-index-write! gitdir
      (List map
        (fn (_ f) (do (git-write-blob! wd gitdir (first f) (first (rest (rest f))) (first (rest f)))
                      (git-entry-of wd (first f) (first (rest (rest f))) (first (rest f)))))
        files))))

; (ERR OUT STATUS) as a command's answer: the error stream's text, then
; standard output's after it.
(def %answer
  (fn (_ r)
    (if (= (Str8 length (first r)) 0) (list (lit out) (first (rest r)) (first (rest (rest r))))
      (list (lit err) (first r) (first (rest (rest r))) (first (rest r))))))

; --- merge ---

(def git-merge-options
  (Opts declare "git merge" "[--ff-only] [<commit>] | --abort" ()
    (list (Opts flag "--ff-only" "Refuse to do anything but fast-forward")
          (Opts flag "--abort" "Abandon the merge in progress: the working directory and index back to HEAD"))))

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
      ((null? gitdir) (git-no-repo))
      ((Opts on? o "--abort") (%answer (%abort! wd gitdir)))
      ((File exists? (Str8 append gitdir "/MERGE_HEAD"))
        (git-fatal "You have not concluded your merge (MERGE_HEAD exists).\nPlease, commit your changes before you merge."))
      ((null? target-name) (git-fatal "No remote for the current branch."))
      ((null? target) (list (lit err) (Str8 append "merge: " target-name " - not something we can merge\n") 1))
      (#t
        (let ((head (git-rev-parse gitdir "HEAD")) (theirs (git-peel gitdir target)))
          (%answer (%fast-forward! wd gitdir head theirs
                     (if (Opts on? o "--ff-only")
                       (%refusal (Str8 append %diverging "fatal: Not possible to fast-forward, aborting.\n"))
                       (fn (_) (%merge-three! wd gitdir head theirs (%merge-message gitdir target-name branch) target-name))))))))))

; --- pull ---

(def git-pull-options
  (Opts declare "git pull" "[--ff-only | --no-rebase] [<repository> [<branch>]]" ()
    (list (Opts flag "--ff-only" "Refuse to do anything but fast-forward")
          (Opts flag "--no-rebase" "Merge diverged histories with a merge commit"))))

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
    (if (null? hit) () (pair (Str8 sub 0 40 hit) hit))))

; What a pull's merge is called: "Merge branch 'B' of URL" from its
; FETCH_HEAD line.
(def %pull-message
  (fn (_ line branch)
    (def i (Str8 index-of "branch '" line))
    (Str8 append "Merge " (if (null? i) line (Str8 sub i (%sub (Str8 length line) i) line)) (%into branch))))

(def git-pull
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-pull-options ops))
    (def operands (Opts operands o))
    (def branch (if (null? gitdir) () (git-current-branch gitdir)))
    (def named (if (or (null? operands) (null? (rest operands))) () (first (rest operands))))
    (match
      ((Opts help? git-pull-options ops) (list (lit out) (Opts usage git-pull-options) 0))
      ((null? gitdir) (git-no-repo))
      ((and (null? named) (or (null? branch) (null? (%upstream gitdir branch)))) (%no-tracking (or branch "<branch>")))
      (#t
        (let ((f (git-fetch wd gitdir (if (null? operands) () (list (first operands))))))
          (if (not (= (first (rest (rest f))) 0)) f
            (let ((fetched (%fetched-for-merge gitdir named)))
              (if (null? fetched) (git-fatal "No remote for the current branch.")
                (let ((head (git-rev-parse gitdir "HEAD")) (target (first fetched)))
                  (let ((r (%fast-forward! wd gitdir head target
                           (match
                             ((Opts on? o "--ff-only")
                               (%refusal (Str8 append %diverging "fatal: Not possible to fast-forward, aborting.\n")))
                             ; told to merge, here or in the config
                             ((or (Opts on? o "--no-rebase") (str=? (or (git-config-value gitdir "pull.rebase") "") "false"))
                               (fn (_) (%merge-three! wd gitdir head target (%pull-message (rest fetched) branch) target)))
                             (#t (%refusal (Str8 append %pull-diverging "fatal: Need to specify how to reconcile divergent branches.\n")))))))
                  (let ((err (Str8 append (first (rest f)) (first r))))
                    (if (= (Str8 length err) 0) (list (lit out) (first (rest r)) (first (rest (rest r))))
                      (list (lit err) err (first (rest (rest r))) (first (rest r)))))))))))))))

(provide git/merge git-merge git-merge-options git-pull git-pull-options git-merge-place! git-restore-head!)
