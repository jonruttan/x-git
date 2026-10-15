# @weight 4
# @timeout-scale 2

clone, fetch and ls-remote over git's pack protocol, the far end
git-upload-pack run as a child on a file:// url, as git runs it.  git makes
every source; x-git and git each clone it into a directory of the same name
and fetch what it grows, and everything git can see -- the report, the
refs, FETCH_HEAD, the pack, fsck -- is compared.  `%pr-dir` makes an empty
directory, `%pr-sh` runs a script in one, `%pr-url` is a source's url.

## ls-remote

### what the service advertises, by url and by path

```git
(def %pr-dir (fn (_) (def t (File temp "/tmp/x-git-pr-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %pr-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd " dir " && " script)))))
(def %pr-git "git -c user.email=a@b.c -c user.name=A")
(def %pr-url (fn (_ dir) (Str8 append "file://" dir)))
(def %pr-d (%pr-dir))
(%pr-sh %pr-d (Str8 append "git init -q -b main src && cd src && printf 'one\\n' > f && git add f && " %pr-git " commit -qm one"
  " && git tag v0 && " %pr-git " tag -a v1 -m tagged"
  " && git checkout -qb feature && printf x > g && git add g && " %pr-git " commit -qm feat && git checkout -q main"))
(def %pr-src (Str8 append %pr-d "/src"))
(write (list (equal? (git-text-in %pr-d "ls-remote" (%pr-url %pr-src)) (git-oracle-in %pr-d "ls-remote" (%pr-url %pr-src)))
             (equal? (git-text-in %pr-d "ls-remote" "src") (git-oracle-in %pr-d "ls-remote" "src"))
             (first (git-text-in %pr-d "ls-remote" (%pr-url %pr-src)))
             (List length (Str8 split "\n" (rest (git-text-in %pr-d "ls-remote" (%pr-url %pr-src)))))))
```
---
    (#t #t 0 7)

### a url that names no repository is refused in git's words

The service says on its own standard error what is wrong; this is the
rest of what git prints.

```git
(write (git-text-in %pr-d "ls-remote" (%pr-url (Str8 append %pr-d "/nowhere"))))
```
---
    (128 . "fatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n")

## clone

### a clone over the wire is git's clone: refs, tree, config, one pack

```git
(File mkdir (Str8 append %pr-d "/x"))
(File mkdir (Str8 append %pr-d "/g"))
(def %pr-xw (Str8 append %pr-d "/x/w"))
(def %pr-gw (Str8 append %pr-d "/g/w"))
(def %pr-xc (git-text-in (Str8 append %pr-d "/x") "clone" (%pr-url %pr-src) "w"))
(def %pr-gc (git-oracle-in (Str8 append %pr-d "/g") "clone" (%pr-url %pr-src) "w"))
(def %pr-xp (List filter (fn (_ f) (Str8 ends? ".pack" f)) (File list-dir (Str8 append %pr-xw "/.git/objects/pack"))))
(write (list (equal? %pr-xc %pr-gc)
             (equal? (git-oracle-in %pr-xw "for-each-ref") (git-oracle-in %pr-gw "for-each-ref"))
             (equal? (git-oracle-in %pr-xw "log" "--oneline" "--all") (git-oracle-in %pr-gw "log" "--oneline" "--all"))
             (equal? (git-oracle-in %pr-xw "status" "--porcelain") (git-oracle-in %pr-gw "status" "--porcelain"))
             (equal? (git-oracle-in %pr-xw "config" "remote.origin.url") (git-oracle-in %pr-gw "config" "remote.origin.url"))
             (equal? (git-oracle-in %pr-xw "config" "branch.main.merge") (git-oracle-in %pr-gw "config" "branch.main.merge"))
             (List length %pr-xp)
             (first (git-oracle-in %pr-xw "verify-pack" "-v" (Str8 append ".git/objects/pack/" (first %pr-xp))))
             (first (git-oracle-in %pr-xw "fsck" "--strict"))
             (equal? (git-text-in %pr-xw "cat-file" "-p" "v1") (git-oracle-in %pr-gw "cat-file" "-p" "v1"))))
```
---
    (#t #t #t #t #t #t 1 0 0 #t)

### a url that names no repository is refused, and nothing is made

```git
(def %pr-bad (git-text-in (Str8 append %pr-d "/x") "clone" (%pr-url (Str8 append %pr-d "/nowhere")) "nope"))
(write (list %pr-bad (File exists? (Str8 append %pr-d "/x/nope"))))
```
---
    ((128 . "Cloning into 'nope'...\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n") #f)

## fetch

### new commits on two branches and a tag into them, as git fetches them

```git
(%pr-sh %pr-src (Str8 append "printf 'two\\n' >> f && " %pr-git " commit -qam two && printf 'three\\n' >> f && " %pr-git " commit -qam three"
  " && " %pr-git " tag -a v2 -m second && git checkout -q feature && printf y >> g && " %pr-git " commit -qam more && git checkout -q main"))
(def %pr-xf (git-text-in %pr-xw "fetch"))
(def %pr-gf (git-oracle-in %pr-gw "fetch"))
(write (list (equal? %pr-xf %pr-gf)
             (equal? (git-oracle-in %pr-xw "for-each-ref") (git-oracle-in %pr-gw "for-each-ref"))
             (str=? (File read-all (Str8 append %pr-xw "/.git/FETCH_HEAD")) (File read-all (Str8 append %pr-gw "/.git/FETCH_HEAD")))
             (first (git-oracle-in %pr-xw "fsck" "--strict"))
             (equal? (git-oracle-in %pr-xw "log" "--oneline" "origin/main") (git-oracle-in %pr-gw "log" "--oneline" "origin/main"))
             (List length (List filter (fn (_ f) (Str8 ends? ".pack" f)) (File list-dir (Str8 append %pr-xw "/.git/objects/pack"))))))
```
---
    (#t #t #t 0 #t 2)

### nothing new says nothing

```git
(write (list (git-text-in %pr-xw "fetch") (git-oracle-in %pr-gw "fetch")))
```
---
    ((0 . "") (0 . ""))

### a new branch, and a tag on a commit this repository already had

The tag's object is not in the pack the branch brings, so it is asked for
on its own.

```git
(%pr-sh %pr-src (Str8 append "git checkout -qb topic && printf t > t && git add t && " %pr-git " commit -qm topic && git checkout -q main"
  " && " %pr-git " tag -a v0.5 -m late HEAD~2"))
(def %pr-xf2 (git-text-in %pr-xw "fetch"))
(def %pr-gf2 (git-oracle-in %pr-gw "fetch"))
(write (list (equal? %pr-xf2 %pr-gf2)
             (equal? (git-oracle-in %pr-xw "for-each-ref") (git-oracle-in %pr-gw "for-each-ref"))
             (str=? (File read-all (Str8 append %pr-xw "/.git/FETCH_HEAD")) (File read-all (Str8 append %pr-gw "/.git/FETCH_HEAD")))
             (first (git-oracle-in %pr-xw "fsck" "--strict"))
             (equal? (git-oracle-in %pr-xw "cat-file" "-p" "v0.5") (git-oracle-in %pr-gw "cat-file" "-p" "v0.5"))))
```
---
    (#t #t #t 0 #t)

### a fetch after this repository has moved on its own

What the service already has is said, and only the rest comes.

```git
(%pr-sh %pr-xw (Str8 append "printf 'mine\\n' > m && git add m && " %pr-git " commit -qm mine"))
(%pr-sh %pr-gw (Str8 append "printf 'mine\\n' > m && git add m && " %pr-git " commit -qm mine"))
(%pr-sh %pr-src (Str8 append "printf 'four\\n' >> f && " %pr-git " commit -qam four"))
(def %pr-xf3 (git-text-in %pr-xw "fetch"))
(def %pr-gf3 (git-oracle-in %pr-gw "fetch"))
(write (list (equal? %pr-xf3 %pr-gf3)
             (equal? (git-oracle-in %pr-xw "for-each-ref" "refs/remotes") (git-oracle-in %pr-gw "for-each-ref" "refs/remotes"))
             (first (git-oracle-in %pr-xw "fsck" "--strict"))
             (equal? (git-oracle-in %pr-xw "log" "--oneline" "origin/main") (git-oracle-in %pr-gw "log" "--oneline" "origin/main"))))
```
---
    (#t #t 0 #t)

### a remote that went away is refused in git's words

```git
(%pr-sh %pr-d "rm -rf src")
(write (git-text-in %pr-xw "fetch"))
```
---
    (128 . "fatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n")

## push

### a fast-forward to a bare remote over the wire, then nothing left to send

git-receive-pack takes the commands and the pack; the report it sends
back is git's, and git reads what landed.  A pack this small is unpacked
there into loose objects, as `receive.unpackLimit` says, so fsck is the
check of what arrived.

```git
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
