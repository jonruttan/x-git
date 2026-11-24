; # x-git -- git on x-lang
;
; ## lib/git/describe.x -- describe
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A commit named from the nearest tag: the tag itself when it names the
; commit, else TAG-N-gABBREV, N the commits reachable from the commit and
; not from the tag.  The walk is git's: commits newest first, each
; carrying a bit for every candidate tag that reaches it, up to ten
; candidates; the fewest commits wins, the first found among equals, and
; the walk then runs on until the winner's count is exact.  A commit
; names its annotated tag over a lightweight one, the newest annotated
; among several, the first lightweight by name.

(module git/describe)

(import x/sys/opts Opts)
(import x/type/dict Dict)
(import git/opts git-opts-parse)
(import git/objects git-object-read)
(import git/commands git-fatal git-no-repo git-unknown-option)
(import git/refs git-ref-read git-ref-names git-commit-of git-headers)
(import git/index git-tracked-changes)

(import x/core/doors int+ int- int< int<< int& int|)

(def git-describe-options
  (Opts declare "git describe" "[--tags] [--always] [--long] [--abbrev=<n>] [--dirty[=<mark>]] [<commit-ish>]" ()
    (list
      (Opts flag "--tags" "Use any tag, also unannotated ones")
      (Opts flag "--always" "Show the abbreviated commit when no tag describes it")
      (Opts flag "--long" "Always use the long format")
      (Opts arg "--abbrev" "<n>" "Use <n> digits of the commit name")
      (Opts flag "--dirty" "Append -dirty, or <mark>, when the work tree has changes"))))

(def %seen 1)
(def %max-candidates 10)

; A header line's epoch: the next-to-last word of `NAME <EMAIL> EPOCH TZ`.
(def %epoch-of
  (fn (_ line)
    (def words (Str8 split " " (Str8 trim line)))
    (def n (List length words))
    (if (int< n 2) 0 (%str->number (List ref (int- n 2) words) 10))))

(def %header
  (fn (_ hs key)
    (def e (List find (fn (_ kv) (str=? (first kv) key)) hs))
    (if (null? e) () (rest e))))

(def %commit-time
  (fn (_ gitdir sha)
    (def c (%header (git-headers gitdir sha) "committer"))
    (if (null? c) 0 (%epoch-of c))))

(def %parents
  (fn (_ gitdir sha)
    (List flat-map (fn (_ kv) (if (str=? (first kv) "parent") (list (rest kv)) ())) (git-headers gitdir sha))))

; The names the tags give, commit -> (NAME PRIO DATE), PRIO 2 for an
; annotated tag and 1 for a lightweight one.
(def %names
  (fn (_ gitdir)
    (def names (Dict make))
    (List for-each
      (fn (_ name)
        (let ((sha (git-ref-read gitdir (Str8 append "refs/tags/" name)))
              (commit (git-commit-of gitdir (Str8 append "refs/tags/" name))))
          (when (not (null? commit))
            (let ((o (git-object-read gitdir sha)))
              (let ((annotated? (and (not (null? o)) (str=? (first o) "tag"))))
                (let ((prio (if annotated? 2 1))
                      (date (if annotated?
                              (let ((t (%header (git-headers gitdir sha) "tagger"))) (if (null? t) 0 (%epoch-of t)))
                              0))
                      (had (names get commit)))
                  (when (or (null? had)
                            (int< (List ref 1 had) prio)
                            (and (= prio 2) (= (List ref 1 had) 2) (int< (List ref 2 had) date)))
                    (names set! commit (list name prio date)))))))))
      (git-ref-names gitdir "refs/tags/"))
    names))

; The walk's queue: (TIME . SHA) newest first, a commit queued after
; those of its own time already there.
(def %enqueue
  (fn (self item q)
    (if (or (null? q) (int< (first (first q)) (first item))) (pair item q)
      (pair (first q) (self item (rest q))))))

; A commit's parents queued, each carrying its child's flags.  x collects
; only when asked: a commit read leaves its object behind, collected every
; 64 commits.
(def %stepped 0)
(def %push-parents
  (fn (_ gitdir flags cur q)
    (set! %stepped (int+ %stepped 1))
    (when (= (int& %stepped 63) 0) (Heap collect))
    (def f (flags get cur))
    (List fold
      (fn (_ acc p)
        (def had (flags get p))
        (flags set! p (int| (if (null? had) 0 had) f))
        (if (null? had) (%enqueue (pair (%commit-time gitdir p) p) acc) acc))
      q (%parents gitdir cur))))

; A candidate: #(NAME DEPTH BIT ORDER).
(def %cand-depth (fn (_ c) (Vector ref 1 c)))
(def %cand-bit (fn (_ c) (Vector ref 2 c)))
(def %cand-deeper! (fn (_ c) (Vector set! 1 (int+ (Vector ref 1 c) 1) c)))

; The walk from target: (CANDIDATES QUEUE UNANNOTATED?), CANDIDATES in
; the order found, QUEUE what was left when it stopped.
(def %search
  (fn (_ gitdir names flags target any?)
    (flags set! target %seen)
    ((fn (self q cands seen unannotated? annotated)
       (if (null? q) (list (List reverse cands) () unannotated?)
         (let ((cur (rest (first q))) (q2 (rest q)))
           (let ((n (names get cur)) (k (List length cands)))
             (match
               ((and (not (null? n)) (not any?) (int< (List ref 1 n) 2))
                 (self (%step gitdir flags cur cands q2) cands (int+ seen 1) #t annotated))
               ((and (not (null? n)) (not (int< k %max-candidates)))
                 ; given up on: back in the queue for the depth walk
                 (list (List reverse cands) q unannotated?))
               (#t
                 (let ((cands2 (if (null? n) cands
                                 (let ((bit (int<< 1 (int+ k 1))))
                                   (do (flags set! cur (int| (flags get cur) bit))
                                       (pair (Vector from-list (list (first n) seen bit (int+ k 1))) cands)))))
                       (annotated2 (if (and (not (null? n)) (= (List ref 1 n) 2)) (int+ annotated 1) annotated)))
                   (do (List for-each (fn (_ c) (when (= 0 (int& (flags get cur) (%cand-bit c))) (%cand-deeper! c))) cands2)
                       (if (and (int< 0 annotated2) (null? q2) (%covered? flags cur cands2))
                         (list (List reverse cands2) () unannotated?)
                         (self (%push-parents gitdir flags cur q2) cands2 (int+ seen 1) unannotated? annotated2))))))))))
     (list (pair (%commit-time gitdir target) target)) () 0 #f 0)))

; One step past a commit that names no candidate: depths counted, parents
; queued.
(def %step
  (fn (_ gitdir flags cur cands q)
    (List for-each (fn (_ c) (when (= 0 (int& (flags get cur) (%cand-bit c))) (%cand-deeper! c))) cands)
    (%push-parents gitdir flags cur q)))

; Does the last path's commit carry every bit of the shallowest candidates?
(def %covered?
  (fn (_ flags cur cands)
    (def best (List fold (fn (_ m c) (if (int< (%cand-depth c) m) (%cand-depth c) m)) (%cand-depth (first cands)) cands))
    (def within (List fold (fn (_ m c) (if (= (%cand-depth c) best) (int| m (%cand-bit c)) m)) 0 cands))
    (= (int& (flags get cur) within) within)))

; The best: fewest commits, the first found among equals.
(def %best
  (fn (_ cands)
    (List fold (fn (_ b c) (if (int< (%cand-depth c) (%cand-depth b)) c b)) (first cands) cands)))

; The walk run on until every queued commit carries best's bit: each
; commit without it counted.
(def %finish!
  (fn (_ gitdir flags best q)
    (def bit (%cand-bit best))
    ((fn (self q)
       (when (not (null? q))
         (let ((cur (rest (first q))) (q2 (rest q)))
           (if (= 0 (int& (flags get cur) bit))
             (do (%cand-deeper! best) (self (%push-parents gitdir flags cur q2)))
             (when (List any? (fn (_ e) (= 0 (int& (flags get (rest e)) bit))) q2)
               (self (%push-parents gitdir flags cur q2)))))))
     q)))

; Does the work tree differ from HEAD: staged, unstaged or unmerged?
(def %dirty?
  (fn (_ wd gitdir)
    (def l (git-tracked-changes wd gitdir))
    (not (and (null? (List ref 0 l)) (null? (List ref 1 l)) (null? (List ref 2 l))))))

; --dirty and --dirty=MARK taken off the line: (MARK-OR-() . REST).
(def %dirty-mark
  (fn (_ ops)
    (List fold
      (fn (_ acc w)
        (match
          ((str=? w "--dirty") (pair "-dirty" (rest acc)))
          ((Str8 starts? "--dirty=" w) (pair (Str8 sub 8 (int- (Str8 length w) 8) w) (rest acc)))
          (#t (pair (first acc) (List append (rest acc) (list w))))))
      (pair () ()) ops)))

(def git-describe
  (fn (_ wd gitdir ops)
    (def dm (%dirty-mark ops))
    (def mark (first dm))
    (def o (git-opts-parse git-describe-options (rest dm)))
    (def operands (Opts operands o))
    (def any? (Opts on? o "--tags"))
    (def abbrev (let ((v (Opts value o "--abbrev" ()))) (if (null? v) 7 (%str->number v 10))))
    (def short (fn (_ sha) (Str8 sub 0 (if (int< 40 abbrev) 40 (if (int< abbrev 4) 4 abbrev)) sha)))
    (match
      ((Opts help? git-describe-options ops) (list (lit out) (Opts usage git-describe-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-describe-options)))
      ((null? gitdir) (git-no-repo))
      ((and (not (null? mark)) (not (null? operands)))
        (git-fatal "option '--dirty' and commit-ishes cannot be used together"))
      (#t
        (let ((rev (if (null? operands) "HEAD" (first operands))))
          (let ((target (git-commit-of gitdir rev))
                (names (%names gitdir))
                (suffix (if (and (not (null? mark)) (%dirty? wd gitdir)) mark "")))
            (let ((exact (if (null? target) () (names get target))))
              (match
                ((null? target) (git-fatal (Str8 append "Not a valid object name " rev)))
                ((and (not (null? exact)) (or any? (= (List ref 1 exact) 2)) (not (Opts on? o "--long")))
                  (list (lit out) (Str8 append (first exact) suffix "\n") 0))
                ((and (names empty?) (not (Opts on? o "--always")))
                  (git-fatal "No names found, cannot describe anything."))
                (#t
                  (let ((flags (Dict make)))
                    (let ((found (%search gitdir names flags target any?)))
                      (match
                        ((and (null? (first found)) (Opts on? o "--always"))
                          (list (lit out) (Str8 append (short target) suffix "\n") 0))
                        ((and (null? (first found)) (List ref 2 found))
                          (git-fatal (Str8 append "No annotated tags can describe '" target "'.\n"
                                       "However, there were unannotated tags: try --tags.")))
                        ((null? (first found))
                          (git-fatal (Str8 append "No tags can describe '" target "'.\n"
                                       "Try --always, or create some tags.")))
                        (#t
                          (let ((best (%best (first found))))
                            (do (%finish! gitdir flags best (List ref 1 found))
                                (list (lit out)
                                  (Str8 append (Vector ref 0 best)
                                    (if (= abbrev 0) ""
                                      (Str8 append "-" (Str8 str (%cand-depth best)) "-g" (short target)))
                                    suffix "\n")
                                  0)))))))))))))))))

(provide git/describe git-describe git-describe-options)
