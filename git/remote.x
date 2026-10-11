; # x-git -- git on x-lang
;
; ## git/remote.x -- fetch and push, to and from a path
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; fetch [<repository>] and push [<repository> [<branch>]] against a
; repository named by a path, as git does over its local transport.  An
; object moves by being read from one repository and written loose into
; the other: a walk from each tip being sent, through commits' trees and
; parents, trees' entries and tags' objects, that stops at an object the
; receiving side already has.  Refs are then written as git writes them,
; and the report is git's, word for word.
;
; fetch takes every branch of the remote to refs/remotes/<remote>/, the
; tags that point into what it now has, and FETCH_HEAD; push sends one
; branch, refusing as git does a push that is not a fast-forward, one whose
; remote holds work this repository has not seen, and one into the branch
; a non-bare remote has checked out.  Nothing travels over a network yet.

(module git/remote)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/objects git-object-read git-object-write! git-object-text git-tree-entries)
(import git/packs git-pack-has?)
(import git/refs git-ref-read)
(import git/repo git-refs-under)
(import git/stage git-config-get)
(import git/clone git-source-gitdir)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))

(def %not-a-repo
  (fn (_) (%fatal "not a git repository (or any of the parent directories): .git")))

(def %no-remote
  (fn (_ name)
    (list (lit err)
      (Str8 append "fatal: '" name "' does not appear to be a git repository\n"
        "fatal: Could not read from remote repository.\n\n"
        "Please make sure you have the correct access rights\n"
        "and the repository exists.\n")
      128)))

; --- objects ---

; Does the repository hold the object, loose or packed?
(def %has?
  (fn (_ gitdir sha)
    (or (File exists? (Str8 append gitdir "/objects/" (Str8 sub 0 2 sha) "/" (Str8 sub 2 38 sha)))
        (git-pack-has? gitdir sha))))

; The header lines of a commit or tag object, up to the blank line.
(def %header-lines
  (fn (_ o)
    ((fn (self lines acc)
       (if (or (null? lines) (= (Str8 length (first lines)) 0)) (List reverse acc)
         (self (rest lines) (pair (first lines) acc))))
     (Str8 split "\n" (git-object-text o)) ())))

; The values of a commit's or tag's headers named key.
(def %header-values
  (fn (_ o key)
    (def prefix (Str8 append key " "))
    (List map (fn (_ l) (Str8 sub (Str8 length prefix) (%sub (Str8 length l) (Str8 length prefix)) l))
      (List filter (fn (_ l) (Str8 starts? prefix l)) (%header-lines o)))))

; The objects an object names: a commit's tree and parents, a tree's
; entries but its submodules, a tag's object.
(def %children
  (fn (_ o)
    (match
      ((str=? (first o) "commit") (List append (%header-values o "tree") (%header-values o "parent")))
      ((str=? (first o) "tree")
        (List map (fn (_ e) (first (rest (rest e))))
          (List filter (fn (_ e) (not (str=? (first e) "160000"))) (git-tree-entries o))))
      ((str=? (first o) "tag") (%header-values o "object"))
      (#t ()))))

; Every object reachable from the work list that `to` lacks, read from
; `from` and written loose into `to`.  An object `to` has is taken to come
; with everything it names, as it does in any repository git wrote.
(def %copy-closure!
  (fn (self from to work)
    (if (null? work) ()
      (if (%has? to (first work)) (self from to (rest work))
        (do (def o (git-object-read from (first work)))
            (git-object-write! to (first o) (first (rest (rest o))) (first (rest (rest (rest o)))) (first (rest o)))
            (self from to (List append (%children o) (rest work))))))))

; Is commit a reachable from commit b, through b's parents?
(def %ancestor?
  (fn (_ gitdir a b)
    ((fn (self work seen)
       (match
         ((null? work) #f)
         ((str=? (first work) a) #t)
         ((List any? (fn (_ s) (str=? s (first work))) seen) (self (rest work) seen))
         (#t (do (def o (git-object-read gitdir (first work)))
                 (self (List append (rest work) (if (null? o) () (%header-values o "parent")))
                       (pair (first work) seen))))))
     (list b) ())))

; A tag followed to what it finally names.
(def %peel
  (fn (self gitdir sha)
    (def o (git-object-read gitdir sha))
    (if (and (not (null? o)) (str=? (first o) "tag"))
      (self gitdir (first (%header-values o "object")))
      sha)))

; --- refs ---

; The directories of a ref's name made under gitdir: refs/remotes/origin
; for refs/remotes/origin/main, say.
(def %ref-dirs!
  (fn (_ gitdir name)
    ((fn (self parts at)
       (if (null? (rest parts)) ()
         (do (def d (Str8 append at "/" (first parts)))
             (if (File exists? d) () (File mkdir d))
             (self (rest parts) d))))
     (Str8 split "/" name) gitdir)))

; A ref written loose, as git writes one: the old file replaced, since git
; leaves refs it writes without write permission.
(def %write-ref!
  (fn (_ gitdir name sha)
    (%ref-dirs! gitdir name)
    (def path (Str8 append gitdir "/" name))
    (if (File exists? path) (File unlink path) ())
    (File write-all path (Str8 append sha "\n"))))

; The branch HEAD names, or () when HEAD is detached.
(def %current-branch
  (fn (_ gitdir)
    (def h (Str8 trim (File read-all (Str8 append gitdir "/HEAD"))))
    (if (Str8 starts? "ref: refs/heads/" h) (Str8 sub 16 (%sub (Str8 length h) 16) h) ())))

(def %sorted (fn (_ names) (List sort (fn (_ a b) (Str8 <? a b)) names)))

(def %strip-heads
  (fn (_ ref) (if (Str8 starts? "refs/heads/" ref) (Str8 sub 11 (%sub (Str8 length ref) 11) ref) ref)))

(def %abbrev (fn (_ sha) (Str8 sub 0 7 sha)))

; A ref's report line: the flag, the summary to 17 columns, then from ->
; to, from padded to width (fetch's alignment; push passes 0).
(def %report-line
  (fn (_ flag summary from width to msg)
    (Str8 append " " flag " " (Str8 pad-right 17 #\space summary) " "
      (Str8 pad-right width #\space from) " -> " to
      (if (null? msg) "" (Str8 append " (" msg ")")) "\n")))

; The repository a remote's url names, or ().
(def %remote-gitdir
  (fn (_ wd url)
    (if (null? url) ()
      (git-source-gitdir (if (Str8 starts? "/" url) url (Str8 append wd "/" url))))))

; --- fetch ---

(def git-fetch-options
  (Opts declare "git fetch" "[<repository>]" () ()))

; One branch of the remote fetched: (LINE-PARTS SHA BRANCH), the
; line () when the ref did not move.
(def %fetch-branch!
  (fn (_ gitdir sgit remote b)
    (def new (git-ref-read sgit (Str8 append "refs/heads/" b)))
    (def tracking (Str8 append "refs/remotes/" remote "/" b))
    (def old (git-ref-read gitdir tracking))
    (%copy-closure! sgit gitdir (list new))
    (def line
      (match
        ((null? old) (list "*" "[new branch]" b (Str8 append remote "/" b) ()))
        ((str=? old new) ())
        ((%ancestor? gitdir old new)
          (list " " (Str8 append (%abbrev old) ".." (%abbrev new)) b (Str8 append remote "/" b) ()))
        (#t (list "+" (Str8 append (%abbrev old) "..." (%abbrev new)) b (Str8 append remote "/" b) "forced update"))))
    (if (null? line) () (%write-ref! gitdir tracking new))
    (list line new b)))

; A tag of the remote taken when it is new here and points into what this
; repository now has: (LINE-PARTS SHA TAG), or ().
(def %fetch-tag!
  (fn (_ gitdir sgit t)
    (def name (Str8 append "refs/tags/" t))
    (def sha (git-ref-read sgit name))
    (if (and (null? (git-ref-read gitdir name)) (%has? gitdir (%peel sgit sha)))
      (do (%copy-closure! sgit gitdir (list sha))
          (%write-ref! gitdir name sha)
          (list (list "*" "[new tag]" t t ()) sha t))
      ())))

(def git-fetch
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-fetch-options ops))
    (def remote (if (null? (Opts operands o)) "origin" (first (Opts operands o))))
    (def url (if (null? gitdir) () (git-config-get gitdir (Str8 append "remote \"" remote "\"") "url")))
    (def sgit (%remote-gitdir wd url))
    (match
      ((Opts help? git-fetch-options ops) (list (lit out) (Opts usage git-fetch-options) 0))
      ((null? gitdir) (%not-a-repo))
      ((null? sgit) (%no-remote remote))
      (#t
        (do
          (def current (%current-branch gitdir))
          ; The branch this one merges from, when it is the remote's: listed
          ; first, and the one FETCH_HEAD does not mark not-for-merge.
          (def merge
            (if (and (not (null? current))
                     (str=? remote (or (git-config-get gitdir (Str8 append "branch \"" current "\"") "remote") "")))
              (%strip-heads (or (git-config-get gitdir (Str8 append "branch \"" current "\"") "merge") ""))
              ""))
          (def all (%sorted (git-refs-under sgit "refs/heads/")))
          (def branches
            (if (List any? (fn (_ b) (str=? b merge)) all)
              (pair merge (List filter (fn (_ b) (not (str=? b merge))) all))
              all))
          (def fetched (List map (fn (_ b) (%fetch-branch! gitdir sgit remote b)) branches))
          (def tags
            (List filter (fn (_ l) (not (null? l)))
              (List map (fn (_ t) (%fetch-tag! gitdir sgit t)) (%sorted (git-refs-under sgit "refs/tags/")))))
          (def lines (List append (List filter (fn (_ l) (not (null? l))) (List map first fetched)) (List map first tags)))
          (def width
            (List fold (fn (_ w l) (if (> (Str8 length (first (rest (rest l)))) w) (Str8 length (first (rest (rest l)))) w))
              10 lines))
          (def fetch-head (Str8 append gitdir "/FETCH_HEAD"))
          (if (File exists? fetch-head) (File unlink fetch-head) ())
          ; Every branch fetched, then the tags taken with them.
          (File write-all fetch-head
            (Str8 join ""
              (List append
                (List map
                  (fn (_ f)
                    (Str8 append (first (rest f)) "\t" (if (str=? (first (rest (rest f))) merge) "" "not-for-merge") "\t"
                      "branch '" (first (rest (rest f))) "' of " url "\n"))
                  fetched)
                (List map
                  (fn (_ t) (Str8 append (first (rest t)) "\tnot-for-merge\ttag '" (first (rest (rest t))) "' of " url "\n"))
                  tags))))
          (list (lit err)
            (if (null? lines) ""
              (Str8 append "From " url "\n"
                (Str8 join ""
                  (List map (fn (_ l) (%report-line (first l) (first (rest l)) (first (rest (rest l))) width
                                        (first (rest (rest (rest l)))) (first (rest (rest (rest (rest l)))))))
                    lines))))
            0))))))

; --- push ---

(def git-push-options
  (Opts declare "git push" "[<repository> [<branch>]]" () ()))

(def %hint (fn (_ lines) (Str8 join "" (List map (fn (_ l) (Str8 append "hint: " l "\n")) lines))))

(def %advice-fetch-first
  (list "Updates were rejected because the remote contains work that you do not"
        "have locally. This is usually caused by another repository pushing to"
        "the same ref. If you want to integrate the remote changes, use"
        "'git pull' before pushing again."
        "See the 'Note about fast-forwards' in 'git push --help' for details."))

(def %advice-pull-before-push
  (list "Updates were rejected because the tip of your current branch is behind"
        "its remote counterpart. If you want to integrate the remote changes,"
        "use 'git pull' before pushing again."
        "See the 'Note about fast-forwards' in 'git push --help' for details."))

(def %advice-checkout-pull-push
  (list "Updates were rejected because a pushed branch tip is behind its remote"
        "counterpart. If you want to integrate the remote changes, use 'git pull'"
        "before pushing again."
        "See the 'Note about fast-forwards' in 'git push --help' for details."))

(def %deny-current
  (list "By default, updating the current branch in a non-bare repository"
        "is denied, because it will make the index and work tree inconsistent"
        "with what you pushed, and will require 'git reset --hard' to match"
        "the work tree to HEAD."
        ""
        "You can set the 'receive.denyCurrentBranch' configuration variable"
        "to 'ignore' or 'warn' in the remote repository to allow pushing into"
        "its current branch; however, this is not recommended unless you"
        "arranged to update its work tree to match what you pushed in some"
        "other way."
        ""
        "To squelch this message and still keep the default behaviour, set"
        "'receive.denyCurrentBranch' configuration variable to 'refuse'."))

(def %failed (fn (_ url) (Str8 append "error: failed to push some refs to '" url "'\n")))

(def %rejected
  (fn (_ url src dst msg advice)
    (list (lit err)
      (Str8 append "To " url "\n" (%report-line "!" "[rejected]" src 0 dst msg) (%failed url) (%hint advice))
      1)))

(def %no-upstream
  (fn (_ branch remote)
    (%fatal
      (Str8 append "The current branch " branch " has no upstream branch.\n"
        "To push the current branch and set the remote as upstream, use\n\n"
        "    git push --set-upstream " remote " " branch "\n\n"
        "To have this happen automatically for branches without a tracking\n"
        "upstream, see 'push.autoSetupRemote' in 'git help config'.\n"))))

; One branch sent: src here to dst there.
(def %push-branch!
  (fn (_ gitdir dgit url remote src dst current?)
    (def new (git-ref-read gitdir (Str8 append "refs/heads/" src)))
    (def old (git-ref-read dgit (Str8 append "refs/heads/" dst)))
    (def bare? (not (Str8 ends? "/.git" dgit)))
    (match
      ((null? new)
        (list (lit err) (Str8 append "error: src refspec " src " does not match any\n" (%failed url)) 1))
      ((and (not (null? old)) (str=? old new)) (list (lit err) "Everything up-to-date\n" 0))
      ((and (not (null? old)) (not (%has? gitdir old)))
        (%rejected url src dst "fetch first" %advice-fetch-first))
      ((and (not (null? old)) (not (%ancestor? gitdir old new)))
        (%rejected url src dst "non-fast-forward" (if current? %advice-pull-before-push %advice-checkout-pull-push)))
      ((and (not bare?) (str=? (or (%current-branch dgit) "") dst))
        (do (%copy-closure! gitdir dgit (list new))
            (list (lit err)
              (Str8 append
                "remote: error: refusing to update checked out branch: refs/heads/" dst "\n"
                (Str8 join "" (List map (fn (_ l) (Str8 append "remote: error: " l "\n")) %deny-current))
                "To " url "\n"
                (%report-line "!" "[remote rejected]" src 0 dst "branch is currently checked out")
                (%failed url))
              1)))
      (#t
        (do (%copy-closure! gitdir dgit (list new))
            (%write-ref! dgit (Str8 append "refs/heads/" dst) new)
            (%write-ref! gitdir (Str8 append "refs/remotes/" remote "/" dst) new)
            (list (lit err)
              (Str8 append "To " url "\n"
                (if (null? old)
                  (%report-line "*" "[new branch]" src 0 dst ())
                  (%report-line " " (Str8 append (%abbrev old) ".." (%abbrev new)) src 0 dst ())))
              0))))))

(def git-push
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-push-options ops))
    (def operands (Opts operands o))
    (def current (if (null? gitdir) () (%current-branch gitdir)))
    (def section (if (null? current) "" (Str8 append "branch \"" current "\"")))
    (def remote
      (match
        ((not (null? operands)) (first operands))
        ((null? gitdir) "origin")
        (#t (or (git-config-get gitdir section "remote") "origin"))))
    (def upstream (if (null? gitdir) () (git-config-get gitdir section "merge")))
    (def url (if (null? gitdir) () (git-config-get gitdir (Str8 append "remote \"" remote "\"") "url")))
    (def dgit (%remote-gitdir wd url))
    ; The branch named after the repository, or ().
    (def branch (if (or (null? operands) (null? (rest operands))) () (first (rest operands))))
    (match
      ((Opts help? git-push-options ops) (list (lit out) (Opts usage git-push-options) 0))
      ((null? gitdir) (%not-a-repo))
      ((and (null? current) (null? branch)) (%fatal "You are not currently on a branch."))
      ((and (null? operands) (null? upstream)) (%no-upstream current remote))
      ((null? dgit) (%no-remote remote))
      ((not (null? branch))
        (%push-branch! gitdir dgit url remote branch branch
          (str=? branch (or current ""))))
      ((null? operands) (%push-branch! gitdir dgit url remote current (%strip-heads upstream) #t))
      (#t (%push-branch! gitdir dgit url remote current current #t)))))

(provide git/remote git-fetch git-fetch-options git-push git-push-options)
