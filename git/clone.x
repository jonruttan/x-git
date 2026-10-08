; # x-git -- git on x-lang
;
; ## git/clone.x -- a repository copied from a path
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; clone <path> [<directory>] makes a repository as git makes one from a
; local path: the layout, the source's objects copied (loose files and
; packs alike), its branches as refs/remotes/origin/* in packed-refs with
; refs/remotes/origin/HEAD naming the branch its HEAD names, its tags, one
; local branch for that HEAD branch, the remote and branch sections in
; .git/config, and the working directory checked out.  The words are
; git's.  Nothing is fetched over a network yet.

(module git/clone)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/objects git-dir git-write-file!)
(import git/refs git-ref-read)
(import git/repo git-init-layout! git-refs-under)
(import git/checkout git-checkout-tree!)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))
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

(def %strip-slash
  (fn (_ s) (if (and (> (Str8 length s) 1) (Str8 ends? "/" s)) (Str8 sub 0 (%sub (Str8 length s) 1) s) s)))

; The name clone gives a directory when none is given: the path's last
; component, less a .git ending.
(def %default-name
  (fn (_ path)
    (def p (%strip-slash path))
    (def i (Str8 last-index-of "/" p))
    (def base (if (null? i) p (Str8 sub (%add i 1) (%sub (Str8 length p) (%add i 1)) p)))
    (if (Str8 ends? ".git" base) (Str8 sub 0 (%sub (Str8 length base) 4) base) base)))

; The source's .git: a working directory's, or the path itself when it is
; one (a bare repository); () when neither.
(def %source-gitdir
  (fn (_ path)
    (match
      ((not (File exists? path)) ())
      ((File exists? (Str8 append path "/.git")) (Str8 append path "/.git"))
      ((and (File exists? (Str8 append path "/HEAD")) (File exists? (Str8 append path "/objects"))) path)
      (#t ()))))

; Every file under a directory copied to the same place under another.
(def %copy-tree!
  (fn (self from to)
    (unless (File exists? to) (File mkdir to))
    (List for-each
      (fn (_ name)
        (let ((f (Str8 append from "/" name)) (t (Str8 append to "/" name)))
          (if (eq? (File type f) (lit dir)) (self f t) (File copy f t))))
      (File list-dir from))))

(def git-clone-options
  (Opts declare "git clone" "<repository> [<directory>]" () ()))

(def git-clone
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-clone-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-clone-options ops) (list (lit out) (Opts usage git-clone-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-clone-options)))
      ((null? operands) (list (lit err) (Opts usage git-clone-options) 129))
      (#t
        (let ((src-arg (first operands)))
          (let ((src (if (Str8 starts? "/" src-arg) src-arg (Str8 append wd "/" src-arg)))
                (name (if (null? (rest operands)) (%default-name src-arg) (first (rest operands)))))
            (let ((sgit (%source-gitdir src))
                  (dest (if (Str8 starts? "/" name) name (Str8 append wd "/" name))))
              (match
                ((null? sgit) (%fatal (Str8 append "repository '" src-arg "' does not exist")))
                ((and (File exists? dest)
                      (or (not (eq? (File type dest) (lit dir))) (not (null? (File list-dir dest)))))
                  (%fatal (Str8 append "destination path '" name "' already exists and is not an empty directory.")))
                (#t
                  (let ((head (Str8 trim (File read-all (Str8 append sgit "/HEAD")))))
                    (let ((branch (if (Str8 starts? "ref: refs/heads/" head) (Str8 sub 16 (%sub (Str8 length head) 16) head) "master")))
                      (let ((g (Str8 append dest "/.git")))
                        (do (git-init-layout! dest branch)
                            ; the objects, loose and packed
                            (%copy-tree! (Str8 append sgit "/objects") (Str8 append g "/objects"))
                            ; the remote's branches, packed; its HEAD, symbolic; its tags
                            (let ((branches (git-refs-under sgit "refs/heads/"))
                                  (tags (git-refs-under sgit "refs/tags/")))
                              (do (File write-all (Str8 append g "/packed-refs")
                                    (Str8 append "# pack-refs with: peeled fully-peeled sorted \n"
                                      (Str8 join ""
                                        (List map (fn (_ b) (Str8 append (git-ref-read sgit (Str8 append "refs/heads/" b)) " refs/remotes/origin/" b "\n")) branches))
                                      (Str8 join ""
                                        (List map (fn (_ t) (Str8 append (git-ref-read sgit (Str8 append "refs/tags/" t)) " refs/tags/" t "\n")) tags))))
                                  (unless (File exists? (Str8 append g "/refs/remotes")) (File mkdir (Str8 append g "/refs/remotes")))
                                  (unless (File exists? (Str8 append g "/refs/remotes/origin")) (File mkdir (Str8 append g "/refs/remotes/origin")))
                                  (File write-all (Str8 append g "/refs/remotes/origin/HEAD") (Str8 append "ref: refs/remotes/origin/" branch "\n"))))
                            ; the local branch for the source's HEAD branch
                            (let ((sha (git-ref-read sgit (Str8 append "refs/heads/" branch))))
                              (do (unless (null? sha)
                                    (git-write-file! (Str8 append g "/refs/heads/" branch) (Str8 append sha "\n") 41))
                                  (File write-all (Str8 append g "/config")
                                    (Str8 append (File read-all (Str8 append g "/config"))
                                      "[remote \"origin\"]\n\turl = " src "\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
                                      "[branch \"" branch "\"]\n\tremote = origin\n\tmerge = refs/heads/" branch "\n"))
                                  (unless (null? sha) (git-checkout-tree! dest g sha))
                                  (list (lit err) (Str8 append "Cloning into '" name "'...\ndone.\n") 0))))))))))))))))

(provide git/clone git-clone git-clone-options)
