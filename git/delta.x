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

(def %add (prim-ref (lit int) (lit +)))
(def %sub (prim-ref (lit int) (lit -)))
(def %mul (prim-ref (lit int) (lit *)))
(def %lt (prim-ref (lit int) (lit <)))
(def %eq (prim-ref (lit int) (lit =)))
(def %and (prim-ref (lit int) (lit &)))
(def %or (prim-ref (lit int) (lit |)))
(def %shl (prim-ref (lit int) (lit <<)))
(def %shr (prim-ref (lit int) (lit >>)))
(def %oref (prim-ref (lit obj) (lit ref)))
(def %oset! (prim-ref (lit obj) (lit set!)))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset! (prim-ref (lit ptr) (lit set!)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %mem-cmp (prim-ref (lit mem) (lit cmp)))

(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))

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
(def %BTOP ((fn (self k v) (if (%eq k 0) v (self (%sub k 1) (%and (%mul v %B) %M32)))) 15 1))

; h taken on over the four bytes at i of p.  A call costs some fifty
; objects and a door one, so the bytes are spelled out, four a call.
(def %hash4
  (fn (_ h p i)
    (%and (%add (%mul (%and (%add (%mul (%and (%add (%mul (%and (%add (%mul h %B)
                                                                      (%and (%pref p i 1) 255)) %M32) %B)
                                                        (%and (%pref p (%add i 1) 1) 255)) %M32) %B)
                                          (%and (%pref p (%add i 2) 1) 255)) %M32) %B)
                (%and (%pref p (%add i 3) 1) 255))
          %M32)))

(def %hash16
  (fn (_ p i) (%hash4 (%hash4 (%hash4 (%hash4 0 p i) p (%add i 4)) p (%add i 8)) p (%add i 12))))

(def %bucket
  (fn (_ h mask) (%and (%add h (%add (%shr h 13) (%shr h 23))) mask)))

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

(def %word (fn (_ t k) (%and (%pref t (%shl k 2) 4) %M32)))
(def %word! (fn (_ t k v) (%pset! t (%shl k 2) v 4)))

(def %bits-for
  (fn (self n bits) (if (%lt (%shl 1 bits) n) (self n (%add bits 1)) bits)))

(def %index-blocks!
  (fn (self ix p k nblocks prev)
    (if (%eq k nblocks) ix
      (do (def h (%hash16 p (%mul k %BLOCK)))
          (if (%eq h prev) (self ix p (%add k 1) nblocks prev)
            (do (def b (%bucket h (%oref ix %IMASK)))
                (def c (%word (%oref ix %ICOUNT) b))
                (if (%lt c %LIMIT)
                  (do (%word! (%oref ix %IHASH) (%add k 1) h)
                      (%word! (%oref ix %INEXT) (%add k 1) (%word (%oref ix %IHEAD) b))
                      (%word! (%oref ix %IHEAD) b (%add k 1))
                      (%word! (%oref ix %ICOUNT) b (%add c 1)))
                  ())
                (self ix p (%add k 1) nblocks h)))))))

; The index of n bytes at p.
(def delta-index
  (fn (_ p n)
    (def nblocks (%shr n 4))
    (def size (%shl 1 (%bits-for (%shl nblocks 2) 4)))
    (def words (%add (%shl size 1) (%shl (%add nblocks 1) 1)))
    (def r (%make-str (%shl words 2)))
    (def t (%str->ptr r))
    (%mem-set t 0 (%shl words 2))
    (def ix (Vector make 8 0))
    (%oset! ix %IBASE p)
    (%oset! ix %IN n)
    (%oset! ix %IMASK (%sub size 1))
    (%oset! ix %IHEAD t)
    (%oset! ix %ICOUNT (%at t (%shl size 2)))
    (%oset! ix %INEXT (%at t (%shl size 3)))
    (%oset! ix %IHASH (%at t (%add (%shl size 3) (%shl (%add nblocks 1) 2))))
    (%oset! ix %ITABLES r)
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
    (def need (%add (%oref w %WN) n))
    (if (%lt (%oref w %WCAP) need)
      (do (def cap ((fn (grow c) (if (%lt c need) (grow (%mul c 2)) c)) (%mul (%oref w %WCAP) 2)))
          (def r (%make-str cap))
          (%mem-copy (%str->ptr r) (%oref w %WP) (%oref w %WN))
          (%oset! w %WR r)
          (%oset! w %WP (%str->ptr r))
          (%oset! w %WCAP cap))
      ())))

(def %put!
  (fn (_ w c)
    (%room! w 1)
    (%pset! (%oref w %WP) (%oref w %WN) c 1)
    (%oset! w %WN (%add (%oref w %WN) 1))))

(def %put-varint!
  (fn (self w v)
    (if (%lt v 128) (%put! w v)
      (do (%put! w (%or (%and v 127) 128)) (self w (%shr v 7))))))

; Inserts of the n bytes at q, 127 at most an op.
(def %insert!
  (fn (self w q n)
    (if (%eq n 0) ()
      (do (def k (if (%lt 127 n) 127 n))
          (%room! w (%add k 1))
          (%put! w k)
          (%mem-copy (%at (%oref w %WP) (%oref w %WN)) q k)
          (%oset! w %WN (%add (%oref w %WN) k))
          (self w (%at q k) (%sub n k))))))

; The op byte's bits for each nonzero byte of v, from bit, and those
; bytes written after it: the op is written first, so its bits are
; counted on a first pass.
(def %field-bits
  (fn (self v bit k count acc)
    (if (%eq k count) acc
      (self v (%shl bit 1) (%add k 1) count
            (if (%eq (%and (%shr v (%mul k 8)) 255) 0) acc (%or acc bit))))))

(def %field-bytes!
  (fn (self w v k count)
    (if (%eq k count) ()
      (do (def c (%and (%shr v (%mul k 8)) 255))
          (if (%eq c 0) () (%put! w c))
          (self w v (%add k 1) count)))))

; Copies of n bytes of the base from off, 64K at most an op.
(def %copy!
  (fn (self w off n)
    (if (%eq n 0) ()
      (do (def k (if (%lt 65536 n) 65536 n))
          (%put! w (%or 128 (%or (%field-bits off 1 0 4 0) (%field-bits k 16 0 3 0))))
          (%field-bytes! w off 0 4)
          (%field-bytes! w k 0 3)
          (self w (%add off k) (%sub n k))))))

; --- matching ---

; How far the bytes at a and b agree, up to n: whole spans of 64 first.
(def %agree
  (fn (self a b i n)
    (if (if (%lt n (%add i 64)) #f (%eq 0 (%mem-cmp (%at a i) (%at b i) 64)))
      (self a b (%add i 64) n)
      ((fn (bytes i) (if (if (%lt i n) (%eq (%pref a i 1) (%pref b i 1)) #f) (bytes (%add i 1)) i)) i))))

; The longest match among a bucket's blocks of hash h for the target at
; i: the best (OFFSET . LENGTH) so far, or ().
(def %best
  (fn (self ix tp i tn h k best)
    (if (%eq k 0) best
      (if (not (%eq h (%word (%oref ix %IHASH) k))) (self ix tp i tn h (%word (%oref ix %INEXT) k) best)
      (do (def off (%mul (%sub k 1) %BLOCK))
          (def bp (%oref ix %IBASE))
          (def most (if (%lt (%sub (%oref ix %IN) off) (%sub tn i)) (%sub (%oref ix %IN) off) (%sub tn i)))
          (def len (if (%eq 0 (%mem-cmp (%at bp off) (%at tp i) %BLOCK)) (%agree (%at bp off) (%at tp i) %BLOCK most) 0))
          (self ix tp i tn h (%word (%oref ix %INEXT) k)
                (if (if (null? best) (%lt 0 len) (%lt (rest best) len)) (pair off len) best)))))))

; A match grown back over the ins bytes inserted before i:
; (OFFSET LENGTH BACK), BACK the bytes it took back.
(def %grow-back
  (fn (self bp tp off i len ins back)
    (if (if (%lt back ins) (if (%lt 0 off) (%eq (%pref bp (%sub off 1) 1) (%pref tp (%sub i 1) 1)) #f) #f)
      (self bp tp (%sub off 1) (%sub i 1) (%add len 1) ins (%add back 1))
      (list off len back))))

; The walk of the target: i where it is, ins the bytes waiting to be
; inserted before i, h the hash of the block at i, room what the delta
; may still grow by.  #f once it would outgrow that.  A byte no block
; matches is the common step, and one call: the bucket is read and the
; hash rolled on in place.
(def %walk
  (fn (self w ix tp tn i ins h heads mask room)
    (if (%lt room ins) #f
      (if (%lt tn (%add i %BLOCK))
        (if (%lt room (%add ins (%sub tn i))) #f
          (do (%insert! w (%at tp (%sub i ins)) (%add ins (%sub tn i))) #t))
        (if (%eq 0 (%pref heads (%shl (%and (%add h (%add (%shr h 13) (%shr h 23))) mask) 2) 4))
          (self w ix tp tn (%add i 1) (%add ins 1)
                (if (%lt (%add i %BLOCK) tn)
                  (%and (%add (%mul (%and (%sub h (%mul (%and (%pref tp i 1) 255) %BTOP)) %M32) %B)
                              (%and (%pref tp (%add i %BLOCK) 1) 255))
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
      (%walk w ix tp tn (%add i 1) (%add ins 1)
             (if (%lt (%add i %BLOCK) tn)
               (%and (%add (%mul (%and (%sub h (%mul (%and (%pref tp i 1) 255) %BTOP)) %M32) %B)
                           (%and (%pref tp (%add i %BLOCK) 1) 255))
                     %M32)
               h)
             heads mask room)
      (%copy-step w ix tp tn i ins heads mask
                  (%grow-back (%oref ix %IBASE) tp (first hit) i (rest hit) ins 0)))))

; A match m, (OFFSET LENGTH BACK), written: the bytes waiting before it,
; then the copy; the walk goes on after it.
(def %copy-step
  (fn (_ w ix tp tn i ins heads mask m)
    (def back (first (rest (rest m))))
    (%insert! w (%at tp (%sub i ins)) (%sub ins back))
    (%copy! w (first m) (first (rest m)))
    (def next (%add (%sub i back) (first (rest m))))
    (%walk w ix tp tn next 0 (if (%lt tn (%add next %BLOCK)) 0 (%hash16 tp next))
           heads mask (%sub (%oref w %WMAX) (%oref w %WN)))))

; The delta that rebuilds the tn bytes at tp from the base ix indexes:
; (REGION . N), or () when it would be more than most bytes.
(def delta-make
  (fn (_ ix tp tn most)
    (def w (Vector make 5 0))
    (def r (%make-str 256))
    (%oset! w %WR r)
    (%oset! w %WP (%str->ptr r))
    (%oset! w %WCAP 256)
    (%oset! w %WN 0)
    (%oset! w %WMAX most)
    (%put-varint! w (%oref ix %IN))
    (%put-varint! w tn)
    (if (%walk w ix tp tn 0 0 (if (%lt tn %BLOCK) 0 (%hash16 tp 0))
               (%oref ix %IHEAD) (%oref ix %IMASK) (%sub most (%oref w %WN)))
      (if (%lt most (%oref w %WN)) () (pair (%oref w %WR) (%oref w %WN)))
      ())))

(provide git/delta delta-index delta-make)
