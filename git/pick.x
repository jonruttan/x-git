; # x-git -- git on x-lang
;
; ## git/pick.x -- cherry-pick
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; git cherry-pick: commits' changes made again on HEAD, as git makes them,
; each committed with the commit's own message and author, the committer
; the one git finds -- one commit, several in the order given, or a range
; oldest first.  -x notes the commit picked, -e edits the message first,
; -n leaves the changes staged, uncommitted, --ff moves HEAD to a commit
; whose parent it is, and --allow-empty keeps a commit that changed
; nothing itself.  A conflict, or a pick that changes nothing, stops it
; for --continue (or a commit) to go on, --skip to leave the commit out,
; --abort to give up and --quit to forget.  git/sequencer does the
; picking.

(module git/pick)

(import x/sys/opts Opts)
(import git/commands git-no-repo)
(import git/sequencer git-sequence! git-sequence-continue! git-sequence-skip! git-sequence-abort! git-sequence-quit!)

(def git-cherry-pick-options
  (Opts declare "git cherry-pick" "[-e] [-n] [-x] [--ff] [--allow-empty] <commit>... | (--continue | --skip | --abort | --quit)" ()
    (list
      (Opts flag "-e" "--edit" "Edit the message first")
      (Opts flag "--no-edit" "Commit with the commit's message, unedited (the default)")
      (Opts flag "-n" "--no-commit" "Leave the changes staged, uncommitted")
      (Opts flag "-x" "Note the commit picked in the message")
      (Opts flag "--ff" "Move HEAD to the commit when HEAD is its parent")
      (Opts flag "--allow-empty" "Commit a commit that changed nothing itself")
      (Opts flag "--continue" "Commit once the conflicts are resolved, and go on")
      (Opts flag "--skip" "Leave the commit out, the working directory and index set back, and go on")
      (Opts flag "--abort" "Give up, back where it began")
      (Opts flag "--quit" "Forget the cherry-pick, its changes and conflicts left"))))

; The options as git's sequencer keeps them, in its order.
(def %opts
  (fn (_ o)
    (List flat-map (fn (_ x) x)
      (list (if (Opts on? o "-n") (list (pair "no-commit" "true")) ())
            (match ((Opts on? o "--no-edit") (list (pair "edit" "false"))) ((Opts on? o "-e") (list (pair "edit" "true"))) (#t ()))
            (if (Opts on? o "--allow-empty") (list (pair "allow-empty" "true")) ())
            (if (Opts on? o "-x") (list (pair "record-origin" "true")) ())
            (if (Opts on? o "--ff") (list (pair "allow-ff" "true")) ())))))

(def git-cherry-pick
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-cherry-pick-options ops))
    (def operands (Opts operands o))
    ; what --ff cannot be used with, the first git finds
    (def clash
      (and (Opts on? o "--ff")
           (match ((Opts on? o "-n") "--no-commit") ((Opts on? o "-x") "-x") ((Opts on? o "-e") "--edit") (#t #f))))
    (match
      ((Opts help? git-cherry-pick-options ops) (list (lit out) (Opts usage git-cherry-pick-options) 0))
      ((not (null? (Opts unknown o)))
        (list (lit err) (Str8 append "error: unknown option `" (Opts unknown o) "'\n" (Opts usage git-cherry-pick-options)) 129))
      ((null? gitdir) (git-no-repo))
      (clash (list (lit err) (Str8 append "fatal: cherry-pick: " clash " cannot be used with --ff\n") 128))
      ((Opts on? o "--abort") (git-sequence-abort! wd gitdir "cherry-pick"))
      ((Opts on? o "--skip") (git-sequence-skip! wd gitdir "cherry-pick"))
      ((Opts on? o "--quit") (git-sequence-quit! gitdir))
      ((Opts on? o "--continue") (git-sequence-continue! wd gitdir "cherry-pick"))
      ((null? operands) (list (lit err) (Opts usage git-cherry-pick-options) 129))
      (#t (git-sequence! wd gitdir "cherry-pick" operands (%opts o))))))

(provide git/pick git-cherry-pick git-cherry-pick-options)
