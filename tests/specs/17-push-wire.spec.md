# @weight 4
# @timeout-scale 2

push over git's pack protocol, the far end git-receive-pack run as a child
on a file:// url, as git runs it.  `%pr-dir` makes an empty directory,
`%pr-sh` runs a script in one, `%pr-url` is a repository's url.

## push

### a fast-forward to a bare remote over the wire, then nothing left to send

git-receive-pack takes the commands and the pack; the report it sends
back is git's, and git reads what landed.  A pack this small is unpacked
there into loose objects, as `receive.unpackLimit` says, so fsck is the
check of what arrived.

```git
(def %pr-dir (fn (_) (def t (File temp "/tmp/x-git-pw-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %pr-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd " dir " && " script)))))
(def %pr-git "git -c user.email=a@b.c -c user.name=A")
(def %pr-url (fn (_ dir) (Str8 append "file://" dir)))
(def %pr-p (%pr-dir))
(%pr-sh %pr-p (Str8 append "git init -q -b main src && cd src && printf 'one\\n' > f && git add f && " %pr-git " commit -qm one"
  " && cd .. && git clone -q --bare src bare.git && mkdir x g"
  " && git clone -q file://" %pr-p "/bare.git g/w && cd g/w && printf 'two\\n' >> f && " %pr-git " commit -qam two"))
(def %pr-pb (Str8 append %pr-p "/bare.git"))
(def %pr-px (Str8 append %pr-p "/x/w"))
(def %pr-pg (Str8 append %pr-p "/g/w"))
(git-text-in (Str8 append %pr-p "/x") "clone" (%pr-url %pr-pb) "w")
(%pr-sh %pr-px (Str8 append "printf 'two\\n' >> f && " %pr-git " commit -qam two"))
(def %pr-pold (git-sha-in %pr-px "origin/main"))
(def %pr-pnew (git-sha-in %pr-px "HEAD"))
(def %pr-pr (git-text-in %pr-px "push"))
(write (list (equal? %pr-pr (pair 0 (Str8 append "To " (%pr-url %pr-pb) "\n   " (Str8 sub 0 7 %pr-pold) ".." (Str8 sub 0 7 %pr-pnew) "  main -> main\n")))
             (str=? (git-sha-in %pr-pb "main") %pr-pnew)
             (str=? (git-sha-in %pr-px "origin/main") %pr-pnew)
             (first (git-oracle-in %pr-pb "fsck" "--strict"))
             (equal? (git-oracle-in %pr-pb "log" "--format=%T %s" "main") (git-oracle-in %pr-px "log" "--format=%T %s" "main"))
             (equal? (git-text-in %pr-px "push") (git-oracle-in %pr-px "push"))
             (git-text-in %pr-px "push")))
```
---
    (#t #t #t 0 #t #t (0 . "Everything up-to-date\n"))

### a new branch named, and one on a commit the remote already has

The second sends the empty pack the protocol asks for.

```git
(%pr-sh %pr-px (Str8 append "git checkout -qb feature && printf x > g && git add g && " %pr-git " commit -qm feat && git branch same main"))
(def %pr-pf (git-text-in %pr-px "push" "origin" "feature"))
(def %pr-ps (git-text-in %pr-px "push" "origin" "same"))
(write (list (equal? %pr-pf (pair 0 (Str8 append "To " (%pr-url %pr-pb) "\n * [new branch]      feature -> feature\n")))
             (str=? (git-sha-in %pr-pb "feature") (git-sha-in %pr-px "feature"))
             (equal? %pr-ps (pair 0 (Str8 append "To " (%pr-url %pr-pb) "\n * [new branch]      same -> same\n")))
             (str=? (git-sha-in %pr-pb "same") %pr-pnew)
             (first (git-oracle-in %pr-pb "fsck" "--strict"))
             (equal? (git-text-in %pr-px "ls-remote" (%pr-url %pr-pb)) (git-oracle-in %pr-pg "ls-remote" (%pr-url %pr-pb)))))
```
---
    (#t #t #t #t 0 #t)

### a push that is not a fast-forward is rejected before anything is sent

```git
(def %pr-pbefore (git-sha-in %pr-pb "main"))
(%pr-sh %pr-px (Str8 append "git checkout -q main && git reset -q --hard HEAD~1 && printf 'other\\n' >> f && " %pr-git " commit -qam other"))
(def %pr-nf (git-text-in %pr-px "push"))
(write (list (first %pr-nf)
             (List take 3 (Str8 split "\n" (Str8 join "<url>" (Str8 split (%pr-url %pr-pb) (rest %pr-nf)))))
             (Str8 includes? "hint: Updates were rejected because the tip of your current branch is behind" (rest %pr-nf))
             (str=? (git-sha-in %pr-pb "main") %pr-pbefore)))
```
---
    (1 ("To <url>" " ! [rejected]        main -> main (non-fast-forward)" "error: failed to push some refs to '<url>'") #t #t)

### the branch a non-bare remote has checked out is refused by its receive-pack

Both push to the same working repository; its words come back on band 2
and are printed as git prints them, padded to clear the line.

```git
(%pr-sh %pr-p "git clone -q src nb")
(def %pr-pn (Str8 append %pr-p "/nb"))
(def %pr-nb-before (git-sha-in %pr-pn "main"))
(def %pr-xco (git-text-in %pr-px "push" (%pr-url %pr-pn) "main"))
(def %pr-gco (git-oracle-in %pr-pg "push" (%pr-url %pr-pn) "main"))
(write (list (equal? %pr-xco %pr-gco)
             (first %pr-xco)
             (List length (Str8 split "\n" (rest %pr-xco)))
             (str=? (git-sha-in %pr-pn "main") %pr-nb-before)))
```
---
    (#t 1 18 #t)

### a url that names no repository is refused in git's words

```git
(write (git-text-in %pr-px "push" (%pr-url (Str8 append %pr-p "/nowhere")) "main"))
```
---
    (128 . "fatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n")
