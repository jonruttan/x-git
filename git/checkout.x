; # x-git -- git on x-lang
;
; ## git/checkout.x -- the working directory set to a tree
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
(import x/sys/file File)
(import git/objects git-object-read git-tree-entries git-write-file! git-read-file git-hash)
(import git/refs git-ref-read git-rev-parse git-tree-of git-commit-of git-headers)
(import git/index git-index-read git-status-lists)
(import git/stage git-index-write!)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %at (fn (_ p off) ((prim-ref (lit int) (lit ->ptr)) (%add ((prim-ref (lit ptr) (lit ->int)) p) off))))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))
(def %error (fn (_ text) (list (lit err) (Str8 append "error: " text "\n") 1)))
(def %no-repo
  (fn (_) (%fatal "not a git repository (or any of the parent directories): .git")))
(def %unknown-option
  (fn (_ w usage)
    (def n (Str8 length w))
    (list (lit err)
      (Str8 append
        (if (Str8 starts? "--" w)
          (Str8 append "error: unknown option `" (Str8 sub 2 (- n 2) w))
          (Str8 append "error: unknown switch `" (Str8 sub 1 (- n 1) w)))
        "'\n" usage)
      129)))

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
       (let ((i (Str8 index-of "/" (Str8 sub from (%sub (Str8 length path) from) path))))
         (unless (null? i)
           (let ((dir (Str8 append wd "/" (Str8 sub 0 (%add from i) path))))
             (do (unless (File exists? dir) (File mkdir dir))
                 (self (%add (%add from i) 1)))))))
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
      ((prim-ref (lit mem) (lit copy)) (%str->ptr body) (%at (%str->ptr (first (rest (rest o)))) (first (rest (rest (rest o))))) (first (rest o))))
    (git-write-file! full body (first (rest o)))
    (File chmod full (if (str=? mode "100755") 493 420))
    ()))

; A file removed, and the directories it leaves empty, up to the root.
(def %remove!
  (fn (_ wd path)
    (def full (Str8 append wd "/" path))
    (when (File exists? full) (File unlink full))
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
    (def st (File stat (Str8 append wd "/" path)))
    (list path (if (str=? mode "100755") 33261 33188) sha (Assoc get (lit size) st) (Assoc get (lit mtime) st))))

; --- the move ---

; The paths with changes of their own: staged or unstaged.
(def %dirty
  (fn (_ wd gitdir)
    (def lists (git-status-lists wd gitdir))
    (List append (List map (fn (_ c) (rest c)) (first lists)) (List map (fn (_ c) (rest c)) (first (rest lists))))))

; The working directory and index set to the tree of commit, from what
; HEAD's tree has now; answers () when done, or the paths that stop it.
(def %move-to!
  (fn (_ wd gitdir commit)
    (def target (%tree-files gitdir (git-tree-of gitdir commit) ""))
    (def current (%tree-files gitdir (git-tree-of gitdir "HEAD") ""))
    (def in (fn (_ files path) (List find (fn (_ f) (str=? (first f) path)) files)))
    (def differs?
      (fn (_ path)
        (let ((t (in target path)) (c (in current path)))
          (not (and (not (null? t)) (not (null? c)) (str=? (first (rest t)) (first (rest c))) (str=? (first (rest (rest t))) (first (rest (rest c)))))))))
    (def dirty (%dirty wd gitdir))
    (def blocked (List filter (fn (_ p) (differs? p)) dirty))
    (if (not (null? blocked)) (List sort (fn (_ a b) (Str8 <? a b)) blocked)
      (do
        ; files the new tree lacks go; the rest are written where they differ
        (List for-each (fn (_ c) (when (null? (in target (first c))) (%remove! wd (first c)))) current)
        (List for-each
          (fn (_ t)
            (when (or (differs? (first t)) (not (File exists? (Str8 append wd "/" (first t)))))
              (%write-blob! wd gitdir (first t) (first (rest t)) (first (rest (rest t))))))
          target)
        (git-index-write! gitdir (List map (fn (_ t) (%entry-of wd (first t) (first (rest t)) (first (rest (rest t))))) target))
        ()))))

(def %overwritten
  (fn (_ paths)
    (list (lit err)
      (Str8 append "error: Your local changes to the following files would be overwritten by checkout:\n"
        (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) paths))
        "Please commit your changes or stash them before you switch branches.\nAborting\n")
      1)))

(def %detached-note
  (fn (_ rev gitdir sha)
    (def subject
      (let ((o (git-object-read gitdir sha)))
        (if (null? o) ""
          (let ((text ((eval (lit git-object-text) (module git/objects)) o)))
            (let ((i (Str8 index-of "\n\n" text)))
              (if (null? i) "" (first (Str8 split "\n" (Str8 sub (%add i 2) (%sub (Str8 length text) (%add i 2)) text)))))))))
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
            "Turn off this advice by setting config variable advice.detachedHead to false" ""
            (Str8 append "HEAD is now at " (Str8 sub 0 7 sha) " " subject) ""))))

; HEAD moved to a branch (made first at start when new? is set) or to a
; commit, the working directory following.
(def %switch!
  (fn (_ wd gitdir rev new? start)
    (def current
      (let ((h (Str8 trim (File read-all (Str8 append gitdir "/HEAD")))))
        (if (Str8 starts? "ref: refs/heads/" h) (Str8 sub 16 (%sub (Str8 length h) 16) h) ())))
    (def branch-sha (if new? () (git-ref-read gitdir (Str8 append "refs/heads/" rev))))
    (match
      ((and new? (not (null? (git-ref-read gitdir (Str8 append "refs/heads/" rev)))))
        (%fatal (Str8 append "a branch named '" rev "' already exists")))
      (new?
        (let ((sha (git-commit-of gitdir start)))
          (if (null? sha) (%fatal (Str8 append "not a valid object name: '" start "'"))
            (let ((blocked (%move-to! wd gitdir sha)))
              (if (not (null? blocked)) (%overwritten blocked)
                (do (git-write-file! (Str8 append gitdir "/refs/heads/" rev) (Str8 append sha "\n") 41)
                    (File write-all (Str8 append gitdir "/HEAD") (Str8 append "ref: refs/heads/" rev "\n"))
                    (list (lit err) (Str8 append "Switched to a new branch '" rev "'\n") 0)))))))
      ((and (not (null? current)) (str=? current rev))
        (list (lit err) (Str8 append "Already on '" rev "'\n") 0))
      ((not (null? branch-sha))
        (let ((blocked (%move-to! wd gitdir branch-sha)))
          (if (not (null? blocked)) (%overwritten blocked)
            (do (File write-all (Str8 append gitdir "/HEAD") (Str8 append "ref: refs/heads/" rev "\n"))
                (list (lit err) (Str8 append "Switched to branch '" rev "'\n") 0)))))
      (#t
        (let ((sha (git-commit-of gitdir rev)))
          (if (null? sha)
            (%error (Str8 append "pathspec '" rev "' did not match any file(s) known to git"))
            (let ((blocked (%move-to! wd gitdir sha)))
              (if (not (null? blocked)) (%overwritten blocked)
                (do (File write-all (Str8 append gitdir "/HEAD") (Str8 append sha "\n"))
                    (list (lit err) (%detached-note rev gitdir sha) 0))))))))))

; Paths put back from the index; one the index lacks stops it all.
(def %restore!
  (fn (_ wd gitdir paths)
    (def index (git-index-read gitdir))
    (def missing (List find (fn (_ p) (null? (List find (fn (_ e) (str=? (first e) p)) index))) paths))
    (if (not (null? missing))
      (%error (Str8 append "pathspec '" missing "' did not match any file(s) known to git"))
      (do (List for-each
            (fn (_ p)
              (let ((e (List find (fn (_ x) (str=? (first x) p)) index)))
                (%write-blob! wd gitdir p (first (rest (rest e))) (first (rest e)))))
            paths)
          (list (lit out) "" 0)))))

; --- the commands ---

(def git-checkout-options
  (Opts declare "git checkout" "[-b <new-branch>] <branch> | <commit>\n   or: git checkout -- <path>..." ()
    (list
      (Opts arg "-b" "<new-branch>" "Make the branch at the start point (HEAD when none), then switch to it"))))

(def git-checkout
  (fn (_ wd gitdir ops)
    ; a "--" is Opts's own end of options; a path after it is a restore,
    ; which the operands carry, so it is looked for in ops as given
    (def dashes? (List any? (fn (_ a) (str=? a "--")) ops))
    (def o (Opts parse git-checkout-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-checkout-options ops) (list (lit out) (Opts usage git-checkout-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-checkout-options)))
      ((null? gitdir) (%no-repo))
      (dashes? (%restore! wd gitdir operands))
      ((not (null? (Opts value o "-b" ())))
        (%switch! wd gitdir (Opts value o "-b" ()) #t (if (null? operands) "HEAD" (first operands))))
      ((null? operands) (list (lit err) (Opts usage git-checkout-options) 129))
      ((and (null? (git-ref-read gitdir (Str8 append "refs/heads/" (first operands))))
            (null? (git-commit-of gitdir (first operands)))
            (not (null? (List find (fn (_ e) (str=? (first e) (first operands))) (git-index-read gitdir)))))
        (%restore! wd gitdir operands))
      (#t (%switch! wd gitdir (first operands) #f ())))))

(def git-switch-options
  (Opts declare "git switch" "[-c <new-branch>] <branch>" ()
    (list
      (Opts arg "-c" "--create" "<new-branch>" "Make the branch at the start point (HEAD when none), then switch to it"))))

(def git-switch
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-switch-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-switch-options ops) (list (lit out) (Opts usage git-switch-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-switch-options)))
      ((null? gitdir) (%no-repo))
      ((not (null? (Opts value o "-c" ())))
        (%switch! wd gitdir (Opts value o "-c" ()) #t (if (null? operands) "HEAD" (first operands))))
      ((null? operands) (list (lit err) (Opts usage git-switch-options) 129))
      ((null? (git-ref-read gitdir (Str8 append "refs/heads/" (first operands))))
        (%fatal (Str8 append "invalid reference: " (first operands))))
      (#t (%switch! wd gitdir (first operands) #f ())))))

(def git-restore-options
  (Opts declare "git restore" "<path>..." () ()))

(def git-restore
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-restore-options ops))
    (match
      ((Opts help? git-restore-options ops) (list (lit out) (Opts usage git-restore-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-restore-options)))
      ((null? gitdir) (%no-repo))
      ((null? (Opts operands o)) (list (lit err) "fatal: you must specify path(s) to restore\n" 128))
      (#t (%restore! wd gitdir (Opts operands o))))))

; The working directory and index set to a commit's tree, for clone;
; answers () when done, or the paths whose own changes stop it.
(def git-checkout-tree!
  (fn (_ wd gitdir commit) (%move-to! wd gitdir commit)))

(provide git/checkout git-checkout git-checkout-options git-switch git-switch-options
  git-restore git-restore-options git-checkout-tree!)
