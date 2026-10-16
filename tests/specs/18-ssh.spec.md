# @weight 4
# @timeout-scale 2

clone, fetch, push and ls-remote over ssh.  The ssh is a stand-in, as
git's own tests use one: a script that writes the arguments it is given
to a log, one to a line, then runs the last of them -- the service's
command line -- here with `sh -c`, which is what an sshd does with it.
x-git and git (held to protocol version 0, which x-git speaks) each run
through it, so the command lines they give an ssh -- `-p PORT`, the host,
the service and its quoted path -- are compared as well as what they
leave.  `GIT_SSH`, `GIT_SSH_COMMAND` and `core.sshCommand` choose the ssh
as git chooses one.

## through GIT_SSH

### ls-remote ssh://user@host:port/path, the path holding a quote

```git
(def %ss-dir (fn (_) (def t (File temp "/tmp/x-git-ss-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %ss-env "export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=A GIT_COMMITTER_EMAIL=a@b.c; ")
(def %ss-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append %ss-env "cd \"$0\" && " script) dir))))
(def %ss-d (%ss-dir))
(File write-all (Str8 append %ss-d "/fake-ssh")
  "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> \"$FAKE_SSH_LOG\"; done\nprintf -- '--\\n' >> \"$FAKE_SSH_LOG\"\nwhile [ $# -gt 1 ]; do shift; done\nexec sh -c \"$1\"\n")
(%ss-sh %ss-d "chmod +x fake-ssh")
(Sys setenv "GIT_SSH" (Str8 append %ss-d "/fake-ssh"))
(Sys setenv "GIT_SSH_VARIANT" "ssh")
(def %ss-xlog (Str8 append %ss-d "/x.log"))
(def %ss-glog (Str8 append %ss-d "/g.log"))
(def %ss-x (fn (_ dir . ops) (do (Sys setenv "FAKE_SSH_LOG" %ss-xlog) (apply git-text-in (pair dir ops)))))
(def %ss-g (fn (_ dir . ops) (do (Sys setenv "FAKE_SSH_LOG" %ss-glog) (apply git-oracle-in (pair dir (pair "-c" (pair "protocol.version=0" ops)))))))
(def %ss-logs-equal? (fn (_) (str=? (File read-all %ss-xlog) (File read-all %ss-glog))))
(%ss-sh %ss-d "git init -q -b main \"it's.git\" && cd \"it's.git\" && printf 'one\\n' > f && git add f && git commit -qm one && git tag -a v1 -m tagged && git checkout -qb feature && printf x > g && git add g && git commit -qm feat && git checkout -q main")
(def %ss-src (Str8 append %ss-d "/it's.git"))
(def %ss-url (Str8 append "ssh://user@example.org:2222" %ss-src))
(write (list (equal? (%ss-x %ss-d "ls-remote" %ss-url) (%ss-g %ss-d "ls-remote" %ss-url))
             (%ss-logs-equal?)
             (List take 3 (Str8 split "\n" (File read-all %ss-xlog)))))
```
---
    (#t #t ("-p" "2222" "user@example.org"))

### clone host:path, scp's form, into the directory git names from the path

```git
(%ss-sh %ss-d "mkdir x g")
(def %ss-scp (Str8 append "example.org:" %ss-src))
(def %ss-xc (%ss-x (Str8 append %ss-d "/x") "clone" %ss-scp))
(def %ss-gc (%ss-g (Str8 append %ss-d "/g") "clone" %ss-scp))
(def %ss-xw (Str8 append %ss-d "/x/it's"))
(def %ss-gw (Str8 append %ss-d "/g/it's"))
(write (list (equal? %ss-xc %ss-gc)
             (%ss-logs-equal?)
             (equal? (git-oracle-in %ss-xw "for-each-ref") (git-oracle-in %ss-gw "for-each-ref"))
             (equal? (git-oracle-in %ss-xw "config" "remote.origin.url") (git-oracle-in %ss-gw "config" "remote.origin.url"))
             (equal? (git-oracle-in %ss-xw "status" "--porcelain") (git-oracle-in %ss-gw "status" "--porcelain"))
             (first (git-oracle-in %ss-xw "fsck" "--strict"))))
```
---
    (#t #t #t #t #t 0)

### fetch through the remote's url, what the source grew

```git
(%ss-sh %ss-src "printf 'two\\n' >> f && git commit -qam two && git tag -a v2 -m second")
(def %ss-xf (%ss-x %ss-xw "fetch"))
(def %ss-gf (%ss-g %ss-gw "fetch"))
(write (list (equal? %ss-xf %ss-gf)
             (%ss-logs-equal?)
             (equal? (git-oracle-in %ss-xw "for-each-ref") (git-oracle-in %ss-gw "for-each-ref"))
             (str=? (File read-all (Str8 append %ss-xw "/.git/FETCH_HEAD")) (File read-all (Str8 append %ss-gw "/.git/FETCH_HEAD")))
             (first (git-oracle-in %ss-xw "fsck" "--strict"))))
```
---
    (#t #t #t #t 0)

### push to twin bare repositories through git-receive-pack

```git
(%ss-sh %ss-d "git clone -q --bare \"it's.git\" x/bare.git && git clone -q --bare \"it's.git\" g/bare.git && git clone -q \"it's.git\" p && cd p && printf 'three\\n' >> f && git commit -qam three")
(def %ss-p (Str8 append %ss-d "/p"))
(def %ss-xp (%ss-x %ss-p "push" (Str8 append "ssh://example.org" %ss-d "/x/bare.git") "main"))
(def %ss-gp (%ss-g %ss-p "push" (Str8 append "ssh://example.org" %ss-d "/g/bare.git") "main"))
(def %ss-scrub (fn (_ r) (pair (first r) (Str8 join "<dir>" (Str8 split "/g/bare.git" (Str8 join "<dir>" (Str8 split "/x/bare.git" (rest r))))))))
(write (list (equal? (%ss-scrub %ss-xp) (%ss-scrub %ss-gp))
             (first %ss-xp)
             (str=? (Str8 join "" (Str8 split "/x/" (File read-all %ss-xlog))) (Str8 join "" (Str8 split "/g/" (File read-all %ss-glog))))
             (equal? (git-oracle-in (Str8 append %ss-d "/x/bare.git") "for-each-ref") (git-oracle-in (Str8 append %ss-d "/g/bare.git") "for-each-ref"))
             (first (git-oracle-in (Str8 append %ss-d "/x/bare.git") "fsck" "--strict"))))
```
---
    (#t 0 #t #t 0)

## choosing the ssh

### GIT_SSH_COMMAND, a command line with options of its own, before GIT_SSH

```git
(File unlink %ss-xlog) (File unlink %ss-glog)
(Sys setenv "GIT_SSH_COMMAND" (Str8 append "'" %ss-d "/fake-ssh' -o Opt=1"))
(def %ss-xc2 (%ss-x %ss-d "ls-remote" %ss-url))
(def %ss-gc2 (%ss-g %ss-d "ls-remote" %ss-url))
(Sys unsetenv "GIT_SSH_COMMAND")
(write (list (equal? %ss-xc2 %ss-gc2) (%ss-logs-equal?)
             (List take 2 (Str8 split "\n" (File read-all %ss-xlog)))))
```
---
    (#t #t ("-o" "Opt=1"))

### core.sshCommand in the repository's config

```git
(File unlink %ss-xlog) (File unlink %ss-glog)
(%ss-sh %ss-xw (Str8 append "git config core.sshCommand \"'" %ss-d "/fake-ssh' -o Conf=1\""))
(%ss-sh %ss-gw (Str8 append "git config core.sshCommand \"'" %ss-d "/fake-ssh' -o Conf=1\""))
(write (list (equal? (%ss-x %ss-xw "ls-remote" "origin") (%ss-g %ss-gw "ls-remote" "origin"))
             (%ss-logs-equal?)
             (List take 2 (Str8 split "\n" (File read-all %ss-xlog)))))
```
---
    (#t #t ("-o" "Conf=1"))

### an ssh that cannot connect is refused in git's words

```git
(File write-all (Str8 append %ss-d "/dead-ssh") "#!/bin/sh\nexit 255\n")
(%ss-sh %ss-d "chmod +x dead-ssh")
(Sys setenv "GIT_SSH" (Str8 append %ss-d "/dead-ssh"))
(def %ss-xd (%ss-x %ss-d "ls-remote" %ss-url))
(def %ss-gd (%ss-g %ss-d "ls-remote" %ss-url))
(Sys setenv "GIT_SSH" (Str8 append %ss-d "/fake-ssh"))
(write (list (equal? %ss-xd %ss-gd) %ss-xd))
```
---
    (#t (128 . "fatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n"))
