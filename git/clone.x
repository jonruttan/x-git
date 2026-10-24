; # x-git -- git on x-lang
;
; ## git/clone.x -- a repository copied from a path or fetched by url
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; clone <repository> [<directory>] makes a repository as git makes one:
; the layout, the source's objects -- copied, loose files and packs
; alike, from a local path; brought as one pack over git/protocol from a
; url -- its branches as refs/remotes/origin/* in packed-refs with
; refs/remotes/origin/HEAD naming the branch its HEAD names, its tags, one
; local branch for that HEAD branch, the remote and branch sections in
; .git/config, and the working directory checked out.  The words are
; git's.

(module git/clone)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/objects git-dir git-write-file! git-object-read)
(import git/refs git-ref-read)
(import git/repo git-init-layout! git-refs-under)
(import git/checkout git-checkout-tree!)
(import git/packs git-pack-index!)
(import git/protocol proto-url? proto-url-path proto-connect proto-advertise proto-cap proto-fetch! proto-unreadable)
(import git/wire wire-close!)

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

(def %lookup
  (fn (_ name alist)
    (def hit (List find (fn (_ e) (str=? (first e) name)) alist))
    (if (null? hit) () (rest hit))))

; The repository's layout and refs from what a service advertised, and
; its objects from the pack the service sends: every branch and tag
; wanted, nothing to say it has.  HEAD's branch is the symref the
; service names, else the first branch at HEAD's commit.
(def %clone-wire!
  (fn (_ url name dest)
    (def w (proto-connect url "upload-pack"))
    (def adv (proto-advertise w))
    (if (null? adv)
      (do (wire-close! w)
          (list (lit err) (Str8 append "Cloning into '" name "'...\n" (proto-unreadable)) 128))
      (let ((refs (List filter (fn (_ e) (not (Str8 ends? "^{}" (first e)))) (first adv)))
            (caps (first (rest adv))))
        (let ((head (%lookup "HEAD" refs))
              (symref (proto-cap caps "symref=HEAD:"))
              (branches (List filter (fn (_ e) (Str8 starts? "refs/heads/" (first e))) refs))
              (tags (List filter (fn (_ e) (Str8 starts? "refs/tags/" (first e))) refs)))
          (let ((branch
                  (match
                    ((not (null? symref)) (if (Str8 starts? "refs/heads/" symref) (Str8 sub 11 (%sub (Str8 length symref) 11) symref) symref))
                    ((null? head) "master")
                    (#t (let ((at (List find (fn (_ e) (str=? (rest e) head)) branches)))
                          (if (null? at) "master" (Str8 sub 11 (%sub (Str8 length (first at)) 11) (first at)))))))
                (g (Str8 append dest "/.git")))
            (do (git-init-layout! dest branch)
                (let ((wants ((fn (self l acc)
                                (if (null? l) (List reverse acc)
                                  (self (rest l) (if (List any? (fn (_ s) (str=? s (rest (first l)))) acc) acc (pair (rest (first l)) acc)))))
                              (List append branches tags) ())))
                  (let ((pack (proto-fetch! w wants () (fn (_ sha) ()))))
                    (do (wire-close! w)
                        (unless (null? pack)
                          (git-pack-index! g (first pack) (rest pack) (fn (_ sha) (git-object-read g sha)))))))
                (File write-all (Str8 append g "/packed-refs")
                  (Str8 append "# pack-refs with: peeled fully-peeled sorted \n"
                    (Str8 join ""
                      (List map (fn (_ e) (Str8 append (rest e) " refs/remotes/origin/" (Str8 sub 11 (%sub (Str8 length (first e)) 11) (first e)) "\n")) branches))
                    (Str8 join "" (List map (fn (_ e) (Str8 append (rest e) " " (first e) "\n")) tags))))
                (unless (File exists? (Str8 append g "/refs/remotes")) (File mkdir (Str8 append g "/refs/remotes")))
                (unless (File exists? (Str8 append g "/refs/remotes/origin")) (File mkdir (Str8 append g "/refs/remotes/origin")))
                (File write-all (Str8 append g "/refs/remotes/origin/HEAD") (Str8 append "ref: refs/remotes/origin/" branch "\n"))
                (let ((sha (%lookup (Str8 append "refs/heads/" branch) refs)))
                  (do (unless (null? sha)
                        (git-write-file! (Str8 append g "/refs/heads/" branch) (Str8 append sha "\n") 41))
                      (File write-all (Str8 append g "/config")
                        (Str8 append (File read-all (Str8 append g "/config"))
                          "[remote \"origin\"]\n\turl = " url "\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
                          "[branch \"" branch "\"]\n\tremote = origin\n\tmerge = refs/heads/" branch "\n"))
                      (unless (null? sha) (git-checkout-tree! dest g sha))
                      (list (lit err)
                        (Str8 append "Cloning into '" name "'...\n"
                          (if (null? refs) "warning: You appear to have cloned an empty repository.\n" ""))
                        0))))))))))

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
                ; a url's directory is named from its path, its host left out
                (name (if (null? (rest operands))
                        (%default-name (if (proto-url? src-arg) (proto-url-path src-arg) src-arg))
                        (first (rest operands)))))
            (let ((sgit (%source-gitdir src))
                  (dest (if (Str8 starts? "/" name) name (Str8 append wd "/" name))))
              (match
                ((and (null? sgit) (not (proto-url? src-arg))) (%fatal (Str8 append "repository '" src-arg "' does not exist")))
                ((and (File exists? dest)
                      (or (not (eq? (File type dest) (lit dir))) (not (null? (File list-dir dest)))))
                  (%fatal (Str8 append "destination path '" name "' already exists and is not an empty directory.")))
                ((proto-url? src-arg) (%clone-wire! src-arg name dest))
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

; The .git a path names, for the modules that read another repository.
(def git-source-gitdir (fn (_ path) (%source-gitdir path)))

(provide git/clone git-clone git-clone-options git-source-gitdir)
