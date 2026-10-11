# @weight 4
# @timeout-scale 2

fetch and push against a repository named by a path.  git makes every
repository here; for fetch, git fetches into one clone and x-git into its
twin, and everything git can see -- the report, the refs, FETCH_HEAD,
fsck -- is compared.  For push, the report is set against the lines git
prints, built from the commits' names, and git reads what landed.
`%rm-dir` makes an empty directory, `%rm-sh` runs a script in one, and
`%rm-url` is the url a clone's origin names, which `%rm-scrub` writes as
`<url>`.

## fetch

### new commits, a new branch and the tags that point into them: as git fetches them

```git
(def %rm-dir (fn (_) (def t (File temp "/tmp/x-git-rm-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %rm-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd " dir " && " script)))))
(def %rm-git "git -c user.email=a@b.c -c user.name=A")
(def %rm-url (fn (_ dir) (Str8 trim (rest (git-oracle-in dir "config" "remote.origin.url")))))
(def %rm-scrub (fn (_ text url) (Str8 join "<url>" (Str8 split url text))))
(def %rm-d (%rm-dir))
(%rm-sh %rm-d (Str8 append "git init -q -b main src && cd src && printf 'one\\n' > f && git add f && " %rm-git " commit -qm one"
  " && cd .. && git clone -q src w1 && git clone -q src w2 && cd src"
  " && printf 'two\\n' >> f && " %rm-git " commit -qam two"
  " && git checkout -qb feature && printf x > g && git add g && " %rm-git " commit -qm feat"
  " && git tag v1 && " %rm-git " tag -a v2 -m tagged && git checkout -q main"))
(def %rm-w1 (Str8 append %rm-d "/w1"))
(def %rm-w2 (Str8 append %rm-d "/w2"))
(def %rm-x (git-text-in %rm-w1 "fetch"))
(def %rm-g (git-oracle-in %rm-w2 "fetch"))
(write (list (equal? %rm-x %rm-g)
             (equal? (git-oracle-in %rm-w1 "for-each-ref") (git-oracle-in %rm-w2 "for-each-ref"))
             (str=? (File read-all (Str8 append %rm-w1 "/.git/FETCH_HEAD")) (File read-all (Str8 append %rm-w2 "/.git/FETCH_HEAD")))
             (first (git-oracle-in %rm-w1 "fsck" "--strict"))
             (equal? (git-text-in %rm-w1 "fetch") (git-oracle-in %rm-w2 "fetch"))))
```
---
    (#t #t #t 0 #t)

### a remote that is not there is refused in git's words

```git
(write (git-text-in %rm-w1 "fetch" "nowhere"))
```
---
    (128 . "fatal: 'nowhere' does not appear to be a git repository\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n")

## push

### a fast-forward to a bare remote, then nothing left to send

```git
(def %rm-p (%rm-dir))
(%rm-sh %rm-p (Str8 append "git init -q -b main src && cd src && printf 'one\\n' > f && git add f && " %rm-git " commit -qm one"
  " && cd .. && git clone -q --bare src bare.git && git clone -q bare.git w && cd w"
  " && printf 'two\\n' >> f && " %rm-git " commit -qam two"))
(def %rm-w (Str8 append %rm-p "/w"))
(def %rm-old (git-sha-in %rm-w "origin/main"))
(def %rm-new (git-sha-in %rm-w "HEAD"))
(def %rm-r (git-text-in %rm-w "push"))
(def %rm-bare (Str8 append %rm-p "/bare.git"))
(write (list (equal? %rm-r (pair 0 (Str8 append "To " (%rm-url %rm-w) "\n   " (Str8 sub 0 7 %rm-old) ".." (Str8 sub 0 7 %rm-new) "  main -> main\n")))
             (str=? (git-sha-in %rm-bare "main") %rm-new)
             (str=? (git-sha-in %rm-w "origin/main") %rm-new)
             (first (git-oracle-in %rm-bare "fsck" "--strict"))
             (git-text-in %rm-w "push")))
```
---
    (#t #t #t 0 (0 . "Everything up-to-date\n"))

### a new branch, named

```git
(%rm-sh %rm-w (Str8 append "git checkout -qb feature && printf x > g && git add g && " %rm-git " commit -qm feat"))
(write (list (equal? (git-text-in %rm-w "push" "origin" "feature")
                     (pair 0 (Str8 append "To " (%rm-url %rm-w) "\n * [new branch]      feature -> feature\n")))
             (str=? (git-sha-in %rm-bare "feature") (git-sha-in %rm-w "feature"))
             (first (git-oracle-in %rm-bare "fsck" "--strict"))))
```
---
    (#t #t 0)

### a push that is not a fast-forward is rejected, and the remote keeps its branch

```git
(def %rm-before (git-sha-in %rm-bare "main"))
(%rm-sh %rm-w (Str8 append "git checkout -q main && git reset -q --hard HEAD~1 && printf 'other\\n' >> f && " %rm-git " commit -qam other"))
(def %rm-nf (git-text-in %rm-w "push"))
(write (list (first %rm-nf)
             (List take 3 (Str8 split "\n" (%rm-scrub (rest %rm-nf) (%rm-url %rm-w))))
             (Str8 includes? "hint: Updates were rejected because the tip of your current branch is behind" (rest %rm-nf))
             (str=? (git-sha-in %rm-bare "main") %rm-before)))
```
---
    (1 ("To <url>" " ! [rejected]        main -> main (non-fast-forward)" "error: failed to push some refs to '<url>'") #t #t)

### work the remote has and this repository has not seen: fetch first

```git
(def %rm-f (%rm-dir))
(%rm-sh %rm-f (Str8 append "git init -q -b main src && cd src && printf 'one\\n' > f && git add f && " %rm-git " commit -qm one"
  " && cd .. && git clone -q --bare src bare.git && git clone -q bare.git a && git clone -q bare.git b"
  " && cd a && printf 'a\\n' >> f && " %rm-git " commit -qam a && cd ../b && printf 'b\\n' >> f && " %rm-git " commit -qam b"))
(def %rm-a (git-text-in (Str8 append %rm-f "/a") "push"))
(def %rm-b (git-text-in (Str8 append %rm-f "/b") "push"))
(write (list (first %rm-a) (first %rm-b)
             (first (rest (Str8 split "\n" (rest %rm-b))))
             (Str8 includes? "hint: Updates were rejected because the remote contains work that you do not" (rest %rm-b))))
```
---
    (0 1 " ! [rejected]        main -> main (fetch first)" #t)

### the branch a non-bare remote has checked out is refused there

```git
(def %rm-c (%rm-dir))
(%rm-sh %rm-c (Str8 append "git init -q -b main src && cd src && printf 'one\\n' > f && git add f && " %rm-git " commit -qm one"
  " && cd .. && git clone -q src w && cd w && printf 'two\\n' >> f && " %rm-git " commit -qam two"))
(def %rm-src-before (git-sha-in (Str8 append %rm-c "/src") "main"))
(def %rm-co (git-text-in (Str8 append %rm-c "/w") "push"))
(def %rm-co-lines (Str8 split "\n" (%rm-scrub (rest %rm-co) (%rm-url (Str8 append %rm-c "/w")))))
(write (list (first %rm-co) (first %rm-co-lines)
             (List ref 15 %rm-co-lines) (List ref 16 %rm-co-lines)
             (str=? (git-sha-in (Str8 append %rm-c "/src") "main") %rm-src-before)))
```
---
    (1 "remote: error: refusing to update checked out branch: refs/heads/main" " ! [remote rejected] main -> main (branch is currently checked out)" "error: failed to push some refs to '<url>'" #t)

### a branch with no upstream is refused in git's words

```git
(%rm-sh (Str8 append %rm-c "/w") (Str8 append "git checkout -qb topic && printf t > t && git add t && " %rm-git " commit -qm t"))
(def %rm-nu (git-text-in (Str8 append %rm-c "/w") "push"))
(write (list (first %rm-nu) (first (Str8 split "\n" (rest %rm-nu)))))
```
---
    (128 "fatal: The current branch topic has no upstream branch.")
