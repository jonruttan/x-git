; # x-git -- git on x-lang
;
; ## git/revert.x -- revert
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; git revert: a commit's change undone, as git undoes it -- HEAD and the
; commit's parent merged three ways from the commit itself (git/merge's
; merge, the markers calling theirs "parent of ABBREV (SUBJECT)") -- and
; committed with git's message: `Revert "SUBJECT"`, or `Reapply "X"` for
; a revert of `Revert "X"`, then "This reverts commit SHA.".  The message
; is edited first unless --no-edit says not to, in the editor git would
; run; -n leaves the change staged, uncommitted.  A conflict stops it
; with REVERT_HEAD and MERGE_MSG left, for --continue (or a commit) to
; conclude and --abort to give up.  One commit at a time; a merge, which
; needs -m to say which parent's side to keep, is refused.

(module git/revert)

(import x/sys/opts Opts)
(import x/sys/file File)
(import x/sys/proc Proc)
(import x/sys/posix Sys)
(import git/objects git-subject)
(import git/commands git-no-repo)
(import git/refs git-commit-of git-tree-of git-headers)
(import git/index git-status-lists git-tree-files)
(import git/stage git-read-entries git-write-tree! git-commit-write! git-merge-state-clear! git-message-strip git-commit)
(import git/merge git-merge-place! git-restore-head!)
(import git/remote git-write-ref! git-current-branch)
(import git/threeway git-tree-flat)
(import git/diff git-commit-summary)
(import git/history git-ident-date)
(import git/config git-config-value)

(def %sub (prim-ref 'int '-))

; A refusal as the sequencer words one: the error, then "revert failed".
(def %failed
  (fn (_ text) (list (lit err) (Str8 append text "fatal: revert failed\n") 128)))

(def git-revert-options
  (Opts declare "git revert" "[--no-edit] [-n] <commit> | (--continue | --abort)" ()
    (list
      (Opts flag "--no-edit" "Commit with git's message, unedited")
      (Opts flag "-e" "--edit" "Edit the message first (the default)")
      (Opts flag "-n" "--no-commit" "Leave the change staged, uncommitted")
      (Opts flag "--continue" "Commit once the conflicts are resolved")
      (Opts flag "--abort" "Give up, the working directory and index set back"))))

; git's message for a revert: a revert of a revert reapplies.
(def %message
  (fn (_ subject sha)
    (Str8 append
      (if (and (Str8 starts? "Revert \"" subject) (Str8 ends? "\"" subject))
        (Str8 append "Reapply " (Str8 sub 7 (%sub (Str8 length subject) 7) subject))
        (Str8 append "Revert \"" subject "\""))
      "\n\nThis reverts commit " sha ".\n")))

(def %env (fn (_ name) (let ((v (Sys getenv name))) (if (or (null? v) (= (Str8 length v) 0)) () v))))

; The editor git runs: GIT_EDITOR, core.editor, VISUAL, EDITOR, then vi.
(def %editor
  (fn (_ gitdir)
    (or (%env "GIT_EDITOR") (git-config-value gitdir "core.editor") (%env "VISUAL") (%env "EDITOR") "vi")))

; The message edited, as git edits one: written to COMMIT_EDITMSG with
; its comment lines, the editor run on it, the comments taken out.
; Answers the message, "" when it was emptied, or () when the editor
; failed.
(def %edit
  (fn (_ gitdir msg branch)
    (def path (Str8 append gitdir "/COMMIT_EDITMSG"))
    (File write-all path
      (Str8 append msg "\n"
        "# Please enter the commit message for your changes. Lines starting\n"
        "# with '#' will be ignored, and an empty message aborts the commit.\n"
        "#\n"
        (if (null? branch) "# HEAD detached\n" (Str8 append "# On branch " branch "\n"))))
    (def status (Proc run! (list "/bin/sh" "-c" (Str8 append (%editor gitdir) " \"$@\"") (%editor gitdir) path)))
    (if (not (= status 0)) () (git-message-strip (File read-all path)))))

(def %hints
  (Str8 join ""
    (List map (fn (_ l) (Str8 append "hint: " l "\n"))
      (list "After resolving the conflicts, mark them with"
            "\"git add/rm <pathspec>\", then run"
            "\"git revert --continue\"."
            "You can instead skip this commit with \"git revert --skip\"."
            "To abort and get back to the state before \"git revert\","
            "run \"git revert --abort\"."
            "Disable this message with \"git config set advice.mergeConflict false\""))))

; The revert committed: the branch moved, git's report of it after what
; the merge said.
(def %commit!
  (fn (_ gitdir head message said)
    (def tree (git-write-tree! gitdir (git-read-entries gitdir)))
    (def sha (git-commit-write! gitdir tree (list head) message))
    (def branch (git-current-branch gitdir))
    (if (null? branch)
      (File write-all (Str8 append gitdir "/HEAD") (Str8 append sha "\n"))
      (git-write-ref! gitdir (Str8 append "refs/heads/" branch) sha))
    (def author (rest (List find (fn (_ kv) (str=? (first kv) "author")) (git-headers gitdir sha))))
    (list (lit out)
      (Str8 append said "[" (if (null? branch) "detached HEAD" branch) " " (Str8 sub 0 7 sha) "] " (first (Str8 split "\n" message)) "\n"
        " Date: " (git-ident-date author) "\n"
        (git-commit-summary gitdir (git-tree-files gitdir (git-tree-of gitdir head)) (git-tree-files gitdir tree)))
      0)))

(def %in-progress? (fn (_ gitdir) (File exists? (Str8 append gitdir "/REVERT_HEAD"))))

(def git-revert
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-revert-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-revert-options ops) (list (lit out) (Opts usage git-revert-options) 0))
      ((not (null? (Opts unknown o)))
        (list (lit err) (Str8 append "error: unknown option `" (Opts unknown o) "'\n" (Opts usage git-revert-options)) 129))
      ((null? gitdir) (git-no-repo))
      ; giving up: the working directory and index back at HEAD
      ((Opts on? o "--abort")
        (if (not (%in-progress? gitdir)) (%failed "error: no cherry-pick or revert in progress\n")
          (do (git-restore-head! wd gitdir) (git-merge-state-clear! gitdir) (list (lit out) "" 0))))
      ; going on: the revert committed as commit concludes it
      ((Opts on? o "--continue")
        (if (not (%in-progress? gitdir)) (%failed "error: no cherry-pick or revert in progress\n")
          (git-commit wd gitdir ())))
      ((null? operands) (list (lit err) (Opts usage git-revert-options) 129))
      ((not (null? (first (rest (rest (rest (git-status-lists wd gitdir)))))))
        (%failed (Str8 append "error: Reverting is not possible because you have unmerged files.\n"
                   "hint: Fix them up in the work tree, and then use 'git add/rm <file>'\n"
                   "hint: as appropriate to mark resolution and make a commit.\n")))
      ((%in-progress? gitdir)
        (%failed "error: revert is already in progress\nhint: try \"git revert (--continue | --abort | --quit)\"\n"))
      (#t
        (let ((sha (git-commit-of gitdir (first operands))))
          (if (null? sha) (list (lit err) (Str8 append "fatal: bad revision '" (first operands) "'\n") 128)
            (let ((parents (List map rest (List filter (fn (_ kv) (str=? (first kv) "parent")) (git-headers gitdir sha))))
                  (head (git-commit-of gitdir "HEAD")))
              (match
                ((not (null? (first (git-status-lists wd gitdir))))
                  (%failed "error: your local changes would be overwritten by revert.\nhint: commit your changes or stash them to proceed.\n"))
                ((< 1 (List length parents))
                  (%failed (Str8 append "error: commit " sha " is a merge but no -m option was given.\n")))
                (#t
                  (let ((subject (git-subject gitdir sha)))
                    (let ((placed (git-merge-place! wd gitdir head
                                    (git-tree-flat gitdir (git-tree-of gitdir sha) "")
                                    (if (null? parents) () (git-tree-flat gitdir (git-tree-of gitdir (first parents)) ""))
                                    (Str8 append "parent of " (Str8 sub 0 7 sha) " (" subject ")")))
                          (message (%message subject sha)))
                      (match
                        ((eq? (first placed) (lit blocked))
                          (%failed (Str8 append "error: Your local changes to the following files would be overwritten by merge:\n"
                                     (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) (rest placed)))
                                     "Please commit your changes or stash them before you merge.\nAborting\n")))
                        ; a conflict: the state left for --continue or --abort
                        ((or (not (null? (first (rest (rest (rest placed)))))) (first (rest (rest (rest (rest placed))))))
                          (do (File write-all (Str8 append gitdir "/REVERT_HEAD") (Str8 append sha "\n"))
                              (File write-all (Str8 append gitdir "/MERGE_MSG")
                                (Str8 append message "\n# Conflicts:\n"
                                  (Str8 join "" (List map (fn (_ p) (Str8 append "#\t" p "\n")) (first (rest (rest (rest placed))))))))
                              (list (lit err)
                                (Str8 append "error: could not revert " (Str8 sub 0 7 sha) "... " subject "\n" %hints)
                                1 (Str8 join "" (first (rest (rest placed)))))))
                        ; -n: staged, and the revert left in progress for a commit to conclude
                        ((Opts on? o "-n")
                          (do (File write-all (Str8 append gitdir "/REVERT_HEAD") (Str8 append sha "\n"))
                              (File write-all (Str8 append gitdir "/MERGE_MSG") message)
                              (list (lit out) (Str8 join "" (first (rest (rest placed)))) 0)))
                        ((Opts on? o "--no-edit") (%commit! gitdir head message (Str8 join "" (first (rest (rest placed))))))
                        (#t
                          (let ((edited (%edit gitdir message (git-current-branch gitdir))))
                            (match
                              ((null? edited) (%failed (Str8 append "error: there was a problem with the editor '" (%editor gitdir) "'\n")))
                              ((= (Str8 length edited) 0)
                                (list (lit err) "Aborting commit due to empty commit message.\n" 1))
                              (#t (%commit! gitdir head edited (Str8 join "" (first (rest (rest placed)))))))))))))))))))))

(provide git/revert git-revert git-revert-options)
