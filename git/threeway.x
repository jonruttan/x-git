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
; from; where there are several, they are merged into one first, as git
; merges them.
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
; Renames are found as git finds them (git/renames), each side against
; the base, and a renamed file merged under its new name.  A directory
; one side renamed takes with it what the other side added to it, as
; merge.directoryRenames says: moved and left in conflict ("conflict",
; git's default), moved ("true"), or left where it is ("false").

(module git/threeway)

(import x/type/vector Vector)
(import git/objects git-object-read git-object-text git-tree-entries git-read-file)
(import git/diff git-edit-script)
(import git/renames git-find-renames)

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

; The merge bases of the commits as and commit b: the common ancestors no
; other common ancestor reaches, oldest first, as git's ort takes them.
(def %merge-bases
  (fn (_ gitdir as b)
    (def from-a (List flat-map (fn (_ a) (%ancestors gitdir a)) as))
    (def common (List filter (fn (_ c) (%member? c from-a)) (%ancestors gitdir b)))
    (def best
      (List filter
        (fn (_ c) (not (List any? (fn (_ d) (and (not (str=? d c)) (%member? c (%ancestors gitdir d)))) common)))
        common))
    (List sort (fn (_ x y) (< (rest (%commit-info gitdir x)) (rest (%commit-info gitdir y)))) best)))

; A commit's files, as git-tree-flat lists them.
(def %commit-files
  (fn (_ gitdir sha)
    (def o (git-object-read gitdir sha))
    (def tree (List find (fn (_ l) (Str8 starts? "tree " l)) (Str8 split "\n" (git-object-text o))))
    (git-tree-flat gitdir (Str8 sub 5 40 tree) "")))

; The files a merge of commits a and b starts from, or #f when they share
; no history: their merge base's, or, when they have more than one, the
; bases merged into one, oldest first, as git's ort makes its virtual
; base -- each merge from the bases those two have, made the same way;
; the sides called "Temporary merge branch 1" and "2", a conflict's text
; left marked with markers two longer a level down, a file the merge
; could not write (binary, deleted on a side) the base's.
(def git-merge-base-files
  (fn (_ gitdir a b write-blob) (%base-files gitdir (list a) b 1 write-blob)))

(def %base-files
  (fn (self gitdir as b depth write-blob)
    (def bases (%merge-bases gitdir as b))
    (if (null? bases) #f
      ((fn (fold merged seen more)
         (if (null? more) merged
           (let ((inner (self gitdir seen (first more) (%add depth 1) write-blob)))
             (fold (%virtual-merge (if (eq? inner #f) () inner) merged (%commit-files gitdir (first more)) depth gitdir write-blob)
                   (pair (first more) seen) (rest more)))))
       (%commit-files gitdir (first bases)) (list (first bases)) (rest bases)))))

(def %virtual-merge
  (fn (_ base ours theirs depth gitdir write-blob)
    (def r (git-merge-trees base ours theirs "Temporary merge branch 1" "Temporary merge branch 2" "true"
             (%add 7 (* 2 depth)) gitdir write-blob))
    (List flat-map
      (fn (_ x)
        (match
          ((eq? (first (rest x)) (lit gone)) ())
          ((eq? (first (rest x)) (lit clean)) (list (list (first x) (first (rest (rest x))) (first (rest (rest (rest x)))))))
          (#t
            (let ((stages (first (rest (rest x)))) (work (first (rest (rest (rest x))))))
              (let ((at (fn (_ k) (List find (fn (_ s) (= (first s) k)) stages))))
                (if (not (null? work))
                  (list (list (first x) (first (rest (or (at 2) (at 3)))) (write-blob work)))
                  (let ((s (or (at 1) (at 2) (at 3)))) (list (list (first x) (first (rest s)) (first (rest (rest s))))))))))))
      (first r))))

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
; `<<<<<<< name1` and `>>>>>>> name2`, markers of size characters: seven,
; and two more a level down when merge bases are merged for a merge.
(def git-merge-text
  (fn (_ base ours theirs name1 name2 size)
    (def open (Str8 append (Str8 repeat size "<") " "))
    (def mid (Str8 append (Str8 repeat size "=") "\n"))
    (def close (Str8 append (Str8 repeat size ">") " "))
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
                         open name1 "\n" (%copy vo (%m m 3) (%m m 4) #t)
                         mid (%copy vt (%m m 5) (%m m 6) #t)
                         close name2 "\n")
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

; --- directory renames ---
;
; A side renamed a directory when the directory is gone from it and its
; files' renames say where they went, as git's ort counts them: a file
; renamed from old/x/f to new/x/f says old/x went to new/x, and old to
; new, up to the first parent whose last part differs.  The destination
; most of a directory's files took is its new name; when no destination
; has more than every other, the directory was split, and nothing added
; to it can follow it.

(def %dir-of
  (fn (_ p) (let ((i (Str8 last-index-of "/" p))) (if (null? i) "" (Str8 sub 0 i p)))))

(def %last-of
  (fn (_ p) (let ((i (Str8 last-index-of "/" p))) (if (null? i) p (Str8 sub (%add i 1) (%sub (Str8 length p) (%add i 1)) p)))))

; Every directory files are under, each once.
(def %dirs
  (fn (_ files)
    ((fn (self ps acc)
       (if (null? ps) acc
         (self (rest ps)
               ((fn (up d acc) (if (or (str=? d "") (%member? d acc)) acc (up (%dir-of d) (pair d acc))))
                (%dir-of (first (first ps))) acc))))
     files ())))

; The (OLD-DIR . NEW-DIR) pairs a file renamed from old to new votes for.
(def %rename-dirs
  (fn (self old new first? acc)
    (if (and (not first?) (not (str=? (%last-of old) (%last-of new)))) acc
      (let ((od (%dir-of old)) (nd (%dir-of new)))
        (if (str=? od nd) acc
          (if (or (str=? od "") (str=? nd "")) (pair (pair od nd) acc)
            (self od nd #f (pair (pair od nd) acc))))))))

; What a side's renames did to the directories gone from it:
; ((DIR . NEW-DIR) ...), NEW-DIR () when the directory was split.
(def %dir-renames
  (fn (_ base side renames)
    (def gone (List filter (fn (_ d) (not (%member? d (%dirs side)))) (%dirs base)))
    (def votes
      (List filter (fn (_ v) (%member? (first v) gone))
        (List flat-map (fn (_ r) (%rename-dirs (first (first r)) (first (first (rest r))) #t ())) renames)))
    (List map
      (fn (_ d)
        (def tally
          ((fn (self vs acc)
             (if (null? vs) acc
               (let ((hit (List find (fn (_ t) (str=? (first t) (first vs))) acc)))
                 (self (rest vs)
                       (if (null? hit) (pair (pair (first vs) 1) acc)
                         (List map (fn (_ t) (if (str=? (first t) (first vs)) (pair (first t) (%add (rest t) 1)) t)) acc))))))
           (List map rest (List filter (fn (_ v) (str=? (first v) d)) votes)) ()))
        (def most (List fold (fn (_ m t) (if (> (rest t) m) (rest t) m)) 0 tally))
        (def top (List filter (fn (_ t) (= (rest t) most)) tally))
        (pair d (if (= (List length top) 1) (first (first top)) ())))
      ((fn (self vs acc) (if (null? vs) acc (self (rest vs) (if (%member? (first (first vs)) acc) acc (pair (first (first vs)) acc)))))
       votes ()))))

; Where the other side's renamed directories take each file a side added
; (or renamed to a new name): ((PATH NEW-PATH DIR) ...), NEW-PATH () when
; DIR, the deepest renamed directory the path is under, was split.  A
; file whose new path is taken already stays where it is.
(def %dir-moves
  (fn (_ base side other dir-renames)
    (List flat-map
      (fn (_ f)
        (def path (first f))
        (def hit
          (List fold (fn (_ best d) (if (and (Str8 starts? (Str8 append (first d) "/") path)
                                              (or (null? best) (> (Str8 length (first d)) (Str8 length (first best)))))
                                       d best))
            () dir-renames))
        (if (or (null? hit) (not (null? (%find path base)))) ()
          (if (null? (rest hit)) (list (list path () (first hit)))
            (let ((tail (Str8 sub (%add (Str8 length (first hit)) 1) (%sub (Str8 length path) (%add (Str8 length (first hit)) 1)) path)))
              (let ((to (if (str=? (rest hit) "") tail (Str8 append (rest hit) "/" tail))))
                (if (or (not (null? (%find to side))) (not (null? (%find to other)))) ()
                  (list (list path to (first hit)))))))))
      side)))

; A file row, or a rename's, at its path after the moves.
(def %moved
  (fn (_ f moves)
    (def m (List find (fn (_ x) (and (str=? (first x) (first f)) (not (null? (first (rest x)))))) moves))
    (if (null? m) f (pair (first (rest m)) (rest f)))))

; Three trees' files merged.  Answers (RESULTS MESSAGES STOPPED?): RESULTS a
; (PATH ...) each --
;   (PATH clean MODE SHA)          the path's file, merged
;   (PATH gone)                    the path's file deleted
;   (PATH conflict STAGES WORK)    in conflict: STAGES ((STAGE MODE SHA) ...),
;                                  WORK the working file's text, or () to
;                                  leave ours as it is
; MESSAGES the lines merge prints, in path order, and STOPPED? whether the
; merge stops though no path is in conflict.  write-blob answers a merged
; text's blob name.  name1 and name2 name the sides; dir-renames is
; merge.directoryRenames; size is the conflict markers' size.
;
; A file one side renamed (git/renames, against the base) is merged under
; its new name: its base, the other side's file at the old name, and the
; renamed one -- the conflict markers naming each side NAME:PATH when the
; paths differ, as git's do.  Renamed by both sides, to the same name, it
; is merged there; to different names, it is a rename/rename conflict.
; Renamed by one side and deleted by the other, a rename/delete conflict.
;
; Before the files are merged, what a side added under a directory the
; other renamed is moved with it -- unless dir-renames is "false" -- and
; once they are, a moved file is left in conflict at its new path, staged
; on its side alone, when dir-renames is "conflict".  A directory that
; was split stops the merge, with nothing left in conflict.
(def git-merge-trees
  (fn (_ base ours theirs name1 name2 dir-renames size gitdir write-blob)
    (def renames-in
      (fn (_ side)
        (git-find-renames gitdir
          (List filter (fn (_ b) (null? (%find (first b) side))) base)
          (List filter (fn (_ f) (null? (%find (first f) base))) side))))
    (def raw-o (renames-in ours))
    (def raw-t (renames-in theirs))
    (def follow? (not (str=? dir-renames "false")))
    (def moves-o (if follow? (%dir-moves base ours theirs (%dir-renames base theirs raw-t)) ()))
    (def moves-t (if follow? (%dir-moves base theirs ours (%dir-renames base ours raw-o)) ()))
    (def move-renames
      (fn (_ rs moves) (List map (fn (_ r) (pair (first r) (pair (%moved (first (rest r)) moves) (rest (rest r))))) rs)))
    (def units
      (%merge-files base (List map (fn (_ f) (%moved f moves-o)) ours) (List map (fn (_ f) (%moved f moves-t)) theirs)
        (move-renames raw-o moves-o) (move-renames raw-t moves-t) name1 name2 size gitdir write-blob))
    ; a moved file's unit: in conflict at its new path, on its own side,
    ; and git's word for the move
    (def placed
      (fn (_ unit moves stage added-in renamed-in)
        (def m (List find (fn (_ x) (and (not (null? (first (rest x)))) (str=? (first (rest x)) (first unit)))) moves))
        (if (null? m) unit
          (let ((from (first m)) (to (first (rest m))))
            (pair to
                  (pair (List map
                          (fn (_ r)
                            (if (and (str=? dir-renames "conflict") (str=? (first r) to) (eq? (first (rest r)) (lit clean)))
                              (let ((f (list to (first (rest (rest r))) (first (rest (rest (rest r)))))))
                                (list to (lit conflict) (list (list stage (first (rest f)) (first (rest (rest f))))) (%blob-text gitdir f)))
                              r))
                          (first (rest unit)))
                        (List append (rest (rest unit))
                          (list (if (str=? dir-renames "conflict")
                                  (Str8 append "CONFLICT (file location): " from " added in " added-in
                                    " inside a directory that was renamed in " renamed-in
                                    ", suggesting it should perhaps be moved to " to ".\n")
                                  (Str8 append "Path updated: " from " added in " added-in
                                    " inside a directory that was renamed in " renamed-in "; moving it to " to ".\n"))))))))))
    ; what ours added goes from where HEAD has it
    (def left
      (List map (fn (_ m) (pair (first m) (pair (list (list (first m) (lit gone))) ())))
        (List filter (fn (_ m) (not (null? (first (rest m))))) moves-o)))
    ; a split directory, said once
    (def split-dirs
      ((fn (self ms acc)
         (if (null? ms) (List reverse acc)
           (self (rest ms)
                 (if (or (not (null? (first (rest (first ms))))) (List any? (fn (_ s) (str=? (first (rest s)) (first (rest (rest (first ms)))))) acc)) acc
                   (pair (pair (first (first ms)) (first (rest (rest (first ms))))) acc)))))
       (List append moves-o moves-t) ()))
    (def splits
      (List map (fn (_ s) (pair (first s) (pair () (list (Str8 append "CONFLICT (directory rename split): Unclear where to rename " (rest s)
                                                            " to; it was renamed to multiple other directories, with no destination getting a majority of the files.\n")))))
        split-dirs))
    (def all
      (List sort (fn (_ a b) (Str8 <? (first a) (first b)))
        (List append (List map (fn (_ u) (placed (placed u moves-o 2 name1 name2) moves-t 3 name2 name1)) units)
          (List append left splits))))
    (list (List flat-map (fn (_ u) (first (rest u))) all) (List flat-map (fn (_ u) (rest (rest u))) all) (not (null? splits)))))

; The files merged once any moves are made, renames known: the units,
; (KEY RECORDS . MESSAGES) each, in path order.
(def %merge-files
  (fn (_ base ours theirs raw-o raw-t name1 name2 size gitdir write-blob)
    (def paths-of (fn (_ files) (List map first files)))
    ; a rename is taken only when the other side has nothing at its new
    ; name, or has it by making the same rename
    (def same-rename?
      (fn (_ r others)
        (List any? (fn (_ x) (and (str=? (first (first x)) (first (first r))) (str=? (first (first (rest x))) (first (first (rest r)))))) others)))
    (def ro (List filter (fn (_ r) (or (null? (%find (first (first (rest r))) theirs)) (same-rename? r raw-t))) raw-o))
    (def rt (List filter (fn (_ r) (or (null? (%find (first (first (rest r))) ours)) (same-rename? r raw-o))) raw-t))
    (def renamed-by (fn (_ rs path) (List find (fn (_ r) (str=? (first (first r)) path)) rs)))
    (def stages
      (fn (_ b o t)
        (List append (if (null? b) () (list (list 1 (first (rest b)) (first (rest (rest b))))))
          (List append (if (null? o) () (list (list 2 (first (rest o)) (first (rest (rest o))))))
            (if (null? t) () (list (list 3 (first (rest t)) (first (rest (rest t))))))))))
    ; one path's entries merged: (RECORDS . MESSAGES).  label1 and label2
    ; are what the markers call the sides.
    (def merge-entries
      (fn (_ path b o t label1 label2)
        (match
          ((%same? o t) (if (null? o) (pair (list (list path (lit gone))) ()) (pair (list (list path (lit clean) (first (rest o)) (first (rest (rest o))))) ())))
          ((%same? b o) (if (null? t) (pair (list (list path (lit gone))) ()) (pair (list (list path (lit clean) (first (rest t)) (first (rest (rest t))))) ())))
          ((%same? b t) (if (null? o) (pair (list (list path (lit gone))) ()) (pair (list (list path (lit clean) (first (rest o)) (first (rest (rest o))))) ())))
          ; one side deleted what the other changed
          ((or (null? o) (null? t))
            (pair (list (list path (lit conflict) (stages b o t) (if (null? o) (%blob-text gitdir t) ())))
                  (list (Str8 append "CONFLICT (modify/delete): " path " deleted in " (if (null? o) name1 name2)
                          " and modified in " (if (null? o) name2 name1) ".  Version " (if (null? o) name2 name1)
                          " of " path " left in tree.\n"))))
          ; both changed it, or both added it: the texts merged
          (#t
            (let ((tb (%blob-text gitdir b)) (to (%blob-text gitdir o)) (tt (%blob-text gitdir t))
                  (kind (if (null? b) "add/add" "content")))
              (if (or (%binary? gitdir b) (%binary? gitdir o) (%binary? gitdir t))
                (pair (list (list path (lit conflict) (stages b o t) ()))
                      (list (Str8 append "warning: Cannot merge binary files: " path " (" label1 " vs. " label2 ")\n")
                            (Str8 append "Auto-merging " path "\n")
                            (Str8 append "CONFLICT (" kind "): Merge conflict in " path "\n")))
                (let ((r (git-merge-text tb to tt label1 label2 size)))
                  (if (= (rest r) 0)
                    (pair (list (list path (lit clean) (first (rest o)) (write-blob (first r)))) (list (Str8 append "Auto-merging " path "\n")))
                    (pair (list (list path (lit conflict) (stages b o t) (first r)))
                          (list (Str8 append "Auto-merging " path "\n")
                                (Str8 append "CONFLICT (" kind "): Merge conflict in " path "\n")))))))))))
    ; the markers' names for a renamed file: NAME:PATH when the paths differ
    (def labels
      (fn (_ b o t)
        (if (and (str=? (first b) (first o)) (str=? (first o) (first t))) (pair name1 name2)
          (pair (Str8 append name1 ":" (first o)) (Str8 append name2 ":" (first t))))))
    ; each renamed file's units, keyed by the path they sort under:
    ; ((KEY RECORDS . MESSAGES) ...), and the paths they account for
    (def rename-units
      (List flat-map
        (fn (_ b)
          (let ((o-r (renamed-by ro (first b))) (t-r (renamed-by rt (first b))))
            (match
              ((and (null? o-r) (null? t-r)) ())
              ; both renamed it
              ((and (not (null? o-r)) (not (null? t-r)))
                (let ((od (first (rest o-r))) (td (first (rest t-r))))
                  (if (str=? (first od) (first td))
                    (let ((lb (labels b od td)))
                      (list (pair (first od) (merge-entries (first od) b od td (first lb) (rest lb)))))
                    (list (pair (first b)
                            (pair (list (list (first b) (lit conflict) (list (list 1 (first (rest b)) (first (rest (rest b))))) ())
                                        (list (first od) (lit conflict) (list (list 2 (first (rest od)) (first (rest (rest od))))) ())
                                        (list (first td) (lit conflict) (list (list 3 (first (rest td)) (first (rest (rest td)))))
                                              (%blob-text gitdir td)))
                                  (list (Str8 append "CONFLICT (rename/rename): " (first b) " renamed to " (first od) " in " name1
                                          " and to " (first td) " in " name2 ".\n"))))))))
              ; ours renamed it
              ((not (null? o-r))
                (let ((od (first (rest o-r))) (t (%find (first b) theirs)))
                  (if (null? t)
                    (list (pair (first od)
                            (pair (list (list (first od) (lit conflict) (stages b od ()) ()))
                                  (list (Str8 append "CONFLICT (rename/delete): " (first b) " renamed to " (first od) " in " name1
                                          ", but deleted in " name2 ".\n")))))
                    (let ((lb (labels b od t)))
                      (list (pair (first od) (merge-entries (first od) b od t (first lb) (rest lb))))))))
              ; theirs renamed it
              (#t
                (let ((td (first (rest t-r))) (o (%find (first b) ours)))
                  (if (null? o)
                    (list (pair (first td)
                            (pair (list (list (first td) (lit conflict) (stages b () td) (%blob-text gitdir td)))
                                  (list (Str8 append "CONFLICT (rename/delete): " (first b) " renamed to " (first td) " in " name2
                                          ", but deleted in " name1 ".\n")))))
                    (let ((lb (labels b o td)))
                      ; the old name goes with it
                      (list (pair (first td)
                              (let ((m (merge-entries (first td) b o td (first lb) (rest lb))))
                                (pair (pair (list (first b) (lit gone)) (first m)) (rest m))))))))))))
        base))
    ; what the renames account for: each source, and each new name in the
    ; side that made it
    (def accounted
      (List append (List map (fn (_ r) (first (first r))) (List append ro rt))
        (List append (List map (fn (_ r) (first (first (rest r)))) ro) (List map (fn (_ r) (first (first (rest r)))) rt))))
    (def paths
      ((fn (self ps acc) (if (null? ps) acc (self (rest ps) (if (or (%member? (first ps) acc) (%member? (first ps) accounted)) acc (pair (first ps) acc)))))
       (List append (paths-of base) (List append (paths-of ours) (paths-of theirs))) ()))
    (def plain-units
      (List map (fn (_ path) (pair path (merge-entries path (%find path base) (%find path ours) (%find path theirs) name1 name2))) paths))
    (List append plain-units rename-units)))

(provide git/threeway git-merge-base-files git-merge-text git-merge-trees git-tree-flat)
