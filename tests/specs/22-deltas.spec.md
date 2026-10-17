# @weight 4
# @timeout-scale 3

Deltas in the packs x-git writes, and thin packs both ways.  The source
is three commits of a 2000-line text file and a 16 KB binary one: lines
dropped, lines inserted, a line changed; bytes inserted in the middle.
A pack x-git writes is read by git -- `verify-pack -v` names each delta
and its depth, `fsck` rebuilds every object.  A thin pack's deltas may
build on objects the reader already has; the reader completes it by
appending those bases whole -- git's index-pack --fix-thin for the packs
x-git sends, x-git's own for the packs git sends -- so a base the
sender never sent, found in the new pack, shows the pack came thin.
The receivers keep packs whole (`receive.unpackLimit`,
`fetch.unpackLimit` 1) so there is a pack to read.  x-git's services
are started as 16-serve starts them.

## the packs x-git writes

### a push by path writes the older blobs as deltas, and git reads them

```git
(def %dl-dir (fn (_) (def t (File temp "/tmp/x-git-dl-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %dl-env "export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=A GIT_COMMITTER_EMAIL=a@b.c; ")
(def %dl-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append %dl-env "cd " dir " && " script)))))
(def %dl-d (%dl-dir))
(%dl-sh %dl-d (Str8 append
  "git init -q -b main src && cd src"
  " && awk 'BEGIN { for (i = 0; i < 2000; i++) print \"row \" i \": \" (i * 7919) % 10007 }' > t.txt"
  " && dd if=/dev/urandom of=b.bin bs=1024 count=16 2>/dev/null"
  " && git add . && git commit -qm one"
  " && awk 'NR >= 50 && NR < 60 { next } NR == 1000 { print \"an inserted line\"; print \"and another\" } NR == 1500 { print \"CHANGED\"; next } { print }' t.txt > t.new && mv t.new t.txt"
  " && { head -c 8000 b.bin; printf 'PATCHED IN THE MIDDLE'; tail -c +8001 b.bin; } > b.new && mv b.new b.bin"
  " && git commit -qam two"
  " && awk 'NR == 10 { print \"row ten\"; next } { print } END { for (i = 0; i < 20; i++) print \"tail \" i }' t.txt > t.new && mv t.new t.txt"
  " && git commit -qam three"))
(def %dl-src (Str8 append %dl-d "/src"))
(def %dl-blob (fn (_ rev) (git-sha-in %dl-src rev)))
(def %dl-packs
  (fn (_ dir) (List filter (fn (_ f) (Str8 ends? ".idx" f)) (File list-dir (Str8 append dir "/objects/pack")))))
; verify-pack -v's rows for a pack: each the words of one line
(def %dl-rows
  (fn (_ dir idx)
    (List map (fn (_ r) (List filter (fn (_ w) (> (Str8 length w) 0)) (Str8 split " " r)))
      (Str8 split "\n" (rest (git-oracle-in dir "verify-pack" "-v" (Str8 append "objects/pack/" idx)))))))
; an object's depth in those rows: 0 when it is whole, () when absent
(def %dl-depth
  (fn (_ rows sha)
    (def r (List find (fn (_ ws) (and (not (null? ws)) (str=? (first ws) sha))) rows))
    (match ((null? r) ()) ((= (List length r) 7) (List ref 5 r)) (#t 0))))
(%dl-sh %dl-d "git init -q --bare by-path.git")
(def %dl-bp (Str8 append %dl-d "/by-path.git"))
(def %dl-push (git-text-in %dl-src "push" %dl-bp "main"))
(def %dl-bp-rows (%dl-rows %dl-bp (first (%dl-packs %dl-bp))))
(write (list (first %dl-push)
             (List map (fn (_ rev) (%dl-depth %dl-bp-rows (%dl-blob rev))) (list "HEAD:t.txt" "HEAD~1:t.txt" "HEAD~2:t.txt"))
             (List map (fn (_ rev) (%dl-depth %dl-bp-rows (%dl-blob rev))) (list "HEAD:b.bin" "HEAD~2:b.bin"))
             (first (git-oracle-in %dl-bp "fsck" "--strict"))
             (equal? (git-oracle-in %dl-bp "cat-file" "-p" "main~1:t.txt") (git-oracle-in %dl-src "cat-file" "-p" "main~1:t.txt"))))
```
---
    (0 (0 "1" "1") (0 "1") 0 #t)

The largest of each file is whole and the others deltas against it,
as git's own repack leaves them.

### git clones from x-git's upload-pack: deltas by offset

```git
(def %dl-langs (Str8 append %dl-d "/langs"))
(%dl-sh %dl-d (Str8 append "mkdir langs && ln -s '" (Sys getenv "X_GIT_BUNDLE") "' langs/git"))
(def %dl-launch (fn (_ env cmd) (Str8 append "unset X_IMG_DIR; cd '" (Sys getenv "X_ROOT") "' && " env " X_LANG_DIR=" %dl-langs "/ '" (Sys getenv "X") "' -l git -- " cmd)))
(%dl-sh %dl-d (Str8 append (%dl-launch "" "version") " >/dev/null 2>&1"))
(def %dl-up (Str8 append "--upload-pack=" (%dl-launch "X_IMAGE_NO_WRITE=1" "upload-pack")))
(def %dl-rp (Str8 append "--receive-pack=" (%dl-launch "X_IMAGE_NO_WRITE=1" "receive-pack")))
(def %dl-clone (git-oracle-in %dl-d "clone" "-q" "--bare" %dl-up (Str8 append "file://" %dl-src) "cloned.git"))
(def %dl-cl (Str8 append %dl-d "/cloned.git"))
(def %dl-cl-rows (%dl-rows %dl-cl (first (%dl-packs %dl-cl))))
(write (list %dl-clone
             (List map (fn (_ rev) (%dl-depth %dl-cl-rows (%dl-blob rev))) (list "HEAD:t.txt" "HEAD~1:t.txt" "HEAD~2:t.txt"))
             (first (git-oracle-in %dl-cl "fsck" "--strict"))))
```
---
    ((0 . "") (0 "1" "1") 0)

## thin packs

### x-git pushes thin to git's receive-pack

The far end has the first commit; the second push sends the other two.
The newest blob is a delta on the first, which the far end had, and the
second a delta on the newest; the first blob, never sent, is in the
pack git kept, appended whole.

```git
(%dl-sh %dl-d (Str8 append "git init -q --bare thin.git && git -C thin.git config receive.unpackLimit 1"
                           " && git clone -q src w1 && cd w1 && git reset -q --hard HEAD~2"))
(def %dl-w1 (Str8 append %dl-d "/w1"))
(def %dl-thin (Str8 append %dl-d "/thin.git"))
(def %dl-p1 (git-text-in %dl-w1 "push" (Str8 append "file://" %dl-thin) "main"))
(%dl-sh %dl-w1 "git merge -q --ff-only origin/main")
(def %dl-before (%dl-packs %dl-thin))
(def %dl-p2 (git-text-in %dl-w1 "push" (Str8 append "file://" %dl-thin) "main"))
(def %dl-new (first (List filter (fn (_ f) (not (List any? (fn (_ g) (str=? f g)) %dl-before))) (%dl-packs %dl-thin))))
(def %dl-new-rows (%dl-rows %dl-thin %dl-new))
(write (list (first %dl-p1) (first %dl-p2)
             (List map (fn (_ rev) (%dl-depth %dl-new-rows (%dl-blob rev))) (list "HEAD:t.txt" "HEAD~1:t.txt" "HEAD~2:t.txt"))
             (first (git-oracle-in %dl-thin "fsck" "--strict"))
             (equal? (git-sha-in %dl-thin "main") (git-sha-in %dl-src "main"))))
```
---
    (0 0 ("1" "2" 0) 0 #t)

### git fetches thin from x-git's upload-pack

```git
(%dl-sh %dl-d "git clone -q --bare src old.git && git -C old.git update-ref refs/heads/main main~2 && git -C old.git repack -adq && git -C old.git prune")
(def %dl-old (Str8 append %dl-d "/old.git"))
(def %dl-before2 (%dl-packs %dl-old))
(def %dl-f (git-oracle-in %dl-old "-c" "fetch.unpackLimit=1" "fetch" "-q" %dl-up (Str8 append "file://" %dl-src) "main:main"))
(def %dl-new2 (first (List filter (fn (_ f) (not (List any? (fn (_ g) (str=? f g)) %dl-before2))) (%dl-packs %dl-old))))
(def %dl-new2-rows (%dl-rows %dl-old %dl-new2))
(write (list %dl-f
             (List map (fn (_ rev) (%dl-depth %dl-new2-rows (%dl-blob rev))) (list "HEAD:t.txt" "HEAD~1:t.txt" "HEAD~2:t.txt"))
             (first (git-oracle-in %dl-old "fsck" "--strict"))
             (equal? (git-sha-in %dl-old "main") (git-sha-in %dl-src "main"))))
```
---
    ((0 . "") ("1" "2" 0) 0 #t)

## thin packs x-git completes

### git pushes thin to x-git's receive-pack

```git
(%dl-sh %dl-d "git init -q --bare xr.git && git clone -q src w2 && cd w2 && git reset -q --hard HEAD~2")
(def %dl-xr (Str8 append %dl-d "/xr.git"))
(def %dl-w2 (Str8 append %dl-d "/w2"))
(def %dl-g1 (git-oracle-in %dl-w2 "push" "-q" %dl-rp (Str8 append "file://" %dl-xr) "main"))
(%dl-sh %dl-w2 "git merge -q --ff-only origin/main")
(def %dl-g2 (git-oracle-in %dl-w2 "push" "-q" %dl-rp (Str8 append "file://" %dl-xr) "main"))
(write (list %dl-g1 %dl-g2
             (first (git-oracle-in %dl-xr "fsck" "--strict"))
             (List map (fn (_ f) (first (git-oracle-in %dl-xr "verify-pack" (Str8 append "objects/pack/" f)))) (%dl-packs %dl-xr))
             (equal? (git-sha-in %dl-xr "main") (git-sha-in %dl-src "main"))))
```
---
    ((0 . "") (0 . "") 0 (0 0) #t)

### x-git fetches thin from git's upload-pack

```git
(%dl-sh %dl-d "git clone -q --bare src xf-src.git && git -C xf-src.git update-ref refs/heads/main main~2")
(def %dl-xc (git-text-in %dl-d "clone" (Str8 append "file://" %dl-d "/xf-src.git") "xf"))
(%dl-sh %dl-d "git -C xf-src.git update-ref refs/heads/main $(git -C src rev-parse main)")
(def %dl-xf (Str8 append %dl-d "/xf"))
(def %dl-fx (git-text-in %dl-xf "fetch" "origin"))
(write (list (first %dl-xc) (first %dl-fx)
             (first (git-oracle-in %dl-xf "fsck" "--strict"))
             (List map (fn (_ f) (first (git-oracle-in (Str8 append %dl-xf "/.git") "verify-pack" (Str8 append "objects/pack/" f))))
               (%dl-packs (Str8 append %dl-xf "/.git")))
             (equal? (git-sha-in %dl-xf "origin/main") (git-sha-in %dl-src "main"))))
```
---
    (0 0 0 (0 0) #t)
