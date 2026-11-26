; # x-git -- git on x-lang
;
; ## lib/git/diff.x -- lines compared: diff, and what a change amounts to
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Two texts compared line by line: the edit script as git's xdiff makes
; it (Myers, and git's steps before and after), laid out as git's unified
; diff -- the header, the index line, hunks of changes with three lines of
; context, each headed by the line above it that starts a function as
; git's default finds one -- or counted as --stat prints them.  The
; counts are also what commit's summary prints, so that lives here too.

(module git/diff)

(import x/sys/opts Opts)
(import x/sys/file File)
(import x/sys/posix Sys)
(import x/type/vector Vector)
(import x/type/dict Dict)
(import x/sys/gc Heap)
(import git/objects git-object-read git-object-text git-read-file git-hash)
(import git/commands git-fatal git-no-repo git-unknown-option)
(import git/refs git-tree-of git-rev-parse)
(import git/index git-index-read git-tree-files git-modes-kept? git-work-mode)
(import git/work git-work-exists? git-work-read)
(import git/renames git-find-renames git-find-renames-of git-blob-bytes git-rename-name git-max-score)
(import git/quote git-quote-path)

(import x/core/doors int+ int- int* int>> str-byte-len str-byte-ref str-byte-sub char->int int<< ptr-ref ptr-set! str-make str->ptr int/)
(def %cvt (prim-ref (lit convert) (lit to)))
(def %string-type (Type named STRING))

; --- lines ---

; A text's lines (a trailing newline closing the last) and whether the
; text ended without one: (LINES . NO-NEWLINE?).  Splitting leaves some
; hundred objects a byte behind, counted as churn.
(def %lines
  (fn (_ s)
    (%churned! (int/ (str-byte-len s) 9))
    (def n (Str8 length s))
    (def ls (Str8 split "\n" s))
    (if (= n 0) (pair () #f)
      (if (= (Str8 length (List last ls)) 0)
        (pair (List take (int- (List length ls) 1) ls) #f)
        (pair ls #t)))))

; --- the edit script ---
;
; As git's xdiff makes it with its default algorithm: each line classed by
; its text; the lines both texts start and end with set aside; a line the
; other text lacks marked changed at once, and one with many matches too
; when it sits among such lines (xdl_cleanup_records); Myers's divide and
; conquer on the rest, with git's cut-offs for an expensive box (xdl_split,
; xdl_recs_cmp); then each group of changes slid as xdl_change_compact
; slides it -- to line up with a change in the other text, else where the
; indent heuristic scores it best.

(def %mem-set (prim-ref (lit mem) (lit set)))

; Words, as the comparison reads and writes them on every step: a region
; of n 8-byte integers, zeroed, as (BUFFER . ADDRESS) -- the buffer held
; so the address stays good (the collector frees in place, never moves).
(def %words
  (fn (_ n)
    (def s (str-make (int<< (int+ n 1) 3)))
    (%mem-set (str->ptr s) 0 (int<< (int+ n 1) 3))
    (pair s (str->ptr s))))
(def %at (fn (_ w i) (ptr-ref (rest w) (int<< i 3) 8)))
(def %at! (fn (_ w i v) (ptr-set! (rest w) (int<< i 3) v 8)))
(def %words-build
  (fn (_ n f)
    (def w (%words n))
    ((fn (self i) (when (< i n) (do (%at! w i (f i)) (self (int+ i 1))))) 0)
    w))
(def %words-of
  (fn (_ l)
    (def w (%words (List length l)))
    ((fn (self l i) (unless (null? l) (do (%at! w i (first l)) (self (rest l) (int+ i 1))))) l 0)
    w))

(def %max-eqlimit 1024)
(def %simscan-window 100)
(def %kpdis-run 4)
(def %max-cost-min 256)
(def %heur-min-cost 256)
(def %snake-cnt 20)
(def %k-heur 4)
(def %line-max 1000000000000)

(def %bogosqrt (fn (self n i) (if (> n 0) (self (int>> n 2) (int* i 2)) i)))

; x collects only when asked.  A diagonal followed leaves some thousand
; objects behind, a line scanned among its neighbours for discarding some
; ten thousand, a line classed some three thousand; churn counts them in
; thousands, collected past 2000.
(def %churn 0)
(def %churned!
  (fn (_ n)
    (set! %churn (int+ %churn n))
    (when (>= %churn 2000) (do (Heap collect) (set! %churn 0)))))

(def %space? (fn (_ c) (or (= c 32) (= c 9) (= c 10) (= c 13))))

; A line's indent, a tab to the next multiple of 8, at most 200; -1 for a
; line of nothing but white space (get_indent).
(def %indent
  (fn (_ s)
    (def n (str-byte-len s))
    ((fn (self i r)
       (if (>= i n) -1
         (let ((c (char->int (str-byte-ref s i))))
           (if (not (%space? c)) r
             (let ((r2 (match ((= c 32) (int+ r 1)) ((= c 9) (int- (int+ r 8) (% r 8))) (#t r))))
               (if (>= r2 200) 200 (self (int+ i 1) r2)))))))
     0 0)))

; Is a line among those around it one to discard: in a run of lines with
; no match, more of them than of lines with many (xdl_clean_mmatch).
; Actions: 0 discard, 1 keep, 2 investigate.
(def %clean-mmatch
  (fn (_ act i len)
    (def s (if (> i %simscan-window) (int- i %simscan-window) 0))
    (def e (if (> (int- (int- len 1) i) %simscan-window) (int+ i %simscan-window) (int- len 1)))
    (def scan
      (fn (_ step)
        ((fn (self r dis pdis)
           (let ((j (int+ i (int* step r))))
             (if (if (< step 0) (< j s) (> j e)) (pair dis pdis)
               (let ((a (%at act j)))
                 (match
                   ((= a 0) (self (int+ r 1) (int+ dis 1) pdis))
                   ((= a 2) (self (int+ r 1) dis (int+ pdis 1)))
                   (#t (pair dis pdis)))))))
         1 0 1)))
    (def before (scan -1))
    (if (= (first before) 0) #f
      (let ((after (scan 1)))
        (if (= (first after) 0) #f
          (let ((dis (int+ (first before) (first after))) (pdis (int+ (rest before) (rest after))))
            (< (int* pdis %kpdis-run) (int+ pdis dis))))))))

; Where a split above line `split` falls among the indents around it:
; (EOF INDENT PRE-BLANK PRE-INDENT POST-BLANK POST-INDENT) (measure_split).
(def %measure
  (fn (_ ind n split)
    (def run
      (fn (_ from step)
        ((fn (self i blank)
           (if (or (< i 0) (>= i n)) (pair blank -1)
             (let ((k (ind i)))
               (if (not (= k -1)) (pair blank k)
                 (if (= (int+ blank 1) 20) (pair 20 0) (self (int+ i step) (int+ blank 1)))))))
         from 0)))
    (def pre (run (int- split 1) -1))
    (def post (run (int+ split 1) 1))
    (list (>= split n) (if (>= split n) -1 (ind split)) (first pre) (rest pre) (first post) (rest post))))

; A split's score, (EFFECTIVE-INDENT . PENALTY), smaller the better
; (score_add_split).
(def %split-score
  (fn (_ m)
    (def eof (first m))
    (def indent (first (rest m)))
    (def pre-blank (first (rest (rest m))))
    (def pre-indent (first (rest (rest (rest m)))))
    (def post-indent (List last m))
    (def post-blank (if (= indent -1) (int+ 1 (first (rest (rest (rest (rest m)))))) 0))
    (def total-blank (int+ pre-blank post-blank))
    (def eff (if (= indent -1) post-indent indent))
    (def any-blanks (not (= total-blank 0)))
    (pair eff
      (int+ (int+ (if (and (= pre-indent -1) (= pre-blank 0)) 1 0) (if eof 21 0))
        (int+ (int+ (int* -30 total-blank) (int* 6 post-blank))
          (match
            ((or (= eff -1) (= pre-indent -1)) 0)
            ((> eff pre-indent) (if any-blanks 10 -4))
            ((= eff pre-indent) 0)
            ((and (not (= post-indent -1)) (> post-indent eff)) (if any-blanks 17 24))
            (#t (if any-blanks 17 23))))))))

(def %score-cmp
  (fn (_ a b)
    (int+ (int* 60 (match ((> (first a) (first b)) 1) ((< (first a) (first b)) -1) (#t 0)))
          (int- (rest a) (rest b)))))

; One text's groups of changes slid against the other's (xdl_change_compact):
; h and ho the texts' classes, ch and cho their changed flags (offset by
; one, so a flag before the first line and after the last reads false),
; ind a line's indent.
(def %compact
  (fn (_ h ch n ho cho no ind)
    (def c? (fn (_ c i) (= (%at c (int+ i 1)) 1)))
    (def c! (fn (_ c i v) (%at! c (int+ i 1) (if v 1 0))))
    (def run-end (fn (self c i) (if (c? c i) (self c (int+ i 1)) i)))
    (def run-start (fn (self c i) (if (c? c (int- i 1)) (self c (int- i 1)) i)))
    (def next (fn (_ c nr g) (if (= (rest g) nr) () (pair (int+ (rest g) 1) (run-end c (int+ (rest g) 1))))))
    (def prev (fn (_ c g) (if (= (first g) 0) () (pair (run-start c (int- (first g) 1)) (int- (first g) 1)))))
    (def empty? (fn (_ g) (= (first g) (rest g))))
    (def down
      (fn (_ g)
        (if (and (< (rest g) n) (= (%at h (first g)) (%at h (rest g))))
          (do (c! ch (first g) #f) (c! ch (rest g) #t)
              (pair (int+ (first g) 1) (run-end ch (int+ (rest g) 1))))
          ())))
    (def up
      (fn (_ g)
        (if (and (> (first g) 0) (= (%at h (int- (first g) 1)) (%at h (int- (rest g) 1))))
          (do (c! ch (int- (first g) 1) #t) (c! ch (int- (rest g) 1) #f)
              (pair (run-start ch (int- (first g) 1)) (int- (rest g) 1)))
          ())))
    ; slid up as far as it goes, then down: (G GO EARLIEST-END END-MATCHING)
    (def slide
      (fn (self g go)
        (def size (int- (rest g) (first g)))
        (def top ((fn (self g go) (let ((g2 (up g))) (if (null? g2) (pair g go) (self g2 (prev cho go))))) g go))
        (def earliest (rest (first top)))
        (def bottom
          ((fn (self g go emo)
             (let ((g2 (down g)))
               (if (null? g2) (list g go emo)
                 (let ((go2 (next cho no go)))
                   (self g2 go2 (if (empty? go2) emo (rest g2)))))))
           (first top) (rest top) (if (empty? (rest top)) -1 earliest)))
        (def g2 (first bottom))
        (if (not (= size (int- (rest g2) (first g2)))) (self g2 (first (rest bottom)))
          (list g2 (first (rest bottom)) earliest (first (rest (rest bottom)))))))
    (def up-to
      (fn (self g go end) (if (> (rest g) end) (self (up g) (prev cho go) end) (pair g go))))
    (def place
      (fn (_ g go)
        (def s (slide g go))
        (def g (first s))
        (def go (first (rest s)))
        (def earliest (first (rest (rest s))))
        (def emo (List last s))
        (match
          ((= (rest g) earliest) (pair g go))
          ((not (= emo -1))
            ((fn (self g go) (if (empty? go) (self (up g) (prev cho go)) (pair g go))) g go))
          (#t
            (let ((size (int- (rest g) (first g))))
              (let ((from (List fold (fn (_ a b) (if (> b a) b a)) earliest
                            (list (int- (int- (rest g) size) 1) (int- (rest g) 100)))))
                (let ((best
                        ((fn (self shift best best-score)
                           (if (> shift (rest g)) best
                             (let ((a (%split-score (%measure ind n shift)))
                                   (b (%split-score (%measure ind n (int- shift size)))))
                               (let ((score (pair (int+ (first a) (first b)) (int+ (rest a) (rest b)))))
                                 (if (or (= best -1) (<= (%score-cmp score best-score) 0))
                                   (self (int+ shift 1) shift score)
                                   (self (int+ shift 1) best best-score))))))
                         from -1 ())))
                  (up-to g go best))))))))
    ((fn (self g go)
       (let ((placed (if (empty? g) (pair g go) (place g go))))
         (let ((g2 (next ch n (first placed))))
           (if (not (null? g2)) (self g2 (next cho no (rest placed)))))))
     (pair 0 (run-end ch 0)) (pair 0 (run-end cho 0)))))

; Which lines of a and b changed, compared by their keys ka and kb:
; (CHANGED-A . CHANGED-B), words of flags offset by one.
(def %changed-lines
  (fn (_ ka kb)
    ; --- classes: lines of one text alike share a number, each class
    ; counting its lines on either side, (LEN-A LEN-B NUMBER)
    (def classes (Dict make))
    (def made (Vector make 2 ()))
    (Vector set! 1 0 made)
    (def class-of
      (fn (_ k side)
        (%churned! 3)
        (def c (classes get k))
        (def c2 (if (null? c)
                  (let ((v (Vector make 3 (Vector ref 1 made))))
                    (do (Vector set! 0 0 v) (Vector set! 1 0 v)
                        (classes set! k v) (Vector set! 0 (pair v (Vector ref 0 made)) made)
                        (Vector set! 1 (int+ (Vector ref 1 made) 1) made) v))
                  c))
        (Vector set! side (int+ (Vector ref side c2) 1) c2)
        (Vector ref 2 c2)))
    (def ha (%words-of (List map (fn (_ k) (class-of k 0)) ka)))
    (def hb (%words-of (List map (fn (_ k) (class-of k 1)) kb)))
    (def counts (Vector from-list (List reverse (Vector ref 0 made))))
    (def n1 (List length ka))
    (def n2 (List length kb))
    (def ch1 (%words (int+ n1 2)))
    (def ch2 (%words (int+ n2 2)))
    (def mark! (fn (_ ch i) (%at! ch (int+ i 1) 1)))
    ; --- the ends both share set aside
    (def lim (if (< n1 n2) n1 n2))
    (def dstart ((fn (self i) (if (and (< i lim) (= (%at ha i) (%at hb i))) (self (int+ i 1)) i)) 0))
    (def tail
      ((fn (self i)
         (if (and (< i (int- lim dstart)) (= (%at ha (int- n1 (int+ i 1))) (%at hb (int- n2 (int+ i 1)))))
           (self (int+ i 1)) i))
       0))
    ; --- lines the other text lacks marked; the rest, by number, to compare
    (def kept
      (fn (_ h ch n len other)
        (def mlim (let ((m (%bogosqrt n 1))) (if (> m %max-eqlimit) %max-eqlimit m)))
        (def act
          (%words-build len
            (fn (_ i)
              (let ((nm (Vector ref other (Vector ref (%at h (int+ i dstart)) counts))))
                (match ((= nm 0) 0) ((< nm mlim) 1) (#t 2))))))
        ((fn (self i acc)
           (if (>= i len) (pair (List length acc) (%words-of (List reverse acc)))
             (let ((a (%at act i)))
               (if (if (= a 2) (do (%churned! 10) (not (%clean-mmatch act i len))) (= a 1))
                 (self (int+ i 1) (pair (int+ i dstart) acc))
                 (do (mark! ch (int+ i dstart)) (self (int+ i 1) acc))))))
         0 ())))
    (def k1 (kept ha ch1 n1 (int- n1 (int+ dstart tail)) 1))
    (def k2 (kept hb ch2 n2 (int- n2 (int+ dstart tail)) 0))
    (def nr1 (first k1))
    (def nr2 (first k2))
    (def r1 (rest k1))
    (def r2 (rest k2))
    (def g1 (%words-build nr1 (fn (_ i) (%at ha (%at r1 i)))))
    (def g2 (%words-build nr2 (fn (_ i) (%at hb (%at r2 i)))))
    (def same? (fn (_ i j) (= (%at g1 i) (%at g2 j))))
    ; --- Myers: the furthest-reaching paths kept forward and back by diagonal
    (def ndiags (int+ (int+ nr1 nr2) 3))
    (def koff (int+ nr2 1))
    (def kvdf (%words ndiags))
    (def kvdb (%words ndiags))
    (def vf (fn (_ d) (%at kvdf (int+ d koff))))
    (def vf! (fn (_ d v) (%at! kvdf (int+ d koff) v)))
    (def vb (fn (_ d) (%at kvdb (int+ d koff))))
    (def vb! (fn (_ d v) (%at! kvdb (int+ d koff) v)))
    (def mxcost (let ((c (%bogosqrt ndiags 1))) (if (< c %max-cost-min) %max-cost-min c)))
    ; a split of the box: (I1 I2 MIN-LO MIN-HI)
    (def split
      (fn (_ off1 lim1 off2 lim2 need-min)
        (def dmin (int- off1 lim2))
        (def dmax (int- lim1 off2))
        (def fmid (int- off1 off2))
        (def bmid (int- lim1 lim2))
        (def odd (= (& (int- fmid bmid) 1) 1))
        (def matched-back? (fn (_ i1 i2) ((fn (self k) (if (> k %snake-cnt) #t (if (same? (int- i1 k) (int- i2 k)) (self (int+ k 1)) #f))) 1)))
        (def matched-on? (fn (_ i1 i2) ((fn (self k) (if (>= k %snake-cnt) #t (if (same? (int+ i1 k) (int+ i2 k)) (self (int+ k 1)) #f))) 0)))
        (vf! fmid off1)
        (vb! bmid lim1)
        ((fn (round ec fmin0 fmax0 bmin0 bmax0)
           (def fmin (if (> fmin0 dmin) (do (vf! (int- fmin0 2) -1) (int- fmin0 1)) (int+ fmin0 1)))
           (def fmax (if (< fmax0 dmax) (do (vf! (int+ fmax0 2) -1) (int+ fmax0 1)) (int- fmax0 1)))
           (%churned! (int- fmax fmin))
           (def fwd
             ((fn (self d snake)
                (if (< d fmin) snake
                  (let ((i1 (if (>= (vf (int- d 1)) (vf (int+ d 1))) (int+ (vf (int- d 1)) 1) (vf (int+ d 1)))))
                    (let ((e ((fn (self a b) (if (and (< a lim1) (< b lim2) (same? a b)) (self (int+ a 1) (int+ b 1)) a)) i1 (int- i1 d))))
                      (do (vf! d e)
                          (if (and odd (<= bmin0 d) (<= d bmax0) (<= (vb d) e))
                            (list e (int- e d) #t #t)
                            (self (int- d 2) (or snake (> (int- e i1) %snake-cnt)))))))))
              fmax #f))
           (if (pair? fwd) fwd
             (do
               (def bmin (if (> bmin0 dmin) (do (vb! (int- bmin0 2) %line-max) (int- bmin0 1)) (int+ bmin0 1)))
               (def bmax (if (< bmax0 dmax) (do (vb! (int+ bmax0 2) %line-max) (int+ bmax0 1)) (int- bmax0 1)))
               (def bwd
                 ((fn (self d snake)
                    (if (< d bmin) snake
                      (let ((i1 (if (< (vb (int- d 1)) (vb (int+ d 1))) (vb (int- d 1)) (int- (vb (int+ d 1)) 1))))
                        (let ((e ((fn (self a b) (if (and (> a off1) (> b off2) (same? (int- a 1) (int- b 1))) (self (int- a 1) (int- b 1)) a)) i1 (int- i1 d))))
                          (do (vb! d e)
                              (if (and (not odd) (<= fmin d) (<= d fmax) (<= e (vf d)))
                                (list e (int- e d) #t #t)
                                (self (int- d 2) (or snake (> (int- i1 e) %snake-cnt)))))))))
                  bmax fwd))
               (match
                 ((pair? bwd) bwd)
                 (need-min (round (int+ ec 1) fmin fmax bmin bmax))
                 (#t (do
                   ; a good snake far enough along, taken though not shortest
                   (def heur-f
                     (if (and bwd (> ec %heur-min-cost))
                       ((fn (self d best)
                          (if (< d fmin) best
                            (let ((i1 (vf d)))
                              (let ((i2 (int- i1 d)) (dd (if (> d fmid) (int- d fmid) (int- fmid d))))
                                (let ((v (int- (int+ (int- i1 off1) (int- i2 off2)) dd)))
                                  (if (and (> v (int* %k-heur ec)) (or (null? best) (> v (first best)))
                                           (<= (int+ off1 %snake-cnt) i1) (< i1 lim1)
                                           (<= (int+ off2 %snake-cnt) i2) (< i2 lim2)
                                           (matched-back? i1 i2))
                                    (self (int- d 2) (list v i1 i2))
                                    (self (int- d 2) best)))))))
                        fmax ())
                       ()))
                   (def heur-b
                     (if (and bwd (> ec %heur-min-cost) (null? heur-f))
                       ((fn (self d best)
                          (if (< d bmin) best
                            (let ((i1 (vb d)))
                              (let ((i2 (int- i1 d)) (dd (if (> d bmid) (int- d bmid) (int- bmid d))))
                                (let ((v (int- (int+ (int- lim1 i1) (int- lim2 i2)) dd)))
                                  (if (and (> v (int* %k-heur ec)) (or (null? best) (> v (first best)))
                                           (< off1 i1) (<= i1 (int- lim1 %snake-cnt))
                                           (< off2 i2) (<= i2 (int- lim2 %snake-cnt))
                                           (matched-on? i1 i2))
                                    (self (int- d 2) (list v i1 i2))
                                    (self (int- d 2) best)))))))
                        bmax ())
                       ()))
                   (match
                     ((not (null? heur-f)) (list (first (rest heur-f)) (List last heur-f) #t #f))
                     ((not (null? heur-b)) (list (first (rest heur-b)) (List last heur-b) #f #t))
                     ((>= ec mxcost)
                       ; enough: the furthest-reaching path either way
                       (let ((fb ((fn (self d best best1)
                                    (if (< d fmin) (pair best best1)
                                      (let ((i1 (if (< (vf d) lim1) (vf d) lim1)))
                                        (let ((i1 (if (< lim2 (int- i1 d)) (int+ lim2 d) i1)))
                                          (let ((s (int+ i1 (int- i1 d))))
                                            (if (< best s) (self (int- d 2) s i1) (self (int- d 2) best best1)))))))
                                  fmax -1 -1))
                             (bb ((fn (self d best best1)
                                    (if (< d bmin) (pair best best1)
                                      (let ((i1 (if (> off1 (vb d)) off1 (vb d))))
                                        (let ((i1 (if (< (int- i1 d) off2) (int+ off2 d) i1)))
                                          (let ((s (int+ i1 (int- i1 d))))
                                            (if (< s best) (self (int- d 2) s i1) (self (int- d 2) best best1)))))))
                                  bmax %line-max %line-max)))
                         (if (< (int- (int+ lim1 lim2) (first bb)) (int- (first fb) (int+ off1 off2)))
                           (list (rest fb) (int- (first fb) (rest fb)) #t #f)
                           (list (rest bb) (int- (first bb) (rest bb)) #f #t))))
                     (#t (round (int+ ec 1) fmin fmax bmin bmax)))))))))
         1 fmid fmid bmid bmid)))
    (def recs-cmp
      (fn (self off1 lim1 off2 lim2 need-min)
        (def lo ((fn (s a b) (if (and (< a lim1) (< b lim2) (same? a b)) (s (int+ a 1) (int+ b 1)) (pair a b))) off1 off2))
        (def o1 (first lo))
        (def o2 (rest lo))
        (def hi ((fn (s a b) (if (and (< o1 a) (< o2 b) (same? (int- a 1) (int- b 1))) (s (int- a 1) (int- b 1)) (pair a b))) lim1 lim2))
        (def l1 (first hi))
        (def l2 (rest hi))
        (match
          ((= o1 l1) ((fn (s j) (when (< j l2) (do (mark! ch2 (%at r2 j)) (s (int+ j 1))))) o2))
          ((= o2 l2) ((fn (s i) (when (< i l1) (do (mark! ch1 (%at r1 i)) (s (int+ i 1))))) o1))
          (#t
            (let ((spl (split o1 l1 o2 l2 need-min)))
              (do (self o1 (first spl) o2 (first (rest spl)) (first (rest (rest spl))))
                  (self (first spl) l1 (first (rest spl)) l2 (List last spl))))))))
    (recs-cmp 0 nr1 0 nr2 #f)
    ; --- each group slid, one text against the other, then the other way
    (def indents
      (fn (_ ks n)
        (def v (Vector from-list ks))
        (def memo (Vector make n ()))
        (fn (_ i)
          (let ((m (Vector ref i memo)))
            (if (null? m) (let ((k (%indent (Vector ref i v)))) (do (Vector set! i k memo) k)) m)))))
    (%compact ha ch1 n1 hb ch2 n2 (indents ka n1))
    (%compact hb ch2 n2 ha ch1 n1 (indents kb n2))
    (pair ch1 ch2)))

; The edit script between line lists a and b, the lines compared by their
; keys ka and kb: ((OP . LINE) ...), OP keep, del or ins, in order, a
; group's deletions before its insertions.
(def %edit-script
  (fn (_ a b ka kb)
    (def ch (%changed-lines ka kb))
    (def c? (fn (_ c i) (= (%at c (int+ i 1)) 1)))
    ((fn (self a b i j acc)
       (match
         ((and (null? a) (null? b)) (List reverse acc))
         ((and (not (null? a)) (c? (first ch) i)) (self (rest a) b (int+ i 1) j (pair (pair (lit del) (first a)) acc)))
         ((and (not (null? b)) (c? (rest ch) j)) (self a (rest b) i (int+ j 1) (pair (pair (lit ins) (first b)) acc)))
         (#t (self (rest a) (rest b) (int+ i 1) (int+ j 1) (pair (pair (lit keep) (first a)) acc)))))
     a b 0 0 ())))

(def git-edit-script (fn (_ a b) (%edit-script a b a b)))

; The script between two texts' lines, (LINES . NO-NEWLINE?) as %lines
; gives them: a last line without its newline is not the same line as one
; with it, as git compares them.
(def %text-script
  (fn (_ la lb)
    (def keys
      (fn (_ l)
        (if (rest l)
          (List append (List take (int- (List length (first l)) 1) (first l)) (list (Str8 append (List last (first l)) "\n")))
          (first l))))
    (%edit-script (first la) (first lb) (keys la) (keys lb))))

; Insertions and deletions of a script: (INS . DEL).
(def %counts
  (fn (_ script)
    (List fold
      (fn (_ acc op)
        (match
          ((eq? (first op) (lit ins)) (pair (int+ (first acc) 1) (rest acc)))
          ((eq? (first op) (lit del)) (pair (first acc) (int+ (rest acc) 1)))
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
                            (self (rest l) (int+ i 1) (if (eq? (first (first l)) (lit keep)) acc (pair i acc)))))
       ops 0 ()))
    (def clamp (fn (_ v) (if (< v 0) 0 (if (> v (int- n 1)) (int- n 1) v))))
    ((fn (self cs acc)
       (if (null? cs) (List reverse acc)
         (let ((start (first cs)))
           ((fn (extend rest-cs last)
              (if (and (not (null? rest-cs)) (<= (int- (first rest-cs) last) (int+ (int* 2 %context) 1)))
                (extend (rest rest-cs) (first rest-cs))
                (self rest-cs (pair (pair (clamp (int- start %context)) (clamp (int+ last %context))) acc))))
            (rest cs) start))))
     changes ())))

; `@@ -S,C +S,C @@`: a count of one is left off; a count of zero puts the
; line before.
(def %range-text
  (fn (_ start count)
    (match
      ((= count 1) (Str8 str start))
      ((= count 0) (Str8 append (Str8 str (int- start 1)) ",0"))
      (#t (Str8 append (Str8 str start) "," (Str8 str count))))))

(def %no-newline "\\ No newline at end of file\n")

; A hunk's text, from count of the script's ops starting at l, with the
; old and new line numbers the ops before it reach; the markers for a side
; whose last line has no newline go after that line (once, for a line both
; keep, as git prints context from the new side); FUNC, when not "",
; after the range.
(def %hunk-text
  (fn (_ l count old-before new-before old-last new-last func)
    (def walked
      ((fn (self l k oi ni acc)
         (if (= k 0) (list (Str8 join "" (List reverse acc)) oi ni)
           (let ((op (first (first l))) (line (rest (first l))))
             (let ((oi2 (if (eq? op (lit ins)) oi (int+ oi 1)))
                   (ni2 (if (eq? op (lit del)) ni (int+ ni 1))))
               (let ((text (Str8 append (match ((eq? op (lit keep)) " ") ((eq? op (lit del)) "-") (#t "+")) line "\n")))
                 (let ((mark (Str8 append
                               (if (and (eq? op (lit del)) (= oi2 old-last)) %no-newline "")
                               (if (and (not (eq? op (lit del))) (= ni2 new-last)) %no-newline ""))))
                   (self (rest l) (int- k 1) oi2 ni2 (pair (Str8 append text mark) acc))))))))
       l count old-before new-before ()))
    (Str8 append "@@ -" (%range-text (int+ old-before 1) (int- (first (rest walked)) old-before))
      " +" (%range-text (int+ new-before 1) (int- (List last walked) new-before)) " @@"
      (if (= (str-byte-len func) 0) "" (Str8 append " " func)) "\n" (first walked))))

; The line a hunk is headed with: the nearest old line above it that
; starts with a letter, `_` or `$` (git's default, def_ff), cut to 80
; bytes, white space at its end left off.  As git's get_func_line, the
; search goes back from `from` no further than `limit`, the line the hunk
; before searched from; found nothing, the hunk before's line stands, or
; "" for none.
(def %func-line
  (fn (_ olds from limit before)
    ((fn (self i)
       (if (or (< i 0) (<= i limit)) before
         (let ((s (Vector ref i olds)))
           (let ((c (if (= (str-byte-len s) 0) 0 (char->int (str-byte-ref s 0)))))
             (if (or (and (>= c 65) (<= c 90)) (and (>= c 97) (<= c 122)) (= c 95) (= c 36))
               (let ((cut (str-byte-sub s 0 (if (> (str-byte-len s) 80) 80 (str-byte-len s)))))
                 ((fn (trim n) (if (and (> n 0) (%space? (char->int (str-byte-ref cut (int- n 1))))) (trim (int- n 1)) (str-byte-sub cut 0 n)))
                  (str-byte-len cut)))
               (self (int- i 1)))))))
     from)))

; Every hunk of a script between texts a and b, the script walked once:
; up to each hunk's start, counting the old and new lines passed.
(def git-hunks
  (fn (_ a b)
    (def la (%lines a))
    (def lb (%lines b))
    (def ops (%text-script la lb))
    (def olds (Vector from-list (first la)))
    (def old-last (if (rest la) (List length (first la)) -1))
    (def new-last (if (rest lb) (List length (first lb)) -1))
    ((fn (self rs l i oi ni limit func acc)
       (if (null? rs) (Str8 join "" (List reverse acc))
         (let ((r (first rs)))
           (if (< i (first r))
             (let ((op (first (first l))))
               (self rs (rest l) (int+ i 1)
                 (if (eq? op (lit ins)) oi (int+ oi 1)) (if (eq? op (lit del)) ni (int+ ni 1)) limit func acc))
             (let ((f (%func-line olds (int- oi 1) limit func)))
               (do (%churned! (int/ (int- (rest r) (first r)) 10))
                   (self (rest rs) l i oi ni (int- oi 1) f
                     (pair (%hunk-text l (int+ (int- (rest r) (first r)) 1) oi ni old-last new-last f) acc))))))))
     (%hunk-ranges ops) ops 0 0 0 -1 "" ())))

; --- one file ---

; Do n bytes from start of region r look binary to git: a NUL among the
; first 8000.  Read as bytes, for a text's own length stops at a NUL.
(def %nul-in?
  (fn (_ r start n)
    (def lim (if (> n 8000) 8000 n))
    (def p (str->ptr r))
    ((fn (self i) (if (>= i lim) #f (if (= (ptr-ref p (int+ start i) 1) 0) #t (self (int+ i 1))))) 0)))

; A side of a file in a diff: (SHA MODE TEXT BINARY? SIZE), or () for no
; file.
(def %side-text (fn (_ side) (first (rest (rest side)))))
(def %binary? (fn (_ side) (if (null? side) #f (first (rest (rest (rest side)))))))
(def %side-size (fn (_ side) (if (null? side) 0 (List ref 4 side))))

; A rename's similarity as git prints it, a percent rounded down.
(def %percent (fn (_ c) (Str8 str (int/ (int* (List ref 5 c) 100) git-max-score))))
(def %rename? (fn (_ c) (= (List length c) 6)))

; One change's diff as git prints it, c as %changed or %renamed gives it.
; A path that turned from a link to a file or back -- a typechange -- is
; two: the old one deleted, the new one created.
(def %file-diff
  (fn (_ c)
    (def path (first c))
    (def old (first (rest c)))
    (def new (first (rest (rest c))))
    (match
      ((%rename? c) (%file-diff-one path old new (pair (List ref 4 c) (%percent c))))
      ((and (not (null? old)) (not (null? new))
            (not (eq? (str=? (first (rest old)) "120000") (str=? (first (rest new)) "120000"))))
        (Str8 append (%file-diff-one path old () ()) (%file-diff-one path () new ())))
      (#t (%file-diff-one path old new ())))))

; One side's diff: the header, the modes and index line, then the hunks.
; a/PATH and b/PATH are quoted whole when the path needs it, and on the
; ---/+++ lines a tab follows a name with a space in it.  A rename, from
; as (SRC . PERCENT), is from SRC: after its header any change of mode,
; its similarity and both names; then, when its blob changed, the index
; line and the hunks.
(def %file-diff-one
  (fn (_ path old new from)
    (def short (fn (_ sha) (Str8 sub 0 7 sha)))
    (def src (if (null? from) path (first from)))
    (def a-name (git-quote-path (Str8 append "a/" src)))
    (def b-name (git-quote-path (Str8 append "b/" path)))
    (def tab (fn (_ p) (if (null? (Str8 index-of " " p)) "" "\t")))
    (def mode-lines
      (if (or (null? old) (null? new) (str=? (first (rest old)) (first (rest new)))) ""
        (Str8 append "old mode " (first (rest old)) "\nnew mode " (first (rest new)) "\n")))
    (def header
      (Str8 append "diff --git " a-name " " b-name "\n"
        (if (null? from) ""
          (Str8 append mode-lines "similarity index " (rest from) "%\n"
            "rename from " (git-quote-path src) "\nrename to " (git-quote-path path) "\n"))))
    (def modes
      (match
        ((null? old) (Str8 append "new file mode " (first (rest new)) "\n"
                                  "index 0000000.." (short (first new)) "\n"))
        ((null? new) (Str8 append "deleted file mode " (first (rest old)) "\n"
                                  "index " (short (first old)) "..0000000\n"))
        ((str=? (first (rest old)) (first (rest new)))
          (Str8 append "index " (short (first old)) ".." (short (first new)) " " (first (rest old)) "\n"))
        ((not (null? from)) (Str8 append "index " (short (first old)) ".." (short (first new)) "\n"))
        (#t (Str8 append mode-lines "index " (short (first old)) ".." (short (first new)) "\n"))))
    (def a-text (if (null? old) "" (%side-text old)))
    (def b-text (if (null? new) "" (%side-text new)))
    (match
      ; the same blob: the header, with a mode's two lines, is the whole of it
      ((and (not (null? old)) (not (null? new)) (str=? (first old) (first new)))
        (if (null? from) (Str8 append header mode-lines) header))
      ((or (%binary? old) (%binary? new))
      (Str8 append header modes "Binary files " (if (null? old) "/dev/null" a-name)
                   " and " (if (null? new) "/dev/null" b-name) " differ\n"))
      (#t
        (Str8 append header modes
          "--- " (if (null? old) "/dev/null" (Str8 append a-name (tab src))) "\n"
          "+++ " (if (null? new) "/dev/null" (Str8 append b-name (tab path))) "\n"
          (git-hunks a-text b-text))))))

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
    (def kept? (git-modes-kept? gitdir))
    (List flat-map
      (fn (_ e)
        (let ((full (Str8 append wd "/" (first e))))
          (if (not (git-work-exists? full)) ()
            (let ((f (git-work-read full)))
              (list (list (first e) (git-hash "blob" (first f) 0 (rest f))
                          (git-work-mode full (first (rest e)) kept?)))))))
      (git-index-read gitdir))))

; A side's entry for path as (SHA MODE TEXT BINARY? SIZE), its text from
; the blob or the working file; () when the side lacks it.
(def %with-text
  (fn (_ wd gitdir side path work?)
    (def e (List find (fn (_ x) (str=? (first x) path)) side))
    (if (null? e) ()
      (if work?
        (let ((f (git-work-read (Str8 append wd "/" path))))
          (list (first (rest e)) (first (rest (rest e))) (Str8 sub 0 (rest f) (first f))
                (%nul-in? (first f) 0 (rest f)) (rest f)))
        (let ((o (git-object-read gitdir (first (rest e)))))
          (if (null? o) (list (first (rest e)) (first (rest (rest e))) "" #f 0)
            (list (first (rest e)) (first (rest (rest e))) (git-object-text o)
                  (%nul-in? (first (rest (rest o))) (first (rest (rest (rest o)))) (first (rest o)))
                  (first (rest o)))))))))

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

; The changes with renames found as git finds them: a file deleted and
; one added that is the same or alike are one change, (DST OLD NEW NAME
; SRC SCORE), NAME as --stat names it, in the added one's place.  A
; side's bytes are its blob's, or, a working file not yet one, the
; file's.
(def %renamed
  (fn (_ wd gitdir changes work?)
    (def old-of (fn (_ c) (first (rest c))))
    (def new-of (fn (_ c) (first (rest (rest c)))))
    (def gone (List filter (fn (_ c) (and (not (null? (old-of c))) (null? (new-of c)))) changes))
    (def added (List filter (fn (_ c) (and (null? (old-of c)) (not (null? (new-of c))))) changes))
    ; as git/renames takes it: (PATH MODE SHA)
    (def entry (fn (_ path side) (list path (first (rest side)) (first side))))
    (def bytes-of
      (fn (_ e)
        (let ((b (git-blob-bytes gitdir (first (rest (rest e))))))
          (if (or (not (null? b)) (not work?)) b
            (let ((f (git-work-read (Str8 append wd "/" (first e)))))
              (pair (str->ptr (first f)) (rest f)))))))
    (def renames
      (if (or (null? gone) (null? added)) ()
        (git-find-renames-of bytes-of
          (List map (fn (_ c) (entry (first c) (old-of c))) gone)
          (List map (fn (_ c) (entry (first c) (new-of c))) added))))
    (if (null? renames) changes
      (List flat-map
        (fn (_ c)
          (let ((as-src (List find (fn (_ r) (str=? (first (first r)) (first c))) renames))
                (as-dst (List find (fn (_ r) (str=? (first (first (rest r))) (first c))) renames)))
            (match
              ((and (not (null? as-src)) (null? (new-of c))) ())
              ((and (not (null? as-dst)) (null? (old-of c)))
                (let ((src (first (first as-dst))))
                  (list (list (first c) (old-of (List find (fn (_ x) (str=? (first x) src)) gone)) (new-of c)
                              (git-rename-name src (first c)) src (first (rest (rest as-dst)))))))
              (#t (list c)))))
        changes))))

; --- --stat, and commit's summary ---

(def %plural
  (fn (_ n one many) (Str8 append (Str8 str n) " " (if (= n 1) one many))))

; ` N file(s) changed, X insertion(s)(+), Y deletion(s)(-)`
; with neither, both are given as none
(def %summary-line
  (fn (_ nfiles ins del)
    (Str8 append " " (%plural nfiles "file changed" "files changed")
      (if (and (= ins 0) (= del 0)) ", 0 insertions(+), 0 deletions(-)"
        (Str8 append
          (if (> ins 0) (Str8 append ", " (%plural ins "insertion(+)" "insertions(+)")) "")
          (if (> del 0) (Str8 append ", " (%plural del "deletion(-)" "deletions(-)")) "")))
      "\n")))

; Each change's counts: ((LABEL INS DEL) ...), LABEL the path quoted, or a
; rename's name, a fourth element.
(def %change-counts
  (fn (_ changes)
    (List map
      (fn (_ c)
        (let ((old (first (rest c))) (new (first (rest (rest c))))
              (name (if (null? (rest (rest (rest c)))) (git-quote-path (first c)) (List ref 3 c))))
          ; a binary file counts no lines; its sizes go along, (OLD . NEW)
          (if (or (%binary? old) (%binary? new))
            (list name 0 0 (pair (%side-size old) (%side-size new)))
            (let ((la (%lines (if (null? old) "" (%side-text old))))
                  (lb (%lines (if (null? new) "" (%side-text new)))))
              (let ((k (%counts (%text-script la lb))))
                (list name (first k) (rest k)))))))
      changes)))

; The columns --stat fits in, as git's term_columns finds them: COLUMNS
; when it holds a number above zero, else 80.
(def %stat-columns
  (fn (_)
    (def v (Sys getenv "COLUMNS"))
    (def n (if (null? v) 0
             ((fn (self i acc)
                (if (>= i (str-byte-len v)) acc
                  (let ((c (char->int (str-byte-ref v i))))
                    (if (and (>= c 48) (<= c 57)) (self (int+ i 1) (int+ (int* acc 10) (int- c 48))) acc))))
              0 0)))
    (if (> n 0) n 80)))

; At least one column for a count that is not none (scale_linear).
(def %scale
  (fn (_ it width most) (if (= it 0) 0 (int+ 1 (int/ (int* it (int- width 1)) most)))))

; --stat as git's show_stats lays it out: a row a file -- the path padded
; to the widest, the count of changed lines, a bar of + and - -- then the
; summary line.  When the rows would pass the columns, the bar takes what
; is left beside the paths, up to 3/8 of them, scaled to the largest
; change, and a path too long for its share is cut from the front to a
; `/`, shown after `...`.
(def %stat-text
  (fn (_ changes)
    (def counts (%change-counts changes))
    (def total (fn (_ c) (int+ (first (rest c)) (first (rest (rest c))))))
    (def max-len (List fold (fn (_ w c) (if (> (Str8 length (first c)) w) (Str8 length (first c)) w)) 0 counts))
    (def max-change (List fold (fn (_ m c) (if (> (total c) m) (total c) m)) 0 counts))
    (def bin? (fn (_ c) (not (null? (rest (rest (rest c)))))))
    ; as wide as the largest count, or as "Bin" when a file is binary
    (def number-width
      (let ((w (Str8 length (Str8 str max-change))))
        (if (and (< w 3) (List any? bin? counts)) 3 w)))
    (def width (let ((w (%stat-columns))) (if (< w (int+ 22 number-width)) (int+ 22 number-width) w)))
    (def fixed (int+ number-width 6))
    (def fits? (<= (int+ (int+ max-len fixed) max-change) width))
    (def graph0
      (if fits? max-change
        (let ((g (int- (int/ (int* width 3) 8) fixed)))
          (if (> max-change g) (if (< g 6) 6 g) max-change))))
    (def name-width (if (and (not fits?) (> max-len (int- (int- width fixed) graph0))) (int- (int- width fixed) graph0) max-len))
    (def graph-width (if (or fits? (< name-width max-len)) graph0 (int- (int- width fixed) name-width)))
    (def ins (List fold (fn (_ a c) (int+ a (first (rest c)))) 0 counts))
    (def del (List fold (fn (_ a c) (int+ a (first (rest (rest c))))) 0 counts))
    (def name-cell
      (fn (_ name)
        (if (<= (Str8 length name) name-width) (Str8 pad-right name-width #\space name)
          (let ((len (if (< name-width 3) 0 (int- name-width 3))))
            (let ((cut (Str8 sub (int- (Str8 length name) len) len name)))
              (let ((slash (Str8 index-of "/" cut)))
                (let ((shown (if (or (null? slash) (< slash 0)) cut (Str8 sub slash (int- (Str8 length cut) slash) cut))))
                  (Str8 append "..." (Str8 pad-right len #\space shown)))))))))
    (def bar
      (fn (_ add del)
        (if (> graph-width max-change) (pair add del)
          (let ((t (%scale (int+ add del) graph-width max-change)))
            (let ((t2 (if (and (< t 2) (> add 0) (> del 0)) 2 t)))
              (if (< add del)
                (let ((a (%scale add graph-width max-change))) (pair a (int- t2 a)))
                (let ((d (%scale del graph-width max-change))) (pair (int- t2 d) d))))))))
    (Str8 append
      (Str8 join ""
        (List map
          (fn (_ c)
            (let ((b (bar (first (rest c)) (first (rest (rest c))))))
              (if (bin? c)
                (let ((sizes (List ref 3 c)))
                  (Str8 append " " (name-cell (first c)) " | " (Str8 pad-left number-width #\space "Bin")
                    (if (and (= (first sizes) 0) (= (rest sizes) 0)) ""
                      (Str8 append " " (Str8 str (first sizes)) " -> " (Str8 str (rest sizes)) " bytes"))
                    "\n"))
              (Str8 append " " (name-cell (first c)) " | "
                (Str8 pad-left number-width #\space (Str8 str (total c)))
                ; a row with no lines changed has no bar
                (if (= (total c) 0) ""
                  (Str8 append " " (Str8 repeat (first b) "+") (Str8 repeat (rest b) "-")))
                "\n"))))
          counts))
      (%summary-line (List length counts) ins del))))

; commit's lines after its header: the summary, then a line a file
; created, deleted, renamed or changed in mode, in path order, from two
; trees (the first () for a root commit).  A rename's change of mode
; follows it, without a name.
(def git-commit-summary
  (fn (_ gitdir old-tree new-tree)
    (def changes (%renamed "" gitdir (%changed "" gitdir (%tree-side gitdir old-tree) (%tree-side gitdir new-tree) #f) #f))
    (def counts (%change-counts changes))
    (Str8 append
      (%summary-line (List length counts)
        (List fold (fn (_ a c) (int+ a (first (rest c)))) 0 counts)
        (List fold (fn (_ a c) (int+ a (first (rest (rest c))))) 0 counts))
      (Str8 join ""
        (List map
          (fn (_ c)
            (let ((path (first c)) (old (first (rest c))) (new (first (rest (rest c)))))
              (match
                ((null? old) (Str8 append " create mode " (first (rest new)) " " (git-quote-path path) "\n"))
                ((null? new) (Str8 append " delete mode " (first (rest old)) " " (git-quote-path path) "\n"))
                ((%rename? c)
                  (Str8 append " rename " (List ref 3 c) " (" (%percent c) "%)\n"
                    (if (str=? (first (rest old)) (first (rest new))) ""
                      (Str8 append " mode change " (first (rest old)) " => " (first (rest new)) "\n"))))
                ((not (str=? (first (rest old)) (first (rest new))))
                  (Str8 append " mode change " (first (rest old)) " => " (first (rest new)) " " (git-quote-path path) "\n"))
                (#t ""))))
          changes)))))

; What merge prints after "Fast-forward" or a merge commit: the --stat of
; one tree against another, renames found as git finds them -- a file
; deleted and one added that is the same or alike, one row `OLD => NEW` --
; then a line a file created, deleted or renamed, in path order.
(def git-tree-diffstat
  (fn (_ gitdir old-tree new-tree)
    (def old-side (%tree-side gitdir old-tree))
    (def new-side (%tree-side gitdir new-tree))
    (def plain (%changed "" gitdir old-side new-side #f))
    (def as-entry (fn (_ e) (list (first e) (first (rest (rest e))) (first (rest e)))))
    (def renames
      (git-find-renames gitdir
        (List map (fn (_ c) (as-entry (List find (fn (_ e) (str=? (first e) (first c))) old-side)))
          (List filter (fn (_ c) (null? (first (rest (rest c))))) plain))
        (List map (fn (_ c) (as-entry (List find (fn (_ e) (str=? (first e) (first c))) new-side)))
          (List filter (fn (_ c) (null? (first (rest c)))) plain))))
    (def renamed-path?
      (fn (_ p) (List any? (fn (_ r) (or (str=? (first (first r)) p) (str=? (first (first (rest r))) p))) renames)))
    ; each row: (KEY CHANGE SUMMARY), CHANGE as %stat-text takes it
    (def rows
      (List sort (fn (_ a b) (Str8 <? (first a) (first b)))
        (List append
          (List map
            (fn (_ c)
              (list (first c) c
                (match
                  ((null? (first (rest c))) (Str8 append " create mode " (first (rest (first (rest (rest c))))) " " (git-quote-path (first c)) "\n"))
                  ((null? (first (rest (rest c)))) (Str8 append " delete mode " (first (rest (first (rest c)))) " " (git-quote-path (first c)) "\n"))
                  (#t ""))))
            (List filter (fn (_ c) (not (renamed-path? (first c)))) plain))
          (List flat-map
            (fn (_ r)
              (let ((src (first (first r))) (dst (first (first (rest r)))) (score (first (rest (rest r)))))
                (let ((name (git-rename-name src dst))
                      (old (%with-text "" gitdir old-side src #f))
                      (new (%with-text "" gitdir new-side dst #f)))
                  (list (list dst (list dst old new name)
                          (Str8 append " rename " name " (" (Str8 str (int/ (int* score 100) git-max-score)) "%)\n"))))))
            renames))))
    (if (null? rows) ""
      (Str8 append (%stat-text (List map (fn (_ r) (first (rest r))) rows))
        (Str8 join "" (List map (fn (_ r) (first (rest (rest r)))) rows))))))

; One tree's changes against another, renames found.  A tree of () is the
; empty tree, a root commit's parent.
(def %tree-changes
  (fn (_ gitdir old-tree new-tree)
    (%renamed "" gitdir (%changed "" gitdir (%tree-side gitdir old-tree) (%tree-side gitdir new-tree) #f) #f)))

; One tree against another as show prints a commit's change: the patch,
; or with stat? the --stat rows and summary; "" when they are the same.
(def git-tree-patch
  (fn (_ gitdir old-tree new-tree stat?)
    (def changes (%tree-changes gitdir old-tree new-tree))
    (match
      ((null? changes) "")
      (stat? (%stat-text changes))
      (#t (Str8 join "" (List map (fn (_ c) (%file-diff c)) changes))))))

; --- diff ---

(def git-diff-options
  (Opts declare "git diff" "[--cached] [--stat] [--numstat] [--raw] [--name-only | --name-status] [<revision> [<revision>]] [--] [<path>...]" ()
    (list
      (Opts flag "--cached" "--staged" "The index against HEAD, not the working directory against the index")
      (Opts flag "--stat" "A row a file and the summary, not the changes")
      (Opts flag "--numstat" "Lines added and removed a file, as numbers, and its name")
      (Opts flag "--raw" "A line a file: both modes, both blobs, the change's letter, the name")
      (Opts flag "--name-only" "Only the names of the files changed")
      (Opts flag "--name-status" "The names of the files changed, each after its change's letter"))))

; A change's letter: A added, D deleted, T a link become a file or back,
; else M.
(def %change-letter
  (fn (_ old new)
    (match
      ((null? old) "A")
      ((null? new) "D")
      ((not (eq? (str=? (first (rest old)) "120000") (str=? (first (rest new)) "120000"))) "T")
      (#t "M"))))

; A change as --raw and --name-status end it: its letter, a tab, its
; name; a rename's R and its similarity in three digits, then both names.
(def %status-names
  (fn (_ c)
    (if (%rename? c)
      (Str8 append "R" (Str8 pad-left 3 #\0 (%percent c)) "\t" (git-quote-path (List ref 4 c)) "\t" (git-quote-path (first c)))
      (Str8 append (%change-letter (first (rest c)) (first (rest (rest c)))) "\t" (git-quote-path (first c))))))

; The changes in each form asked for: --name-only or --name-status alone,
; else --raw, --numstat and --stat in that order, else the patch.  A
; working-directory side is named by its blob only when it is the
; index's, as git names it, or when renames were looked for, which hash
; each file added; else by zeros.
(def %diff-forms
  (fn (_ gitdir o changes work?)
    (def index (if work? (git-index-read gitdir) ()))
    (def zeros "0000000")
    (def short (fn (_ sha) (Str8 sub 0 7 sha)))
    (def added? (fn (_ c) (or (%rename? c) (null? (first (rest c))))))
    (def looked?
      (or (List any? %rename? changes)
          (and (List any? (fn (_ c) (null? (first (rest c)))) changes)
               (List any? (fn (_ c) (null? (first (rest (rest c))))) changes))))
    (def raw-line
      (fn (_ c)
        (let ((old (first (rest c))) (new (first (rest (rest c)))))
          (let ((e (List find (fn (_ x) (str=? (first x) (first c))) index)))
            (Str8 append ":" (if (null? old) "000000" (first (rest old))) " " (if (null? new) "000000" (first (rest new)))
              " " (if (null? old) zeros (short (first old)))
              " " (match
                    ((null? new) zeros)
                    ((not work?) (short (first new)))
                    ((and looked? (added? c)) (short (first new)))
                    ((and (not (null? e)) (str=? (first (rest (rest e))) (first new)) (str=? (first (rest e)) (first (rest new))))
                      (short (first new)))
                    (#t zeros))
              " " (%status-names c) "\n")))))
    (def numstat-line
      (fn (_ c k)
        (let ((old (first (rest c))) (new (first (rest (rest c)))))
          (if (or (%binary? old) (%binary? new))
            (Str8 append "-\t-\t" (first k) "\n")
            (Str8 append (Str8 str (first (rest k))) "\t" (Str8 str (first (rest (rest k)))) "\t" (first k) "\n")))))
    (def each (fn (_ f) (Str8 join "" (List map f changes))))
    (match
      ((null? changes) "")
      ((Opts on? o "--name-only") (each (fn (_ c) (Str8 append (git-quote-path (first c)) "\n"))))
      ((Opts on? o "--name-status")
        (each (fn (_ c) (Str8 append (%status-names c) "\n"))))
      ((or (Opts on? o "--raw") (Opts on? o "--numstat") (Opts on? o "--stat"))
        (Str8 append
          (if (Opts on? o "--raw") (each raw-line) "")
          (if (Opts on? o "--numstat")
            (Str8 join "" (List map (fn (_ c) (numstat-line c (first (%change-counts (list c))))) changes))
            "")
          (if (Opts on? o "--stat") (%stat-text changes) "")))
      (#t (each (fn (_ c) (%file-diff c)))))))

; git's refusal of an operand it cannot place, its hint lines after.
(def %ambiguous
  (fn (_ head)
    (list (lit err)
      (Str8 join "\n"
        (list (Str8 append "fatal: " head)
              "Use '--' to separate paths from revisions, like this:"
              "'git <command> [<revision>...] -- [<file>...]'"
              ""))
      128)))

; A revision operand as the revisions it names: "A..B" its two ends, an
; end left empty HEAD; () when it names none.
(def %revs-of
  (fn (_ gitdir a)
    (let ((i (Str8 index-of ".." a)))
      (if (or (null? i) (Str8 includes? "..." a))
        (if (null? (git-rev-parse gitdir a)) () (list a))
        (let ((l (Str8 sub 0 i a)) (r (Str8 sub (int+ i 2) (int- (Str8 length a) (int+ i 2)) a)))
          (let ((l (if (str=? l "") "HEAD" l)) (r (if (str=? r "") "HEAD" r)))
            (if (or (null? (git-rev-parse gitdir l)) (null? (git-rev-parse gitdir r))) () (list l r))))))))

; The operands split as git splits them: (#t REVS PATHS), or (#f REFUSAL).
; Before a "--" each must be a revision, after it each is a path.
; Without one, revisions run to the first operand that is none, which
; and every one after must be in the working tree; a revision that is
; also a file there is ambiguous.
(def %diff-operands
  (fn (_ wd gitdir operands dashed)
    (def here? (fn (_ p) (git-work-exists? (Str8 append wd "/" p))))
    (if (not (eq? dashed #f))
      (let ((before (List take (int- (List length operands) (List length dashed)) operands)))
        (let ((bad (List find (fn (_ a) (null? (%revs-of gitdir a))) before)))
          (if (null? bad) (list #t (List flat-map (fn (_ a) (%revs-of gitdir a)) before) dashed)
            (list #f (git-fatal (Str8 append "bad revision '" bad "'"))))))
      (let go ((as operands) (revs ()))
        (match
          ((null? as) (list #t (List reverse revs) ()))
          ((not (null? (%revs-of gitdir (first as))))
            (if (here? (first as))
              (list #f (%ambiguous (Str8 append "ambiguous argument '" (first as) "': both revision and filename")))
              (go (rest as) (List append (List reverse (%revs-of gitdir (first as))) revs))))
          ((not (here? (first as)))
            (list #f (%ambiguous (Str8 append "ambiguous argument '" (first as) "': unknown revision or path not in the working tree."))))
          (#t
            (let ((gone (List find (fn (_ p) (not (here? p))) (rest as))))
              (if (null? gone) (list #t (List reverse revs) as)
                (list #f (list (lit err)
                           (Str8 append "fatal: " gone ": no such path in the working tree.\n"
                                        "Use 'git <command> -- <path>...' to specify paths that do not exist locally.\n")
                           128))))))))))

(def git-diff
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-diff-options ops))
    (def operands (Opts operands o))
    ; what follows a "--", all of it paths; #f when there is none
    (def dashed
      (let seek ((os ops)) (match ((null? os) #f) ((str=? (first os) "--") (rest os)) (#t (seek (rest os))))))
    (def split (if (null? gitdir) () (%diff-operands wd gitdir operands dashed)))
    (match
      ((Opts help? git-diff-options ops) (list (lit out) (Opts usage git-diff-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-diff-options)))
      ((null? gitdir) (git-no-repo))
      ((not (first split)) (first (rest split)))
      ((and (Opts on? o "--name-only") (Opts on? o "--name-status"))
        (git-fatal "options '--name-only', '--name-status', '--check', and '-s' cannot be used together"))
      (#t
        (let ((revs (first (rest split))) (paths (first (rest (rest split)))))
          (let ((bad (List find (fn (_ r) (null? (git-tree-of gitdir r))) revs)))
            (if (not (null? bad)) (git-fatal (Str8 append "bad revision '" bad "'"))
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
                                        (List any? (fn (_ p) (or (str=? p ".") (str=? p (first c)) (Str8 starts? (Str8 append p "/") (first c)))) paths)))
                          (%changed wd gitdir (first sides) (first (rest sides)) (first (rest (rest sides)))))))
                  (let ((changes (%renamed wd gitdir changes (first (rest (rest sides))))))
                    (list (lit out) (%diff-forms gitdir o changes (first (rest (rest sides)))) 0)))))))))))

; One tree against another as --raw draws it, a line a file; "" when
; they are the same.
(def git-tree-raw
  (fn (_ gitdir old-tree new-tree)
    (%diff-forms gitdir (Opts parse git-diff-options (list "--raw")) (%tree-changes gitdir old-tree new-tree) #f)))

(provide git/diff git-diff git-diff-options git-edit-script git-hunks git-commit-summary git-tree-diffstat git-tree-patch git-tree-raw)
