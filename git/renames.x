; # x-git -- git on x-lang
;
; ## git/renames.x -- which deleted file a new one is
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Renames as git's diffcore-rename finds them, between the files one tree
; lacks of another (the sources) and the files it has that the other
; lacks (the destinations).  An exact rename -- the same blob -- is taken
; first.  Then each pair is scored as git's estimate_similarity scores it:
; each file cut into spans at a newline or after 64 bytes (a CR before a
; newline left out of a text), the bytes of the spans the two share,
; counted the fewer times either has them, over the larger file's size;
; a pair whose sizes differ by more than half the larger is not scored.
; Pairs scoring half or more are taken, the best first, each file once.
; git keys a span by a hash of it and these by its text, so the two can
; differ only where git's hash collides.

(module git/renames)

(import git/objects git-object-read)
(import git/quote git-quote-path)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %mul (prim-ref 'int '*))
(def %div (prim-ref (lit int) (lit /)))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %pset! (prim-ref (lit ptr) (lit set!)))

; git's scale: a score of 60000 is identical.
(def git-max-score 60000)
(def %minimum-score 30000)

(def %member? (fn (_ s l) (List any? (fn (_ x) (str=? x s)) l)))

; A blob's bytes: (PTR . N), or () when it is missing.
(def %bytes
  (fn (_ gitdir sha)
    (def o (git-object-read gitdir sha))
    (if (null? o) ()
      (pair (%int->ptr (%add (%ptr->int (%str->ptr (first (rest (rest o))))) (first (rest (rest (rest o))))))
            (first (rest o))))))

(def %binary?
  (fn (_ p n)
    (def m (if (> n 8000) 8000 n))
    ((fn (self i) (if (>= i m) #f (if (= (& (%pref p i 1) 255) 0) #t (self (%add i 1))))) 0)))

; A file's spans counted: ((TEXT . BYTES) ...), each span's text once with
; the bytes it adds up to.  hash_chars, keyed by text.
(def %spans
  (fn (_ p n)
    (def text? (not (%binary? p n)))
    (def span-text
      (fn (_ start len)
        (def s (%make-str (%add len 1)))
        (%mem-copy (%str->ptr s) (%int->ptr (%add (%ptr->int p) start)) len)
        (%pset! (%str->ptr s) len 0 1)
        s))
    ; the spans as (START . LEN) runs of bytes kept, CRs of CRLF left out
    (def counts
      ((fn (self i start k acc)
         (if (>= i n)
           (if (> k 0) (pair (pair (span-text start (%sub i start)) k) acc) acc)
           (let ((c (& (%pref p i 1) 255)))
             (if (and text? (= c 13) (< (%add i 1) n) (= (& (%pref p (%add i 1) 1) 255) 10))
               (self (%add i 1) start k acc)
               (let ((k2 (%add k 1)))
                 (if (or (>= k2 64) (= c 10))
                   (self (%add i 1) (%add i 1) 0 (pair (pair (span-text start (%sub (%add i 1) start)) k2) acc))
                   (self (%add i 1) start k2 acc)))))))
       0 0 0 ()))
    ; the same text's bytes added together
    ((fn (self cs acc)
       (if (null? cs) acc
         (let ((hit (List find (fn (_ a) (str=? (first a) (first (first cs)))) acc)))
           (if (null? hit) (self (rest cs) (pair (first cs) acc))
             (self (rest cs) (List map (fn (_ a) (if (eq? a hit) (pair (first a) (%add (rest a) (rest (first cs)))) a)) acc))))))
     counts ())))

; How alike two blobs are, 0 to git-max-score.
(def git-similarity
  (fn (_ gitdir src dst)
    (def a (%bytes gitdir src))
    (def b (%bytes gitdir dst))
    (if (or (null? a) (null? b)) 0
      (let ((na (rest a)) (nb (rest b)))
        (let ((max-size (if (> na nb) na nb)) (base-size (if (< na nb) na nb)))
          (if (< (%mul max-size (%sub git-max-score %minimum-score)) (%mul (%sub max-size base-size) git-max-score)) 0
            (if (= max-size 0) git-max-score
              (let ((sa (%spans (first a) na)) (sb (%spans (first b) nb)))
                (let ((copied (List fold
                                (fn (_ acc s)
                                  (let ((d (List find (fn (_ x) (str=? (first x) (first s))) sb)))
                                    (if (null? d) acc (%add acc (if (< (rest s) (rest d)) (rest s) (rest d))))))
                                0 sa)))
                  (%div (%mul copied git-max-score) max-size))))))))))

; The renames from the sources to the destinations, each (PATH MODE SHA):
; ((SRC DST SCORE) ...), SRC and DST the entries.
(def git-find-renames
  (fn (_ gitdir sources destinations)
    ; exact: the same blob, each file taken once
    (def exact
      ((fn (self ds used acc)
         (if (null? ds) (List reverse acc)
           (let ((s (List find (fn (_ s) (and (str=? (first (rest (rest s))) (first (rest (rest (first ds)))))
                                              (not (%member? (first s) used))))
                      sources)))
             (if (null? s) (self (rest ds) used acc)
               (self (rest ds) (pair (first s) used) (pair (list s (first ds) git-max-score) acc))))))
       destinations () ()))
    (def taken-src (List map (fn (_ r) (first (first r))) exact))
    (def taken-dst (List map (fn (_ r) (first (first (rest r)))) exact))
    (def srcs (List filter (fn (_ s) (not (%member? (first s) taken-src))) sources))
    (def dsts (List filter (fn (_ d) (not (%member? (first d) taken-dst))) destinations))
    ; inexact: every pair scored, the best first
    (def scored
      (List sort (fn (_ x y) (> (first (rest (rest x))) (first (rest (rest y)))))
        (List filter (fn (_ r) (>= (first (rest (rest r))) %minimum-score))
          (List flat-map
            (fn (_ d) (List map (fn (_ s) (list s d (git-similarity gitdir (first (rest (rest s))) (first (rest (rest d)))))) srcs))
            dsts))))
    (def inexact
      ((fn (self rs used-s used-d acc)
         (if (null? rs) (List reverse acc)
           (let ((r (first rs)))
             (if (or (%member? (first (first r)) used-s) (%member? (first (first (rest r))) used-d))
               (self (rest rs) used-s used-d acc)
               (self (rest rs) (pair (first (first r)) used-s) (pair (first (first (rest r))) used-d) (pair r acc))))))
       scored () () ()))
    (List append exact inexact)))

; A rename as git prints it in a diffstat (pprint_rename): the part both
; names share up to a / and from one written once, the rest as
; {OLD => NEW}; when either needs quoting, each whole, quoted as it needs.
(def git-rename-name
  (fn (_ a b)
    (if (or (not (str=? (git-quote-path a) a)) (not (str=? (git-quote-path b) b)))
      (Str8 append (git-quote-path a) " => " (git-quote-path b))
      (%rename-name a b))))

(def %rename-name
  (fn (_ a b)
    (def la (Str8 length a))
    (def lb (Str8 length b))
    ; a character, the end of the name read as one more character alike
    ; in both, before the start as one unlike any
    (def at (fn (_ s n i) (match ((< i 0) ()) ((>= i n) "") (#t (Str8 sub i 1 s)))))
    (def prefix
      ((fn (self i pfx)
         (if (or (>= i la) (>= i lb) (not (str=? (at a la i) (at b lb i)))) pfx
           (self (%add i 1) (if (str=? (at a la i) "/") (%add i 1) pfx))))
       0 0))
    (def suffix
      ((fn (self oi ni sfx)
         (let ((ca (at a la oi)) (cb (at b lb ni)))
           (if (or (< oi (%sub prefix 1)) (< ni (%sub prefix 1)) (null? ca) (null? cb) (not (str=? ca cb))) sfx
             (self (%sub oi 1) (%sub ni 1) (if (str=? ca "/") (%sub la oi) sfx)))))
       la lb 0))
    (if (and (= prefix 0) (= suffix 0)) (Str8 append a " => " b)
      (Str8 append (Str8 sub 0 prefix a) "{"
        (Str8 sub prefix (%sub (%sub la prefix) suffix) a) " => "
        (Str8 sub prefix (%sub (%sub lb prefix) suffix) b) "}"
        (Str8 sub (%sub la suffix) suffix a)))))

(provide git/renames git-find-renames git-similarity git-rename-name git-max-score)
