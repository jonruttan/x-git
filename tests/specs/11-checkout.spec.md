# @weight 3

checkout, switch and restore, against git itself.  The refs fixture has
two commits (`f.txt` differs between them), branches `main`, `side` and
`loose` (the last two at the first commit), and tags.  Its state is
cumulative down the cases.

## switching branches

### to a branch at the older commit: the file changes, git sees a clean tree

```git
(def %co (git-fixture-refs))
(write (list (git-text-in %co "checkout" "side")
             (Str8 trim (File read-all (Str8 append %co "/.git/HEAD")))
             (File read-all (Str8 append %co "/f.txt"))
             (git-oracle-in %co "status" "--porcelain")
             (equal? (git-text-in %co "ls-files" "--stage") (git-oracle-in %co "ls-files" "--stage"))))
```
---
    ((0 . "Switched to branch 'side'\n") "ref: refs/heads/side" "hello\n" (0 . "") #t)

### back to main, and already there

```git
(def %co (git-fixture-refs))
(write (list (git-text-in %co "switch" "main")
             (File read-all (Str8 append %co "/f.txt"))
             (git-text-in %co "checkout" "main")
             (git-oracle-in %co "status" "--porcelain")))
```
---
    ((0 . "Switched to branch 'main'\n") "hello\nmore\n" (0 . "Already on 'main'\n") (0 . ""))

### a local change the move would overwrite stops it, in git's words

```git
(def %co (git-fixture-refs))
(File write-all (Str8 append %co "/f.txt") "dirty\n")
(def %co-r (git-text-in %co "checkout" "side"))
(def %co-g (git-oracle-in %co "checkout" "side"))
(write (list %co-r (if (equal? %co-r %co-g) #t %co-g)
             (Str8 trim (File read-all (Str8 append %co "/.git/HEAD")))))
```
---
    ((1 . "error: Your local changes to the following files would be overwritten by checkout:\n\tf.txt\nPlease commit your changes or stash them before you switch branches.\nAborting\n") #t "ref: refs/heads/main")

### the file put back from the index: checkout -- and restore

```git
(def %co (git-fixture-refs))
(def %co-a (git-text-in %co "checkout" "--" "f.txt"))
(def %co-after (File read-all (Str8 append %co "/f.txt")))
(File write-all (Str8 append %co "/f.txt") "dirty\n")
(def %co-b (git-text-in %co "restore" "f.txt"))
(write (list %co-a %co-after %co-b (File read-all (Str8 append %co "/f.txt"))
             (git-text-in %co "checkout" "--" "nosuch")
             (equal? (git-text-in %co "checkout" "--" "nosuch") (git-oracle-in %co "checkout" "--" "nosuch"))))
```
---
    ((0 . "") "hello\nmore\n" (0 . "") "hello\nmore\n" (1 . "error: pathspec 'nosuch' did not match any file(s) known to git\n") #t)

### a new branch made and switched to, at a start point

```git
(def %co (git-fixture-refs))
(write (list (git-text-in %co "checkout" "-b" "work" "HEAD~1")
             (Str8 trim (File read-all (Str8 append %co "/.git/HEAD")))
             (equal? (git-oracle-in %co "rev-parse" "work") (git-oracle-in %co "rev-parse" "main~1"))
             (File read-all (Str8 append %co "/f.txt"))
             (git-text-in %co "switch" "-c" "work")
             (git-text-in %co "switch" "main")))
```
---
    ((0 . "Switched to a new branch 'work'\n") "ref: refs/heads/work" #t "hello\n" (128 . "fatal: a branch named 'work' already exists\n") (0 . "Switched to branch 'main'\n"))

### detached at a commit, then back

```git
(def %co (git-fixture-refs))
(def %co-r (git-text-in %co "checkout" "HEAD~1"))
(def %co-head (Str8 trim (File read-all (Str8 append %co "/.git/HEAD"))))
(write (list (first %co-r) (Str8 starts? "Note: switching to 'HEAD~1'." (rest %co-r))
             (Str8 includes? "HEAD is now at " (rest %co-r))
             (= (Str8 length %co-head) 40)
             (equal? (pair 0 (Str8 append %co-head "\n")) (git-oracle-in %co "rev-parse" "main~1"))
             (git-oracle-in %co "status" "--porcelain")
             (git-text-in %co "checkout" "main")))
```
---
    (0 #t #t #t #t (0 . "") (0 . "Switched to branch 'main'\n"))

### a name that is neither branch nor commit nor path

```git
(def %co (git-fixture-refs))
(write (list (git-text-in %co "checkout" "nosuch") (equal? (git-text-in %co "checkout" "nosuch") (git-oracle-in %co "checkout" "nosuch"))))
```
---
    ((1 . "error: pathspec 'nosuch' did not match any file(s) known to git\n") #t)
