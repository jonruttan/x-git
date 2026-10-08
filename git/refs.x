; # x-git -- git on x-lang
;
; ## git/refs.x -- refs and revision names
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A ref is a file under .git holding a name (`ref: refs/heads/main`) or an
; object's SHA-1, or a line of .git/packed-refs, where an annotated tag's
; line may be followed by `^` and the object it peels to.  A revision
; (gitrevisions(7)) is a ref or an object name, with suffixes: `~N` the
; Nth first parent, `^N` the Nth parent, `^{TYPE}` peeled to that type,
; `^{}` peeled through tags, and `:PATH` the entry at PATH in the tree.
; Everything here answers a full SHA-1 or (); the words of a refusal are
; the command's.

(module git/refs)

(import x/sys/file File)
(import git/objects git-object-read git-resolve git-tree-entries git-object-text)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

; --- refs ---

; The text of a ref file, trimmed, or () when there is none.
(def %ref-file
  (fn (_ gitdir name)
    (def path (Str8 append gitdir "/" name))
    (if (File exists? path) (Str8 trim (File read-all path)) ())))

; packed-refs as ((NAME . SHA) ...), a tag's peeled line folded into its
; entry's cdr as (SHA . PEELED).
(def %packed-refs
  (fn (_ gitdir)
    (def text (%ref-file gitdir "packed-refs"))
    (if (null? text) ()
      ((fn (self lines acc)
         (match
           ((null? lines) (List reverse acc))
           ((= (Str8 length (first lines)) 0) (self (rest lines) acc))
           ((Str8 starts? "#" (first lines)) (self (rest lines) acc))
           ((Str8 starts? "^" (first lines))
             (if (null? acc) (self (rest lines) acc)
               (let ((e (first acc)))
                 (self (rest lines) (pair (pair (first e) (pair (rest e) (Str8 sub 1 40 (first lines)))) (rest acc))))))
           (#t
             (self (rest lines)
               (pair (pair (Str8 sub 41 (%sub (Str8 length (first lines)) 41) (first lines))
                           (Str8 sub 0 40 (first lines)))
                     acc)))))
       (Str8 split "\n" text) ()))))

; What a ref holds: its SHA-1, following symbolic refs, loose before
; packed; () when there is no such ref.
(def git-ref-read
  (fn (self gitdir name)
    (def loose (%ref-file gitdir name))
    (match
      ((and (not (null? loose)) (Str8 starts? "ref: " loose))
        (self gitdir (Str8 trim (Str8 sub 5 (%sub (Str8 length loose) 5) loose))))
      ((not (null? loose)) loose)
      (#t
        (let ((hit (List find (fn (_ e) (str=? (first e) name)) (%packed-refs gitdir))))
          (match
            ((null? hit) ())
            ((pair? (rest hit)) (first (rest hit)))
            (#t (rest hit))))))))

; A short name tried as gitrevisions does: as given, under refs/, tags/,
; heads/, remotes/, and remotes/NAME/HEAD.
(def %ref-lookup
  (fn (_ gitdir name)
    ((fn (self cands)
       (if (null? cands) ()
         (let ((sha (git-ref-read gitdir (first cands))))
           (if (null? sha) (self (rest cands)) sha))))
     (list name
           (Str8 append "refs/" name)
           (Str8 append "refs/tags/" name)
           (Str8 append "refs/heads/" name)
           (Str8 append "refs/remotes/" name)
           (Str8 append "refs/remotes/" name "/HEAD")))))

; --- objects behind a revision ---

; The header lines of a commit or tag, as ((KEY . VALUE) ...), up to the
; blank line.
(def %headers
  (fn (_ gitdir sha)
    (def o (git-object-read gitdir sha))
    (if (null? o) ()
      ((fn (self lines acc)
         (if (or (null? lines) (= (Str8 length (first lines)) 0)) (List reverse acc)
           (let ((i (Str8 index-of " " (first lines))))
             (if (null? i) (self (rest lines) acc)
               (self (rest lines)
                 (pair (pair (Str8 sub 0 i (first lines))
                             (Str8 sub (%add i 1) (%sub (Str8 length (first lines)) (%add i 1)) (first lines)))
                       acc))))))
       (Str8 split "\n" (git-object-text o)) ()))))

(def %type-of
  (fn (_ gitdir sha)
    (def o (git-object-read gitdir sha))
    (if (null? o) () (first o))))

; A tag peeled once: the object it names.
(def %peel-tag
  (fn (_ gitdir sha)
    (def h (%headers gitdir sha))
    (def e (List find (fn (_ kv) (str=? (first kv) "object")) h))
    (if (null? e) () (rest e))))

; Peeled through every tag to what is not one.
(def %peel-tags
  (fn (self gitdir sha)
    (if (and (not (null? sha)) (str=? (%type-of gitdir sha) "tag"))
      (self gitdir (%peel-tag gitdir sha))
      sha)))

; A commit's Nth parent (1 the first), or ().
(def %parent
  (fn (_ gitdir sha n)
    (def c (%peel-tags gitdir sha))
    (if (or (null? c) (not (str=? (%type-of gitdir c) "commit"))) ()
      (let ((parents (List filter (fn (_ kv) (str=? (first kv) "parent")) (%headers gitdir c))))
        (if (> n (List length parents)) () (rest (List ref (%sub n 1) parents)))))))

; A commit's tree, a tag's through the tag; a tree is itself.
(def %tree-of
  (fn (_ gitdir sha)
    (def c (%peel-tags gitdir sha))
    (if (null? c) ()
      (let ((type (%type-of gitdir c)))
        (match
          ((str=? type "tree") c)
          ((str=? type "commit")
            (let ((e (List find (fn (_ kv) (str=? (first kv) "tree")) (%headers gitdir c))))
              (if (null? e) () (rest e))))
          (#t ()))))))

; The entry at PATH in a tree: one component at a time; "" is the tree.
(def %path-in
  (fn (self gitdir tree path)
    (if (or (null? tree) (= (Str8 length path) 0)) tree
      (let ((i (Str8 index-of "/" path)))
        (let ((head (if (null? i) path (Str8 sub 0 i path)))
              (tail (if (null? i) "" (Str8 sub (%add i 1) (%sub (Str8 length path) (%add i 1)) path))))
          (let ((o (git-object-read gitdir tree)))
            (if (or (null? o) (not (str=? (first o) "tree"))) ()
              (let ((e (List find (fn (_ ent) (str=? (first (rest ent)) head)) (git-tree-entries o))))
                (if (null? e) () (self gitdir (first (rest (rest e))) tail))))))))))

; --- revisions ---

; A suffix's count: its digits as a number, 1 when there are none, ()
; when it is not digits.
(def %count
  (fn (_ s)
    (def n (Str8 length s))
    (def digits?
      ((fn (self i)
         (if (>= i n) #t
           (let ((c (Char ->int (Str8 ref i s))))
             (if (and (>= c 48) (<= c 57)) (self (%add i 1)) #f))))
       0))
    (match
      ((= n 0) 1)
      (digits? (%str->number s 10))
      (#t ()))))

; A revision without a `:PATH` tail, to a SHA-1: the suffixes peeled off
; the right end and applied after the base resolves.
(def %rev-base
  (fn (self gitdir rev)
    (def n (Str8 length rev))
    (match
      ((= n 0) ())
      ; ^{TYPE} and ^{}
      ((and (Str8 ends? "}" rev) (not (null? (Str8 last-index-of "^{" rev))))
        (let ((i (Str8 last-index-of "^{" rev)))
          (let ((inner (self gitdir (Str8 sub 0 i rev)))
                (want (Str8 sub (%add i 2) (%sub (%sub n i) 3) rev)))
            (match
              ((null? inner) ())
              ((= (Str8 length want) 0) (%peel-tags gitdir inner))
              ((str=? want "tree") (%tree-of gitdir inner))
              ((str=? want "commit")
                (let ((c (%peel-tags gitdir inner)))
                  (if (and (not (null? c)) (str=? (%type-of gitdir c) "commit")) c ())))
              ((str=? want "tag") (if (str=? (%type-of gitdir inner) "tag") inner ()))
              ((str=? want "blob")
                (let ((c (%peel-tags gitdir inner)))
                  (if (and (not (null? c)) (str=? (%type-of gitdir c) "blob")) c ())))
              (#t ())))))
      ; ~N: N first parents
      ((not (null? (Str8 last-index-of "~" rev)))
        (let ((i (Str8 last-index-of "~" rev)))
          (let ((cnt (%count (Str8 sub (%add i 1) (%sub n (%add i 1)) rev))))
            (if (null? cnt) ()
              ((fn (walk sha k) (if (or (null? sha) (= k 0)) sha (walk (%parent gitdir sha 1) (%sub k 1))))
               (self gitdir (Str8 sub 0 i rev)) cnt)))))
      ; ^N: the Nth parent
      ((not (null? (Str8 last-index-of "^" rev)))
        (let ((i (Str8 last-index-of "^" rev)))
          (let ((cnt (%count (Str8 sub (%add i 1) (%sub n (%add i 1)) rev))))
            (let ((base (if (null? cnt) () (self gitdir (Str8 sub 0 i rev)))))
              (if (null? base) () (%parent gitdir base cnt))))))
      (#t
        (let ((sha (git-resolve gitdir rev)))
          (if (null? sha) (%ref-lookup gitdir rev) sha))))))

; A revision to a full SHA-1, or (): an object name or a ref with any of
; the suffixes, and `REV:PATH` the entry at PATH in REV's tree.
(def git-rev-parse
  (fn (_ gitdir rev)
    (def i (Str8 index-of ":" rev))
    (if (null? i) (%rev-base gitdir rev)
      (let ((base (%rev-base gitdir (Str8 sub 0 i rev)))
            (path (Str8 sub (%add i 1) (%sub (Str8 length rev) (%add i 1)) rev)))
        (if (null? base) () (%path-in gitdir (%tree-of gitdir base) path))))))

; Is the trouble with `REV:PATH` the path, given REV itself resolves?
; Answers REV when so, else ().
(def git-rev-path-missing
  (fn (_ gitdir rev)
    (def i (Str8 index-of ":" rev))
    (if (null? i) ()
      (let ((base (%rev-base gitdir (Str8 sub 0 i rev))))
        (if (null? base) () (Str8 sub 0 i rev))))))

; A revision's tree: a commit's, a tag's through the tag, a tree itself;
; () when the revision does not resolve or has no tree.
(def git-tree-of
  (fn (_ gitdir rev)
    (def sha (git-rev-parse gitdir rev))
    (if (null? sha) () (%tree-of gitdir sha))))

; A revision's commit: itself, or what its tag peels to; () when the
; revision does not resolve or does not reach a commit.
(def git-commit-of
  (fn (_ gitdir rev)
    (def c (%peel-tags gitdir (git-rev-parse gitdir rev)))
    (if (and (not (null? c)) (str=? (%type-of gitdir c) "commit")) c ())))

; A commit's header lines, ((KEY . VALUE) ...), for the commands that
; print them; () for a name that is not a commit or tag.
(def git-headers
  (fn (_ gitdir sha) (%headers gitdir sha)))

(provide git/refs git-ref-read git-rev-parse git-rev-path-missing git-tree-of git-commit-of git-headers)
