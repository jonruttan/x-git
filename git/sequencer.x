; # x-git -- git on x-lang
;
; ## git/sequencer.x -- what cherry-pick and revert share
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; git's sequencer: commits picked or reverted one after another, as git
; does it.  Each step is a three-way merge onto HEAD -- a pick merges the
; commit from its parent, a revert the parent from the commit (git/merge's
; merge) -- committed with the commit's message and author for a pick,
; git's `Revert "SUBJECT"` for a revert; -x notes the commit picked, -e
; edits the message first, -n leaves the change staged, merging each onto
; what is staged, and --ff moves the branch to a commit whose parent is
; HEAD.  A merge, which needs -m to say which parent's side to keep, is
; refused.
;
; One commit is a step alone.  Several, or a range, are a sequence, kept
; in .git/sequencer as git keeps one: head, where it began; todo, the
; steps left, the one that stopped first; opts, its options; and
; abort-safety, HEAD as the sequence last left it.  A step that stops --
; a conflict, with CHERRY_PICK_HEAD or REVERT_HEAD and MERGE_MSG left; a
; pick that changes nothing; a refusal -- stops the sequence there, for
; --continue (or a commit, then --continue) to go on, --skip to leave the
; step out and go on, --abort to go back to where it began and --quit to
; forget it.

(module git/sequencer)

(import x/sys/file File)
(import x/sys/proc Proc)
(import x/sys/posix Sys)
(import git/objects git-subject git-object-read git-object-text)
(import git/refs git-commit-of git-tree-of git-headers)
(import git/index git-status-lists git-tree-files git-long-status)
(import git/stage git-read-entries git-write-tree! git-commit-write-by! git-commit-report-idents git-merge-state-clear!
  git-message-strip git-commit)
(import git/merge git-merge-place-on! git-restore-head!)
(import git/remote git-write-ref! git-current-branch)
(import git/threeway git-tree-flat)
(import git/diff git-commit-summary)
(import git/config git-config-value)
(import git/reflog git-ref-log!)
(import git/history git-rev-walk)

(import x/core/doors int+ int-)

(def %pick? (fn (_ action) (str=? action "cherry-pick")))

; A refusal as the sequencer words one: the error, then "ACTION failed".
(def git-pick-failed
  (fn (_ action text) (list (lit err) (Str8 append text "fatal: " action " failed\n") 128)))

; --- answers ---

(def %code (fn (_ r) (first (rest (rest r)))))

; What an answer has for standard output.
(def %said-of
  (fn (_ r)
    (if (eq? (first r) (lit out)) (first (rest r))
      (let ((more (rest (rest (rest r))))) (if (null? more) "" (first more))))))

; An answer with said before its standard output.
(def %after
  (fn (_ said r)
    (if (eq? (first r) (lit out)) (list (lit out) (Str8 append said (first (rest r))) (%code r))
      (list (lit err) (first (rest r)) (%code r) (Str8 append said (%said-of r))))))

; --- the editor ---

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

; --- messages ---

; git's hints after a conflict; with -n, the short ones.
(def %hints
  (fn (_ action no-commit?)
    (Str8 join ""
      (List map (fn (_ l) (Str8 append "hint: " l "\n"))
        (if no-commit?
          (list "after resolving the conflicts, mark the corrected paths"
                "with 'git add <paths>' or 'git rm <paths>'"
                "Disable this message with \"git config set advice.mergeConflict false\"")
          (list "After resolving the conflicts, mark them with"
                "\"git add/rm <pathspec>\", then run"
                (Str8 append "\"git " action " --continue\".")
                (Str8 append "You can instead skip this commit with \"git " action " --skip\".")
                (Str8 append "To abort and get back to the state before \"git " action "\",")
                (Str8 append "run \"git " action " --abort\".")
                "Disable this message with \"git config set advice.mergeConflict false\""))))))

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

; git's message for a revert: a revert of a revert reapplies.
(def %revert-message
  (fn (_ subject sha)
    (Str8 append
      (if (and (Str8 starts? "Revert \"" subject) (Str8 ends? "\"" subject))
        (Str8 append "Reapply " (Str8 sub 7 (int- (Str8 length subject) 7) subject))
        (Str8 append "Revert \"" subject "\""))
      "\n\nThis reverts commit " sha ".\n")))

(def %empty-text
  (Str8 append
    "The previous cherry-pick is now empty, possibly due to conflict resolution.\n"
    "If you wish to commit it anyway, use:\n\n"
    "    git commit --allow-empty\n\n"
    "Otherwise, please use 'git cherry-pick --skip'\n"))

(def %overwritten
  (fn (_ paths)
    (Str8 append "error: Your local changes to the following files would be overwritten by merge:\n"
      (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) paths))
      "Please commit your changes or stash them before you merge.\nAborting\n")))

; --- the sequence's state ---

(def %seq (fn (_ gitdir name) (Str8 append gitdir "/sequencer/" name)))
(def %sequencing? (fn (_ gitdir) (File exists? (Str8 append gitdir "/sequencer"))))

(def %seq-files (list "head" "todo" "opts" "abort-safety"))

(def %seq-remove!
  (fn (_ gitdir)
    (when (%sequencing? gitdir)
      (do (List for-each (fn (_ f) (let ((p (%seq gitdir f))) (when (File exists? p) (File unlink p)))) %seq-files)
          (File rmdir (Str8 append gitdir "/sequencer"))))))

(def %head-file (fn (_ gitdir action) (Str8 append gitdir (if (%pick? action) "/CHERRY_PICK_HEAD" "/REVERT_HEAD"))))

; A revert or a cherry-pick stopped, either of which --abort and
; --continue take up.
(def git-pick-in-progress?
  (fn (_ gitdir)
    (or (File exists? (Str8 append gitdir "/REVERT_HEAD")) (File exists? (Str8 append gitdir "/CHERRY_PICK_HEAD")))))

; abort-safety: HEAD as the sequence leaves it, written after each step
; that moves it, so --abort and --skip can tell when something else has.
(def %safety!
  (fn (_ gitdir)
    (when (%sequencing? gitdir)
      (File write-all (%seq gitdir "abort-safety") (Str8 append (or (git-commit-of gitdir "HEAD") "") "\n")))))

(def %safe?
  (fn (_ gitdir)
    (def p (%seq gitdir "abort-safety"))
    (and (File exists? p) (str=? (Str8 trim (File read-all p)) (or (git-commit-of gitdir "HEAD") "")))))

; The todo, as ((ACTION . SHA) ...): git's lines, "pick ABBREV SUBJECT"
; or "revert ABBREV SUBJECT".
(def %todo-write!
  (fn (_ gitdir items)
    (File write-all (%seq gitdir "todo")
      (Str8 join ""
        (List map
          (fn (_ it) (Str8 append (if (%pick? (first it)) "pick " "revert ") (Str8 sub 0 7 (rest it)) " "
                       (git-subject gitdir (rest it)) "\n"))
          items)))))

(def %todo
  (fn (_ gitdir)
    (def p (%seq gitdir "todo"))
    (if (not (File exists? p)) ()
      (List flat-map
        (fn (_ line)
          (let ((words (Str8 split " " line)))
            (if (< (List length words) 2) ()
              (list (pair (if (str=? (first words) "pick") "cherry-pick" "revert")
                          (git-commit-of gitdir (first (rest words))))))))
        (Str8 split "\n" (File read-all p))))))

; What the sequence does: its todo's first step's action, () when there
; is none.
(def %seq-action
  (fn (_ gitdir) (let ((t (%todo gitdir))) (if (null? t) () (first (first t))))))

; The options, as ((KEY . VALUE) ...) in git's order, and opts as git
; writes them; none, no file.
(def %opts-write!
  (fn (_ gitdir opts)
    (unless (null? opts)
      (File write-all (%seq gitdir "opts")
        (Str8 append "[options]\n"
          (Str8 join "" (List map (fn (_ kv) (Str8 append "\t" (first kv) " = " (rest kv) "\n")) opts)))))))

(def %opts
  (fn (_ gitdir)
    (def p (%seq gitdir "opts"))
    (if (not (File exists? p)) ()
      (List flat-map
        (fn (_ line)
          (let ((i (Str8 index-of " = " line)))
            (if (null? i) ()
              (list (pair (Str8 trim (Str8 sub 0 i line))
                          (Str8 trim (Str8 sub (int+ i 3) (int- (Str8 length line) (int+ i 3)) line)))))))
        (Str8 split "\n" (File read-all p))))))

(def %opt (fn (_ opts key) (let ((kv (List find (fn (_ kv) (str=? (first kv) key)) opts))) (if (null? kv) () (rest kv)))))
(def %on? (fn (_ opts key) (let ((v (%opt opts key))) (and (not (null? v)) (str=? v "true")))))

; --- a step ---

; HEAD moved to sha and logged, the branch with it unless detached.
(def %move!
  (fn (_ gitdir head sha msg)
    (def branch (git-current-branch gitdir))
    (if (null? branch)
      (File write-all (Str8 append gitdir "/HEAD") (Str8 append sha "\n"))
      (git-write-ref! gitdir (Str8 append "refs/heads/" branch) sha))
    (git-ref-log! gitdir (if (null? branch) "HEAD" (Str8 append "refs/heads/" branch)) head sha msg)))

; A revert or a cherry-pick committed: the index's tree on head, by the
; author given (or () for git's), HEAD moved and logged as action logs
; it, git's report of it after what the merge said.
(def %commit!
  (fn (_ gitdir head message said by action)
    (def tree (git-write-tree! gitdir (git-read-entries gitdir)))
    (def sha (git-commit-write-by! gitdir tree (list head) message by))
    (def branch (git-current-branch gitdir))
    (%move! gitdir head sha (Str8 append (or (Sys getenv "GIT_REFLOG_ACTION") action) ": " (first (Str8 split "\n" message))))
    (%safety! gitdir)
    (list (lit out)
      (Str8 append said "[" (if (null? branch) "detached HEAD" branch) " " (Str8 sub 0 7 sha) "] " (first (Str8 split "\n" message)) "\n"
        (git-commit-report-idents gitdir sha #t)
        ; a commit that changes nothing has no summary line
        (if (str=? tree (git-tree-of gitdir head)) ""
          (git-commit-summary gitdir (git-tree-files gitdir (git-tree-of gitdir head)) (git-tree-files gitdir tree))))
      0)))

; One commit picked or reverted onto HEAD, with the options opts: as git
; answers it.
(def %step!
  (fn (_ wd gitdir action sha opts)
    (def pick? (%pick? action))
    (def failed (fn (_ text) (git-pick-failed action text)))
    (def no-commit? (%on? opts "no-commit"))
    (def head (git-commit-of gitdir "HEAD"))
    (def parents (List map rest (List filter (fn (_ kv) (str=? (first kv) "parent")) (git-headers gitdir sha))))
    (def lists (git-status-lists wd gitdir))
    (match
      ((not (null? (first (rest (rest (rest lists))))))
        (failed (Str8 append "error: " (if pick? "Cherry-picking" "Reverting") " is not possible because you have unmerged files.\n"
                  "hint: Fix them up in the work tree, and then use 'git add/rm <file>'\n"
                  "hint: as appropriate to mark resolution and make a commit.\n")))
      ((and (not no-commit?) (not (null? (first lists))))
        (failed (Str8 append "error: your local changes would be overwritten by " action ".\n"
                  "hint: commit your changes or stash them to proceed.\n")))
      ((< 1 (List length parents))
        (failed (Str8 append "error: commit " sha " is a merge but no -m option was given.\n")))
      ; --ff: HEAD the commit's parent, HEAD moved to the commit itself
      ((and pick? (%on? opts "allow-ff") (not (null? parents)) (str=? (first parents) (or head "")))
        (let ((placed (git-merge-place-on! wd gitdir head (git-tree-flat gitdir (git-tree-of gitdir head) "")
                        (List append (List map rest (first lists)) (List map rest (first (rest lists))))
                        (git-tree-flat gitdir (git-tree-of gitdir head) "")
                        (git-tree-flat gitdir (git-tree-of gitdir sha) "")
                        (Str8 sub 0 7 sha))))
          (if (eq? (first placed) (lit blocked)) (failed (%overwritten (rest placed)))
            (do (%move! gitdir head sha (Str8 append (or (Sys getenv "GIT_REFLOG_ACTION") action) ": fast-forward"))
                (%safety! gitdir)
                (list (lit out) "" 0)))))
      (#t (%merge-step! wd gitdir action sha parents head lists opts)))))

; The step's merge, and what follows it: a conflict, -n's staged change,
; a pick that changes nothing, or the commit.
(def %merge-step!
  (fn (_ wd gitdir action sha parents head lists opts)
    (def pick? (%pick? action))
    (def failed (fn (_ text) (git-pick-failed action text)))
    (def no-commit? (%on? opts "no-commit"))
    (def subject (git-subject gitdir sha))
    (def tree (git-tree-of gitdir sha))
    (def parent-tree (if (null? parents) () (git-tree-of gitdir (first parents))))
    (def flat (fn (_ t) (if (null? t) () (git-tree-flat gitdir t ""))))
    (def message
      (match
        ((not pick?) (%revert-message subject sha))
        ((%on? opts "record-origin") (%note (%message-of gitdir sha) sha))
        (#t (%message-of gitdir sha))))
    ; -n merges onto what is staged, only the working directory's own
    ; changes in its way
    (def placed
      (git-merge-place-on! wd gitdir head
        (if no-commit? (flat (git-write-tree! gitdir (git-read-entries gitdir))) (flat (git-tree-of gitdir head)))
        (if no-commit? (List map rest (first (rest lists)))
          (List append (List map rest (first lists)) (List map rest (first (rest lists)))))
        (if pick? (flat parent-tree) (flat tree))
        (if pick? (flat tree) (flat parent-tree))
        (Str8 append (if pick? "" "parent of ") (Str8 sub 0 7 sha) " (" subject ")")))
    (def ok? (eq? (first placed) (lit placed)))
    (def said (if ok? (Str8 join "" (first (rest (rest placed)))) ""))
    (def conflicted (if ok? (first (rest (rest (rest placed)))) ()))
    (def state! (fn (_) (File write-all (%head-file gitdir action) (Str8 append sha "\n"))))
    (match
      ((not ok?) (failed (%overwritten (rest placed))))
      ; a conflict: the state left for --continue, --skip or --abort; a
      ; pick's with -n, only the message
      ((or (not (null? conflicted)) (first (rest (rest (rest (rest placed))))))
        (do (when (or (not pick?) (not no-commit?)) (state!))
            (File write-all (Str8 append gitdir "/MERGE_MSG")
              (Str8 append message "\n# Conflicts:\n"
                (Str8 join "" (List map (fn (_ p) (Str8 append "#\t" p "\n")) conflicted))))
            (list (lit err)
              (Str8 append "error: could not " (if pick? "apply " "revert ") (Str8 sub 0 7 sha) "... " subject "\n"
                (%hints action no-commit?))
              1 said)))
      ; -n: staged, uncommitted; a revert left in progress for a commit to
      ; conclude
      (no-commit?
        (do (unless pick? (state!))
            (File write-all (Str8 append gitdir "/MERGE_MSG") message)
            (list (lit out) said 0)))
      ; a revert that changes nothing stops as commit stops, with nothing
      ; to commit
      ((and (not pick?) (str=? (git-write-tree! gitdir (git-read-entries gitdir)) (git-tree-of gitdir head)))
        (do (File write-all (Str8 append gitdir "/MERGE_MSG") message)
            (list (lit out) (Str8 append said (git-long-status gitdir (git-status-lists wd gitdir))) 1)))
      ; a pick that changes nothing stops for a commit --allow-empty or a
      ; skip -- unless the commit changed nothing itself and --allow-empty
      ; says to keep it
      ((and pick?
            (str=? (git-write-tree! gitdir (git-read-entries gitdir)) (git-tree-of gitdir head))
            (not (and (%on? opts "allow-empty")
                      (str=? tree (if (null? parent-tree) (git-write-tree! gitdir ()) parent-tree)))))
        (do (state!)
            (File write-all (Str8 append gitdir "/MERGE_MSG") message)
            (list (lit err) %empty-text 1
              (Str8 append said (git-long-status gitdir (git-status-lists wd gitdir))))))
      ; a pick's message is edited when -e says to, a revert's unless
      ; --no-edit says not to
      ((if pick? (%on? opts "edit") (not (str=? (or (%opt opts "edit") "") "false")))
        (let ((edited (%edit gitdir message (git-current-branch gitdir))))
          (match
            ((null? edited) (failed (Str8 append "error: there was a problem with the editor '" (%editor gitdir) "'\n")))
            ((= (Str8 length edited) 0) (list (lit err) "Aborting commit due to empty commit message.\n" 1))
            (#t (%commit! gitdir head edited said (%author gitdir sha pick?) action)))))
      (#t (%commit! gitdir head message said (%author gitdir sha pick?) action)))))

; A pick's commit is by the commit's author; a revert's, by whoever git
; finds.
(def %author
  (fn (_ gitdir sha pick?)
    (if (not pick?) ()
      (rest (List find (fn (_ kv) (str=? (first kv) "author")) (git-headers gitdir sha))))))

; --- a sequence ---

; The steps from items on, each after the last, until one stops: then the
; todo left from it, for --continue, --skip or --abort.  The todo is
; written before each step, as git writes it, for status to read.  said
; is what the steps before have said.
(def %run!
  (fn (_ wd gitdir items opts said)
    (if (null? items) (do (%seq-remove! gitdir) (list (lit out) said 0))
      (let ((r (do (%todo-write! gitdir items) (%step! wd gitdir (first (first items)) (rest (first items)) opts))))
        (if (= (%code r) 0) (%run! wd gitdir (rest items) opts (Str8 append said (%said-of r)))
          (%after said r))))))

; The commits operands name, as ((ACTION . SHA) ...): in the order given,
; each once; or, when a range or a ^REV is among them, as git's walk lists
; them -- oldest first for a pick, newest first for a revert.  Answers
; (bad OPERAND) for one that names none.
(def %items
  (fn (_ gitdir action operands)
    (def resolve
      (fn (_ op)
        (def dots (Str8 index-of ".." op))
        (match
          ((not (null? dots))
            (let ((a (Str8 sub 0 dots op)) (b (Str8 sub (int+ dots 2) (int- (Str8 length op) (int+ dots 2)) op)))
              (let ((ends (git-commit-of gitdir (if (= (Str8 length a) 0) "HEAD" a)))
                    (start (git-commit-of gitdir (if (= (Str8 length b) 0) "HEAD" b))))
                (if (or (null? ends) (null? start)) () (list (list start) (list ends))))))
          ((Str8 starts? "^" op)
            (let ((s (git-commit-of gitdir (Str8 sub 1 (int- (Str8 length op) 1) op)))) (if (null? s) () (list () (list s)))))
          (#t (let ((s (git-commit-of gitdir op))) (if (null? s) () (list (list s) ())))))))
    (def resolved (List map (fn (_ op) (pair op (resolve op))) operands))
    (def bad (List find (fn (_ r) (null? (rest r))) resolved))
    (if (not (null? bad)) (list (lit bad) (first bad))
      (let ((starts (List flat-map (fn (_ r) (first (rest r))) resolved))
            (ends (List flat-map (fn (_ r) (first (rest (rest r)))) resolved)))
        (list (lit ok)
          (List map (fn (_ sha) (pair action sha))
            (if (null? ends)
              (List reverse
                (List fold (fn (_ acc s) (if (List any? (fn (_ x) (str=? x s)) acc) acc (pair s acc))) () starts))
              (let ((walked (git-rev-walk gitdir starts ends)))
                (if (%pick? action) (List reverse walked) walked)))))))))

; One commit named alone is a step of its own; more, a range or a ^REV,
; a sequence.
(def %one?
  (fn (_ operands)
    (and (= (List length operands) 1) (null? (Str8 index-of ".." (first operands))) (not (Str8 starts? "^" (first operands))))))

; cherry-pick or revert of the commits operands name, with the options
; opts, ((KEY . VALUE) ...) in git's order.
(def git-sequence!
  (fn (_ wd gitdir action operands opts)
    (def failed (fn (_ text) (git-pick-failed action text)))
    (def items (%items gitdir action operands))
    (match
      ((eq? (first items) (lit bad))
        (list (lit err) (Str8 append "fatal: bad revision '" (first (rest items)) "'\n") 128))
      ((%one? operands) (%step! wd gitdir action (rest (first (first (rest items)))) opts))
      ((null? (first (rest items))) (failed "error: empty commit set passed\n"))
      ; the sequence in progress named, whichever it is
      ((%sequencing? gitdir)
        (let ((doing (or (%seq-action gitdir) action)))
          (failed (Str8 append "error: " doing " is already in progress\n"
                    "hint: try \"git " doing " (--continue | --skip | --abort | --quit)\"\n"))))
      (#t
        (let ((head (git-commit-of gitdir "HEAD")))
          (do (File mkdir (Str8 append gitdir "/sequencer"))
              (File write-all (%seq gitdir "head") (Str8 append (or head "") "\n"))
              (%opts-write! gitdir opts)
              (%safety! gitdir)
              (%run! wd gitdir (first (rest items)) opts "")))))))

; The steps after the one that stopped, said after what the stop's
; conclusion said.
(def %resume!
  (fn (_ wd gitdir said)
    (%run! wd gitdir (let ((t (%todo gitdir))) (if (null? t) () (rest t))) (%opts gitdir) said)))

; --continue: the stopped step committed as commit concludes it -- by its
; author, for a pick -- then the sequence's steps after it.
(def git-sequence-continue!
  (fn (_ wd gitdir action)
    (def failed (fn (_ text) (git-pick-failed action text)))
    (match
      ((%sequencing? gitdir)
        (let ((doing (%seq-action gitdir)) (lists (git-status-lists wd gitdir)))
          (match
            ((and (not (null? doing)) (not (str=? doing action)))
              (failed (Str8 append "error: cannot " action " during a " doing ".\n")))
            ((git-pick-in-progress? gitdir)
              (let ((r (git-commit wd gitdir ())))
                (if (not (= (%code r) 0)) r
                  (do (%safety! gitdir) (%resume! wd gitdir (%said-of r))))))
            ((not (null? (first (rest (rest (rest lists))))))
              (failed (Str8 append "error: " (if (%pick? action) "Cherry-picking" "Reverting")
                        " is not possible because you have unmerged files.\n"
                        "hint: Fix them up in the work tree, and then use 'git add/rm <file>'\n"
                        "hint: as appropriate to mark resolution and make a commit.\n")))
            ((not (null? (first lists)))
              (failed (Str8 append "error: your local changes would be overwritten by " action ".\n"
                        "hint: commit your changes or stash them to proceed.\n")))
            (#t (%resume! wd gitdir "")))))
      ((git-pick-in-progress? gitdir) (git-commit wd gitdir ()))
      (#t (failed "error: no cherry-pick or revert in progress\n")))))

; Given up, back at target: HEAD moved there and the working directory
; and index with it, the state cleared, and the reset that does it in git
; logged as git logs it.
(def %give-up!
  (fn (_ wd gitdir target)
    (def head (git-commit-of gitdir "HEAD"))
    (def branch (git-current-branch gitdir))
    (unless (str=? target head)
      (if (null? branch)
        (File write-all (Str8 append gitdir "/HEAD") (Str8 append target "\n"))
        (git-write-ref! gitdir (Str8 append "refs/heads/" branch) target)))
    (git-restore-head! wd gitdir)
    (git-merge-state-clear! gitdir)
    (File write-all (Str8 append gitdir "/ORIG_HEAD") (Str8 append head "\n"))
    (git-ref-log! gitdir (if (null? branch) "HEAD" (Str8 append "refs/heads/" branch)) head target
      (Str8 append "reset: moving to " target))
    (list (lit out) "" 0)))

; --skip: the stopped step given up, then the sequence's steps after it.
; A step that stopped with nothing to give up -- a refusal -- is skipped
; while HEAD is where the sequence left it.
(def git-sequence-skip!
  (fn (_ wd gitdir action)
    (def failed (fn (_ text) (git-pick-failed action text)))
    (def go-on
      (fn (_)
        (do (%give-up! wd gitdir (git-commit-of gitdir "HEAD"))
            (if (%sequencing? gitdir) (git-sequence-continue! wd gitdir action) (list (lit out) "" 0)))))
    (match
      ((File exists? (%head-file gitdir action)) (go-on))
      ((and (%sequencing? gitdir) (equal? (%seq-action gitdir) action))
        (if (%safe? gitdir) (go-on)
          (failed (Str8 append "error: there is nothing to skip\n"
                    "hint: have you committed already?\n"
                    "hint: try \"git " action " --continue\"\n"))))
      (#t (failed (Str8 append "error: no " action " in progress\n"))))))

; --abort: back where the sequence began -- unless HEAD has moved since it
; left it, when git leaves it be -- or, for a step alone, at HEAD.
(def git-sequence-abort!
  (fn (_ wd gitdir action)
    (match
      ((File exists? (%seq gitdir "head"))
        (let ((target (Str8 trim (File read-all (%seq gitdir "head")))))
          (if (%safe? gitdir)
            (do (%give-up! wd gitdir target) (%seq-remove! gitdir) (list (lit out) "" 0))
            (do (%seq-remove! gitdir)
                (list (lit err) "warning: You seem to have moved HEAD. Not rewinding, check your HEAD!\n" 0)))))
      ((git-pick-in-progress? gitdir) (%give-up! wd gitdir (git-commit-of gitdir "HEAD")))
      (#t (git-pick-failed action "error: no cherry-pick or revert in progress\n")))))

; --quit: the state forgotten, the changes and conflicts left.
(def git-sequence-quit!
  (fn (_ gitdir) (do (git-merge-state-clear! gitdir) (%seq-remove! gitdir) (list (lit out) "" 0))))

(provide git/sequencer git-sequence! git-sequence-continue! git-sequence-skip! git-sequence-abort! git-sequence-quit!
  git-pick-failed git-pick-in-progress?)
