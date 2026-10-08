; # x-git -- git on x-lang
;
; ## git/repo.x -- init, branch and tag
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A repository made (the .git layout git makes, the branch HEAD names
; given), and the refs under refs/heads and refs/tags listed, made and
; deleted, loose or packed.  The words are git's.

(module git/repo)

(import x/sys/opts Opts)
(import x/sys/file File)
(import x/sys/posix Sys)
(import git/objects git-write-file!)
(import git/refs git-ref-read git-rev-parse git-commit-of)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))
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

; --- init ---

(def git-init-options
  (Opts declare "git init" "[-b <branch>] [<directory>]" ()
    (list
      (Opts arg "-b" "--initial-branch" "<branch>" "The name of the first branch; master when not given"))))

(def %mkdir-p
  (fn (_ path) (unless (File exists? path) (File mkdir path))))

(def %core-config
  "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n")

; The .git layout made under dir, HEAD naming branch; answers whether it
; was there already (then nothing but the directories is touched).
(def git-init-layout!
  (fn (_ dir branch)
    (def g (Str8 append dir "/.git"))
    (def again? (File exists? g))
    (%mkdir-p dir)
    (%mkdir-p g)
    (List for-each (fn (_ d) (%mkdir-p (Str8 append g "/" d)))
      (list "objects" "objects/info" "objects/pack" "refs" "refs/heads" "refs/tags" "hooks" "info"))
    (unless again?
      (do (File write-all (Str8 append g "/HEAD") (Str8 append "ref: refs/heads/" branch "\n"))
          (File write-all (Str8 append g "/config") %core-config)
          (File write-all (Str8 append g "/description")
            "Unnamed repository; edit this file 'description' to name the repository.\n")))
    again?))

(def git-init
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-init-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-init-options ops) (list (lit out) (Opts usage git-init-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-init-options)))
      (#t
        (let ((dir (if (null? operands) wd
                     (if (Str8 starts? "/" (first operands)) (first operands) (Str8 append wd "/" (first operands))))))
          (let ((again? (git-init-layout! dir (Opts value o "-b" "master"))))
            (list (lit out)
              (Str8 append (if again? "Reinitialized existing" "Initialized empty") " Git repository in " dir "/.git/\n")
              0)))))))

; --- branch and tag ---

; The refs under a prefix (refs/heads/, refs/tags/), by name, loose and
; packed together, each once, sorted.
(def %refs-under
  (fn (_ gitdir prefix)
    (def dir (Str8 append gitdir "/" prefix))
    (def loose
      (if (File exists? dir)
        ((fn (self d p)
           (List flat-map
             (fn (_ name)
               (let ((full (Str8 append d "/" name)))
                 (if (eq? (File type full) (lit dir)) (self full (Str8 append p name "/")) (list (Str8 append p name)))))
             (File list-dir d)))
         dir "")
        ()))
    (def packed-path (Str8 append gitdir "/packed-refs"))
    (def packed
      (if (not (File exists? packed-path)) ()
        (List flat-map
          (fn (_ l)
            (if (and (> (Str8 length l) 41) (not (Str8 starts? "#" l)) (not (Str8 starts? "^" l))
                     (Str8 starts? prefix (Str8 sub 41 (%sub (Str8 length l) 41) l)))
              (list (Str8 sub (%add 41 (Str8 length prefix)) (%sub (Str8 length l) (%add 41 (Str8 length prefix))) l))
              ()))
          (Str8 split "\n" (File read-all packed-path)))))
    (List sort (fn (_ a b) (Str8 <? a b))
      ((fn (self ns acc) (if (null? ns) acc (self (rest ns) (if (List any? (fn (_ a) (str=? a (first ns))) acc) acc (pair (first ns) acc)))))
       (List append loose packed) ()))))

; A packed ref's line taken out of packed-refs, its peeled line too.
(def %unpack-ref!
  (fn (_ gitdir full)
    (def path (Str8 append gitdir "/packed-refs"))
    (when (File exists? path)
      (let ((lines (Str8 split "\n" (File read-all path))))
        (let ((kept
                ((fn (self ls drop-peel acc)
                   (match
                     ((null? ls) (List reverse acc))
                     ((and drop-peel (Str8 starts? "^" (first ls))) (self (rest ls) #f acc))
                     ((and (> (Str8 length (first ls)) 41) (str=? (Str8 sub 41 (%sub (Str8 length (first ls)) 41) (first ls)) full))
                       (self (rest ls) #t acc))
                     (#t (self (rest ls) #f (pair (first ls) acc)))))
                 lines #f ())))
          (File write-all path (Str8 join "\n" kept)))))))

(def %current-branch
  (fn (_ gitdir)
    (def head (Str8 trim (File read-all (Str8 append gitdir "/HEAD"))))
    (if (Str8 starts? "ref: refs/heads/" head) (Str8 sub 16 (%sub (Str8 length head) 16) head) ())))

; A ref made at a revision's object, or deleted; the list of them when
; nothing is named.  kind is "branch" or "tag", prefix its directory.
(def %ref-command
  (fn (_ gitdir kind prefix usage o)
    (def operands (Opts operands o))
    (def current (%current-branch gitdir))
    (match
      ((Opts on? o "-d")
        (if (null? operands) (list (lit err) (Str8 append "fatal: " kind " name required\n") 128)
          (let ((name (first operands)))
            (let ((full (Str8 append prefix name)))
             (let ((sha (git-ref-read gitdir full)))
              (match
                ((null? sha)
                  (list (lit err)
                    (if (str=? kind "branch")
                      (Str8 append "error: branch '" name "' not found.\n")
                      (Str8 append "error: tag '" name "' not found.\n"))
                    1))
                ((and (str=? kind "branch") (not (null? current)) (str=? current name))
                  (list (lit err) (Str8 append "error: cannot delete branch '" name "' used by worktree\n") 1))
                (#t
                  (do (when (File exists? (Str8 append gitdir "/" full)) (File unlink (Str8 append gitdir "/" full)))
                      (%unpack-ref! gitdir full)
                      (list (lit out)
                        (if (str=? kind "branch")
                          (Str8 append "Deleted branch " name " (was " (Str8 sub 0 7 sha) ").\n")
                          (Str8 append "Deleted tag '" name "' (was " (Str8 sub 0 7 sha) ")\n"))
                        0)))))))))
      ((null? operands)
        (list (lit out)
          (Str8 join ""
            (List map
              (fn (_ n) (if (str=? kind "branch")
                          (Str8 append (if (and (not (null? current)) (str=? current n)) "* " "  ") n "\n")
                          (Str8 append n "\n")))
              (%refs-under gitdir prefix)))
          0))
      (#t
        (let ((name (first operands))
              (start (if (null? (rest operands)) "HEAD" (first (rest operands)))))
          (let ((sha (if (str=? kind "branch") (git-commit-of gitdir start) (git-rev-parse gitdir start))))
            (match
              ((not (null? (git-ref-read gitdir (Str8 append prefix name))))
                (%fatal (Str8 append (if (str=? kind "branch") "a branch named '" "tag '") name "' already exists")))
              ((null? sha)
                (%fatal (Str8 append "not a valid object name: '" start "'")))
              (#t
                (do (git-write-file! (Str8 append gitdir "/" prefix name) (Str8 append sha "\n") 41)
                    (list (lit out) "" 0))))))))))

(def git-branch-options
  (Opts declare "git branch" "[-d] [<branch> [<start-point>]]" ()
    (list (Opts flag "-d" "--delete" "Delete the branch"))))

(def git-branch
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-branch-options ops))
    (match
      ((Opts help? git-branch-options ops) (list (lit out) (Opts usage git-branch-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-branch-options)))
      ((null? gitdir) (%no-repo))
      (#t (%ref-command gitdir "branch" "refs/heads/" (Opts usage git-branch-options) o)))))

(def git-tag-options
  (Opts declare "git tag" "[-d] [<tag> [<object>]]" ()
    (list (Opts flag "-d" "--delete" "Delete the tag"))))

(def git-tag
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-tag-options ops))
    (match
      ((Opts help? git-tag-options ops) (list (lit out) (Opts usage git-tag-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-tag-options)))
      ((null? gitdir) (%no-repo))
      (#t (%ref-command gitdir "tag" "refs/tags/" (Opts usage git-tag-options) o)))))

; The names under a refs prefix, for clone.
(def git-refs-under
  (fn (_ gitdir prefix) (%refs-under gitdir prefix)))

(provide git/repo git-init git-init-options git-init-layout! git-refs-under
  git-branch git-branch-options git-tag git-tag-options)
