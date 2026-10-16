; # x-git -- git on x-lang
;
; ## git/threeway.x -- two histories merged from where they parted
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The merge base, the files merged line by line, and the trees merged
; path by path, as git's merge (ort, with its default file merge) does
; them.
;
; The base is the common ancestor no other common ancestor descends
; from; where there are several, the one committed last is taken, where
; git would merge them into one first.
;
; A file both sides changed is merged as git's xdiff merges at level
; ZEALOUS: the changes each side made against the base, in order; a
; change of one side only taken; changes that touch the same lines a
; conflict, unless both made the same change; a conflict narrowed to the
; lines where the sides differ, and conflicts with three lines or fewer
; between them made one.  A conflict is written between markers:
; `<<<<<<< ours`, ours, `=======`, theirs, `>>>>>>> theirs`.  The line
; differences come from x-git's own differ, not xdiff's, so where a change
; can be read more than one way the two may draw it differently.
;
; Renames are not looked for: a file moved on one side and changed on
; the other merges as a deletion and an addition.

(module git/threeway)

(import x/type/vector Vector)
(import git/objects git-object-read git-object-text git-tree-entries git-read-file)
(import git/diff git-edit-script)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

(def %member? (fn (_ s l) (List any? (fn (_ x) (str=? x s)) l)))

; --- the merge base ---

; A commit's parents and its commit time.
(def %commit-info
  (fn (_ gitdir sha)
    (def o (git-object-read gitdir sha))
    (if (or (null? o) (not (str=? (first o) "commit"))) (pair () 0)
      (let ((lines (Str8 split "\n" (git-object-text o))))
        (let ((header ((fn (self ls acc) (if (or (null? ls) (= (Str8 length (first ls)) 0)) (List reverse acc) (self (rest ls) (pair (first ls) acc)))) lines ())))
          (pair (List map (fn (_ l) (Str8 sub 7 40 l)) (List filter (fn (_ l) (Str8 starts? "parent " l)) header))
                (let ((c (List find (fn (_ l) (Str8 starts? "committer " l)) header)))
                  (if (null? c) 0
                    (let ((parts (Str8 split " " c)))
                      (%str->number (List ref (%sub (List length parts) 2) parts) 10))))))))))

; Every commit a commit reaches through its parents, itself among them.
(def %ancestors
  (fn (_ gitdir sha)
    ((fn (self work seen)
       (match
         ((null? work) seen)
         ((%member? (first work) seen) (self (rest work) seen))
         (#t (self (List append (rest work) (first (%commit-info gitdir (first work)))) (pair (first work) seen)))))
     (list sha) ())))

; The merge base of two commits, or () when they share no history.
(def git-merge-base
  (fn (_ gitdir a b)
    (def from-a (%ancestors gitdir a))
    (def common (List filter (fn (_ c) (%member? c from-a)) (%ancestors gitdir b)))
    ; the common ancestors no other common ancestor reaches
    (def best
      (List filter
        (fn (_ c) (not (List any? (fn (_ d) (and (not (str=? d c)) (%member? c (%ancestors gitdir d)))) common)))
        common))
    (if (null? best) ()
      (first (List sort (fn (_ x y) (> (rest (%commit-info gitdir x)) (rest (%commit-info gitdir y)))) best)))))

; --- lines ---

; A text's lines, each with its newline; the last without one when the
; text ends without one.
(def %lines
  (fn (_ s)
    (def parts (Str8 split "\n" s))
    ((fn (self ps acc)
       (match
         ((null? ps) (List reverse acc))
         ((null? (rest ps)) (List reverse (if (= (Str8 length (first ps)) 0) acc (pair (first ps) acc))))
         (#t (self (rest ps) (pair (Str8 append (first ps) "\n") acc)))))
     parts ())))

; The changes of an edit script as hunks (I1 CHG1 I2 CHG2): CHG1 lines of
; the first text from I1 replaced by CHG2 lines of the second from I2.
(def %hunks
  (fn (_ script)
    ((fn (self ops i j acc)
       (match
         ((null? ops) (List reverse acc))
         ((eq? (first (first ops)) (lit keep)) (self (rest ops) (%add i 1) (%add j 1) acc))
         (#t
           ((fn (run os di dj)
              (if (and (not (null? os)) (not (eq? (first (first os)) (lit keep))))
                (if (eq? (first (first os)) (lit del)) (run (rest os) (%add di 1) dj) (run (rest os) di (%add dj 1)))
                (self os (%add i di) (%add j dj) (pair (list i di j dj) acc))))
            ops 0 0))))
     script 0 0 ())))

(def %h-i1 (fn (_ h) (first h)))
(def %h-chg1 (fn (_ h) (first (rest h))))
(def %h-i2 (fn (_ h) (first (rest (rest h)))))
(def %h-chg2 (fn (_ h) (first (rest (rest (rest h))))))

; --- the file merge ---
;
; A merge record is a vector: 0 its mode -- 1 ours alone, 2 theirs alone,
; 0 a conflict, 4 the same on both sides -- then i0 chg0 in the base, i1
; chg1 in ours, i2 chg2 in theirs.

(def %m-make
  (fn (_ mode i0 chg0 i1 chg1 i2 chg2)
    (def v (Vector make 7 0))
    (Vector set! 0 mode v) (Vector set! 1 i0 v) (Vector set! 2 chg0 v) (Vector set! 3 i1 v)
    (Vector set! 4 chg1 v) (Vector set! 5 i2 v) (Vector set! 6 chg2 v)
    v))
(def %m (fn (_ v k) (Vector ref k v)))
(def %m! (fn (_ v k x) (Vector set! k x v)))

; A record put after the last of acc (newest first), or the last grown to
; reach it when they touch: xdl_append_merge.
(def %append-merge
  (fn (_ acc mode i0 chg0 i1 chg1 i2 chg2)
    (def m (if (null? acc) () (first acc)))
    (if (and (not (null? m)) (or (<= i1 (%add (%m m 3) (%m m 4))) (<= i2 (%add (%m m 5) (%m m 6)))))
      (do (unless (= mode (%m m 0)) (%m! m 0 0))
          (%m! m 2 (%sub (%add i0 chg0) (%m m 1)))
          (%m! m 4 (%sub (%add i1 chg1) (%m m 3)))
          (%m! m 6 (%sub (%add i2 chg2) (%m m 5)))
          acc)
      (pair (%m-make mode i0 chg0 i1 chg1 i2 chg2) acc))))

; n lines of vectors a and b from i and j the same?
(def %same-lines?
  (fn (self a i b j n)
    (if (= n 0) #t
      (if (str=? (Vector ref i a) (Vector ref j b)) (self a (%add i 1) b (%add j 1) (%sub n 1)) #f))))

; The records of two sides' hunks against the base, in order:
; xdl_do_merge's walk.
(def %records
  (fn (_ h1s h2s ours theirs nbase nours ntheirs)
    ((fn (self h1s h2s acc)
       (match
         ((and (null? h1s) (null? h2s)) (List reverse acc))
         ((null? h2s)
           (let ((h (first h1s)))
             (self (rest h1s) h2s
               (%append-merge acc 1 (%h-i1 h) (%h-chg1 h) (%h-i2 h) (%h-chg2 h) (%add (%h-i1 h) (%sub ntheirs nbase)) (%h-chg1 h)))))
         ((null? h1s)
           (let ((h (first h2s)))
             (self h1s (rest h2s)
               (%append-merge acc 2 (%h-i1 h) (%h-chg1 h) (%add (%h-i1 h) (%sub nours nbase)) (%h-chg1 h) (%h-i2 h) (%h-chg2 h)))))
         (#t
           (let ((x1 (first h1s)) (x2 (first h2s)))
             (match
               ((< (%add (%h-i1 x1) (%h-chg1 x1)) (%h-i1 x2))
                 (self (rest h1s) h2s
                   (%append-merge acc 1 (%h-i1 x1) (%h-chg1 x1) (%h-i2 x1) (%h-chg2 x1)
                     (%add (%sub (%h-i2 x2) (%h-i1 x2)) (%h-i1 x1)) (%h-chg1 x1))))
               ((< (%add (%h-i1 x2) (%h-chg1 x2)) (%h-i1 x1))
                 (self h1s (rest h2s)
                   (%append-merge acc 2 (%h-i1 x2) (%h-chg1 x2) (%add (%sub (%h-i2 x1) (%h-i1 x1)) (%h-i1 x2)) (%h-chg1 x2)
                     (%h-i2 x2) (%h-chg2 x2))))
               (#t
                 (let ((acc2
                         (if (and (= (%h-i1 x1) (%h-i1 x2)) (= (%h-chg1 x1) (%h-chg1 x2)) (= (%h-chg2 x1) (%h-chg2 x2))
                                  (%same-lines? ours (%h-i2 x1) theirs (%h-i2 x2) (%h-chg2 x1)))
                           acc
                           (let ((off (%sub (%h-i1 x1) (%h-i1 x2))))
                             (let ((ffo (%add off (%sub (%h-chg1 x1) (%h-chg1 x2))))
                                   (i0 (if (> off 0) (%sub (%h-i1 x1) off) (%h-i1 x1)))
                                   (i1 (if (> off 0) (%sub (%h-i2 x1) off) (%h-i2 x1)))
                                   (i2 (if (> off 0) (%h-i2 x2) (%add (%h-i2 x2) off))))
                               (let ((chg0 (%sub (%add (%h-i1 x1) (%h-chg1 x1)) i0))
                                     (chg1 (%sub (%add (%h-i2 x1) (%h-chg2 x1)) i1))
                                     (chg2 (%sub (%add (%h-i2 x2) (%h-chg2 x2)) i2)))
                                 (if (< ffo 0)
                                   (%append-merge acc 0 i0 (%sub chg0 ffo) i1 (%sub chg1 ffo) i2 chg2)
                                   (%append-merge acc 0 i0 chg0 i1 chg1 i2 (%add chg2 ffo)))))))))
                   (let ((e1 (%add (%h-i1 x1) (%h-chg1 x1))) (e2 (%add (%h-i1 x2) (%h-chg1 x2))))
                     (self (if (>= e2 e1) (rest h1s) h1s) (if (>= e1 e2) (rest h2s) h2s) acc2)))))))))
     h1s h2s ())))

; A conflict narrowed to where the sides differ: the sides' lines diffed,
; each difference a conflict of its own; none, and they agree.
; xdl_refine_conflicts.
(def %refine
  (fn (_ records ours theirs)
    (List flat-map
      (fn (_ m)
        (if (or (not (= (%m m 0) 0)) (= (%m m 4) 0) (= (%m m 6) 0)) (list m)
          (let ((a (List map (fn (_ k) (Vector ref (%add (%m m 3) k) ours)) (List range 0 (%m m 4))))
                (b (List map (fn (_ k) (Vector ref (%add (%m m 5) k) theirs)) (List range 0 (%m m 6)))))
            (let ((hs (%hunks (git-edit-script a b))))
              (if (null? hs) (do (%m! m 0 4) (list m))
                (List map
                  (fn (_ h) (%m-make 0 (%m m 1) (%m m 2) (%add (%h-i1 h) (%m m 3)) (%h-chg1 h) (%add (%h-i2 h) (%m m 5)) (%h-chg2 h)))
                  hs))))))
      records)))

; Conflicts with three lines or fewer of ours between them made one:
; xdl_simplify_non_conflicts.
(def %simplify
  (fn (self records)
    (match
      ((or (null? records) (null? (rest records))) records)
      (#t
        (let ((m (first records)) (n (first (rest records))))
          (if (and (= (%m m 0) 0) (= (%m n 0) 0) (<= (%sub (%m n 3) (%add (%m m 3) (%m m 4))) 3))
            (do (%m! m 4 (%sub (%add (%m n 3) (%m n 4)) (%m m 3)))
                (%m! m 6 (%sub (%add (%m n 5) (%m n 6)) (%m m 5)))
                (self (pair m (rest (rest records)))))
            (pair m (self (rest records)))))))))

; n lines of vector v from i, as text; a last line without its newline
; given one when closed? asks.
(def %copy
  (fn (_ v i n closed?)
    (def text (Str8 join "" (List map (fn (_ k) (Vector ref (%add i k) v)) (List range 0 (if (< n 0) 0 n)))))
    (if (and closed? (> (Str8 length text) 0) (not (Str8 ends? "\n" text))) (Str8 append text "\n") text)))

; Three texts merged: (TEXT . CONFLICTS), the conflicts marked between
; `<<<<<<< name1` and `>>>>>>> name2`.
(def git-merge-text
  (fn (_ base ours theirs name1 name2)
    (def lb (%lines base)) (def lo (%lines ours)) (def lt (%lines theirs))
    (def vo (Vector from-list lo)) (def vt (Vector from-list lt))
    (def records
      (%simplify
        (%refine
          (%records (%hunks (git-edit-script lb lo)) (%hunks (git-edit-script lb lt)) vo vt
            (List length lb) (List length lo) (List length lt))
          vo vt)))
    ((fn (self ms i acc conflicts)
       (if (null? ms)
         (pair (Str8 join "" (List reverse (pair (%copy vo i (%sub (List length lo) i) #f) acc))) conflicts)
         (let ((m (first ms)))
           (match
             ((= (%m m 0) 0)
               (self (rest ms) (%add (%m m 3) (%m m 4))
                 (pair (Str8 append (%copy vo i (%sub (%m m 3) i) #f)
                         "<<<<<<< " name1 "\n" (%copy vo (%m m 3) (%m m 4) #t)
                         "=======\n" (%copy vt (%m m 5) (%m m 6) #t)
                         ">>>>>>> " name2 "\n")
                       acc)
                 (%add conflicts 1)))
             ((= (%m m 0) 4) (self (rest ms) i acc conflicts))
             (#t
               (self (rest ms) (%add (%m m 3) (%m m 4))
                 (pair (Str8 append (%copy vo i (%sub (%m m 3) i) #f)
                         (if (= (& (%m m 0) 1) 0) "" (%copy vo (%m m 3) (%m m 4) #f))
                         (if (= (& (%m m 0) 2) 0) "" (%copy vt (%m m 5) (%m m 6) #f)))
                       acc)
                 conflicts))))))
     records 0 () 0)))

; --- the tree merge ---

; A tree's files: (PATH MODE SHA) each, every subtree walked.
(def git-tree-flat
  (fn (self gitdir tree prefix)
    (def o (if (null? tree) () (git-object-read gitdir tree)))
    (if (null? o) ()
      (List flat-map
        (fn (_ e)
          (let ((path (Str8 append prefix (first (rest e)))))
            (if (str=? (first e) "40000")
              (self gitdir (first (rest (rest e))) (Str8 append path "/"))
              (list (list path (Str8 pad-left 6 #\0 (first e)) (first (rest (rest e))))))))
        (git-tree-entries o)))))

(def %find (fn (_ path files) (List find (fn (_ f) (str=? (first f) path)) files)))
(def %same? (fn (_ a b) (if (or (null? a) (null? b)) (and (null? a) (null? b)) (and (str=? (first (rest a)) (first (rest b))) (str=? (first (rest (rest a))) (first (rest (rest b))))))))

(def %blob-text
  (fn (_ gitdir f)
    (if (null? f) ""
      (let ((o (git-object-read gitdir (first (rest (rest f)))))) (if (null? o) "" (git-object-text o))))))

(def %pref (prim-ref (lit ptr) (lit ref)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))

; Is a file binary, as git judges one: a NUL among its first 8000 bytes.
(def %binary?
  (fn (_ gitdir f)
    (def o (if (null? f) () (git-object-read gitdir (first (rest (rest f))))))
    (if (null? o) #f
      (let ((p (%int->ptr (%add (%ptr->int (%str->ptr (first (rest (rest o))))) (first (rest (rest (rest o)))))))
            (n (if (> (first (rest o)) 8000) 8000 (first (rest o)))))
        ((fn (self i) (if (>= i n) #f (if (= (& (%pref p i 1) 255) 0) #t (self (%add i 1))))) 0)))))

; Three trees' files merged.  Answers (RESULTS MESSAGES): RESULTS a
; (PATH ...) each --
;   (PATH clean MODE SHA)          the path's file, merged
;   (PATH gone)                    the path's file deleted
;   (PATH conflict STAGES WORK)    in conflict: STAGES ((STAGE MODE SHA) ...),
;                                  WORK the working file's text, or () to
;                                  leave ours as it is
; and MESSAGES the lines merge prints, in path order.  write-blob answers
; a merged text's blob name.  name1 and name2 name the sides.
(def git-merge-trees
  (fn (_ base ours theirs name1 name2 gitdir write-blob)
    (def paths
      (List sort (fn (_ a b) (Str8 <? a b))
        ((fn (self ps acc) (if (null? ps) acc (self (rest ps) (if (%member? (first ps) acc) acc (pair (first ps) acc)))))
         (List map first (List append base (List append ours theirs))) ())))
    (def stages
      (fn (_ b o t)
        (List append (if (null? b) () (list (list 1 (first (rest b)) (first (rest (rest b))))))
          (List append (if (null? o) () (list (list 2 (first (rest o)) (first (rest (rest o))))))
            (if (null? t) () (list (list 3 (first (rest t)) (first (rest (rest t))))))))))
    (def merged
      (List map
        (fn (_ path)
          (let ((b (%find path base)) (o (%find path ours)) (t (%find path theirs)))
            (match
              ((%same? o t) (if (null? o) (pair (list path (lit gone)) ()) (pair (list path (lit clean) (first (rest o)) (first (rest (rest o)))) ())))
              ((%same? b o) (if (null? t) (pair (list path (lit gone)) ()) (pair (list path (lit clean) (first (rest t)) (first (rest (rest t)))) ())))
              ((%same? b t) (if (null? o) (pair (list path (lit gone)) ()) (pair (list path (lit clean) (first (rest o)) (first (rest (rest o)))) ())))
              ; one side deleted what the other changed
              ((or (null? o) (null? t))
                (pair (list path (lit conflict) (stages b o t) (if (null? o) (%blob-text gitdir t) ()))
                      (list (Str8 append "CONFLICT (modify/delete): " path " deleted in " (if (null? o) name1 name2)
                              " and modified in " (if (null? o) name2 name1) ".  Version " (if (null? o) name2 name1)
                              " of " path " left in tree.\n"))))
              ; both changed it, or both added it: the texts merged
              (#t
                (let ((tb (%blob-text gitdir b)) (to (%blob-text gitdir o)) (tt (%blob-text gitdir t))
                      (kind (if (null? b) "add/add" "content")))
                  (if (or (%binary? gitdir b) (%binary? gitdir o) (%binary? gitdir t))
                    (pair (list path (lit conflict) (stages b o t) ())
                          (list (Str8 append "warning: Cannot merge binary files: " path " (" name1 " vs. " name2 ")\n")
                                (Str8 append "Auto-merging " path "\n")
                                (Str8 append "CONFLICT (" kind "): Merge conflict in " path "\n")))
                    (let ((r (git-merge-text tb to tt name1 name2)))
                      (if (= (rest r) 0)
                        (pair (list path (lit clean) (first (rest o)) (write-blob (first r))) (list (Str8 append "Auto-merging " path "\n")))
                        (pair (list path (lit conflict) (stages b o t) (first r))
                              (list (Str8 append "Auto-merging " path "\n")
                                    (Str8 append "CONFLICT (" kind "): Merge conflict in " path "\n")))))))))))
        paths))
    (list (List map first merged) (List flat-map rest merged))))

(provide git/threeway git-merge-base git-merge-text git-merge-trees git-tree-flat)
