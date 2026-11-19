# @weight 3

add and commit, against git itself: x-git writes the index, the blobs,
the trees, the commit and the ref, and the system git reads every one of
them back.  The loose fixture is fresh for this file and its state is
cumulative down the cases.

## add

### a pathspec nothing matches is refused in git's words

```git
(write (list (git-text "add" "nosuch") (git-oracle "add" "nosuch")))
```
---
    ((128 . "fatal: pathspec 'nosuch' did not match any files\n") (128 . "fatal: pathspec 'nosuch' did not match any files\n"))

### a new file and a changed one staged by x-git, read by git

```git
(def %cm (git-fixture))
(File write-all (Str8 append %cm "/n.txt") "new\n")
(File write-all (Str8 append %cm "/f.txt") "hello\nmore\n")
(write (list (git-text "add" "n.txt" "f.txt")
             (git-oracle "status" "--porcelain")
             (equal? (git-text "ls-files" "--stage") (git-oracle "ls-files" "--stage"))
             (git-oracle "cat-file" "-p" (Str8 trim (rest (git-oracle "rev-parse" ":n.txt"))))))
```
---
    ((0 . "") (0 . "M  f.txt\nA  n.txt\n") #t (0 . "new\n"))

## commit

### the commit git reads back: its summary, its object, the log, a clean tree

```git
(def %cm (git-fixture))
(def %cm-r (git-text "commit" "-m" "two"))
(def %cm-head (Str8 trim (rest (git-oracle "rev-parse" "HEAD"))))
(def %cm-lines (Str8 split "\n" (rest %cm-r)))
(write (list (first %cm-r)
             (str=? (first %cm-lines) (Str8 append "[main " (Str8 sub 0 7 %cm-head) "] two"))
             (List ref 1 %cm-lines) (List ref 2 %cm-lines)
             (git-oracle "log" "--oneline" "--format=%s")
             (git-oracle "log" "-1" "--format=%an <%ae>")
             (git-oracle "status" "--porcelain")
             (first (git-oracle "fsck" "--strict"))))
```
---
    (0 #t " 2 files changed, 2 insertions(+)" " create mode 100644 n.txt" (0 . "two\ninit\n") (0 . "A <a@b.c>\n") (0 . "") 0)

### the commit object as git prints it

```git
(def %cm (git-fixture))
(def %cm-obj (Str8 split "\n" (rest (git-oracle "cat-file" "-p" "HEAD"))))
(write (list (Str8 sub 0 5 (first %cm-obj)) (Str8 sub 0 7 (List ref 1 %cm-obj))
             (Str8 starts? "author A <a@b.c> " (List ref 2 %cm-obj))
             (Str8 starts? "committer A <a@b.c> " (List ref 3 %cm-obj))
             (List ref 4 %cm-obj) (List ref 5 %cm-obj)
             (equal? (git-oracle "rev-parse" "HEAD^{tree}") (git-oracle "rev-parse" "HEAD^{tree}"))
             (equal? (git-text "ls-tree" "-r" "HEAD") (git-oracle "ls-tree" "-r" "HEAD"))))
```
---
    ("tree " "parent " #t #t "" "two" #t #t)

### a removal staged with add, committed: the deletion line

```git
(def %cm (git-fixture))
(File unlink (Str8 append %cm "/n.txt"))
(def %cm-add (git-text "add" "n.txt"))
(def %cm-r (git-text "commit" "-m" "drop it"))
(write (list %cm-add (first %cm-r) (rest (Str8 split "\n" (rest %cm-r)))
             (git-oracle "status" "--porcelain")
             (equal? (git-text "ls-tree" "HEAD") (git-oracle "ls-tree" "HEAD"))))
```
---
    ((0 . "") 0 (" 1 file changed, 1 deletion(-)" " delete mode 100644 n.txt" "") (0 . "") #t)

### nothing to commit prints the status, status 1; -q prints nothing

```git
(def %cm (git-fixture))
(def %cm-r (git-text "commit" "-m" "again"))
(File write-all (Str8 append %cm "/f.txt") "quiet\n")
(git-text "add" "f.txt")
(write (list %cm-r (git-text "commit" "-q" "-m" "quietly") (git-oracle "log" "--format=%s")))
```
---
    ((1 . "On branch main\nnothing to commit, working tree clean\n") (0 . "") (0 . "quietly\ndrop it\ntwo\ninit\n"))

### add -A stages everything, in a subdirectory too; git's commit follows x-git's

```git
(def %cm (git-fixture))
(File mkdir (Str8 append %cm "/deep"))
(File write-all (Str8 append %cm "/deep/one") "1\n")
(File write-all (Str8 append %cm "/sub/g") "changed\n")
(git-text "add" "-A")
(def %cm-r (git-text "commit" "-m" "deep"))
(File write-all (Str8 append %cm "/deep/two") "2\n")
(git-oracle "add" "-A")
(git-oracle "commit" "-q" "-m" "by git")
(write (list (rest (Str8 split "\n" (rest %cm-r)))
             (equal? (git-text "log" "--oneline") (git-oracle "log" "--oneline"))
             (equal? (git-text "ls-tree" "-r" "HEAD") (git-oracle "ls-tree" "-r" "HEAD"))
             (git-oracle "status" "--porcelain")))
```
---
    ((" 2 files changed, 2 insertions(+), 1 deletion(-)" " create mode 100644 deep/one" "") #t #t (0 . ""))

## who

### the author and committer found as git finds them: <role>.name and .email, then user.*, then EMAIL

Twin repositories, x-git committing in one and git in the other, the
user's and the system's config set aside and the dates fixed, so the two
commits and their reflog lines are compared byte for byte.

```git
(def %who-env
  (list (pair "GIT_CONFIG_GLOBAL" "/dev/null") (pair "GIT_CONFIG_NOSYSTEM" "1")
        (pair "GIT_AUTHOR_DATE" "2026-01-01T00:00:00Z") (pair "GIT_COMMITTER_DATE" "2026-01-01T00:00:00Z")
        (pair "EMAIL" "e@mail.x")))
(List for-each (fn (_ e) (Sys setenv (first e) (rest e))) %who-env)
(def %who-mk
  (fn (_ config)
    (def d (let ((t (File temp "/tmp/x-git-who-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
    (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && git init -q -b main && echo a>f && git add f" config) d))
    d))
(def %who
  (fn (_ config)
    (def x (%who-mk config))
    (def g (%who-mk config))
    (def xr (git-text-in x "commit" "-q" "-m" "one"))
    (def gr (git-oracle-in g "commit" "-q" "-m" "one"))
    (list xr (equal? xr gr)
          (equal? (git-oracle-in x "cat-file" "-p" "HEAD") (git-oracle-in g "cat-file" "-p" "HEAD"))
          (equal? (File read-all (Str8 append x "/.git/logs/HEAD")) (File read-all (Str8 append g "/.git/logs/HEAD")))
          (List filter (fn (_ l) (or (Str8 starts? "author " l) (Str8 starts? "committer " l)))
            (Str8 split "\n" (rest (git-oracle-in x "cat-file" "-p" "HEAD")))))))
(write (list (%who " && git config user.name U && git config user.email u@x && git config author.name AN && git config committer.email ce@x")
             (%who " && git config user.name U && git config committer.name CN")))
(List for-each (fn (_ e) (Sys unsetenv (first e))) %who-env)
```
---
    (((0 . "") #t #t #t ("author AN <u@x> 1767225600 +0000" "committer U <ce@x> 1767225600 +0000")) ((0 . "") #t #t #t ("author U <e@mail.x> 1767225600 +0000" "committer CN <e@mail.x> 1767225600 +0000")))

### a name or email not given is guessed from the account and the host, as git guesses it

With no name or no email given, git guesses: the name from the account's
full name, the email from the login and the host's full name.  A commit
made with a guessed email says so after its first line (a guessed name
alone passes); a guess git cannot use (a host name with no domain, an
account with no full name) refuses the commit; the reflog takes the
guess either way.  What the guess comes to is this machine's, so each
case answers whether x-git and git agree -- the report, the commit, the
reflog -- and whether git said what the case expects of it.  HOME is a
directory of the case's, since the note's wording turns on whether a
~/.gitconfig is there.

```git
(def %gx-env
  (list (pair "GIT_CONFIG_GLOBAL" "/dev/null") (pair "GIT_CONFIG_NOSYSTEM" "1")
        (pair "GIT_AUTHOR_DATE" "2026-01-01T00:00:00Z") (pair "GIT_COMMITTER_DATE" "2026-01-01T00:00:00Z")))
(def %gx-home (Sys getenv "HOME"))
(def %gx-mail (Sys getenv "EMAIL"))
(List for-each (fn (_ e) (Sys setenv (first e) (rest e))) %gx-env)
(Sys unsetenv "EMAIL")
(def %gx-dir
  (fn (_ p)
    (let ((t (File temp p))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))))
(def %gx-mk
  (fn (_ setup)
    (def d (%gx-dir "/tmp/x-git-guess-"))
    (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && git init -q -b main && echo a>f && git add f" setup) d))
    d))
(def %gx-log (fn (_ d) (let ((p (Str8 append d "/.git/logs/HEAD"))) (if (File exists? p) (File read-all p) ()))))
; the commit made with the note, or refused for a guess git cannot use:
; a host with no domain, an account with no full name
(def %gx-refused
  (fn (_ s) (or (Str8 includes? "fatal: unable to auto-detect email address" s)
                (Str8 includes? "fatal: empty ident name" s))))
(def %gx-noted
  (fn (_ s) (or (Str8 includes? "were configured automatically" s) (%gx-refused s))))
(def %gx-plain (fn (_ s) (or (not (Str8 includes? " Committer: " s)) (%gx-refused s))))
(def %gx-quiet
  (fn (_ s) (or (and (Str8 includes? " Committer: " s) (not (Str8 includes? "were configured automatically" s)))
                (%gx-refused s))))
(def %gx-switched (fn (_ s) (Str8 includes? "Switched to a new branch 'side'" s)))
; the setup's shell steps, a ~/.gitconfig or not, what git must say
(def %gx
  (fn (_ setup gitconfig? said? . ops)
    (def home (%gx-dir "/tmp/x-git-home-"))
    (when gitconfig? (Proc run! (list "/bin/sh" "-c" "touch \"$0/.gitconfig\"" home)))
    (Sys setenv "HOME" home)
    (def x (%gx-mk setup))
    (def g (%gx-mk setup))
    (def xr (apply git-text-in (pair x ops)))
    (def gr (apply git-oracle-in (pair g ops)))
    (def r (list (equal? (rest xr) (rest gr))
                 (equal? (git-oracle-in x "cat-file" "-p" "HEAD") (git-oracle-in g "cat-file" "-p" "HEAD"))
                 (equal? (%gx-log x) (%gx-log g))
                 (said? (rest gr))))
    (if (List all? (fn (_ b) (eq? b #t)) r) #t (list r (rest xr) (rest gr)))))
(write (list
  (%gx "" #f %gx-noted "commit" "-m" "one")
  (%gx "" #t %gx-noted "commit" "-m" "one")
  (%gx " && git config user.name U" #f %gx-noted "commit" "-m" "one")
  (%gx " && git config user.name U" #t %gx-noted "commit" "-m" "one")
  (%gx " && git config user.email u@x" #f %gx-plain "commit" "-m" "one")
  (%gx " && git config advice.implicitIdentity false" #f %gx-quiet "commit" "-m" "one")
  (%gx " && git -c user.name=A -c user.email=a@b.c commit -q -m one" #f %gx-switched "checkout" "-b" "side")))
(List for-each (fn (_ e) (Sys unsetenv (first e))) %gx-env)
(Sys setenv "HOME" %gx-home)
(when (not (null? %gx-mail)) (Sys setenv "EMAIL" %gx-mail))
```
---
    (#t #t #t #t #t #t #t)
