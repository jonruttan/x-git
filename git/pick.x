; # x-git -- git on x-lang
;
; ## git/pick.x -- cherry-pick
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; git cherry-pick: a commit's change made again on HEAD, as git makes it
; -- HEAD and the commit merged three ways from the commit's parent
; (git/merge's merge, the markers calling theirs "ABBREV (SUBJECT)") --
; and committed with the commit's own message and author, the committer
; the one git finds; -x notes the commit picked, -e edits the message
; first, -n leaves the change staged, uncommitted, and --ff moves the
; branch to the commit itself when HEAD is its parent.  A conflict stops
; it with CHERRY_PICK_HEAD and MERGE_MSG left, for --continue (or a
; commit) to conclude, --skip or --abort to give up and --quit to forget;
; so does a pick that changes nothing, unless --allow-empty and the
; commit changed nothing itself.  One commit at a time; a merge, which
; needs -m to say which parent's side to keep, is refused.  revert's
; machinery (git/revert) does the committing, editing and refusing.

(module git/pick)

(import x/sys/opts Opts)
(import x/sys/file File)
(import x/sys/posix Sys)
(import git/objects git-subject git-object-read git-object-text)
(import git/commands git-no-repo)
(import git/refs git-commit-of git-tree-of git-headers)
(import git/index git-status-lists git-long-status)
(import git/stage git-merge-state-clear! git-commit git-write-tree! git-read-entries)
(import git/merge git-merge-place! git-restore-head!)
(import git/remote git-write-ref! git-current-branch)
(import git/threeway git-tree-flat)
(import git/reflog git-ref-log!)
(import git/revert git-pick-failed git-pick-editor git-pick-edit git-pick-hints git-pick-in-progress? git-pick-commit!
  git-pick-give-up!)

(import x/core/doors int+ int-)

(def %failed (fn (_ text) (git-pick-failed "cherry-pick" text)))

(def git-cherry-pick-options
  (Opts declare "git cherry-pick" "[-e] [-n] [-x] [--ff] [--allow-empty] <commit> | (--continue | --skip | --abort | --quit)" ()
    (list
      (Opts flag "-e" "--edit" "Edit the message first")
      (Opts flag "--no-edit" "Commit with the commit's message, unedited (the default)")
      (Opts flag "-n" "--no-commit" "Leave the change staged, uncommitted")
      (Opts flag "-x" "Note the commit picked in the message")
      (Opts flag "--ff" "Move the branch to the commit when HEAD is its parent")
      (Opts flag "--allow-empty" "Commit a commit that changed nothing itself")
      (Opts flag "--continue" "Commit once the conflicts are resolved")
      (Opts flag "--skip" "Give the commit up, the working directory and index set back")
      (Opts flag "--abort" "Give up, the working directory and index set back")
      (Opts flag "--quit" "Forget the cherry-pick, its changes and conflicts left"))))

(def %picking? (fn (_ gitdir) (File exists? (Str8 append gitdir "/CHERRY_PICK_HEAD"))))

; A commit's message as it was written: the text after its header.
(def %message-of
  (fn (_ gitdir sha)
    (def text (git-object-text (git-object-read gitdir sha)))
    (def i (Str8 index-of "\n\n" text))
    (if (null? i) "" (Str8 sub (int+ i 2) (int- (Str8 length text) (int+ i 2)) text))))

; A line as git reads a trailer: a token without spaces, a colon, a
; space; or the line -x itself adds.
(def %trailer?
  (fn (_ line)
    (or (Str8 starts? "(cherry picked from commit " line)
        (let ((c (Str8 index-of ": " line)))
          (and (not (null? c)) (> c 0) (null? (Str8 index-of " " (Str8 sub 0 c line))))))))

; -x's note added: on a line of its own after a blank one, or straight
; after a last paragraph of trailers, as git adds it.
(def %note
  (fn (_ message sha)
    (def body (if (Str8 ends? "\n" message) message (Str8 append message "\n")))
    ; the lines from the last, back to the first blank one
    (def lines (List reverse (Str8 split "\n" (Str8 trim body))))
    (def last-para
      ((fn (self ls acc) (if (or (null? ls) (= (Str8 length (Str8 trim (first ls))) 0)) acc (self (rest ls) (pair (first ls) acc))))
       lines ()))
    (def more? (< (List length last-para) (List length lines)))
    (Str8 append body
      (if (and more? (List all? %trailer? last-para)) "" "\n")
      "(cherry picked from commit " sha ")\n")))

(def %empty-text
  (Str8 append
    "The previous cherry-pick is now empty, possibly due to conflict resolution.\n"
    "If you wish to commit it anyway, use:\n\n"
    "    git commit --allow-empty\n\n"
    "Otherwise, please use 'git cherry-pick --skip'\n"))

; The branch, or HEAD when detached, moved to sha and logged.
(def %move!
  (fn (_ gitdir head sha msg)
    (def branch (git-current-branch gitdir))
    (if (null? branch)
      (File write-all (Str8 append gitdir "/HEAD") (Str8 append sha "\n"))
      (git-write-ref! gitdir (Str8 append "refs/heads/" branch) sha))
    (git-ref-log! gitdir (if (null? branch) "HEAD" (Str8 append "refs/heads/" branch)) head sha
      (Str8 append (or (Sys getenv "GIT_REFLOG_ACTION") "cherry-pick") ": " msg))))

; The pick itself: the commit sha, its parents, onto head.
(def %pick
  (fn (_ wd gitdir o sha parents head)
    (def subject (git-subject gitdir sha))
    (def tree (git-tree-of gitdir sha))
    (def parent-tree (if (null? parents) () (git-tree-of gitdir (first parents))))
    (def author (rest (List find (fn (_ kv) (str=? (first kv) "author")) (git-headers gitdir sha))))
    (def message (if (Opts on? o "-x") (%note (%message-of gitdir sha) sha) (%message-of gitdir sha)))
    (def placed
      (git-merge-place! wd gitdir head
        (if (null? parent-tree) () (git-tree-flat gitdir parent-tree ""))
        (git-tree-flat gitdir tree "")
        (Str8 append (Str8 sub 0 7 sha) " (" subject ")")))
    (def said (if (eq? (first placed) (lit placed)) (Str8 join "" (first (rest (rest placed)))) ""))
    (def conflicted (if (eq? (first placed) (lit placed)) (first (rest (rest (rest placed)))) ()))
    (match
      ((eq? (first placed) (lit blocked))
        (%failed (Str8 append "error: Your local changes to the following files would be overwritten by merge:\n"
                   (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) (rest placed)))
                   "Please commit your changes or stash them before you merge.\nAborting\n")))
      ; a conflict: the state left for --continue, --skip or --abort; with
      ; -n, only the message
      ((or (not (null? conflicted)) (first (rest (rest (rest (rest placed))))))
        (do (when (not (Opts on? o "-n"))
              (File write-all (Str8 append gitdir "/CHERRY_PICK_HEAD") (Str8 append sha "\n")))
            (File write-all (Str8 append gitdir "/MERGE_MSG")
              (Str8 append message "\n# Conflicts:\n"
                (Str8 join "" (List map (fn (_ p) (Str8 append "#\t" p "\n")) conflicted))))
            (list (lit err)
              (Str8 append "error: could not apply " (Str8 sub 0 7 sha) "... " subject "\n"
                (if (Opts on? o "-n")
                  (Str8 append "hint: after resolving the conflicts, mark the corrected paths\n"
                    "hint: with 'git add <paths>' or 'git rm <paths>'\n"
                    "hint: Disable this message with \"git config set advice.mergeConflict false\"\n")
                  (git-pick-hints "cherry-pick")))
              1 said)))
      ((Opts on? o "-n")
        (do (File write-all (Str8 append gitdir "/MERGE_MSG") message)
            (list (lit out) said 0)))
      ; a pick that changes nothing stops for a commit --allow-empty or a
      ; skip -- unless the commit changed nothing itself and --allow-empty
      ; says to keep it
      ((and (str=? (git-write-tree! gitdir (git-read-entries gitdir)) (git-tree-of gitdir head))
            (not (and (Opts on? o "--allow-empty")
                      (str=? tree (if (null? parent-tree) (git-write-tree! gitdir ()) parent-tree)))))
        (do (File write-all (Str8 append gitdir "/CHERRY_PICK_HEAD") (Str8 append sha "\n"))
            (File write-all (Str8 append gitdir "/MERGE_MSG") message)
            (list (lit err) %empty-text 1
              (Str8 append said (git-long-status gitdir (git-status-lists wd gitdir))))))
      ((Opts on? o "-e")
        (let ((edited (git-pick-edit gitdir message (git-current-branch gitdir))))
          (match
            ((null? edited)
              (%failed (Str8 append "error: there was a problem with the editor '" (git-pick-editor gitdir) "'\n")))
            ((= (Str8 length edited) 0) (list (lit err) "Aborting commit due to empty commit message.\n" 1))
            (#t (git-pick-commit! gitdir head edited said author "cherry-pick")))))
      (#t (git-pick-commit! gitdir head message said author "cherry-pick")))))

(def git-cherry-pick
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-cherry-pick-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-cherry-pick-options ops) (list (lit out) (Opts usage git-cherry-pick-options) 0))
      ((not (null? (Opts unknown o)))
        (list (lit err) (Str8 append "error: unknown option `" (Opts unknown o) "'\n" (Opts usage git-cherry-pick-options)) 129))
      ((null? gitdir) (git-no-repo))
      ; giving up: the working directory and index back at HEAD
      ((Opts on? o "--abort")
        (if (not (git-pick-in-progress? gitdir)) (%failed "error: no cherry-pick or revert in progress\n")
          (git-pick-give-up! wd gitdir)))
      ; skipping the one commit: as giving up, when it is a cherry-pick
      ((Opts on? o "--skip")
        (if (not (%picking? gitdir)) (%failed "error: no cherry-pick in progress\n")
          (git-pick-give-up! wd gitdir)))
      ; quitting: the state forgotten, the changes and conflicts left
      ((Opts on? o "--quit") (do (git-merge-state-clear! gitdir) (list (lit out) "" 0)))
      ; going on: the pick committed as commit concludes it, by its author
      ((Opts on? o "--continue")
        (if (not (git-pick-in-progress? gitdir)) (%failed "error: no cherry-pick or revert in progress\n")
          (git-commit wd gitdir ())))
      ((null? operands) (list (lit err) (Opts usage git-cherry-pick-options) 129))
      ((or (< 1 (List length operands)) (not (null? (Str8 index-of ".." (first operands)))))
        (list (lit err) "fatal: this git picks one commit at a time\n" 128))
      (#t
        (let ((sha (git-commit-of gitdir (first operands))))
          (if (null? sha) (list (lit err) (Str8 append "fatal: bad revision '" (first operands) "'\n") 128)
            (let ((parents (List map rest (List filter (fn (_ kv) (str=? (first kv) "parent")) (git-headers gitdir sha))))
                  (head (git-commit-of gitdir "HEAD"))
                  (lists (git-status-lists wd gitdir)))
              (match
                ((not (null? (first (rest (rest (rest lists))))))
                  (%failed (Str8 append "error: Cherry-picking is not possible because you have unmerged files.\n"
                             "hint: Fix them up in the work tree, and then use 'git add/rm <file>'\n"
                             "hint: as appropriate to mark resolution and make a commit.\n")))
                ((and (not (Opts on? o "-n")) (not (null? (first lists))))
                  (%failed "error: your local changes would be overwritten by cherry-pick.\nhint: commit your changes or stash them to proceed.\n"))
                ((< 1 (List length parents))
                  (%failed (Str8 append "error: commit " sha " is a merge but no -m option was given.\n")))
                ; --ff: HEAD the commit's parent, the branch moved to the commit itself
                ((and (Opts on? o "--ff") (not (Opts on? o "-n")) (not (Opts on? o "-e"))
                      (not (null? parents)) (str=? (first parents) head))
                  (let ((placed (git-merge-place! wd gitdir head
                                  (git-tree-flat gitdir (git-tree-of gitdir head) "")
                                  (git-tree-flat gitdir (git-tree-of gitdir sha) "")
                                  (Str8 sub 0 7 sha))))
                    (if (eq? (first placed) (lit blocked))
                      (%failed (Str8 append "error: Your local changes to the following files would be overwritten by merge:\n"
                                 (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) (rest placed)))
                                 "Please commit your changes or stash them before you merge.\nAborting\n"))
                      (do (%move! gitdir head sha "fast-forward") (list (lit out) "" 0)))))
                (#t (%pick wd gitdir o sha parents head))))))))))

(provide git/pick git-cherry-pick git-cherry-pick-options)
