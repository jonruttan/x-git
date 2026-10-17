; # x-git -- git on x-lang
;
; ## git/remote.x -- fetch, push and ls-remote, by path or by wire
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; fetch [<repository>], push [<repository> [<branch>]] and ls-remote
; [<repository>].  A remote named by a path is read as git reads one over
; its local transport: the objects move as one pack, a walk from each tip
; being sent, through commits' trees and parents, trees' entries and
; tags' objects, that stops at an object the receiving side already has,
; and git/packs writes what it lacks into its objects/pack.  A remote
; named by a url is spoken to over git/protocol: its service advertises,
; and sends the pack this repository negotiates for.  Either way the refs
; are then written as git writes them, and the report is git's, word for
; word.
;
; fetch takes every branch of the remote to refs/remotes/<remote>/, the
; tags that point into what it now has, and FETCH_HEAD; push sends one
; branch, refusing as git does a push that is not a fast-forward, one whose
; remote holds work this repository has not seen, and one into the branch
; a non-bare remote has checked out -- by path, or by url to receive-pack,
; which takes the pack of what it lacks and reports what it did.

(module git/remote)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/objects git-object-read git-object-text git-tree-entries)
(import git/packs git-pack-has? git-pack-write! git-pack-bytes git-pack-index!)
(import git/refs git-ref-read)
(import git/repo git-refs-under)
(import git/stage git-config-get)
(import git/clone git-source-gitdir)
(import git/protocol proto-url? proto-connect proto-advertise proto-fetch! proto-push! proto-remote-lines proto-cannot-read)
(import git/wire wire-close! wire-flush!)
(import x/type/vector Vector)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))

(def %not-a-repo
  (fn (_) (%fatal "not a git repository (or any of the parent directories): .git")))

(def %cannot-read proto-cannot-read)

(def %no-remote
  (fn (_ name)
    (list (lit err)
      (Str8 append "fatal: '" name "' does not appear to be a git repository\n" %cannot-read)
      128)))

; The service on the wire said nothing: it has said why on its own
; standard error, as git's does; this is the rest of what git prints.
(def %not-read (fn (_) (list (lit err) %cannot-read 128)))

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

; The objects an object names, with the path each is at, (SHA . PATH):
; a commit's tree and parents, a tree's entries but its submodules, a
; tag's object.  A tree's entries are under name, its own path; what a
; commit or a tag names is at none.
(def %named-children
  (fn (_ o name)
    (def at (fn (_ sha) (pair sha "")))
    (match
      ((str=? (first o) "commit") (List map at (List append (%header-values o "tree") (%header-values o "parent"))))
      ((str=? (first o) "tree")
        (List map (fn (_ e) (pair (first (rest (rest e)))
                                  (if (str=? name "") (first (rest e)) (Str8 append name "/" (first (rest e))))))
          (List filter (fn (_ e) (not (str=? (first e) "160000"))) (git-tree-entries o))))
      ((str=? (first o) "tag") (List map at (%header-values o "object")))
      (#t ()))))

; An object row with the path it was found at.
(def %row (fn (_ sha o name) (pair sha (List append o (list name)))))

; Every object reachable from the work list that `to` lacks, read from
; `from`: (SHA TYPE SIZE REGION START PATH) each, each once.  An object
; `to` has is taken to come with everything it names, as it does in any
; repository git wrote.  The work list is (SHA . PATH) each.
(def %closure
  (fn (self from to work seen acc)
    (match
      ((null? work) (List reverse acc))
      ((or (%has? to (first (first work))) (List any? (fn (_ s) (str=? s (first (first work)))) seen))
        (self from to (rest work) seen acc))
      (#t
        (do (def sha (first (first work)))
            (def o (git-object-read from sha))
            (self from to (List append (%named-children o (rest (first work))) (rest work)) (pair sha seen)
                  (pair (%row sha o (rest (first work))) acc)))))))

; What `to` lacks of the objects behind the tips, sent as one pack; none
; when it has them all.
(def %send!
  (fn (_ from to tips)
    (def objects (%closure from to (List map (fn (_ t) (pair t "")) tips) () ()))
    (if (null? objects) () (git-pack-write! to objects))))

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

; --- the remote, by path or by wire ---
;
; A source is what fetch needs of a remote, however it is reached:
; (REFS PEELED BRING! DONE!) -- REFS its refs as (NAME . SHA), PEELED
; each annotated tag's name with what it finally names, BRING! a function
; of object names that brings them, and everything behind them, here,
; DONE! what to call when fetch is through with it.

(def %lookup
  (fn (_ name alist)
    (def hit (List find (fn (_ e) (str=? (first e) name)) alist))
    (if (null? hit) () (rest hit))))

(def %ref-names
  (fn (_ gitdir prefix) (List map (fn (_ n) (Str8 append prefix n)) (git-refs-under gitdir prefix))))

; A repository on a path: its refs read from its files, its objects
; copied as a pack.
(def %path-source
  (fn (_ gitdir sgit)
    (def names (List append (%ref-names sgit "refs/heads/") (%ref-names sgit "refs/tags/")))
    (def refs (List map (fn (_ n) (pair n (git-ref-read sgit n))) names))
    (list refs
          (List filter (fn (_ e) (not (null? e)))
            (List map (fn (_ e) (let ((p (%peel sgit (rest e)))) (if (str=? p (rest e)) () (pair (first e) p))))
              (List filter (fn (_ e) (Str8 starts? "refs/tags/" (first e))) refs)))
          (fn (_ shas) (%send! sgit gitdir shas))
          (fn (_) ()))))

; The commits this repository has, for the wire: its branches, remote
; branches and tags, the tags peeled.
(def %local-tips
  (fn (_ gitdir)
    (List map (fn (_ n) (%peel gitdir (git-ref-read gitdir n)))
      (List append (%ref-names gitdir "refs/heads/")
        (List append (%ref-names gitdir "refs/remotes/") (%ref-names gitdir "refs/tags/"))))))

; A commit's parents, () for an object this repository lacks or that is
; no commit.
(def %parents-of
  (fn (_ gitdir)
    (fn (_ sha)
      (def o (git-object-read gitdir sha))
      (if (and (not (null? o)) (str=? (first o) "commit")) (%header-values o "parent") ()))))

; The objects behind the names this repository lacks, fetched from the
; service on an open wire and indexed; the wire is closed.
(def %fetch-wire!
  (fn (_ gitdir w shas)
    (def wants (List filter (fn (_ sha) (not (%has? gitdir sha))) shas))
    (def pack (proto-fetch! w wants (%local-tips gitdir) (%parents-of gitdir)))
    (wire-close! w)
    (unless (null? pack)
      (git-pack-index! gitdir (first pack) (rest pack) (fn (_ sha) (git-object-read gitdir sha))))))

; A repository a url names, its service spoken to on a wire: the
; advertisement read now, the objects brought on this connection the
; first time and on a fresh one after.  () when the service said nothing.
(def %wire-source
  (fn (_ gitdir url)
    (def w (proto-connect url "upload-pack" gitdir))
    (def adv (proto-advertise w))
    (if (null? adv) (do (wire-close! w) ())
      (let ((open (Vector make 1 w))
            (refs (List filter (fn (_ e) (not (Str8 ends? "^{}" (first e)))) (first adv)))
            (peeled (List map (fn (_ e) (pair (Str8 sub 0 (%sub (Str8 length (first e)) 3) (first e)) (rest e)))
                      (List filter (fn (_ e) (Str8 ends? "^{}" (first e))) (first adv)))))
        (list refs peeled
              (fn (_ shas)
                (def w2 (if (null? (%oref open 1)) (proto-connect url "upload-pack" gitdir) (%oref open 1)))
                (when (null? (%oref open 1))
                  (when (null? (proto-advertise w2)) (do (wire-close! w2) (%fail "the remote went away"))))
                (%oset! open 1 ())
                (%fetch-wire! gitdir w2 shas))
              ; the connection never used for objects told there is nothing
              ; wanted of it
              (fn (_)
                (unless (null? (%oref open 1))
                  (do (wire-flush! (%oref open 1)) (wire-close! (%oref open 1)) (%oset! open 1 ())))))))))

(def %oref (prim-ref (lit obj) (lit ref)))
(def %oset! (prim-ref (lit obj) (lit set!)))
(def %fail (fn (_ what) (Err raise (lit value) (Str8 append "git: " what) ())))

; The source a remote's url names: by wire for a url, by path for a
; path; () when there is no repository there.
(def %source
  (fn (_ wd gitdir url)
    (match
      ((null? url) ())
      ((proto-url? url) (%wire-source gitdir url))
      (#t (let ((sgit (%remote-gitdir wd url))) (if (null? sgit) () (%path-source gitdir sgit)))))))

; --- fetch ---

(def git-fetch-options
  (Opts declare "git fetch" "[<repository>]" () ()))

; One branch of the remote fetched: (LINE-PARTS SHA BRANCH), the
; line () when the ref did not move.
(def %fetch-branch!
  (fn (_ gitdir new remote b)
    (def tracking (Str8 append "refs/remotes/" remote "/" b))
    (def old (git-ref-read gitdir tracking))
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
  (fn (_ gitdir src name sha)
    (def t (Str8 sub 10 (%sub (Str8 length name) 10) name))
    (def target (or (%lookup name (first (rest src))) sha))
    (if (and (null? (git-ref-read gitdir name)) (%has? gitdir target))
      (do (unless (%has? gitdir sha) ((first (rest (rest src))) (list sha)))
          (%write-ref! gitdir name sha)
          (list (list "*" "[new tag]" t t ()) sha t))
      ())))

; A url as fetch shows it, in its report and in FETCH_HEAD: trailing
; slashes dropped, then a trailing .git.
(def %shown-url
  (fn (_ url)
    (def n ((fn (self k) (if (and (> k 0) (str=? (Str8 sub (%sub k 1) 1 url) "/")) (self (%sub k 1)) k)) (Str8 length url)))
    (if (and (> n 4) (str=? (Str8 sub (%sub n 4) 4 url) ".git"))
      (Str8 sub 0 (%sub n 4) url)
      (Str8 sub 0 n url))))

(def git-fetch
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-fetch-options ops))
    (def remote (if (null? (Opts operands o)) "origin" (first (Opts operands o))))
    (def url (if (null? gitdir) () (git-config-get gitdir (Str8 append "remote \"" remote "\"") "url")))
    (def src (if (null? gitdir) () (%source wd gitdir url)))
    (match
      ((Opts help? git-fetch-options ops) (list (lit out) (Opts usage git-fetch-options) 0))
      ((null? gitdir) (%not-a-repo))
      ((and (null? src) (proto-url? url)) (%not-read))
      ((null? src) (%no-remote remote))
      (#t
        (do
          (def refs (first src))
          (def bring! (first (rest (rest src))))
          (def current (%current-branch gitdir))
          ; The branch this one merges from, when it is the remote's: listed
          ; first, and the one FETCH_HEAD does not mark not-for-merge.
          (def merge
            (if (and (not (null? current))
                     (str=? remote (or (git-config-get gitdir (Str8 append "branch \"" current "\"") "remote") "")))
              (%strip-heads (or (git-config-get gitdir (Str8 append "branch \"" current "\"") "merge") ""))
              ""))
          (def all
            (%sorted (List map (fn (_ e) (%strip-heads (first e)))
                       (List filter (fn (_ e) (Str8 starts? "refs/heads/" (first e))) refs))))
          (def branches
            (if (List any? (fn (_ b) (str=? b merge)) all)
              (pair merge (List filter (fn (_ b) (not (str=? b merge))) all))
              all))
          ; every branch's objects in one pack, then the refs
          (bring! (List map (fn (_ b) (%lookup (Str8 append "refs/heads/" b) refs)) branches))
          (def fetched
            (List map (fn (_ b) (%fetch-branch! gitdir (%lookup (Str8 append "refs/heads/" b) refs) remote b)) branches))
          (def tags
            (List filter (fn (_ l) (not (null? l)))
              (List map (fn (_ e) (%fetch-tag! gitdir src (first e) (rest e)))
                (List sort (fn (_ a b) (Str8 <? (first a) (first b)))
                  (List filter (fn (_ e) (Str8 starts? "refs/tags/" (first e))) refs)))))
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
                      "branch '" (first (rest (rest f))) "' of " (%shown-url url) "\n"))
                  fetched)
                (List map
                  (fn (_ t) (Str8 append (first (rest t)) "\tnot-for-merge\ttag '" (first (rest (rest t))) "' of " (%shown-url url) "\n"))
                  tags))))
          ((first (rest (rest (rest src)))))
          (list (lit err)
            (if (null? lines) ""
              (Str8 append "From " (%shown-url url) "\n"
                (Str8 join ""
                  (List map (fn (_ l) (%report-line (first l) (first (rest l)) (first (rest (rest l))) width
                                        (first (rest (rest (rest l)))) (first (rest (rest (rest (rest l)))))))
                    lines))))
            0))))))

; --- ls-remote ---

(def git-ls-remote-options
  (Opts declare "git ls-remote" "[<repository>]" () ()))

; What git-upload-pack advertises for a repository on a path: HEAD, then
; every ref in name order, an annotated tag followed by what it names
; as "NAME^{}"; each (NAME . SHA).
(def %advertised
  (fn (_ sgit)
    (def head (git-ref-read sgit "HEAD"))
    (List append (if (null? head) () (list (pair "HEAD" head)))
      (List flat-map
        (fn (_ n)
          (def sha (git-ref-read sgit n))
          (def p (if (Str8 starts? "refs/tags/" n) (%peel sgit sha) sha))
          (if (str=? p sha) (list (pair n sha)) (list (pair n sha) (pair (Str8 append n "^{}") p))))
        (%sorted (%ref-names sgit "refs/"))))))

(def %ref-lines
  (fn (_ refs) (Str8 join "" (List map (fn (_ e) (Str8 append (rest e) "\t" (first e) "\n")) refs))))

; The refs a remote has, as its service advertises them: the remote
; named, or a url or path given.
(def git-ls-remote
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-ls-remote-options ops))
    (def operand (if (null? (Opts operands o)) "origin" (first (Opts operands o))))
    (def configured (if (null? gitdir) () (git-config-get gitdir (Str8 append "remote \"" operand "\"") "url")))
    (def url (if (null? configured) operand configured))
    (match
      ((Opts help? git-ls-remote-options ops) (list (lit out) (Opts usage git-ls-remote-options) 0))
      ((proto-url? url)
        (let ((w (proto-connect url "upload-pack" gitdir)))
          (let ((adv (proto-advertise w)))
            (do (unless (null? adv) (wire-flush! w))
                (wire-close! w)
                (if (null? adv) (%not-read) (list (lit out) (%ref-lines (first adv)) 0))))))
      (#t
        (let ((sgit (%remote-gitdir wd url)))
          (if (null? sgit) (%no-remote operand) (list (lit out) (%ref-lines (%advertised sgit)) 0)))))))

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

; What receive-pack says, on band 2, when a non-bare remote's checked-out
; branch is pushed to.
(def %deny-current
  (fn (_ dst)
    (Str8 append
      "error: refusing to update checked out branch: refs/heads/" dst "\n"
      "error: By default, updating the current branch in a non-bare repository\n"
      "is denied, because it will make the index and work tree inconsistent\n"
      "with what you pushed, and will require 'git reset --hard' to match\n"
      "the work tree to HEAD.\n"
      "\n"
      "You can set the 'receive.denyCurrentBranch' configuration variable\n"
      "to 'ignore' or 'warn' in the remote repository to allow pushing into\n"
      "its current branch; however, this is not recommended unless you\n"
      "arranged to update its work tree to match what you pushed in some\n"
      "other way.\n"
      "\n"
      "To squelch this message and still keep the default behaviour, set\n"
      "'receive.denyCurrentBranch' configuration variable to 'refuse'.\n")))

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

; --- the remote pushed to, by path or by wire ---
;
; A destination is what push needs of a remote, however it is reached:
; (REFS DELIVER! DONE!) -- REFS its refs as (NAME . SHA), DELIVER! a
; function of (OLD NEW NAME) that sends the objects behind NEW and asks
; for the ref to move, answering (REMOTE . REASON): the remote's words as
; git prints them, and () when the ref moved or why it did not; DONE!
; what to call when push sends nothing after all.

(def %ZERO "0000000000000000000000000000000000000000")

; A repository on a path: its refs read from its files, the objects it
; lacks written as a pack, the ref written -- unless it is the branch a
; non-bare repository has checked out, refused as receive-pack refuses
; it, after the objects landed.
(def %path-destination
  (fn (_ gitdir dgit)
    (def bare? (not (Str8 ends? "/.git" dgit)))
    (list (List map (fn (_ n) (pair n (git-ref-read dgit n))) (%ref-names dgit "refs/"))
          (fn (_ old new name)
            (def dst (%strip-heads name))
            (%send! gitdir dgit (list new))
            (if (and (not bare?) (str=? (or (%current-branch dgit) "") dst))
              (pair (proto-remote-lines (%deny-current dst)) "branch is currently checked out")
              (do (%write-ref! dgit name new) (pair "" ()))))
          (fn (_) ()))))

(def %member? (fn (_ s l) (List any? (fn (_ x) (str=? x s)) l)))

; Every object behind the tips that a remote holding the stop commits
; lacks, and the objects it has that a thin pack may build on: (SEND .
; BASES), object rows (SHA TYPE SIZE REGION START PATH) each.  The
; commits behind a stop are the remote's, and so is the snapshot of each
; commit the walk stops at -- its tree and everything under it.  What an
; older snapshot shares with a newer one and nothing else may travel
; again; the remote keeps one copy.  The bases are the trees and blobs
; of those snapshots at the paths of trees and blobs sent, as git's
; preferred bases are.
(def %objects-to-send
  (fn (_ gitdir tips stops)
    (def parents (%parents-of gitdir))
    (def known
      ((fn (self work seen)
         (match
           ((null? work) seen)
           ((%member? (first work) seen) (self (rest work) seen))
           (#t (self (List append (rest work) (parents (first work))) (pair (first work) seen)))))
       stops ()))
    ; the snapshot's trees and blobs, (SHA . PATH) each, on acc
    (def snapshot
      (fn (_ sha acc)
        (def o (git-object-read gitdir sha))
        ((fn (self work acc)
           (match
             ((null? work) acc)
             ((List any? (fn (_ e) (str=? (first e) (first (first work)))) acc) (self (rest work) acc))
             (#t (let ((t (git-object-read gitdir (first (first work)))))
                   (self (List append (if (and (not (null? t)) (str=? (first t) "tree")) (%named-children t (rest (first work))) ())
                                      (rest work))
                         (pair (first work) acc))))))
         (if (and (not (null? o)) (str=? (first o) "commit")) (List map (fn (_ t) (pair t "")) (%header-values o "tree")) ())
         acc)))
    (def found
      ((fn (self work seen excluded acc)
         (match
           ((null? work) (pair (List reverse acc) excluded))
           ((or (%member? (first (first work)) seen) (List any? (fn (_ e) (str=? (first e) (first (first work)))) excluded))
             (self (rest work) seen excluded acc))
           ((%member? (first (first work)) known)
             (self (rest work) (pair (first (first work)) seen) (snapshot (first (first work)) excluded) acc))
           (#t (let ((sha (first (first work))) (o (git-object-read gitdir (first (first work)))))
                 (do (when (null? o) (%fail (Str8 append "an object behind what is pushed is missing: " sha)))
                     (self (List append (%named-children o (rest (first work))) (rest work)) (pair sha seen) excluded
                           (pair (%row sha o (rest (first work))) acc)))))))
       (List map (fn (_ t) (pair t "")) tips) () () ()))
    (def paths
      (List map (fn (_ r) (List last r))
        (List filter (fn (_ r) (or (str=? (first (rest r)) "tree") (str=? (first (rest r)) "blob"))) (first found))))
    (pair (first found)
          (List map (fn (_ e) (%row (first e) (git-object-read gitdir (first e)) (rest e)))
            (List filter (fn (_ e) (%member? (rest e) paths)) (rest found))))))

; A repository a url names, its receive-pack spoken to on a wire: the
; advertisement read now; the command, the pack of what it lacks and
; its report on the same connection.
(def %wire-destination
  (fn (_ gitdir url)
    (def w (proto-connect url "receive-pack" gitdir))
    (def adv (proto-advertise w))
    (if (null? adv) (do (wire-close! w) ())
      (let ((refs (List filter (fn (_ e) (not (Str8 ends? "^{}" (first e)))) (first adv))))
        (list refs
              (fn (_ old new name)
                (def stops
                  (List map (fn (_ sha) (%peel gitdir sha))
                    (List filter (fn (_ sha) (%has? gitdir sha)) (List map rest refs))))
                ; thin, as git push sends: receive-pack completes it
                (def objs (%objects-to-send gitdir (list new) stops))
                (def r (proto-push! w (list (list (if (null? old) %ZERO old) new name))
                         (git-pack-bytes (first objs) (rest objs)
                           (List any? (fn (_ c) (str=? c "ofs-delta")) (first (rest adv))))))
                (wire-close! w)
                (def unpack (first (rest r)))
                (def hit (List find (fn (_ e) (str=? (first e) name)) (first (rest (rest r)))))
                (pair (first r)
                      (match
                        ((not (str=? unpack "ok")) (Str8 append "unpacker error: " unpack))
                        ((null? hit) "no report")
                        (#t (rest hit)))))
              (fn (_) (do (wire-flush! w) (wire-close! w))))))))

; The destination a remote's url names: by wire for a url, by path for
; a path; () when there is no repository there.
(def %destination
  (fn (_ wd gitdir url)
    (match
      ((null? url) ())
      ((proto-url? url) (%wire-destination gitdir url))
      (#t (let ((dgit (%remote-gitdir wd url))) (if (null? dgit) () (%path-destination gitdir dgit)))))))

; One branch sent: src here to dst there; remote the name whose
; tracking ref follows, or () for a url or path named outright.
(def %push-branch!
  (fn (_ gitdir dest url remote src dst current?)
    (def new (git-ref-read gitdir (Str8 append "refs/heads/" src)))
    (def name (Str8 append "refs/heads/" dst))
    (def old (%lookup name (first dest)))
    (def deliver! (first (rest dest)))
    (def done! (first (rest (rest dest))))
    (match
      ((null? new)
        (do (done!) (list (lit err) (Str8 append "error: src refspec " src " does not match any\n" (%failed url)) 1)))
      ((and (not (null? old)) (str=? old new)) (do (done!) (list (lit err) "Everything up-to-date\n" 0)))
      ((and (not (null? old)) (not (%has? gitdir old)))
        (do (done!) (%rejected url src dst "fetch first" %advice-fetch-first)))
      ((and (not (null? old)) (not (%ancestor? gitdir old new)))
        (do (done!) (%rejected url src dst "non-fast-forward" (if current? %advice-pull-before-push %advice-checkout-pull-push))))
      (#t
        (let ((r (deliver! old new name)))
          (if (null? (rest r))
            (do (unless (null? remote) (%write-ref! gitdir (Str8 append "refs/remotes/" remote "/" dst) new))
                (list (lit err)
                  (Str8 append (first r) "To " url "\n"
                    (if (null? old)
                      (%report-line "*" "[new branch]" src 0 dst ())
                      (%report-line " " (Str8 append (%abbrev old) ".." (%abbrev new)) src 0 dst ())))
                  0))
            (list (lit err)
              (Str8 append (first r) "To " url "\n"
                (%report-line "!" "[remote rejected]" src 0 dst (rest r))
                (%failed url))
              1)))))))

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
    ; A remote's configured url, or the url or path named outright, which
    ; has no tracking ref to move.
    (def configured (if (null? gitdir) () (git-config-get gitdir (Str8 append "remote \"" remote "\"") "url")))
    (def url (if (null? configured) (if (null? operands) () remote) configured))
    ; The branch named after the repository, or ().
    (def branch (if (or (null? operands) (null? (rest operands))) () (first (rest operands))))
    ; The remote reached only once push has something to say to it.
    (def push!
      (fn (_ src dst current?)
        (def dest (%destination wd gitdir url))
        (match
          ((and (null? dest) (proto-url? url)) (%not-read))
          ((null? dest) (%no-remote remote))
          (#t (%push-branch! gitdir dest url (if (null? configured) () remote) src dst current?)))))
    (match
      ((Opts help? git-push-options ops) (list (lit out) (Opts usage git-push-options) 0))
      ((null? gitdir) (%not-a-repo))
      ((and (null? current) (null? branch)) (%fatal "You are not currently on a branch."))
      ((and (null? operands) (null? upstream)) (%no-upstream current remote))
      ((not (null? branch)) (push! branch branch (str=? branch (or current ""))))
      ((null? operands) (push! current (%strip-heads upstream) #t))
      (#t (push! current current #t)))))

; --- for the services ---

; What git-upload-pack advertises for a repository: HEAD, then its refs
; in name order, an annotated tag followed by what it names.
(def git-advertised (fn (_ gitdir) (%advertised gitdir)))

; The objects behind tips a remote holding stops lacks, and the bases a
; thin pack may name: (SEND . BASES), object rows each.
(def git-objects-to-send (fn (_ gitdir tips stops) (%objects-to-send gitdir tips stops)))

(def git-has-object? (fn (_ gitdir sha) (%has? gitdir sha)))
(def git-peel (fn (_ gitdir sha) (%peel gitdir sha)))
(def git-write-ref! (fn (_ gitdir name sha) (%write-ref! gitdir name sha)))
(def git-current-branch (fn (_ gitdir) (%current-branch gitdir)))
(def git-deny-current (fn (_ dst) (%deny-current dst)))
(def git-ancestor? (fn (_ gitdir a b) (%ancestor? gitdir a b)))

(provide git/remote git-fetch git-fetch-options git-push git-push-options git-ls-remote git-ls-remote-options
  git-advertised git-objects-to-send git-has-object? git-peel git-write-ref! git-current-branch git-deny-current
  git-ancestor?)
