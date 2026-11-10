; # x-git -- git on x-lang
;
; ## git/revert.x -- revert
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; git revert: commits' changes undone, as git undoes them -- one commit,
; several in the order given, or a range newest first -- each committed
; with git's message: `Revert "SUBJECT"`, or `Reapply "X"` for a revert
; of `Revert "X"`, then "This reverts commit SHA.".  The message is edited
; first unless --no-edit says not to, in the editor git would run; -n
; leaves the changes staged, uncommitted.  A conflict stops it for
; --continue (or a commit) to go on, --skip to leave the commit out,
; --abort to give up and --quit to forget.  git/sequencer does the
; reverting.

(module git/revert)

(import x/sys/opts Opts)
(import git/commands git-no-repo)
(import git/sequencer git-sequence! git-sequence-continue! git-sequence-skip! git-sequence-abort! git-sequence-quit!)

(def git-revert-options
  (Opts declare "git revert" "[--no-edit] [-n] <commit>... | (--continue | --skip | --abort | --quit)" ()
    (list
      (Opts flag "--no-edit" "Commit with git's message, unedited")
      (Opts flag "-e" "--edit" "Edit the message first (the default)")
      (Opts flag "-n" "--no-commit" "Leave the changes staged, uncommitted")
      (Opts flag "--continue" "Commit once the conflicts are resolved, and go on")
      (Opts flag "--skip" "Leave the commit out, the working directory and index set back, and go on")
      (Opts flag "--abort" "Give up, back where it began")
      (Opts flag "--quit" "Forget the revert, its changes and conflicts left"))))

; The options as git's sequencer keeps them, in its order.
(def %opts
  (fn (_ o)
    (List flat-map (fn (_ x) x)
      (list (if (Opts on? o "-n") (list (pair "no-commit" "true")) ())
            (match ((Opts on? o "--no-edit") (list (pair "edit" "false"))) ((Opts on? o "-e") (list (pair "edit" "true"))) (#t ()))))))

(def git-revert
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-revert-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-revert-options ops) (list (lit out) (Opts usage git-revert-options) 0))
      ((not (null? (Opts unknown o)))
        (list (lit err) (Str8 append "error: unknown option `" (Opts unknown o) "'\n" (Opts usage git-revert-options)) 129))
      ((null? gitdir) (git-no-repo))
      ((Opts on? o "--abort") (git-sequence-abort! wd gitdir "revert"))
      ((Opts on? o "--skip") (git-sequence-skip! wd gitdir "revert"))
      ((Opts on? o "--quit") (git-sequence-quit! gitdir))
      ((Opts on? o "--continue") (git-sequence-continue! wd gitdir "revert"))
      ((null? operands) (list (lit err) (Opts usage git-revert-options) 129))
      (#t (git-sequence! wd gitdir "revert" operands (%opts o))))))

(provide git/revert git-revert git-revert-options)
