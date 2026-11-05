# @weight 3
# @timeout-scale 3

The reflog, against git itself.  The same commands are run twice, by
x-git in one fresh repository and by git in another, the identity and
the clock fixed, and each log under .git/logs is compared line for line:
commit (initial, plain and concluding a merge), branch, checkout and
switch, reset, merge (a fast-forward and a merge commit), revert, a
deleted branch's log gone with it, and clone, fetch, pull and push
across two repositories.  Then the logs read back: `@{N}` in a
revision, `@{-N}`, `checkout -`, and `git reflog`.

## each move logged as git logs it

### commit, branch, checkout, switch, reset, merge and revert

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "C") (pair "GIT_COMMITTER_EMAIL" "c@d.e") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(def %rl-dir (fn (_) (def t (File temp "/tmp/x-git-rl-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %rl-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
; each step: a command line, or (sh SCRIPT) for a file changed between
(def %rl-steps
  (fn (_ dir run steps)
    (List for-each
      (fn (_ s) (if (str=? (first s) "sh") (%rl-sh dir (first (rest s))) (apply run (pair dir s))))
      steps)))
; the logs of two repositories set side by side: #t, or the first that differs
(def %rl-same
  (fn (_ x g files)
    (def read (fn (_ d f) (let ((p (Str8 append d "/.git/logs/" f))) (if (File exists? p) (File read-all p) ()))))
    (def bad (List find (fn (_ f) (not (equal? (read x f) (read g f)))) files))
    (if (null? bad) #t (list bad (read x bad) (read g bad)))))
(def %rl-twin
  (fn (_ steps files)
    (def x (%rl-dir))
    (def g (%rl-dir))
    (%rl-sh x "git init -q -b main .")
    (%rl-sh g "git init -q -b main .")
    (%rl-steps x git-text-in steps)
    (%rl-steps g git-oracle-in steps)
    (list (%rl-same x g files) x g)))
(def %rl-local
  (%rl-twin
    (list (list "sh" "printf 'a\\n' > a") (list "add" "a") (list "commit" "-q" "-m" "one  two\n\nbody")
          (list "sh" "printf 'b\\n' >> a") (list "add" "a") (list "commit" "-q" "-m" "two")
          (list "branch" "topic") (list "branch" "gone" "HEAD~1")
          (list "checkout" "-b" "side")
          (list "sh" "printf 'c\\n' > c") (list "add" "c") (list "commit" "-q" "-m" "three")
          (list "switch" "main") (list "checkout" "main") (list "checkout" "topic") (list "checkout" "main")
          (list "reset" "-q" "--hard" "HEAD~1") (list "reset" "-q" "topic") (list "reset" "-q" "--soft" "HEAD")
          (list "merge" "side")
          (list "checkout" "-b" "c1" "HEAD~1")
          (list "sh" "printf 'z\\n' > a") (list "add" "a") (list "commit" "-q" "-m" "z")
          (list "checkout" "main")
          (list "sh" "printf 'y\\n' > m") (list "add" "m") (list "commit" "-q" "-m" "y")
          (list "merge" "c1")
          (list "sh" "printf 'w\\n' > w") (list "add" "w") (list "commit" "-q" "-m" "w")
          (list "revert" "--no-edit" "HEAD")
          (list "branch" "-d" "gone"))
    (list "HEAD" "refs/heads/main" "refs/heads/topic" "refs/heads/side" "refs/heads/c1" "refs/heads/gone")))
(write (first %rl-local))
```
---
    #t

### a merge's conflicts concluded by commit, and a commit on a detached HEAD

```git
(write (first
  (%rl-twin
    (list (list "sh" "printf 'a\\n' > a") (list "add" "a") (list "commit" "-q" "-m" "one")
          (list "checkout" "-b" "s")
          (list "sh" "printf 's\\n' > a") (list "add" "a") (list "commit" "-q" "-m" "s")
          (list "checkout" "main")
          (list "sh" "printf 'm\\n' > a") (list "add" "a") (list "commit" "-q" "-m" "m")
          (list "merge" "s")
          (list "sh" "printf 'q\\n' > a") (list "add" "a") (list "commit" "-q" "--no-edit")
          (list "checkout" "HEAD~1")
          (list "sh" "printf 'd\\n' > d") (list "add" "d") (list "commit" "-q" "-m" "detached"))
    (list "HEAD" "refs/heads/main" "refs/heads/s"))))
```
---
    #t

### clone, fetch, pull and push

The source is made by git, twice alike, so x-git and git each clone
their own; their logs name the source, which is set aside.

```git
(def %rl-remote
  (fn (_ run)
    (def top (%rl-dir))
    (%rl-sh top "git init -q -b main src && cd src && printf 'a\\n' > a && git add a && git commit -qm one")
    (%rl-steps top run (list (list "clone" "src" "c")))
    (def c (Str8 append top "/c"))
    (def src (Str8 append top "/src"))
    (%rl-steps c run
      (list (list "sh" "printf 'n\\n' > n") (list "add" "n") (list "commit" "-q" "-m" "n")
            (list "push" "origin" "main:pushed")))
    (%rl-sh src "printf 'o\\n' > o && git add o && git commit -qm o")
    (%rl-steps c run (list (list "fetch") (list "pull" "--no-rebase")))
    (List map
      (fn (_ f)
        (def p (Str8 append (if (Str8 starts? "src:" f) src c) "/.git/logs/" (if (Str8 starts? "src:" f) (Str8 sub 4 (%sub (Str8 length f) 4) f) f)))
        (if (File exists? p) (Str8 join "SRC" (Str8 split src (File read-all p))) ()))
      (list "HEAD" "refs/heads/main" "refs/remotes/origin/HEAD" "refs/remotes/origin/main" "refs/remotes/origin/pushed" "src:refs/heads/pushed"))))
(def %sub (prim-ref 'int '-))
(def %rl-x (%rl-remote git-text-in))
(def %rl-g (%rl-remote git-oracle-in))
; the pull's merge commit names the source in its message, so its name
; differs; the lines are compared up to it
(def %rl-cut (fn (_ text) (if (null? text) () (List map (fn (_ l) (if (Str8 includes? "pull --no-rebase" l) (Str8 sub 82 (%sub (Str8 length l) 82) l) l)) (Str8 split "\n" text)))))
(write (List map (fn (_ p) (equal? (%rl-cut (first p)) (%rl-cut (rest p)))) (List map pair %rl-x %rl-g)))
```
---
    (#t #t #t #t #t #t)

## the logs read back

### @{N}, @{-N} and a log too short, in rev-parse, log and show

```git
(def %rl-r (first (rest (rest %rl-local))))
(def %rl-both
  (fn (_ . ops)
    (def x (apply git-text-in (pair %rl-r ops)))
    (def g (apply git-oracle-in (pair %rl-r ops)))
    (if (equal? x g) #t (list x g))))
(write (list (%rl-both "rev-parse" "HEAD@{1}" "main@{2}" "@{1}" "@{0}" "@" "@~1" "HEAD@{1}~1" "main@{1}^{tree}")
             (%rl-both "rev-parse" "@{-1}" "@{-2}")
             (%rl-both "rev-parse" "refs/heads/side@{1}" "side@{0}")
             (%rl-both "rev-parse" "main@{1}" "main@{99}")
             (%rl-both "rev-parse" "@{99}")
             (%rl-both "rev-parse" "nosuch@{1}")
             (%rl-both "log" "--oneline" "main@{2}")
             (%rl-both "log" "--oneline" "main@{99}")
             (%rl-both "show" "-s" "--oneline" "HEAD@{3}")
             (%rl-both "show" "-s" "--oneline" "HEAD@{99}")))
```
---
    (#t #t #t #t #t #t #t #t #t #t)

### git reflog: show, -n, a ref's name as given, exists

```git
(write (list (%rl-both "reflog")
             (%rl-both "reflog" "show" "main")
             (%rl-both "reflog" "main")
             (%rl-both "reflog" "show" "refs/heads/main")
             (%rl-both "reflog" "show" "side" "c1")
             (%rl-both "reflog" "-n" "3")
             (%rl-both "reflog" "show" "-n" "3" "main" "side")
             (%rl-both "reflog" "show" "@{-1}")
             (%rl-both "reflog" "show" "main" "nosuch")
             (%rl-both "reflog" "exists" "refs/heads/main")
             (%rl-both "reflog" "exists" "main")))
```
---
    (#t #t #t #t #t #t #t #t #t #t #t)

### checkout - and switch -: back to the branch before

```git
(def %rl-f (%rl-dir))
(%rl-sh %rl-f "git init -q -b main . && git commit -q --allow-empty -m a")
(write (list (first
               (%rl-twin
                 (list (list "sh" "printf 'a\\n' > a") (list "add" "a") (list "commit" "-q" "-m" "one")
                       (list "branch" "b") (list "checkout" "b") (list "checkout" "-") (list "switch" "-")
                       (list "checkout" "-b" "c") (list "checkout" "@{-2}"))
                 (list "HEAD" "refs/heads/b" "refs/heads/c")))
             ; with no branch before, refused as git refuses it
             (equal? (git-text-in %rl-f "checkout" "-") (git-oracle-in %rl-f "checkout" "-"))
             (equal? (git-text-in %rl-f "switch" "-") (git-oracle-in %rl-f "switch" "-"))))
```
---
    (#t #t #t)
