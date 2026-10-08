# @weight 3

clone from a local path, against git itself: the refs fixture (two
commits, packed tags and branches, a loose branch) cloned by x-git and
read by git.

## clone

### the clone git sees: its branches, tags, history, config and clean tree

```git
(def %cl-src (git-fixture-refs))
(def %cl-t (File temp "/tmp/x-git-cl-"))
(File close (first %cl-t))
(File unlink (rest %cl-t))
(def %cl (rest %cl-t))
(def %cl-r (git-run (git-plan (list "clone" %cl-src %cl))))
(write (list (first (rest (rest %cl-r)))
             (str=? (first (rest %cl-r)) (Str8 append "Cloning into '" %cl "'...\ndone.\n"))
             (git-oracle-in %cl "status" "--porcelain")
             (equal? (git-oracle-in %cl "log" "--oneline") (git-oracle-in %cl-src "log" "--oneline"))
             (git-oracle-in %cl "branch" "-a")
             (git-oracle-in %cl "tag")
             (equal? (git-oracle-in %cl "rev-parse" "v1^{}") (git-oracle-in %cl-src "rev-parse" "HEAD~1"))
             (first (git-oracle-in %cl "fsck" "--strict"))
             (Str8 includes? (Str8 append "url = " %cl-src) (File read-all (Str8 append %cl "/.git/config")))
             (git-oracle-in %cl "config" "branch.main.merge")
             (File read-all (Str8 append %cl "/f.txt"))))
```
---
    (0 #t (0 . "") #t (0 . "* main\n  remotes/origin/HEAD -> origin/main\n  remotes/origin/loose\n  remotes/origin/main\n  remotes/origin/side\n") (0 . "light\nv1\n") #t 0 #t (0 . "refs/heads/main\n") "hello\nmore\n")

### x-git reads its own clone too

```git
(def %cl-src (git-fixture-refs))
(def %cl-t (File temp "/tmp/x-git-cl-"))
(File close (first %cl-t))
(File unlink (rest %cl-t))
(def %cl (rest %cl-t))
(git-run (git-plan (list "clone" %cl-src %cl)))
(write (list (equal? (git-text-in %cl "log" "--oneline") (git-oracle-in %cl-src "log" "--oneline"))
             (git-text-in %cl "branch")
             (git-text-in %cl "status" "--porcelain")
             (equal? (git-text-in %cl "rev-parse" "origin/side") (git-oracle-in %cl "rev-parse" "origin/side"))))
```
---
    (#t (0 . "* main\n") (0 . "") #t)

### the refusals, in git's words

The destination here is a file File temp made, which git counts as a
destination that exists and is not an empty directory.

```git
(def %cl-src (git-fixture-refs))
(def %cl-t (File temp "/tmp/x-git-cl-"))
(File close (first %cl-t))
(def %cl (rest %cl-t))
(def %cl-mine (git-run (git-plan (list "clone" %cl-src %cl))))
(def %cl-git (Proc capture (list "/bin/sh" "-c" "exec git clone \"$0\" \"$1\" 2>&1" %cl-src %cl)))
(write (list (git-run (git-plan (list "clone" "/nosuchdir" "/tmp/x-git-never")))
             (first %cl-mine) (first (rest (rest %cl-mine)))
             (str=? (first (rest %cl-mine)) (Str8 append "fatal: destination path '" %cl "' already exists and is not an empty directory.\n"))
             (equal? (list (first (rest %cl-mine)) (first (rest (rest %cl-mine)))) (list (rest %cl-git) (first %cl-git)))))
```
---
    (('err "fatal: repository '/nosuchdir' does not exist\n" 128) 'err 128 #t #t)
