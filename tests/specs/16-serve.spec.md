# @weight 4
# @timeout-scale 3

x-git as the far end: git, the client, runs x-git's upload-pack and
receive-pack as the services of a file:// url, the way it runs its own,
and what it prints and leaves is set beside what it does with its own
services.  x-git is started as a process of its own, through the x under
test and from this tree (`X` and `X_GIT_BUNDLE`, set by the runner), with
`X_LANG_DIR` naming a directory that holds this tree as `git`, and from
x's own root (`X_ROOT`), where a checkout's x finds its library.  A first
launch writes x-git's state image, with its words thrown away; the
services are then started with `X_IMAGE_NO_WRITE`, which uses that image
and writes none, so nothing x prints of its own reaches git's output.
Commits carry a fixed date, so twin repositories name the same objects.

## upload-pack

### ls-remote: the refs advertised, as git's own upload-pack advertises them

```git
(def %sv-dir (fn (_) (def t (File temp "/tmp/x-git-sv-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %sv-env "export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=A GIT_COMMITTER_EMAIL=a@b.c; ")
(def %sv-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append %sv-env "cd " dir " && " script)))))
(def %sv-d (%sv-dir))
(def %sv-langs (Str8 append %sv-d "/langs"))
(%sv-sh %sv-d (Str8 append "mkdir langs && ln -s '" (Sys getenv "X_GIT_BUNDLE") "' langs/git"))
(def %sv-launch (fn (_ env cmd) (Str8 append "unset X_IMG_DIR; cd '" (Sys getenv "X_ROOT") "' && " env " X_LANG_DIR=" %sv-langs "/ '" (Sys getenv "X") "' -l git -- " cmd)))
(%sv-sh %sv-d (Str8 append (%sv-launch "" "version") " >/dev/null 2>&1"))
(def %sv-up (Str8 append "--upload-pack=" (%sv-launch "X_IMAGE_NO_WRITE=1" "upload-pack")))
(def %sv-rp (Str8 append "--receive-pack=" (%sv-launch "X_IMAGE_NO_WRITE=1" "receive-pack")))
(def %sv-url (fn (_ dir) (Str8 append "file://" dir)))
(%sv-sh %sv-d "git init -q -b main src && cd src && printf 'one\\n' > f && git add f && git commit -qm one && git tag light && git tag -a v1 -m tagged && git checkout -qb feature && printf x > g && git add g && git commit -qm feat && git checkout -q main")
(def %sv-src (Str8 append %sv-d "/src"))
(write (list (equal? (git-oracle-in %sv-d "ls-remote" %sv-up (%sv-url %sv-src)) (git-oracle-in %sv-d "ls-remote" (%sv-url %sv-src)))
             (List length (Str8 split "\n" (rest (git-oracle-in %sv-d "ls-remote" %sv-up (%sv-url %sv-src)))))))
```
---
    (#t 7)

### clone: the refs, the tree, the tags and the objects of git's clone

```git
(%sv-sh %sv-d "mkdir x g")
(def %sv-xw (Str8 append %sv-d "/x/w"))
(def %sv-gw (Str8 append %sv-d "/g/w"))
(def %sv-xc (git-oracle-in (Str8 append %sv-d "/x") "clone" "-q" %sv-up (%sv-url %sv-src) "w"))
(def %sv-gc (git-oracle-in (Str8 append %sv-d "/g") "clone" "-q" (%sv-url %sv-src) "w"))
(write (list (equal? %sv-xc %sv-gc)
             (equal? (git-oracle-in %sv-xw "for-each-ref") (git-oracle-in %sv-gw "for-each-ref"))
             (equal? (git-oracle-in %sv-xw "log" "--oneline" "--all") (git-oracle-in %sv-gw "log" "--oneline" "--all"))
             (equal? (git-oracle-in %sv-xw "status" "--porcelain") (git-oracle-in %sv-gw "status" "--porcelain"))
             (first (git-oracle-in %sv-xw "fsck" "--strict"))
             (rest (git-oracle-in %sv-xw "tag"))))
```
---
    (#t #t #t #t 0 "light\nv1\n")

### fetch: new commits, a new branch and an annotated tag on what is sent

The tag comes in the same pack, as include-tag asks.  git's own
upload-pack reports its progress on band 2, which x-git's does not, so
the `remote:` lines are left out of the comparison.

```git
(def %sv-plain (fn (_ r) (pair (first r) (Str8 join "\n" (List filter (fn (_ l) (not (Str8 starts? "remote:" l))) (Str8 split "\n" (rest r)))))))
(%sv-sh %sv-src "printf 'two\\n' >> f && git commit -qam two && git tag -a v2 -m second && git checkout -qb topic && printf t > t && git add t && git commit -qm topic && git checkout -q main")
(def %sv-xf (git-oracle-in %sv-xw "fetch" %sv-up))
(def %sv-gf (git-oracle-in %sv-gw "fetch"))
(write (list (equal? (%sv-plain %sv-xf) (%sv-plain %sv-gf))
             (equal? (git-oracle-in %sv-xw "for-each-ref") (git-oracle-in %sv-gw "for-each-ref"))
             (str=? (File read-all (Str8 append %sv-xw "/.git/FETCH_HEAD")) (File read-all (Str8 append %sv-gw "/.git/FETCH_HEAD")))
             (first (git-oracle-in %sv-xw "fsck" "--strict"))))
```
---
    (#t #t #t 0)

### fetch after the clone has moved on its own: its commits are said, and only the rest comes

```git
(%sv-sh %sv-xw "printf 'mine\\n' > m && git add m && git commit -qm mine")
(%sv-sh %sv-gw "printf 'mine\\n' > m && git add m && git commit -qm mine")
(%sv-sh %sv-src "printf 'three\\n' >> f && git commit -qam three")
(def %sv-xf2 (git-oracle-in %sv-xw "fetch" %sv-up))
(def %sv-gf2 (git-oracle-in %sv-gw "fetch"))
(write (list (equal? (%sv-plain %sv-xf2) (%sv-plain %sv-gf2))
             (equal? (git-oracle-in %sv-xw "for-each-ref") (git-oracle-in %sv-gw "for-each-ref"))
             (first (git-oracle-in %sv-xw "fsck" "--strict"))
             (equal? (git-oracle-in %sv-xw "fetch" %sv-up) (git-oracle-in %sv-gw "fetch"))))
```
---
    (#t #t 0 #t)

### an empty repository, and a path that is none, as git's upload-pack answers them

Version 0 has no word for an unborn HEAD, which git's own upload-pack
sends in version 2, so a client of x-git's names the branch itself; the
default is set, so a git that would hint about choosing it says nothing.

```git
(%sv-sh %sv-d "git init -q --bare empty.git")
(def %sv-xe (git-oracle-in (Str8 append %sv-d "/x") "-c" "init.defaultBranch=main" "clone" %sv-up (%sv-url (Str8 append %sv-d "/empty.git")) "e"))
(def %sv-ge (git-oracle-in (Str8 append %sv-d "/g") "-c" "init.defaultBranch=main" "clone" (%sv-url (Str8 append %sv-d "/empty.git")) "e"))
(def %sv-xn (git-oracle-in %sv-d "ls-remote" %sv-up (%sv-url (Str8 append %sv-d "/nowhere"))))
(def %sv-gn (git-oracle-in %sv-d "ls-remote" (%sv-url (Str8 append %sv-d "/nowhere"))))
(write (list (equal? %sv-xe %sv-ge) (first %sv-xe)
             (equal? %sv-xn %sv-gn) (first %sv-xn)))
```
---
    (#t 0 #t 128)

## receive-pack

### a push, a new branch and its deletion, as git's own receive-pack takes them

One working clone pushes to two bare twins, x/bare.git through x-git's
receive-pack and g/bare.git through git's; the urls are written `<dir>`.

```git
(%sv-sh %sv-d "git clone -q --bare src x/bare.git && git clone -q --bare src g/bare.git && git clone -q src p && cd p && printf 'four\\n' >> f && git commit -qam four")
(def %sv-p (Str8 append %sv-d "/p"))
(def %sv-xb (Str8 append %sv-d "/x/bare.git"))
(def %sv-gb (Str8 append %sv-d "/g/bare.git"))
(def %sv-scrub (fn (_ r) (pair (first r) (Str8 join "<dir>" (Str8 split %sv-gb (Str8 join "<dir>" (Str8 split %sv-xb (rest r))))))))
(def %sv-xpush (fn (_ . more) (%sv-scrub (apply git-oracle-in (pair %sv-p (pair "push" (pair %sv-rp (pair (%sv-url %sv-xb) more))))))))
(def %sv-gpush (fn (_ . more) (%sv-scrub (apply git-oracle-in (pair %sv-p (pair "push" (pair (%sv-url %sv-gb) more)))))))
(def %sv-x1 (%sv-xpush "main"))
(def %sv-g1 (%sv-gpush "main"))
(def %sv-x2 (%sv-xpush "main:side"))
(def %sv-g2 (%sv-gpush "main:side"))
(def %sv-x3 (%sv-xpush "--delete" "side"))
(def %sv-g3 (%sv-gpush "--delete" "side"))
(write (list (equal? %sv-x1 %sv-g1) (first %sv-x1)
             (equal? %sv-x2 %sv-g2) (equal? %sv-x3 %sv-g3)
             (equal? (git-oracle-in %sv-xb "for-each-ref") (git-oracle-in %sv-gb "for-each-ref"))
             (first (git-oracle-in %sv-xb "fsck" "--strict"))
             (equal? (%sv-xpush "main") (%sv-gpush "main"))))
```
---
    (#t 0 #t #t #t 0 #t)

### HEAD's branch is not deleted, even in a bare repository

```git
(def %sv-xd (%sv-xpush "--delete" "main"))
(write (list (equal? %sv-xd (%sv-gpush "--delete" "main")) (first %sv-xd)
             (str=? (git-sha-in %sv-xb "main") (git-sha-in %sv-gb "main"))))
```
---
    (#t 1 #t)

### a non-bare repository's checked-out branch is refused in receive-pack's words

```git
(%sv-sh %sv-d "git clone -q src x/nb && git clone -q src g/nb")
(def %sv-xnb (Str8 append %sv-d "/x/nb"))
(def %sv-gnb (Str8 append %sv-d "/g/nb"))
(def %sv-before (git-sha-in %sv-xnb "main"))
(def %sv-xco (git-oracle-in %sv-p "push" %sv-rp (%sv-url %sv-xnb) "main"))
(def %sv-gco (git-oracle-in %sv-p "push" (%sv-url %sv-gnb) "main"))
(write (list (equal? (Str8 join "<dir>" (Str8 split %sv-xnb (rest %sv-xco))) (Str8 join "<dir>" (Str8 split %sv-gnb (rest %sv-gco))))
             (first %sv-xco)
             (str=? (git-sha-in %sv-xnb "main") %sv-before)))
```
---
    (#t 1 #t)
