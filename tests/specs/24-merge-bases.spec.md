# @weight 4
# @timeout-scale 3

Merges with more than one merge base.  A criss-cross history -- two
branches each merging the other -- leaves two commits as the best common
ancestors of their next tips; git's ort merges those into one, a virtual
base, and merges from it.  Each case builds the history in a source,
every commit a second after the last so the bases have an order, clones
it twice into x/w and g/w, and merges origin/x into main there, x-git in
one and git in the other.  What each prints and leaves -- the commit,
the index with its stages (stage 1 is the virtual base's), the status,
the file -- is compared.

## the bases merged into one

### the bases took different sides of a conflict: it is a conflict again

The cross merges settled line 10 each its own way, so the virtual base
holds that conflict marked, and both tips differ from it there.

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(def %mb-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %mb-plain
  (fn (_ s)
    (def kept (List filter (fn (_ l) (not (or (= (Str8 length l) 0) (Str8 starts? "hint:" l)))) (Str8 split "\n" s)))
    (Str8 join "" (List map (fn (_ l) (Str8 append l "\n")) kept))))
(def %mb-x
  (fn (_ dir . ops)
    (def r (git-run (git-plan (pair "-C" (pair dir ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out))
      (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) (%mb-plain text)))))
(def %mb-g
  (fn (_ dir . ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>\"$0/../git.err\"" (pair dir ops))))))
    (list (first r) (rest r) (%mb-plain (File read-all (Str8 append dir "/../git.err"))))))
(def %mb-d ())
(def %mb-xw ())
(def %mb-gw ())
; a line of f changed to a word, and committed at second n
(def %mb-edit
  (fn (_ line word n msg)
    (Str8 append "sed 's/^" line "$/" word "/' f > f.new && mv f.new f && D " n " && git commit -qam " msg)))
; the history: base; x1 and m1; the cross merges, each settled by
; resolve (a shell command run with the conflict, if any, in place); x2
; and m2.  Then the twins, and the merges.
(def %mb-case
  (fn (_ x1 m1 resolve-x resolve-m x2 m2)
    (def t (File temp "/tmp/x-git-mb-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %mb-d (rest t))
    (set! %mb-xw (Str8 append %mb-d "/x/w"))
    (set! %mb-gw (Str8 append %mb-d "/g/w"))
    (%mb-sh %mb-d
      (Str8 append
        "D() { export GIT_AUTHOR_DATE=\"$((1767225600 + $1)) +0000\" GIT_COMMITTER_DATE=\"$((1767225600 + $1)) +0000\"; }; "
        "git init -q -b main src && cd src && seq 1 30 > f && git add f && D 1 && git commit -qm base"
        " && git checkout -qb x && " x1
        " && git checkout -q main && " m1
        " && git checkout -q x && { git merge -q --no-edit main >/dev/null 2>&1; " resolve-x "; D 4; git commit -qam 'x takes main' >/dev/null 2>&1; true; }"
        " && git checkout -q main && { git merge -q --no-edit x^1 >/dev/null 2>&1; " resolve-m "; D 5; git commit -qam 'main takes x' >/dev/null 2>&1; true; }"
        " && git checkout -q x && " x2
        " && git checkout -q main && " m2
        " && cd .. && mkdir x g && git clone -q src x/w && git clone -q src g/w"))
    (list (%mb-x %mb-xw "merge" "origin/x") (%mb-g %mb-gw "merge" "origin/x"))))
(def %mb-file (fn (_ dir path) (let ((p (Str8 append dir "/" path))) (if (File exists? p) (File read-all p) ()))))
(def %mb-same?
  (fn (_)
    (and (equal? (git-oracle-in %mb-xw "rev-parse" "HEAD") (git-oracle-in %mb-gw "rev-parse" "HEAD"))
         (equal? (git-oracle-in %mb-xw "ls-files" "-s") (git-oracle-in %mb-gw "ls-files" "-s"))
         (equal? (git-oracle-in %mb-xw "status" "--porcelain") (git-oracle-in %mb-gw "status" "--porcelain"))
         (equal? (%mb-file %mb-xw "f") (%mb-file %mb-gw "f")))))
(def %mb-1
  (%mb-case (%mb-edit "10" "ten-x" "2" "x1") (%mb-edit "10" "ten-m" "3" "m1")
            "git checkout -q --ours f" "git checkout -q --ours f"
            (%mb-edit "20" "twenty-x" "6" "x2") (%mb-edit "1" "one-m" "7" "m2")))
(write (list (equal? (first %mb-1) (first (rest %mb-1))) (first (first %mb-1)) (%mb-same?)
             (List length (Str8 split "\n" (Str8 trim (rest (git-oracle-in %mb-gw "merge-base" "--all" "HEAD" "origin/x")))))
             (Str8 includes? "<<<<<<<<< Temporary merge branch 1"
               (rest (git-oracle-in %mb-xw "cat-file" "-p" (Str8 trim (rest (git-oracle-in %mb-xw "rev-parse" ":1:f"))))))))
```
---
    (#t 1 #t 2 #t)

### the bases agree but for what each took first: a clean merge

```git
(def %mb-2
  (%mb-case (%mb-edit "5" "five-x" "2" "x1") (%mb-edit "25" "twentyfive-m" "3" "m1")
            "true" "true"
            (%mb-edit "15" "fifteen-x" "6" "x2") (%mb-edit "3" "three-m" "7" "m2")))
(write (list (equal? (first %mb-2) (first (rest %mb-2))) (first (first %mb-2)) (%mb-same?)
             (rest (git-oracle-in %mb-xw "log" "-1" "--format=%s"))))
```
---
    (#t 0 #t "Merge remote-tracking branch 'origin/x'\n")
