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

### an advertisement longer than one read

1500 refs advertise some 90 KB, more than the wire reads at once, so a
read ends inside a packet and the rest is read after it -- which once
went round forever, the room after the unread bytes never enough for a
read.  A hosted repository's pull requests are refs like these.

```git
(%pr-sh %pr-d (Str8 append "git init -q -b main many && cd many && " %pr-git " commit -q --allow-empty -m one"
  " && h=$(git rev-parse HEAD) && i=1000 && { echo '# pack-refs with: peeled fully-peeled sorted '"
  " && while [ $i -lt 2500 ]; do echo \"$h refs/pull/$i/head\"; i=$((i+1)); done; } > .git/packed-refs"))
(def %pr-many (git-text-in %pr-d "ls-remote" (%pr-url (Str8 append %pr-d "/many"))))
(write (list (equal? %pr-many (git-oracle-in %pr-d "ls-remote" (%pr-url (Str8 append %pr-d "/many"))))
             (List length (Str8 split "\n" (rest %pr-many)))))
```
---
    (#t 1503)

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
