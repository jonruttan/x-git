# @weight 4
# @timeout-scale 3

git's smart http transport, against git itself.  The far end is git's
own `git http-backend`, run as a CGI program by tests/http-server.x, a
small http server this spec starts as a process of its own: it reads
each request, runs the backend with the request in its environment and
its body on its input, and answers with what the backend wrote.  x-git
and git each reach the same repository through it -- ls-remote, clone,
then a fetch after more commits land -- and what each prints and ends
with is compared.  https is refused for now, and that refusal is checked.

## the server

### a bare repository served over http

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(def %ht-d (let ((t (File temp "/tmp/x-git-ht-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(def %ht-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(%ht-sh %ht-d
  (Str8 append "mkdir srv srvd x g && git init -q -b main src && cd src"
    " && printf 'a\\n' > a && mkdir d && printf 'f\\n' > d/f && git add . && git commit -qm one"
    " && printf 'b\\n' >> a && git commit -qam two && git tag v1 && git tag -a v2 -m 'tag two'"
    " && git checkout -qb side && printf 's\\n' > s && git add s && git commit -qm side && git checkout -q main"
    " && git clone -q --bare . ../srv/repo.git"))
; the server started as a process of its own, from x's root, as a
; checkout's x needs, and not waited for; then its port awaited
(Sys setenv "HT_ROOT" (Str8 append %ht-d "/srv"))
(Sys setenv "HT_DIR" (Str8 append %ht-d "/srvd"))
(def %ht-server (Sys fork))
(when (= %ht-server 0)
  (guard (e (Sys exit 125))
    (Sys exec "/bin/sh"
      (list "-c" "cd \"$X_ROOT\" && exec \"$X\" -f \"$X_GIT_BUNDLE/tests/http-server.x\" >/dev/null 2>&1")))
  (Sys exit 127))
(%ht-sh %ht-d "i=0; while [ ! -s srvd/port ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done")
(def %ht-url (Str8 append "http://127.0.0.1:" (Str8 trim (File read-all (Str8 append %ht-d "/srvd/port"))) "/repo.git"))
(def %ht-x
  (fn (_ dir . ops)
    (def r (git-run (git-plan (pair "-C" (pair (Str8 append %ht-d "/" dir) ops)))))
    (def text (first (rest r)))
    (if (eq? (first r) (lit out)) (list (first (rest (rest r))) text "") (list (first (rest (rest r))) "" text))))
(def %ht-g
  (fn (_ dir . ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git -c protocol.version=0 \"$@\" 2>\"$0/../git.err\"" (pair (Str8 append %ht-d "/" dir) ops))))))
    (list (first r) (rest r) (File read-all (Str8 append %ht-d "/" dir "/../git.err")))))
(write (equal? (%ht-x "x" "ls-remote" %ht-url) (%ht-g "g" "ls-remote" %ht-url)))
```
---
    #t

## fetching

### clone: the refs, the tags, the files, the objects git's clone has

```git
(def %ht-xc (%ht-x "x" "clone" %ht-url "c"))
(def %ht-gc (%ht-g "g" "clone" %ht-url "c"))
(def %ht-both
  (fn (_ . args)
    (equal? (apply git-oracle-in (pair (Str8 append %ht-d "/x/c") args)) (apply git-oracle-in (pair (Str8 append %ht-d "/g/c") args)))))
(write (list (equal? %ht-xc %ht-gc)
             (%ht-both "for-each-ref" "--format=%(refname) %(objectname)")
             (%ht-both "log" "--oneline" "--all")
             (%ht-both "status" "--porcelain")
             (first (git-oracle-in (Str8 append %ht-d "/x/c") "fsck" "--strict"))))
```
---
    (#t #t #t #t 0)

### fetch: what is new on the server, negotiated from what each has

```git
(%ht-sh (Str8 append %ht-d "/src")
  "printf 'c\\n' >> a && git commit -qam three && git checkout -qb more && printf 'm\\n' > m && git add m && git commit -qm more && git checkout -q main && git push -q ../srv/repo.git main more")
(write (list (equal? (%ht-x "x/c" "fetch" "origin") (%ht-g "g/c" "fetch" "origin"))
             (%ht-both "for-each-ref" "--format=%(refname) %(objectname)")
             (first (git-oracle-in (Str8 append %ht-d "/x/c") "fsck" "--strict"))))
```
---
    (#t #t 0)

## refusals

### no repository there; a push, which x-git does not make over http; https, not yet

```git
(def %ht-nope (Str8 append (Str8 sub 0 (- (Str8 length %ht-url) 8) %ht-url) "/nope.git"))
(def %ht-push (%ht-x "x/c" "push" %ht-url "main"))
(def %ht-tls (%ht-x "x" "ls-remote" (Str8 append "https" (Str8 sub 4 (- (Str8 length %ht-url) 4) %ht-url))))
(def %ht-missing (equal? (%ht-x "x" "ls-remote" %ht-nope) (%ht-g "g" "ls-remote" %ht-nope)))
(%ht-sh %ht-d "kill $(cat srvd/pid)")
(Sys wait %ht-server)
(write (list %ht-missing
             (first %ht-push)
             (Str8 includes? "pushing over http is not supported by x-git" (first (rest (rest %ht-push))))
             (first %ht-tls)
             (Str8 includes? "https is not yet supported by x-git" (first (rest (rest %ht-tls))))))
```
---
    (#t 128 #t 128 #t)
