; # x-git -- git on x-lang
;
; ## git/delta.x -- deltas between objects
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A delta rebuilds one object from another, its base: the two sizes in
; varints, then ops, each a copy of a span of the base or an insert of
; bytes the delta carries.  The shape is git's diff-delta: the base is
; indexed by the hash of each 16-byte block at a 16-byte step, a run of
; equal blocks kept once and at most 64 blocks a bucket; the target is
; walked with a rolling hash of the 16 bytes from each offset, a bucket's
; blocks are tried, and the longest match, grown back over the inserts
; before it, becomes a copy.  A delta that grows past the size it is
; allowed is given up.
;
; The paths run once a byte are written in primitives alone, as
; x/codec/deflate's are: def in a body, if, do, self-calls, the int doors.

(module git/delta)

(import x/type/vector Vector)

(import x/core/doors int+ int- int* int< int= int& int| int<< int>> obj-ref obj-set! ptr-ref ptr-set! str-make str->ptr ptr->int int->ptr mem-copy mem-cmp)

(def %at (fn (_ p off) (int->ptr (int+ (ptr->int p) off))))

; --- the hash ---
;
; A block's hash is a polynomial in its bytes, 32 bits wide; rolling it
; one byte on takes the oldest byte's term out and the new byte in.  A
; bucket adds the high bits in, since the low bits of a product only
; see the low bits of the bytes.

(def %BLOCK 16)
(def %M32 4294967295)
(def %B 16777619)
; B to the 15th, modulo 2^32: the weight of a block's first byte
(def %BTOP ((fn (self k v) (if (int= k 0) v (self (int- k 1) (int& (int* v %B) %M32)))) 15 1))

; h taken on over the four bytes at i of p.  A call costs some fifty
; objects and a door one, so the bytes are spelled out, four a call.
(def %hash4
  (fn (_ h p i)
    (int& (int+ (int* (int& (int+ (int* (int& (int+ (int* (int& (int+ (int* h %B)
                                                                      (int& (ptr-ref p i 1) 255)) %M32) %B)
                                                        (int& (ptr-ref p (int+ i 1) 1) 255)) %M32) %B)
                                          (int& (ptr-ref p (int+ i 2) 1) 255)) %M32) %B)
                (int& (ptr-ref p (int+ i 3) 1) 255))
          %M32)))

(def %hash16
  (fn (_ p i) (%hash4 (%hash4 (%hash4 (%hash4 0 p i) p (int+ i 4)) p (int+ i 8)) p (int+ i 12))))

(def %bucket
  (fn (_ h mask) (int& (int+ h (int+ (int>> h 13) (int>> h 23))) mask)))

; --- the index of a base ---
;
; Its slots: the base's address and size, the bucket mask, then the
; tables, each a region of 32-bit words, as x/codec/deflate keeps its
; chains: the head of each bucket (a block's number plus one, 0 for
; none), each bucket's count, each block's next in its bucket, each
; block's hash; and the region holding them.  Four buckets a block, so
; most bytes of a target that matches nothing find an empty one; a
; block's hash is compared before its bytes.

(def %IBASE 1)
(def %IN 2)
(def %IMASK 3)
(def %IHEAD 4)
(def %ICOUNT 5)
(def %INEXT 6)
(def %IHASH 7)
(def %ITABLES 8)
(def %LIMIT 64)

(def %mem-set (prim-ref (lit mem) (lit set)))

(def %word (fn (_ t k) (int& (ptr-ref t (int<< k 2) 4) %M32)))
(def %word! (fn (_ t k v) (ptr-set! t (int<< k 2) v 4)))

(def %bits-for
  (fn (self n bits) (if (int< (int<< 1 bits) n) (self n (int+ bits 1)) bits)))

(def %index-blocks!
  (fn (self ix p k nblocks prev)
    (if (int= k nblocks) ix
      (do (def h (%hash16 p (int* k %BLOCK)))
          (if (int= h prev) (self ix p (int+ k 1) nblocks prev)
            (do (def b (%bucket h (obj-ref ix %IMASK)))
                (def c (%word (obj-ref ix %ICOUNT) b))
                (if (int< c %LIMIT)
                  (do (%word! (obj-ref ix %IHASH) (int+ k 1) h)
                      (%word! (obj-ref ix %INEXT) (int+ k 1) (%word (obj-ref ix %IHEAD) b))
                      (%word! (obj-ref ix %IHEAD) b (int+ k 1))
                      (%word! (obj-ref ix %ICOUNT) b (int+ c 1)))
                  ())
                (self ix p (int+ k 1) nblocks h)))))))

; The index of n bytes at p.
(def delta-index
  (fn (_ p n)
    (def nblocks (int>> n 4))
    (def size (int<< 1 (%bits-for (int<< nblocks 2) 4)))
    (def words (int+ (int<< size 1) (int<< (int+ nblocks 1) 1)))
    (def r (str-make (int<< words 2)))
    (def t (str->ptr r))
    (%mem-set t 0 (int<< words 2))
    (def ix (Vector make 8 0))
    (obj-set! ix %IBASE p)
    (obj-set! ix %IN n)
    (obj-set! ix %IMASK (int- size 1))
    (obj-set! ix %IHEAD t)
    (obj-set! ix %ICOUNT (%at t (int<< size 2)))
    (obj-set! ix %INEXT (%at t (int<< size 3)))
    (obj-set! ix %IHASH (%at t (int+ (int<< size 3) (int<< (int+ nblocks 1) 2))))
    (obj-set! ix %ITABLES r)
    (%index-blocks! ix p 0 nblocks -1)))

; --- the delta's bytes ---
;
; A writer's slots: the region, its address, its size, how much is
; written, the most it may hold.

(def %WR 1)
(def %WP 2)
(def %WCAP 3)
(def %WN 4)
(def %WMAX 5)

(def %room!
  (fn (_ w n)
    (def need (int+ (obj-ref w %WN) n))
    (if (int< (obj-ref w %WCAP) need)
      (do (def cap ((fn (grow c) (if (int< c need) (grow (int* c 2)) c)) (int* (obj-ref w %WCAP) 2)))
          (def r (str-make cap))
          (mem-copy (str->ptr r) (obj-ref w %WP) (obj-ref w %WN))
          (obj-set! w %WR r)
          (obj-set! w %WP (str->ptr r))
          (obj-set! w %WCAP cap))
      ())))

(def %put!
  (fn (_ w c)
    (%room! w 1)
    (ptr-set! (obj-ref w %WP) (obj-ref w %WN) c 1)
    (obj-set! w %WN (int+ (obj-ref w %WN) 1))))

(def %put-varint!
  (fn (self w v)
    (if (int< v 128) (%put! w v)
      (do (%put! w (int| (int& v 127) 128)) (self w (int>> v 7))))))

; Inserts of the n bytes at q, 127 at most an op.
(def %insert!
  (fn (self w q n)
    (if (int= n 0) ()
      (do (def k (if (int< 127 n) 127 n))
          (%room! w (int+ k 1))
          (%put! w k)
          (mem-copy (%at (obj-ref w %WP) (obj-ref w %WN)) q k)
          (obj-set! w %WN (int+ (obj-ref w %WN) k))
          (self w (%at q k) (int- n k))))))

; The op byte's bits for each nonzero byte of v, from bit, and those
; bytes written after it: the op is written first, so its bits are
; counted on a first pass.
(def %field-bits
  (fn (self v bit k count acc)
    (if (int= k count) acc
      (self v (int<< bit 1) (int+ k 1) count
            (if (int= (int& (int>> v (int* k 8)) 255) 0) acc (int| acc bit))))))

(def %field-bytes!
  (fn (self w v k count)
    (if (int= k count) ()
      (do (def c (int& (int>> v (int* k 8)) 255))
          (if (int= c 0) () (%put! w c))
          (self w v (int+ k 1) count)))))

; Copies of n bytes of the base from off, 64K at most an op.
(def %copy!
  (fn (self w off n)
    (if (int= n 0) ()
      (do (def k (if (int< 65536 n) 65536 n))
          (%put! w (int| 128 (int| (%field-bits off 1 0 4 0) (%field-bits k 16 0 3 0))))
          (%field-bytes! w off 0 4)
          (%field-bytes! w k 0 3)
          (self w (int+ off k) (int- n k))))))

; --- matching ---

; How far the bytes at a and b agree, up to n: whole spans of 64 first.
(def %agree
  (fn (self a b i n)
    (if (if (int< n (int+ i 64)) #f (int= 0 (mem-cmp (%at a i) (%at b i) 64)))
      (self a b (int+ i 64) n)
      ((fn (bytes i) (if (if (int< i n) (int= (ptr-ref a i 1) (ptr-ref b i 1)) #f) (bytes (int+ i 1)) i)) i))))

; The longest match among a bucket's blocks of hash h for the target at
; i: the best (OFFSET . LENGTH) so far, or ().
(def %best
  (fn (self ix tp i tn h k best)
    (if (int= k 0) best
      (if (not (int= h (%word (obj-ref ix %IHASH) k))) (self ix tp i tn h (%word (obj-ref ix %INEXT) k) best)
      (do (def off (int* (int- k 1) %BLOCK))
          (def bp (obj-ref ix %IBASE))
          (def most (if (int< (int- (obj-ref ix %IN) off) (int- tn i)) (int- (obj-ref ix %IN) off) (int- tn i)))
          (def len (if (int= 0 (mem-cmp (%at bp off) (%at tp i) %BLOCK)) (%agree (%at bp off) (%at tp i) %BLOCK most) 0))
          (self ix tp i tn h (%word (obj-ref ix %INEXT) k)
                (if (if (null? best) (int< 0 len) (int< (rest best) len)) (pair off len) best)))))))

; A match grown back over the ins bytes inserted before i:
; (OFFSET LENGTH BACK), BACK the bytes it took back.
(def %grow-back
  (fn (self bp tp off i len ins back)
    (if (if (int< back ins) (if (int< 0 off) (int= (ptr-ref bp (int- off 1) 1) (ptr-ref tp (int- i 1) 1)) #f) #f)
      (self bp tp (int- off 1) (int- i 1) (int+ len 1) ins (int+ back 1))
      (list off len back))))

; The walk of the target: i where it is, ins the bytes waiting to be
; inserted before i, h the hash of the block at i, room what the delta
; may still grow by.  #f once it would outgrow that.  A byte no block
; matches is the common step, and one call: the bucket is read and the
; hash rolled on in place.
(def %walk
  (fn (self w ix tp tn i ins h heads mask room)
    (if (int< room ins) #f
      (if (int< tn (int+ i %BLOCK))
        (if (int< room (int+ ins (int- tn i))) #f
          (do (%insert! w (%at tp (int- i ins)) (int+ ins (int- tn i))) #t))
        (if (int= 0 (ptr-ref heads (int<< (int& (int+ h (int+ (int>> h 13) (int>> h 23))) mask) 2) 4))
          (self w ix tp tn (int+ i 1) (int+ ins 1)
                (if (int< (int+ i %BLOCK) tn)
                  (int& (int+ (int* (int& (int- h (int* (int& (ptr-ref tp i 1) 255) %BTOP)) %M32) %B)
                              (int& (ptr-ref tp (int+ i %BLOCK) 1) 255))
                        %M32)
                  h)
                heads mask room)
          (%bucket-step w ix tp tn i ins h heads mask room))))))

; The step at i when the bucket has blocks: the longest match becomes a
; copy, grown back over the bytes waiting; none, and i is a byte to
; insert after all.
(def %bucket-step
  (fn (_ w ix tp tn i ins h heads mask room)
    (def hit (%best ix tp i tn h (%word heads (%bucket h mask)) ()))
    (if (null? hit)
      (%walk w ix tp tn (int+ i 1) (int+ ins 1)
             (if (int< (int+ i %BLOCK) tn)
               (int& (int+ (int* (int& (int- h (int* (int& (ptr-ref tp i 1) 255) %BTOP)) %M32) %B)
                           (int& (ptr-ref tp (int+ i %BLOCK) 1) 255))
                     %M32)
               h)
             heads mask room)
      (%copy-step w ix tp tn i ins heads mask
                  (%grow-back (obj-ref ix %IBASE) tp (first hit) i (rest hit) ins 0)))))

; A match m, (OFFSET LENGTH BACK), written: the bytes waiting before it,
; then the copy; the walk goes on after it.
(def %copy-step
  (fn (_ w ix tp tn i ins heads mask m)
    (def back (first (rest (rest m))))
    (%insert! w (%at tp (int- i ins)) (int- ins back))
    (%copy! w (first m) (first (rest m)))
    (def next (int+ (int- i back) (first (rest m))))
    (%walk w ix tp tn next 0 (if (int< tn (int+ next %BLOCK)) 0 (%hash16 tp next))
           heads mask (int- (obj-ref w %WMAX) (obj-ref w %WN)))))

; The delta that rebuilds the tn bytes at tp from the base ix indexes:
; (REGION . N), or () when it would be more than most bytes.
(def delta-make
  (fn (_ ix tp tn most)
    (def w (Vector make 5 0))
    (def r (str-make 256))
    (obj-set! w %WR r)
    (obj-set! w %WP (str->ptr r))
    (obj-set! w %WCAP 256)
    (obj-set! w %WN 0)
    (obj-set! w %WMAX most)
    (%put-varint! w (obj-ref ix %IN))
    (%put-varint! w tn)
    (if (%walk w ix tp tn 0 0 (if (int< tn %BLOCK) 0 (%hash16 tp 0))
               (obj-ref ix %IHEAD) (obj-ref ix %IMASK) (int- most (obj-ref w %WN)))
      (if (int< most (obj-ref w %WN)) () (pair (obj-ref w %WR) (obj-ref w %WN)))
      ())))

(provide git/delta delta-index delta-make)
