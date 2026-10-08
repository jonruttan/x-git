; # x-git -- git on x-lang
;
; ## git/diff.x -- lines compared: diff, and what a change amounts to
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Two texts compared line by line: the edit script by the longest common
; subsequence (a table of n by m, so files past a million cells are shown
; as wholly replaced), laid out as git's unified diff -- the header, the
; index line, hunks of changes with three lines of context -- or counted
; as --stat prints them.  The counts are also what commit's summary
; prints, so that lives here too.  git's own algorithm (Myers) picks the
; same script where only one is shortest; where several are, the hunks
; may differ from git's.

(module git/diff)

(import x/sys/opts Opts)
(import x/sys/file File)
(import x/type/vector Vector)
(import git/objects git-object-read git-object-text git-read-file git-hash)
(import git/refs git-tree-of git-rev-parse)
(import git/index git-index-read git-tree-files)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %mul (prim-ref 'int '*))
(def %cvt (prim-ref (lit convert) (lit to)))
(def %string-type (Type named STRING))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))
(def %no-repo
  (fn (_) (%fatal "not a git repository (or any of the parent directories): .git")))
(def %unknown-option
  (fn (_ w usage)
    (def n (Str8 length w))
    (list (lit err)
      (Str8 append
        (if (Str8 starts? "--" w)
          (Str8 append "error: unknown option `" (Str8 sub 2 (- n 2) w))
          (Str8 append "error: unknown switch `" (Str8 sub 1 (- n 1) w)))
        "'\n" usage)
      129)))

; --- lines ---

; A text's lines (a trailing newline closing the last) and whether the
; text ended without one: (LINES . NO-NEWLINE?).
(def %lines
  (fn (_ s)
    (def n (Str8 length s))
    (def ls (Str8 split "\n" s))
    (if (= n 0) (pair () #f)
      (if (= (Str8 length (List last ls)) 0)
        (pair (List take (%sub (List length ls) 1) ls) #f)
        (pair ls #t)))))

; The edit script between two line lists: ((OP . LINE) ...), OP keep,
; del or ins, in order.  Where the table ties, an insertion is taken on
; the way back, so a replaced line reads as git shows it: its deletion,
; then its insertion.
(def git-edit-script
  (fn (_ a b)
    (def n (List length a))
    (def m (List length b))
    (if (> (%mul n m) 1000000)
      (List append (List map (fn (_ l) (pair (lit del) l)) a) (List map (fn (_ l) (pair (lit ins) l)) b))
      (let ((av (Vector from-list a)) (bv (Vector from-list b))
            (w (%add m 1))
            (t (Vector make (%mul (%add n 1) (%add m 1)) 0)))
        (let ((at (fn (_ i j) (Vector ref (%add (%mul i w) j) t))))
          (do ((fn (rows i)
                 (when (<= i n)
                   (do ((fn (cols j)
                          (when (<= j m)
                            (do (Vector set! (%add (%mul i w) j)
                                  (if (str=? (Vector ref (%sub i 1) av) (Vector ref (%sub j 1) bv))
                                    (%add (at (%sub i 1) (%sub j 1)) 1)
                                    (let ((up (at (%sub i 1) j)) (left (at i (%sub j 1))))
                                      (if (> up left) up left)))
                                  t)
                                (cols (%add j 1)))))
                        1)
                       (rows (%add i 1)))))
               1)
              ((fn (back i j acc)
                 (match
                   ((and (= i 0) (= j 0)) acc)
                   ((= i 0) (back i (%sub j 1) (pair (pair (lit ins) (Vector ref (%sub j 1) bv)) acc)))
                   ((= j 0) (back (%sub i 1) j (pair (pair (lit del) (Vector ref (%sub i 1) av)) acc)))
                   ((and (str=? (Vector ref (%sub i 1) av) (Vector ref (%sub j 1) bv))
                         (= (at i j) (%add (at (%sub i 1) (%sub j 1)) 1)))
                     (back (%sub i 1) (%sub j 1) (pair (pair (lit keep) (Vector ref (%sub i 1) av)) acc)))
                   ((>= (at i (%sub j 1)) (at (%sub i 1) j))
                     (back i (%sub j 1) (pair (pair (lit ins) (Vector ref (%sub j 1) bv)) acc)))
                   (#t (back (%sub i 1) j (pair (pair (lit del) (Vector ref (%sub i 1) av)) acc)))))
               n m ())))))))

; Insertions and deletions of a script: (INS . DEL).
(def %counts
  (fn (_ script)
    (List fold
      (fn (_ acc op)
        (match
          ((eq? (first op) (lit ins)) (pair (%add (first acc) 1) (rest acc)))
          ((eq? (first op) (lit del)) (pair (first acc) (%add (rest acc) 1)))
          (#t acc)))
      (pair 0 0) script)))

; --- hunks ---

(def %context 3)

; The hunks of a script: each (START . END), indexes into the script,
; changes within 2 * context lines of each other sharing one.
(def %hunk-ranges
  (fn (_ ops)
    (def n (List length ops))
    (def changes
      ((fn (self l i acc) (if (null? l) (List reverse acc)
                            (self (rest l) (%add i 1) (if (eq? (first (first l)) (lit keep)) acc (pair i acc)))))
       ops 0 ()))
    (def clamp (fn (_ v) (if (< v 0) 0 (if (> v (%sub n 1)) (%sub n 1) v))))
    ((fn (self cs acc)
       (if (null? cs) (List reverse acc)
         (let ((start (first cs)))
           ((fn (extend rest-cs last)
              (if (and (not (null? rest-cs)) (<= (%sub (first rest-cs) last) (%add (%mul 2 %context) 1)))
                (extend (rest rest-cs) (first rest-cs))
                (self rest-cs (pair (pair (clamp (%sub start %context)) (clamp (%add last %context))) acc))))
            (rest cs) start))))
     changes ())))

; `@@ -S,C +S,C @@`: a count of one is left off; a count of zero puts the
; line before.
(def %range-text
  (fn (_ start count)
    (match
      ((= count 1) (Str8 str start))
      ((= count 0) (Str8 append (Str8 str (%sub start 1)) ",0"))
      (#t (Str8 append (Str8 str start) "," (Str8 str count))))))

(def %no-newline "\\ No newline at end of file\n")

; A hunk's text, from the script's ops in [start, end], with the old and
; new line numbers the ops before it reach; the markers for a side whose
; last line has no newline go after that line.
(def %hunk-text
  (fn (_ ops start end old-before new-before old-last new-last)
    (def slice (List take (%add (%sub end start) 1) (List drop start ops)))
    (def olds (List length (List filter (fn (_ op) (not (eq? (first op) (lit ins)))) slice)))
    (def news (List length (List filter (fn (_ op) (not (eq? (first op) (lit del)))) slice)))
    (def body
      ((fn (self l oi ni acc)
         (if (null? l) (Str8 join "" (List reverse acc))
           (let ((op (first (first l))) (line (rest (first l))))
             (let ((oi2 (if (eq? op (lit ins)) oi (%add oi 1)))
                   (ni2 (if (eq? op (lit del)) ni (%add ni 1))))
               (let ((text (Str8 append (match ((eq? op (lit keep)) " ") ((eq? op (lit del)) "-") (#t "+")) line "\n")))
                 (let ((mark (Str8 append
                               (if (and (not (eq? op (lit ins))) (= oi2 old-last)) %no-newline "")
                               (if (and (not (eq? op (lit del))) (= ni2 new-last)) %no-newline ""))))
                   (self (rest l) oi2 ni2 (pair (Str8 append text mark) acc))))))))
       slice old-before new-before ()))
    (Str8 append "@@ -" (%range-text (%add old-before 1) olds) " +" (%range-text (%add new-before 1) news) " @@\n" body)))

; Every hunk of a script between texts a and b.
(def git-hunks
  (fn (_ a b)
    (def la (%lines a))
    (def lb (%lines b))
    (def ops (git-edit-script (first la) (first lb)))
    (def old-last (if (rest la) (List length (first la)) -1))
    (def new-last (if (rest lb) (List length (first lb)) -1))
    (Str8 join ""
      (List map
        (fn (_ r)
          (let ((before (List take (first r) ops)))
            (%hunk-text ops (first r) (rest r)
              (List length (List filter (fn (_ op) (not (eq? (first op) (lit ins)))) before))
              (List length (List filter (fn (_ op) (not (eq? (first op) (lit del)))) before))
              old-last new-last)))
        (%hunk-ranges ops)))))

; --- one file ---

; Does a text look binary to git: a NUL in its first 8000 bytes.
(def %binary?
  (fn (_ s)
    (def n (Str8 length s))
    (def lim (if (> n 8000) 8000 n))
    ((fn (self i) (if (>= i lim) #f (if (= (Char ->int (Str8 ref i s)) 0) #t (self (%add i 1))))) 0)))

; A side of a file in a diff: (SHA MODE TEXT), or () for no file.
(def %side-text (fn (_ side) (first (rest (rest side)))))

; One file's diff as git prints it: the header, the modes and index line,
; then the hunks.
(def %file-diff
  (fn (_ path old new)
    (def short (fn (_ sha) (Str8 sub 0 7 sha)))
    (def header (Str8 append "diff --git a/" path " b/" path "\n"))
    (def modes
      (match
        ((null? old) (Str8 append "new file mode " (first (rest new)) "\n"
                                  "index 0000000.." (short (first new)) "\n"))
        ((null? new) (Str8 append "deleted file mode " (first (rest old)) "\n"
                                  "index " (short (first old)) "..0000000\n"))
        ((str=? (first (rest old)) (first (rest new)))
          (Str8 append "index " (short (first old)) ".." (short (first new)) " " (first (rest old)) "\n"))
        (#t (Str8 append "old mode " (first (rest old)) "\nnew mode " (first (rest new)) "\n"
                         "index " (short (first old)) ".." (short (first new)) "\n"))))
    (def a-text (if (null? old) "" (%side-text old)))
    (def b-text (if (null? new) "" (%side-text new)))
    (if (or (%binary? a-text) (%binary? b-text))
      (Str8 append header modes "Binary files " (if (null? old) "/dev/null" (Str8 append "a/" path))
                   " and " (if (null? new) "/dev/null" (Str8 append "b/" path)) " differ\n")
      (Str8 append header modes
        "--- " (if (null? old) "/dev/null" (Str8 append "a/" path)) "\n"
        "+++ " (if (null? new) "/dev/null" (Str8 append "b/" path)) "\n"
        (git-hunks a-text b-text)))))

; --- the sides ---

; A tree's files as ((PATH SHA MODE) ...).
(def %tree-side
  (fn (_ gitdir tree)
    (def o (if (null? tree) () (git-object-read gitdir tree)))
    (if (null? o) ()
      ((fn (self t prefix)
         (let ((obj (git-object-read gitdir t)))
           (List flat-map
             (fn (_ e)
               (let ((path (Str8 append prefix (first (rest e)))))
                 (if (str=? (first e) "40000")
                   (self (first (rest (rest e))) (Str8 append path "/"))
                   (list (list path (first (rest (rest e))) (Str8 pad-left 6 #\0 (first e)))))))
             ((eval (lit git-tree-entries) (module git/objects)) obj))))
       tree ""))))

(def %index-side
  (fn (_ gitdir)
    (List map (fn (_ e) (list (first e) (first (rest (rest e))) (first (rest e)))) (git-index-read gitdir))))

; The working directory's version of the index's paths: the file as it
; is, named by its hash, or () when gone.
(def %work-side
  (fn (_ wd gitdir)
    (List flat-map
      (fn (_ e)
        (let ((full (Str8 append wd "/" (first e))))
          (if (not (File exists? full)) ()
            (let ((f (git-read-file full)) (st (File stat full)))
              (list (list (first e) (git-hash "blob" (first f) 0 (rest f))
                          (if (= (& (Assoc get (lit mode) st) 73) 0) "100644" "100755")))))))
      (git-index-read gitdir))))

; A side's entry for path as (SHA MODE TEXT), its text from the blob or
; the working file; () when the side lacks it.
(def %with-text
  (fn (_ wd gitdir side path work?)
    (def e (List find (fn (_ x) (str=? (first x) path)) side))
    (if (null? e) ()
      (list (first (rest e)) (first (rest (rest e)))
        (if work?
          (let ((f (git-read-file (Str8 append wd "/" path)))) (Str8 sub 0 (rest f) (first f)))
          (let ((o (git-object-read gitdir (first (rest e))))) (if (null? o) "" (git-object-text o))))))))

; The paths that differ between two sides, in order, with their entries:
; ((PATH OLD NEW) ...).
(def %changed
  (fn (_ wd gitdir old-side new-side new-work?)
    (def paths
      (List sort (fn (_ a b) (Str8 <? a b))
        ((fn (self ps acc)
           (if (null? ps) acc
             (self (rest ps) (if (List any? (fn (_ a) (str=? a (first ps))) acc) acc (pair (first ps) acc)))))
         (List append (List map (fn (_ e) (first e)) old-side) (List map (fn (_ e) (first e)) new-side)) ())))
    (List flat-map
      (fn (_ path)
        (let ((o (List find (fn (_ x) (str=? (first x) path)) old-side))
              (n (List find (fn (_ x) (str=? (first x) path)) new-side)))
          (if (and (not (null? o)) (not (null? n))
                   (str=? (first (rest o)) (first (rest n))) (str=? (first (rest (rest o))) (first (rest (rest n)))))
            ()
            (list (list path (%with-text wd gitdir old-side path #f) (%with-text wd gitdir new-side path new-work?))))))
      paths)))

; --- --stat, and commit's summary ---

(def %plural
  (fn (_ n one many) (Str8 append (Str8 str n) " " (if (= n 1) one many))))

; ` N file(s) changed, X insertion(s)(+), Y deletion(s)(-)`
(def %summary-line
  (fn (_ nfiles ins del)
    (Str8 append " " (%plural nfiles "file changed" "files changed")
      (if (> ins 0) (Str8 append ", " (%plural ins "insertion(+)" "insertions(+)")) "")
      (if (> del 0) (Str8 append ", " (%plural del "deletion(-)" "deletions(-)")) "")
      "\n")))

; Each change's counts: ((PATH INS DEL) ...).
(def %change-counts
  (fn (_ changes)
    (List map
      (fn (_ c)
        (let ((old (first (rest c))) (new (first (rest (rest c)))))
          (let ((la (first (%lines (if (null? old) "" (%side-text old)))))
                (lb (first (%lines (if (null? new) "" (%side-text new))))))
            (let ((k (%counts (git-edit-script la lb))))
              (list (first c) (first k) (rest k))))))
      changes)))

; --stat: a row a file -- the path padded to the widest, the count of
; changed lines, a bar of + and - -- then the summary line.
(def %stat-text
  (fn (_ changes)
    (def counts (%change-counts changes))
    (def width (List fold (fn (_ w c) (if (> (Str8 length (first c)) w) (Str8 length (first c)) w)) 0 counts))
    (def total-width (List fold (fn (_ w c) (let ((n (Str8 length (Str8 str (%add (first (rest c)) (first (rest (rest c)))))))) (if (> n w) n w))) 0 counts))
    (def ins (List fold (fn (_ a c) (%add a (first (rest c)))) 0 counts))
    (def del (List fold (fn (_ a c) (%add a (first (rest (rest c))))) 0 counts))
    (Str8 append
      (Str8 join ""
        (List map
          (fn (_ c)
            (Str8 append " " (Str8 pad-right width #\space (first c)) " | "
              (Str8 pad-left total-width #\space (Str8 str (%add (first (rest c)) (first (rest (rest c))))))
              " " (Str8 repeat (first (rest c)) "+") (Str8 repeat (first (rest (rest c))) "-") "\n"))
          counts))
      (%summary-line (List length counts) ins del))))

; commit's lines after its header: the summary, then a line a mode
; created or deleted, from two trees' flat files ((PATH . SHA) ...).
(def git-commit-summary
  (fn (_ gitdir before after)
    (def side (fn (_ files) (List map (fn (_ f) (list (first f) (rest f) "100644")) files)))
    (def changes (%changed "" gitdir (side before) (side after) #f))
    (def counts (%change-counts changes))
    (def mode-of (fn (_ path) (let ((e (List find (fn (_ x) (str=? (first x) path)) (git-index-read gitdir)))) (if (null? e) "100644" (first (rest e))))))
    (Str8 append
      (%summary-line (List length counts)
        (List fold (fn (_ a c) (%add a (first (rest c)))) 0 counts)
        (List fold (fn (_ a c) (%add a (first (rest (rest c))))) 0 counts))
      (Str8 join "" (List map (fn (_ c) (Str8 append " create mode " (mode-of (first c)) " " (first c) "\n"))
                      (List filter (fn (_ c) (null? (first (rest c)))) changes)))
      (Str8 join "" (List map (fn (_ c) (Str8 append " delete mode 100644 " (first c) "\n"))
                      (List filter (fn (_ c) (null? (first (rest (rest c))))) changes))))))

; --- diff ---

(def git-diff-options
  (Opts declare "git diff" "[--cached] [--stat] [<revision> [<revision>]] [--] [<path>...]" ()
    (list
      (Opts flag "--cached" "--staged" "The index against HEAD, not the working directory against the index")
      (Opts flag "--stat" "A row a file and the summary, not the changes"))))

(def git-diff
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-diff-options ops))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-diff-options ops) (list (lit out) (Opts usage git-diff-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-diff-options)))
      ((null? gitdir) (%no-repo))
      (#t
        ; the revisions among the operands: those that resolve; the rest are paths
        (let ((revs (List filter (fn (_ a) (not (null? (git-rev-parse gitdir a)))) operands))
              (paths (List filter (fn (_ a) (null? (git-rev-parse gitdir a))) operands)))
          (let ((bad (List find (fn (_ r) (null? (git-tree-of gitdir r))) revs)))
            (if (not (null? bad)) (%fatal (Str8 append "bad revision '" bad "'"))
              (let ((sides
                      (match
                        ((= (List length revs) 2)
                          (list (%tree-side gitdir (git-tree-of gitdir (first revs)))
                                (%tree-side gitdir (git-tree-of gitdir (first (rest revs)))) #f))
                        ((= (List length revs) 1)
                          (if (Opts on? o "--cached")
                            (list (%tree-side gitdir (git-tree-of gitdir (first revs))) (%index-side gitdir) #f)
                            (list (%tree-side gitdir (git-tree-of gitdir (first revs))) (%work-side wd gitdir) #t)))
                        ((Opts on? o "--cached")
                          (list (%tree-side gitdir (git-tree-of gitdir "HEAD")) (%index-side gitdir) #f))
                        (#t (list (%index-side gitdir) (%work-side wd gitdir) #t)))))
                (let ((changes
                        (List filter
                          (fn (_ c) (or (null? paths)
                                        (List any? (fn (_ p) (or (str=? p (first c)) (Str8 starts? (Str8 append p "/") (first c)))) paths)))
                          (%changed wd gitdir (first sides) (first (rest sides)) (first (rest (rest sides)))))))
                  (list (lit out)
                    (if (null? changes) ""
                      (if (Opts on? o "--stat") (%stat-text changes)
                        (Str8 join "" (List map (fn (_ c) (%file-diff (first c) (first (rest c)) (first (rest (rest c))))) changes))))
                    0))))))))))

(provide git/diff git-diff git-diff-options git-edit-script git-hunks git-commit-summary)
