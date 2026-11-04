# @weight 2
# @timeout-scale 3

Revisions against git itself: each is read by x-git and by git in the
same repository, and the two answers, output and refusal alike, are set
side by side.  Each section's first case makes its fixture; the cases
after it go on in it, a few commands each.

## upstreams

A clone of a repository with two branches.

### @{upstream} and @{u}, in any case, after a branch, HEAD or nothing

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "C") (pair "GIT_COMMITTER_EMAIL" "c@d.e") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(def %rv-dir (fn (_) (def t (File temp "/tmp/x-git-rv-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %rv-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %rv-same
  (fn (_ dir ops)
    (def x (apply git-text-in (pair dir ops)))
    (def g (apply git-oracle-in (pair dir ops)))
    (if (equal? x g) #t (list x g))))
(def %rv-top (%rv-dir))
(%rv-sh %rv-top
  (Str8 append "git init -q -b main up && cd up && echo a > a && git add a && git commit -q -m one"
               " && echo b >> a && git commit -q -a -m two && git branch topic HEAD~1"
               " && cd .. && git clone -q up r"))
(def %rv-r (Str8 append %rv-top "/r"))
(def %rv-both (fn (_ . ops) (%rv-same %rv-r ops)))
(def %rv-step (fn (_ script) (%rv-sh %rv-r script)))
(write
  (list (%rv-both "rev-parse" "@{u}" "@{upstream}" "@{U}" "@{UpStream}")
        (%rv-both "rev-parse" "main@{u}" "HEAD@{u}" "@{u}~1" "main@{u}^{tree}")
        (%rv-both "log" "--oneline" "-n" "1" "@{u}")))
```
---
    (#t #t #t)

### a branch that is not one, a full ref name, and a reflog entry after it refused as git refuses them

```git
(write
  (list (%rv-both "rev-parse" "nosuch@{u}")
        (%rv-both "rev-parse" "refs/heads/main@{u}")
        (%rv-both "rev-parse" "@{u}@{0}")))
```
---
    (#t #t #t)

### none configured, then the remote `.`, then one fetched to nowhere

```git
(write
  (list (do (%rv-step "git checkout -q -b loc") (%rv-both "rev-parse" "@{u}"))
        (%rv-both "rev-parse" "loc@{upstream}")
        (do (%rv-step "git config branch.loc.remote . && git config branch.loc.merge refs/heads/main")
            (%rv-both "rev-parse" "@{u}" "loc@{u}~1"))
        (do (%rv-step "git config branch.loc.remote origin && git config branch.loc.merge refs/heads/gone")
            (%rv-both "rev-parse" "@{u}"))))
```
---
    (#t #t #t #t)

### through the fetch refspecs: one that does not take the branch, then a pattern that does

```git
(write
  (list (do (%rv-step "git config branch.loc.merge refs/heads/topic && git config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'")
            (%rv-both "rev-parse" "@{u}"))
        (do (%rv-step "git config --add remote.origin.fetch '+refs/heads/t*c:refs/remotes/o2/x*y' && git update-ref refs/remotes/o2/xopiy HEAD~1")
            (%rv-both "rev-parse" "@{u}"))
        (do (%rv-step "git config branch.loc.remote nowhere") (%rv-both "rev-parse" "@{u}"))))
```
---
    (#t #t #t)

### no merge set, and HEAD on no branch, for rev-parse, show and log

```git
(write
  (list (do (%rv-step "git config --unset branch.loc.merge") (%rv-both "rev-parse" "@{u}"))
        (do (%rv-step "git checkout -q --detach") (%rv-both "rev-parse" "@{u}"))
        (%rv-both "show" "-s" "--oneline" "@{u}")
        (%rv-both "log" "--oneline" "@{u}")))
```
---
    (#t #t #t #t)

## commits by message

Two branches, a commit only HEAD's reflog reaches, and an annotated tag,
the commit dates out of the order they were made in.

### :/TEXT from every ref and HEAD, the newest match first

```git
(def %cm-r (%rv-dir))
(%rv-sh %cm-r
  (Str8 append
    "git init -q -b main . && c() { GIT_AUTHOR_DATE=\"$1 +0000\" GIT_COMMITTER_DATE=\"$1 +0000\"; export GIT_AUTHOR_DATE GIT_COMMITTER_DATE;"
    " echo \"$2\" >> f; git add f; git commit -q -m \"$2\" -m \"$3\"; }"
    " && c 1767225600 'fix: one' 'body of one' && c 1767225700 'feat: two words' 'two'"
    " && git checkout -q -b side && c 1767225900 'fix: side newer' 'x'"
    " && git checkout -q main && c 1767225800 'Fix: main three' 'y'"
    " && git tag -a -m 'tag msg fix' t1 HEAD~2"
    " && git checkout -q --detach HEAD~1 && c 1767225750 'fix: detached' 'z' && git checkout -q main"))
(def %cm-both (fn (_ . ops) (%rv-same %cm-r ops)))
(write
  (list (%cm-both "rev-parse" ":/fix" ":/Fix" ":/^feat")
        (%cm-both "rev-parse" ":/two w" ":/^fix: o" ":/body of")))
```
---
    (#t #t)

### the pattern an extended regular expression; `!-` negates it

```git
(write
  (list (%cm-both "rev-parse" ":/fi[x]" ":/f.x: s" ":/(one|two)")
        (%cm-both "rev-parse" ":/x+" ":/^(Fix|feat)" ":/!-fix")))
```
---
    (#t #t)

### `!!` alone, no match, and the rest of the revision the pattern, `~1` and `:PATH` too

```git
(write
  (list (%cm-both "rev-parse" ":/!!")
        (%cm-both "rev-parse" ":/nomatch")
        (%cm-both "rev-parse" ":/fix~1")
        (%cm-both "rev-parse" ":/fix:f")))
```
---
    (#t #t #t #t)

### REV^{/TEXT} from REV, a tag peeled, suffixes after it

```git
(write
  (list (%cm-both "rev-parse" "main^{/fix}" "main^{/^feat}" "side^{/one}")
        (%cm-both "rev-parse" "t1^{/one}" "main^{/fix}~1" "main^{/fix: o}")
        (%cm-both "rev-parse" "main^{/nomatch}")))
```
---
    (#t #t #t)

### in log and show

```git
(write
  (list (%cm-both "log" "-n" "1" "--oneline" ":/feat")
        (%cm-both "show" "-s" "--oneline" "side^{/^fix}")))
```
---
    (#t #t)

## reflog dates

A branch's log of three commits days apart, in three zones.  The dates
asked are a day or more from any entry, so the time of day a bare date
takes from the clock never decides one.

### REF@{DATE}: the value then, for a branch, HEAD and the current branch

```git
(def %rd-r (%rv-dir))
(%rv-sh %rd-r
  (Str8 append
    "git init -q -b main . && c() { GIT_AUTHOR_DATE=\"$1\" GIT_COMMITTER_DATE=\"$1\"; export GIT_AUTHOR_DATE GIT_COMMITTER_DATE;"
    " echo \"$2\" >> f; git add f; git commit -q -m \"$2\"; }"
    " && c 2026-01-01T12:00:00Z one && c 2026-01-15T12:00:00-05:00 two && c 2026-02-01T12:00:00+01:00 three"
    " && git branch side HEAD~1"))
(def %rd-both (fn (_ . ops) (%rv-same %rd-r ops)))
(write
  (list (%rd-both "rev-parse" "main@{2026-01-20}" "main@{2026-01-10}" "main@{2026-03-01}")
        (%rd-both "rev-parse" "@{2026-01-20}" "HEAD@{2026-01-20}")
        (%rd-both "rev-parse" "main@{2026-01-15 16:59:59 +0000}" "main@{2026-01-15 17:00:00 +0000}" "main@{2026-01-15T16:59:59}")))
```
---
    (#t #t #t)

### the date's forms: slashes, dots, month names, a timestamp, @EPOCH and relative dates

```git
(write
  (list (%rd-both "rev-parse" "main@{2026/01/20}" "main@{01/20/2026}" "main@{20.01.2026}")
        (%rd-both "rev-parse" "main@{Jan 20 2026}" "main@{20 Jan 2026}")
        (%rd-both "rev-parse" "main@{1767225600}" "main@{1767225599}" "main@{@1767225600}")
        (%rd-both "rev-parse" "main@{now}" "main@{1.week.ago}" "main@{2 years ago}" "main@{100 days ago}")))
```
---
    (#t #t #t #t)

### a date before the log: the oldest, with git's warning, under the name as given

```git
(write
  (list (%rd-both "rev-parse" "main@{2025-12-01}")
        (%rd-both "rev-parse" "@{2025-12-01}" "HEAD@{2025-12-01}" "refs/heads/main@{2025-12-01}")))
```
---
    (#t #t)

### suffixes after it; in log and show; a date git cannot read and a branch with no log refused

```git
(write
  (list (%rd-both "rev-parse" "main@{2026-01-20}~1" "main@{2026-01-20}^{tree}")
        (%rd-both "log" "--oneline" "-n" "1" "main@{2026-01-20}")
        (%rd-both "log" "--oneline" "main@{2025-12-01}")
        (%rd-both "show" "-s" "--oneline" "main@{2025-12-01}")
        (%rd-both "rev-parse" "main@{nonsense}")
        (%rd-both "rev-parse" "nosuch@{2026-01-20}")))
```
---
    (#t #t #t #t #t #t)
