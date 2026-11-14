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
; git prints the "Please commit ..." line only with advice.commitBeforeMerge on
; (a blank line stands where it was); both sides are compared without it.
(def %co-plain (fn (_ r) (pair (first r) (Str8 join "\n" (List filter (fn (_ l) (not (or (str=? l "") (Str8 starts? "Please " l)))) (Str8 split "\n" (rest r)))))))
(write (list %co-r (if (equal? (%co-plain %co-r) (%co-plain %co-g)) #t %co-g)
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

### -q: a switch that works says nothing, a refusal is still told

```git
(def %co (git-fixture-refs))
(write (list (git-text-in %co "checkout" "-q" "side")
             (git-text-in %co "checkout" "-q" "side")
             (git-text-in %co "checkout" "--quiet" "main")
             (git-text-in %co "checkout" "-q" "HEAD~1")
             (git-text-in %co "switch" "-q" "main")
             (git-text-in %co "checkout" "-q" "-b" "hush")
             (git-text-in %co "switch" "--quiet" "-c" "work2")
             (git-text-in %co "switch" "-q" "-c" "work2")
             (git-text-in %co "switch" "-q" "nosuch")
             (git-text-in %co "checkout" "-q" "nosuch")
             (Str8 trim (File read-all (Str8 append %co "/.git/HEAD")))))
(File write-all (Str8 append %co "/f.txt") "dirty\n")
(write (list (first (git-text-in %co "checkout" "-q" "main"))
             (first (git-text-in %co "checkout" "-q" "side"))
             (git-text-in %co "restore" "-q" "f.txt")
             (File read-all (Str8 append %co "/f.txt"))))
```
---
    ((0 . "") (0 . "") (0 . "") (0 . "") (0 . "") (0 . "") (0 . "") (128 . "fatal: a branch named 'work2' already exists\n") (128 . "fatal: invalid reference: nosuch\n") (1 . "error: pathspec 'nosuch' did not match any file(s) known to git\n") "ref: refs/heads/work2")(0 1 (0 . "") "hello\nmore\n")

### changes carried by a switch, and listed after it, as git lists them

A file staged as new and one deleted, neither touched by the move, go
with HEAD to the other branch: the index keeps the new one and the
working directory keeps the deletion.  Each switch lists them on standard
output after what it says; a new branch made at HEAD lists nothing, and
checkout with no operand only lists.

```git
(def %co (git-fixture-refs))
(def %co-clean (git-text-in %co "checkout"))
(File write-all (Str8 append %co "/n.txt") "new\n")
(git-oracle-in %co "add" "n.txt")
(File unlink (Str8 append %co "/sub/g"))
(write (list %co-clean
             (git-text-in %co "checkout")
             (equal? (git-text-in %co "checkout") (git-oracle-in %co "checkout"))
             (git-text-in %co "checkout" "-q")
             (git-text-in %co "checkout" "side")
             (File read-all (Str8 append %co "/f.txt"))
             (File exists? (Str8 append %co "/sub/g"))
             (git-oracle-in %co "status" "--porcelain")
             (git-text-in %co "checkout" "-q" "main")
             (git-text-in %co "checkout" "-b" "carry")
             (git-text-in %co "switch" "-c" "carry2" "side")
             (git-text-in %co "checkout" "carry2")))
```
---
    ((0 . "") (0 . "A\tn.txt\nD\tsub/g\n") #t (0 . "") (0 . "Switched to branch 'side'\nA\tn.txt\nD\tsub/g\n") "hello\n" #f (0 . "A  n.txt\n D sub/g\n") (0 . "") (0 . "Switched to a new branch 'carry'\n") (0 . "Switched to a new branch 'carry2'\nA\tn.txt\nD\tsub/g\n") (0 . "Already on 'carry2'\nA\tn.txt\nD\tsub/g\n"))

## paths in conflict

A merge left in conflict on two paths, `f` and `h`.  What is refused
changes nothing, so git's answer is had in the same repository.

### checkout, switch, restore and merge refuse, in git's words

```git
(def %cf-dir (let ((t (File temp "/tmp/x-git-cf-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(def %cf-sh
  (fn (_ script)
    (Proc run! (list "/bin/sh" "-c"
      (Str8 append "export GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=A GIT_COMMITTER_EMAIL=a@b.c; cd \"$0\" && " script) %cf-dir))))
(%cf-sh (Str8 append "git init -q -b main && echo a>f && echo a>h && echo k>g && git add . && git commit -qm one"
          " && git branch side && git branch other && echo main>f && echo main>h && git commit -qam two"
          " && git checkout -q side && echo side>f && echo side>h && git commit -qam three && git checkout -q main"
          " && { git merge -q side >/dev/null 2>&1; true; }"))
(def %cf-same? (fn (_ . ops) (equal? (apply git-text-in (pair %cf-dir ops)) (apply git-oracle-in (pair %cf-dir ops)))))
(write (list (git-text-in %cf-dir "checkout" "side")
             (git-text-in %cf-dir "switch" "side")
             (git-text-in %cf-dir "checkout" "--" "g" "f" "h")
             (git-text-in %cf-dir "merge" "side")
             (List map (fn (_ ops) (apply %cf-same? ops))
               (list (list "checkout" "side") (list "checkout" "-q" "side") (list "checkout") (list "checkout" "HEAD")
                     (list "checkout" "-b" "w" "side") (list "checkout" "HEAD~1")
                     (list "switch" "other") (list "switch" "-c" "w")
                     (list "checkout" "--" "f" "h") (list "checkout" "h" "g") (list "restore" "g" "f")))
             (git-oracle-in %cf-dir "status" "--porcelain")))
```
---
    ((1 . "error: you need to resolve your current index first\nf: needs merge\nh: needs merge\n") (128 . "fatal: cannot switch branch while merging\nConsider \"git merge --quit\" or \"git worktree add\".\n") (1 . "error: path 'f' is unmerged\nerror: path 'h' is unmerged\n") (128 . "error: Merging is not possible because you have unmerged files.\nhint: Fix them up in the work tree, and then use 'git add/rm <file>'\nhint: as appropriate to mark resolution and make a commit.\nfatal: Exiting because of an unresolved conflict.\n") (#t #t #t #t #t #t #t #t #t #t #t) (0 . "UU f\nUU h\n"))

### a new branch at HEAD is made, and gives the merge up; a pick given up is warned of

```git
(write (list (git-text-in %cf-dir "checkout" "-b" "w")
             (File exists? (Str8 append %cf-dir "/.git/MERGE_HEAD"))
             (git-oracle-in %cf-dir "status" "--porcelain")
             (git-text-in %cf-dir "checkout" "side")))
(%cf-sh "git checkout -q -f main && { git cherry-pick side >/dev/null 2>&1; true; } && echo side>f && echo side>h && git add f h")
(write (list (git-text-in %cf-dir "switch" "other")
             (git-text-in %cf-dir "checkout" "-b" "cp")
             (File exists? (Str8 append %cf-dir "/.git/CHERRY_PICK_HEAD"))))
```
---
    ((0 . "Switched to a new branch 'w'\n") #f (0 . "UU f\nUU h\n") (1 . "error: you need to resolve your current index first\nf: needs merge\nh: needs merge\n"))((128 . "fatal: cannot switch branch while cherry-picking\nConsider \"git cherry-pick --quit\" or \"git worktree add\".\n") (0 . "Switched to a new branch 'cp'\nwarning: cancelling a cherry picking in progress\n") #f)
