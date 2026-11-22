; # x-git -- git on x-lang
;
; ## lib/git/checkout.x -- the working directory set to a tree
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; checkout and switch move HEAD to a branch or a commit and make the
; working directory and the index match its tree: files written from
; blobs, files the new tree lacks removed, directories left empty removed
; too.  A path with changes of its own that the move would overwrite stops
; it, in git's words.  `checkout -- PATH` and `restore PATH` put a file
; back from the index.

(module git/checkout)

(import x/sys/opts Opts)
(import git/opts git-opts-parse)
(import x/sys/file File)
(import git/objects git-object-read git-tree-entries git-write-file! git-read-file git-hash)
(import git/commands git-fatal git-no-repo git-unknown-option git-strip-slash)
(import git/refs git-ref-read git-rev-parse git-tree-of git-commit-of git-headers git-previous-branch)
(import git/index git-index-read git-status-lists)
(import git/stage git-index-write! git-read-entries git-merge-state-clear!)
(import git/reflog git-reflog-append!)
(import git/work git-work-write! git-work-exists? git-work-stat)

(import x/core/doors int+ int- str->ptr)
(def %at (fn (_ p off) ((prim-ref (lit int) (lit ->ptr)) (int+ ((prim-ref (lit ptr) (lit ->int)) p) off))))

(def %error (fn (_ text) (list (lit err) (Str8 append "error: " text "\n") 1)))

; --- trees and files ---

; A tree's files, (PATH SHA MODE-TEXT) each.
(def %tree-files
  (fn (self gitdir tree prefix)
    (def o (if (null? tree) () (git-object-read gitdir tree)))
    (if (or (null? o) (not (str=? (first o) "tree"))) ()
      (List flat-map
        (fn (_ e)
          (let ((path (Str8 append prefix (first (rest e)))))
            (if (str=? (first e) "40000")
              (self gitdir (first (rest (rest e))) (Str8 append path "/"))
              (list (list path (first (rest (rest e))) (first e))))))
        (git-tree-entries o)))))

; Every directory on the way to path made.
(def %mkdir-parents!
  (fn (_ wd path)
    ((fn (self from)
       (let ((i (Str8 index-of "/" (Str8 sub from (int- (Str8 length path) from) path))))
         (unless (null? i)
           (let ((dir (Str8 append wd "/" (Str8 sub 0 (int+ from i) path))))
             (do (unless (File exists? dir) (File mkdir dir))
                 (self (int+ (int+ from i) 1)))))))
     0)))

; A blob written to a path in the working directory, its mode set.
(def %write-blob!
  (fn (_ wd gitdir path sha mode)
    (def o (git-object-read gitdir sha))
    (when (null? o) (Err raise (lit value) (Str8 append "git: missing blob " sha) ()))
    (def full (Str8 append wd "/" path))
    (%mkdir-parents! wd path)
    (def body ((prim-ref (lit str) (lit make)) (if (= (first (rest o)) 0) 1 (first (rest o)))))
    (when (> (first (rest o)) 0)
      ((prim-ref (lit mem) (lit copy)) (str->ptr body) (%at (str->ptr (first (rest (rest o)))) (first (rest (rest (rest o))))) (first (rest o))))
    (git-work-write! full body (first (rest o)) mode)
    ()))

; A file removed, and the directories it leaves empty, up to the root.
(def %remove!
  (fn (_ wd path)
    (def full (Str8 append wd "/" path))
    (when (git-work-exists? full) (File unlink full))
    ((fn (self p)
       (let ((i (Str8 last-index-of "/" p)))
         (unless (null? i)
           (let ((dir (Str8 sub 0 i p)))
             (let ((fdir (Str8 append wd "/" dir)))
               (when (and (File exists? fdir) (null? (File list-dir fdir)))
                 (do (File rmdir fdir) (self dir))))))))
     path)))

; An index entry for a path just written: (PATH MODE-NUMBER SHA SIZE MTIME).
(def %entry-of
  (fn (_ wd path sha mode)
    (def st (git-work-stat (Str8 append wd "/" path)))
    (list path (match ((str=? mode "100755") 33261) ((str=? mode "120000") 40960) (#t 33188)) sha (Assoc get (lit size) st) (Assoc get (lit mtime) st))))

; --- the move ---

; The paths with changes of their own: staged or unstaged.
(def %dirty
  (fn (_ wd gitdir)
    (def lists (git-status-lists wd gitdir))
    (List append (List map (fn (_ c) (rest c)) (first lists)) (List map (fn (_ c) (rest c)) (first (rest lists))))))

; The working directory and index set to the tree of commit, from what
; HEAD's tree has now; answers () when done, or the paths that stop it.
(def %move-to!
  (fn (_ wd gitdir commit . fresh)
    (def target (%tree-files gitdir (git-tree-of gitdir commit) ""))
    ; fresh, for clone: from nothing, whatever HEAD names
    (def current (if (null? fresh) (%tree-files gitdir (git-tree-of gitdir "HEAD") "") ()))
    (def in (fn (_ files path) (List find (fn (_ f) (str=? (first f) path)) files)))
    (def differs?
      (fn (_ path)
        (let ((t (in target path)) (c (in current path)))
          (not (and (not (null? t)) (not (null? c)) (str=? (first (rest t)) (first (rest c))) (str=? (first (rest (rest t))) (first (rest (rest c)))))))))
    (def dirty (if (null? fresh) (%dirty wd gitdir) ()))
    ; a path either tree has, the two disagreeing on it: the move's to set
    (def moved? (fn (_ path) (and (or (not (null? (in target path))) (not (null? (in current path)))) (differs? path))))
    (def blocked (List filter (fn (_ p) (moved? p)) dirty))
    (if (not (null? blocked)) (List sort (fn (_ a b) (Str8 <? a b)) blocked)
      (do
        ; files the new tree lacks go; the rest are written where they
        ; differ; a path the trees agree on keeps its changes, staged or
        ; not, as does one neither tree has
        (List for-each (fn (_ c) (when (null? (in target (first c))) (%remove! wd (first c)))) current)
        (List for-each
          (fn (_ t)
            (when (differs? (first t))
              (%write-blob! wd gitdir (first t) (first (rest t)) (first (rest (rest t))))))
          target)
        (git-index-write! gitdir
          (List append
            (List flat-map (fn (_ t) (if (differs? (first t)) (list (%entry-of wd (first t) (first (rest t)) (first (rest (rest t))))) ())) target)
            (List filter (fn (_ e) (not (moved? (first e)))) (if (null? fresh) (git-read-entries gitdir) ()))))
        ()))))

(def %overwritten
  (fn (_ paths)
    (list (lit err)
      (Str8 append "error: Your local changes to the following files would be overwritten by checkout:\n"
        (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) paths))
        "Please commit your changes or stash them before you switch branches.\nAborting\n")
      1)))

; A commit's short name and subject, as git describes a detached HEAD.
(def %described
  (fn (_ gitdir sha)
    (def subject
      (let ((o (git-object-read gitdir sha)))
        (if (null? o) ""
          (let ((text ((eval (lit git-object-text) (module git/objects)) o)))
            (let ((i (Str8 index-of "\n\n" text)))
              (if (null? i) "" (first (Str8 split "\n" (Str8 sub (int+ i 2) (int- (Str8 length text) (int+ i 2)) text)))))))))
    (Str8 append (Str8 sub 0 7 sha) " " subject)))

; Leaving a detached HEAD for another commit: where it was, as git says
; it first; "" otherwise.
(def %previous
  (fn (_ gitdir branch old new)
    (if (or (not (null? branch)) (null? old) (str=? old new)) ""
      (Str8 append "Previous HEAD position was " (%described gitdir old) "\n"))))

; A HEAD detached at sha: git's advice first when it was on a branch and
; --detach was not asked for, then where HEAD is now.
(def %detached-note
  (fn (_ rev gitdir sha advise?)
    (Str8 append
      (if (not advise?) ""
        (Str8 join "\n"
          (list (Str8 append "Note: switching to '" rev "'.") ""
                "You are in 'detached HEAD' state. You can look around, make experimental"
                "changes and commit them, and you can discard any commits you make in this"
                "state without impacting any branches by switching back to a branch." ""
                "If you want to create a new branch to retain commits you create, you may"
                "do so (now or later) by using -c with the switch command. Example:" ""
                "  git switch -c <new-branch-name>" ""
                "Or undo this operation with:" ""
                "  git switch -" ""
                "Turn off this advice by setting config variable advice.detachedHead to false" "" "")))
      "HEAD is now at " (%described gitdir sha) "\n")))

; The paths whose working copy differs from HEAD, as git lists them after
; a switch: "M\tPATH" and the like, one a line, () when none.  A path is
; looked at through the index: gone from it, D; new to it, A, unless
; gone from the working directory too; else D when gone from there, M
; when changed in either.
(def %changes
  (fn (_ wd gitdir)
    (def lists (git-status-lists wd gitdir))
    (def code-in (fn (_ l p) (let ((c (List find (fn (_ c) (str=? (rest c) p)) l))) (if (null? c) () (first c)))))
    (def paths (List sort (fn (_ a b) (Str8 <? a b))
                 (List fold (fn (_ acc c) (if (List any? (fn (_ p) (str=? p (rest c))) acc) acc (pair (rest c) acc)))
                   () (List append (first lists) (first (rest lists))))))
    (def lines
      (List flat-map
        (fn (_ p)
          (let ((s (code-in (first lists) p)) (u (code-in (first (rest lists)) p)))
            (let ((code (match
                          ((equal? s "D") "D")
                          ((equal? s "A") (if (equal? u "D") () "A"))
                          ((equal? u "D") "D")
                          (#t "M"))))
              (if (null? code) () (list (Str8 append code "\t" p "\n"))))))
        paths))
    (if (null? lines) () (Str8 join "" lines))))

; A merge, cherry-pick or revert left unfinished is given up by a switch
; that works, a pick's or a revert's with a warning; the warning's text.
(def %settle!
  (fn (_ gitdir)
    (def warning
      (match
        ((File exists? (Str8 append gitdir "/CHERRY_PICK_HEAD")) "warning: cancelling a cherry picking in progress\n")
        ((File exists? (Str8 append gitdir "/REVERT_HEAD")) "warning: cancelling a revert in progress\n")
        (#t "")))
    (git-merge-state-clear! gitdir)
    warning))

; A switch done: what it says on standard error, and after it on standard
; output the changes it carried.
(def %told
  (fn (_ gitdir text changes)
    (def said (Str8 append text (%settle! gitdir)))
    (if (null? changes) (list (lit err) said 0) (list (lit err) said 0 changes))))

; The paths in conflict in the index, each once, in order.
(def %unmerged-paths
  (fn (_ gitdir)
    (List reverse
      (List fold (fn (_ acc e) (if (or (= (first (rest (rest (rest e)))) 0) (and (not (null? acc)) (str=? (first acc) (first e)))) acc (pair (first e) acc)))
        () (git-index-read gitdir)))))

; A switch refused while paths are in conflict: () when none are.
(def %unresolved
  (fn (_ gitdir)
    (def paths (%unmerged-paths gitdir))
    (if (null? paths) ()
      (list (lit err) "error: you need to resolve your current index first\n" 1
        (Str8 join "" (List map (fn (_ p) (Str8 append p ": needs merge\n")) paths))))))

; switch refuses outright while a merge, cherry-pick or revert is under
; way: () when none is.
(def %under-way
  (fn (_ gitdir)
    (def doing
      (match
        ((File exists? (Str8 append gitdir "/MERGE_HEAD")) (pair "merging" "merge"))
        ((File exists? (Str8 append gitdir "/CHERRY_PICK_HEAD")) (pair "cherry-picking" "cherry-pick"))
        ((File exists? (Str8 append gitdir "/REVERT_HEAD")) (pair "reverting" "revert"))
        (#t ())))
    (if (null? doing) ()
      (git-fatal (Str8 append "cannot switch branch while " (first doing)
                   "\nConsider \"git " (rest doing) " --quit\" or \"git worktree add\".")))))

; HEAD moved to a branch (made first at start when new? is set) or to a
; commit, the working directory following; with detach? to the commit rev
; names, a branch's too.
(def %switch!
  (fn (_ wd gitdir rev new? given . detach)
    (def detach? (not (null? detach)))
    ; a new branch made at HEAD, no start given, lists no changes, as git
    (def start (or given "HEAD"))
    (def current
      (let ((h (Str8 trim (File read-all (Str8 append gitdir "/HEAD")))))
        (if (Str8 starts? "ref: refs/heads/" h) (Str8 sub 16 (int- (Str8 length h) 16) h) ())))
    (def old (git-rev-parse gitdir "HEAD"))
    ; HEAD's log: from the branch it named, or the commit it was at
    (def moved! (fn (_ new) (git-reflog-append! gitdir "HEAD" old new (Str8 append "checkout: moving from " (or current old) " to " rev))))
    (def branch-sha (if (or new? detach?) () (git-ref-read gitdir (Str8 append "refs/heads/" rev))))
    (match
      ((and new? (not (null? (git-ref-read gitdir (Str8 append "refs/heads/" rev)))))
        (git-fatal (Str8 append "a branch named '" rev "' already exists")))
      ; paths in conflict stop a move; a new branch made at HEAD moves nothing
      ((and (not (and new? (null? given))) (not (null? (%unresolved gitdir)))) (%unresolved gitdir))
      (new?
        (let ((sha (git-commit-of gitdir start)))
          (if (null? sha) (git-fatal (Str8 append "not a valid object name: '" start "'"))
            (let ((blocked (%move-to! wd gitdir sha)))
              (if (not (null? blocked)) (%overwritten blocked)
                (do (git-write-file! (Str8 append gitdir "/refs/heads/" rev) (Str8 append sha "\n") 41)
                    (git-reflog-append! gitdir (Str8 append "refs/heads/" rev) () sha (Str8 append "branch: Created from " start))
                    (File write-all (Str8 append gitdir "/HEAD") (Str8 append "ref: refs/heads/" rev "\n"))
                    (moved! sha)
                    (%told gitdir (Str8 append (%previous gitdir current old sha) "Switched to a new branch '" rev "'\n") (if (null? given) () (%changes wd gitdir)))))))))
      ((and (not detach?) (not (null? current)) (str=? current rev))
        (do (moved! old) (%told gitdir (Str8 append "Already on '" rev "'\n") (%changes wd gitdir))))
      ((not (null? branch-sha))
        (let ((blocked (%move-to! wd gitdir branch-sha)))
          (if (not (null? blocked)) (%overwritten blocked)
            (do (File write-all (Str8 append gitdir "/HEAD") (Str8 append "ref: refs/heads/" rev "\n"))
                (moved! branch-sha)
                (%told gitdir (Str8 append (%previous gitdir current old branch-sha) "Switched to branch '" rev "'\n") (%changes wd gitdir))))))
      (#t
        (let ((sha (git-commit-of gitdir rev)))
          (if (null? sha)
            (%error (Str8 append "pathspec '" rev "' did not match any file(s) known to git"))
            (let ((blocked (%move-to! wd gitdir sha)))
              (if (not (null? blocked)) (%overwritten blocked)
                (do (File write-all (Str8 append gitdir "/HEAD") (Str8 append sha "\n"))
                    ; detached already at that commit, git logs nothing
                    (unless (and (null? current) (str=? old sha)) (moved! sha))
                    (%told gitdir
                      (Str8 append (%previous gitdir current old sha)
                        (%detached-note rev gitdir sha (and (not detach?) (not (null? current)))))
                      (%changes wd gitdir)))))))))))

; Does a path fall under one of the pathspecs: the path itself, a
; directory holding it, or "."?
(def %under?
  (fn (_ path specs)
    (List any? (fn (_ s) (or (str=? path s) (str=? s ".") (Str8 starts? (Str8 append s "/") path))) specs)))

; A mode's text as the index keeps it, a number.
(def %mode-number
  (fn (_ mode) (match ((str=? mode "100755") 33261) ((str=? mode "120000") 40960) (#t 33188))))

; And back: a mode number spelled as a tree spells it.
(def %mode-text
  (fn (_ n) (match ((= n 33261) "100755") ((= n 40960) "120000") ((= n 57344) "160000") (#t "100644"))))

; Paths put back, as restore puts them: from source, a tree's name, or
; the index when it is (); into the working directory, the index, or
; both.  A path the source lacks goes from where it is put back.  A
; pathspec that matches nothing either has stops it all, as does a path
; in conflict when the working directory takes it from the index.
(def %restore!
  (fn (_ wd gitdir specs source staged? worktree?)
    (def entries (git-read-entries gitdir))
    ; the source's files, (PATH SHA MODE-TEXT) each
    (def from
      (if (null? source)
        (List flat-map (fn (_ e) (if (= (first (rest (rest (rest (rest (rest e)))))) 0)
                                   (list (list (first e) (first (rest (rest e))) (%mode-text (first (rest e))))) ()))
          entries)
        (%tree-files gitdir source "")))
    (def known (List append (List map first entries) (List map first from)))
    (def missing (List find (fn (_ s) (not (List any? (fn (_ p) (%under? p (list s))) known))) specs))
    (def paths
      (List sort (fn (_ a b) (Str8 <? a b))
        ((fn (self ps acc) (if (null? ps) acc (self (rest ps) (if (List any? (fn (_ a) (str=? a (first ps))) acc) acc (pair (first ps) acc)))))
         (List filter (fn (_ p) (%under? p specs)) known) ())))
    (def unmerged
      (if (null? source) (List filter (fn (_ p) (List any? (fn (_ u) (str=? u p)) (%unmerged-paths gitdir))) paths) ()))
    (def in-from (fn (_ p) (List find (fn (_ x) (str=? (first x) p)) from)))
    (match
      ((not (null? missing))
        (%error (Str8 append "pathspec '" missing "' did not match any file(s) known to git")))
      ((not (null? unmerged))
        (list (lit err) (Str8 join "" (List map (fn (_ p) (Str8 append "error: path '" p "' is unmerged\n")) unmerged)) 1))
      (#t
        (do (when worktree?
              (List for-each
                (fn (_ p)
                  (let ((s (in-from p)))
                    (if (null? s) (%remove! wd p) (%write-blob! wd gitdir p (first (rest s)) (first (rest (rest s)))))))
                paths))
            ; the index's entries for the paths, a conflict's stages and
            ; all, replaced by the source's; stat taken from a file just
            ; written, else left for git to look at again
            (when staged?
              (git-index-write! gitdir
                (List append
                  (List filter (fn (_ e) (not (List any? (fn (_ p) (str=? p (first e))) paths))) entries)
                  (List flat-map
                    (fn (_ p)
                      (let ((s (in-from p)))
                        (match
                          ((null? s) ())
                          (worktree? (list (%entry-of wd p (first (rest s)) (first (rest (rest s))))))
                          (#t (list (list p (%mode-number (first (rest (rest s)))) (first (rest s)) 0 0))))))
                    paths))))
            (list (lit out) "" 0))))))

; --- the commands ---

; checkout with no operand, or HEAD: nothing moves, the changes are
; listed and what was under way given up, unless paths are in conflict.
(def %stay
  (fn (_ wd gitdir)
    (def refused (%unresolved gitdir))
    (if (not (null? refused)) refused
      (let ((warning (%settle! gitdir)) (changes (or (%changes wd gitdir) "")))
        (if (= (Str8 length warning) 0) (list (lit out) changes 0) (list (lit err) warning 0 changes))))))


; - and @{-N}: the branch checked out that many switches ago, or else
; when there was none.
(def %prior
  (fn (_ gitdir a else)
    (def spec (if (str=? a "-") "@{-1}" a))
    (if (or (null? gitdir) (not (Str8 starts? "@{-" spec))) a
      (or (git-previous-branch gitdir spec) else))))

; With -q a switch that works says nothing; a refusal is still told.
(def %hush
  (fn (_ o r)
    (if (and (Opts on? o "-q") (= (first (rest (rest r))) 0)) (list (first r) "" 0) r)))

; --detach: HEAD at a commit, a branch's too, the start HEAD when none
; is given.  checkout takes what is no commit as a path, which --detach
; does not; switch takes it as no reference.
(def %detach
  (fn (_ wd gitdir o operands new-flag path-refusal?)
    (def rev (if (null? operands) "HEAD" (first operands)))
    (def stray
      (match
        ((not (null? (Opts value o new-flag ()))) (git-fatal "'--detach' cannot be used with '-b/-B/--orphan'"))
        ((and (not (null? operands)) (null? (git-commit-of gitdir rev)))
          (git-fatal (if path-refusal?
                       (Str8 append "git checkout: --detach does not take a path argument '" rev "'")
                       (Str8 append "invalid reference: " rev))))
        ((and (not (null? operands)) (not (null? (rest operands))))
          (git-fatal (if path-refusal?
                       (Str8 append "git checkout: --detach does not take a path argument '" (first (rest operands)) "'")
                       "only one reference expected")))
        (#t ())))
    (if (not (null? stray)) stray
      (%hush o (%switch! wd gitdir rev #f () #t)))))

(def git-checkout-options
  (Opts declare "git checkout" "[-q] [-b <new-branch>] [<branch> | <commit>]\n   or: git checkout [-q] --detach [<commit>]\n   or: git checkout [-q] -- <path>..." ()
    (list
      (Opts flag "-q" "--quiet" "Say nothing when it works")
      (Opts flag "-d" "--detach" "Detach HEAD at the commit (HEAD when none), a branch's too")
      (Opts arg "-b" "<new-branch>" "Make the branch at the start point (HEAD when none), then switch to it"))))

(def git-checkout
  (fn (_ wd gitdir ops)
    ; a "--" is Opts's own end of options; a path after it is a restore,
    ; which the operands carry, so it is looked for in ops as given
    (def dashes? (List any? (fn (_ a) (str=? a "--")) ops))
    (def o (git-opts-parse git-checkout-options ops))
    (def operands (List map (fn (_ a) (%prior gitdir a a)) (Opts operands o)))
    (match
      ((Opts help? git-checkout-options ops) (list (lit out) (Opts usage git-checkout-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-checkout-options)))
      ((null? gitdir) (git-no-repo))
      ((Opts on? o "-d") (%detach wd gitdir o operands "-b" #t))
      (dashes? (%restore! wd gitdir operands () #f #t))
      ((not (null? (Opts value o "-b" ())))
        (%hush o (%switch! wd gitdir (Opts value o "-b" ()) #t (if (null? operands) () (first operands)))))
      ; no operand, or HEAD: nothing moves
      ((or (null? operands) (and (null? (rest operands)) (str=? (first operands) "HEAD"))) (%hush o (%stay wd gitdir)))
      ((and (null? (git-ref-read gitdir (Str8 append "refs/heads/" (first operands))))
            (null? (git-commit-of gitdir (first operands)))
            (not (null? (List find (fn (_ e) (str=? (first e) (first operands))) (git-index-read gitdir)))))
        (%restore! wd gitdir operands () #f #t))
      (#t (%hush o (%switch! wd gitdir (first operands) #f ()))))))

(def git-switch-options
  (Opts declare "git switch" "[-q] [-c <new-branch>] <branch>\n   or: git switch [-q] --detach [<commit>]" ()
    (list
      (Opts flag "-q" "--quiet" "Say nothing when it works")
      (Opts flag "-d" "--detach" "Detach HEAD at the commit (HEAD when none), a branch's too")
      (Opts arg "-c" "--create" "<new-branch>" "Make the branch at the start point (HEAD when none), then switch to it"))))

(def git-switch
  (fn (_ wd gitdir ops)
    (def o (git-opts-parse git-switch-options ops))
    (def operands (List map (fn (_ a) (%prior gitdir a (if (str=? a "-") "@{-1}" a))) (Opts operands o)))
    (match
      ((Opts help? git-switch-options ops) (list (lit out) (Opts usage git-switch-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-switch-options)))
      ((null? gitdir) (git-no-repo))
      ((not (null? (%under-way gitdir))) (%under-way gitdir))
      ((Opts on? o "-d") (%detach wd gitdir o operands "-c" #f))
      ((not (null? (Opts value o "-c" ())))
        (%hush o (%switch! wd gitdir (Opts value o "-c" ()) #t (if (null? operands) () (first operands)))))
      ((null? operands) (list (lit err) (Opts usage git-switch-options) 129))
      ((null? (git-ref-read gitdir (Str8 append "refs/heads/" (first operands))))
        (let ((kind (match
                      ((not (null? (git-ref-read gitdir (Str8 append "refs/tags/" (first operands))))) "tag")
                      ((not (null? (git-commit-of gitdir (first operands)))) "commit")
                      (#t ()))))
          (if (null? kind) (git-fatal (Str8 append "invalid reference: " (first operands)))
            (list (lit err)
              (Str8 append "fatal: a branch is expected, got " kind " '" (first operands) "'\n"
                "hint: If you want to detach HEAD at the commit, try again with the --detach option.\n")
              128))))
      (#t (%hush o (%switch! wd gitdir (first operands) #f ()))))))

(def git-restore-options
  (Opts declare "git restore" "[-s <tree>] [-S] [-W] [-q] <path>..." ()
    (list
      (Opts arg "-s" "--source" "<tree>" "Take the paths from this commit or tree: HEAD with --staged, else the index")
      (Opts flag "-S" "--staged" "Put the paths back in the index")
      (Opts flag "-W" "--worktree" "Put the paths back in the working directory, as with neither")
      (Opts flag "-q" "--quiet" "Say nothing when it works"))))

(def git-restore
  (fn (_ wd gitdir ops)
    (def o (git-opts-parse git-restore-options ops))
    (def staged? (Opts on? o "-S"))
    (def worktree? (or (Opts on? o "-W") (not staged?)))
    ; the source: the one named, HEAD for the index, else the index
    (def named (Opts value o "-s" ()))
    (def rev (or named (if staged? "HEAD" ())))
    (def source (if (or (null? rev) (null? gitdir)) () (git-tree-of gitdir rev)))
    (def paths (List map (fn (_ p) (git-strip-slash p)) (Opts operands o)))
    (match
      ((Opts help? git-restore-options ops) (list (lit out) (Opts usage git-restore-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-restore-options)))
      ((null? gitdir) (git-no-repo))
      ((null? paths) (list (lit err) "fatal: you must specify path(s) to restore\n" 128))
      ((and (not (null? rev)) (null? source)) (git-fatal (Str8 append "could not resolve '" rev "'")))
      (#t (%restore! wd gitdir paths source staged? worktree?)))))

; The working directory and index moved to a commit's tree from HEAD's,
; for merge's fast-forward;
; answers () when done, or the paths whose own changes stop it.
(def git-checkout-tree!
  (fn (_ wd gitdir commit) (%move-to! wd gitdir commit)))

; The working directory and index made from a commit's tree, as from
; nothing, for clone.
(def git-checkout-new!
  (fn (_ wd gitdir commit) (%move-to! wd gitdir commit #t)))

; A blob written to a path of the working directory, its mode set; a
; path's file removed with the directories it leaves empty; an index
; entry for a path just written.  For merge, which writes paths one by
; one.
(def git-write-blob! (fn (_ wd gitdir path sha mode) (%write-blob! wd gitdir path sha mode)))
(def git-remove-file! (fn (_ wd path) (%remove! wd path)))
(def git-entry-of (fn (_ wd path sha mode) (%entry-of wd path sha mode)))

(provide git/checkout git-checkout git-checkout-options git-switch git-switch-options
  git-restore git-restore-options git-checkout-tree! git-checkout-new! git-write-blob! git-remove-file! git-entry-of)
