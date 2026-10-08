; # x-git -- git on x-lang
;
; ## git/packs.x -- packed objects
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A pack (.git/objects/pack/pack-X.pack) holds objects end to end, each a
; header -- its type and size in a varint -- then a zlib stream of its
; bytes, or of a delta against another object: one earlier in the same
; pack, named by how far back it starts (OFS_DELTA), or anywhere, named by
; its SHA-1 (REF_DELTA).  The .idx beside it says where each object is: a
; fanout of 256 counts, the names sorted, their CRCs, their offsets.
;
; Nothing here reads a file whole.  An idx is read where its tables are
; -- the fanout, the names of one bucket, one offset -- and an object is
; read from its offset in a span that doubles until the stream fits.

(module git/packs)

(import x/sys/file File)
(import x/codec/inflate Inflate)
(import x/codec/hex Hex)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %mul (prim-ref 'int '*))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset! (prim-ref (lit ptr) (lit set!)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %mem-cmp (prim-ref (lit mem) (lit cmp)))

(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))
(def %byte (fn (_ p i) (& (%pref p i 1) 255)))

(def %fail (fn (_ what) (Err raise (lit value) (Str8 append "git: " what) ())))

; n bytes at offset off of the open file fd, as a region; fewer when the
; file ends first, the count in the pair.
(def %pread
  (fn (_ fd off n)
    (File seek fd off (lit set))
    (def r (%make-str n))
    (def got (File read fd r n))
    (pair r (if (< got 0) 0 got))))

; A big-endian 32-bit word at i of p.
(def %u32
  (fn (_ p i)
    (| (<< (%byte p i) 24)
       (| (<< (%byte p (%add i 1)) 16)
          (| (<< (%byte p (%add i 2)) 8) (%byte p (%add i 3)))))))

(def %u64
  (fn (_ p i) (| (<< (%u32 p i) 32) (%u32 p (%add i 4)))))

; The 20 raw bytes of a hex name, as a region.
(def %sha-raw
  (fn (_ hex)
    (def bytes (Hex decode-bytes hex))
    (def r (%make-str 20))
    (def p (%str->ptr r))
    ((fn (self i l) (unless (null? l) (do (%pset! p i (first l) 1) (self (%add i 1) (rest l))))) 0 bytes)
    r))

(def %sha-hex
  (fn (_ p i)
    (Hex encode-bytes
      ((fn (self k acc) (if (< k 0) acc (self (%sub k 1) (pair (%byte p (%add i k)) acc)))) 19 ()))))

; --- the index ---

; The packs of a repository: (IDX-PATH . PACK-PATH) each.
(def git-packs
  (fn (_ gitdir)
    (def dir (Str8 append gitdir "/objects/pack"))
    (if (not (File exists? dir)) ()
      (List map
        (fn (_ f)
          (let ((stem (Str8 sub 0 (%sub (Str8 length f) 4) f)))
            (pair (Str8 append dir "/" f) (Str8 append dir "/" stem ".pack"))))
        (List filter (fn (_ f) (Str8 ends? ".idx" f)) (File list-dir dir))))))

; The idx's object count, and the bucket of names a first byte falls in:
; (COUNT LO HI), names LO up to HI.
(def %idx-bucket
  (fn (_ fd b)
    (def fan (%pread fd 8 1024))
    (def p (%str->ptr (first fan)))
    (list (%u32 p 1020)
          (if (= b 0) 0 (%u32 p (%mul (%sub b 1) 4)))
          (%u32 p (%mul b 4)))))

; Row i's offset into the pack: the 4-byte table, or the 8-byte one it
; points into when its top bit is set.
(def %idx-offset
  (fn (_ fd n i)
    (def o (%u32 (%str->ptr (first (%pread fd (%add (%add 1032 (%mul n 24)) (%mul i 4)) 4))) 0))
    (if (= (& o 2147483648) 0) o
      (%u64 (%str->ptr (first (%pread fd (%add (%add 1032 (%mul n 28)) (%mul (& o 2147483647) 8)) 8))) 0))))

; The rows of a bucket: (REGION LO COUNT), the names from LO on, 20 bytes
; each, in REGION.
(def %idx-rows
  (fn (_ fd lo hi)
    (def rows (%pread fd (%add 1032 (%mul lo 20)) (%mul (%sub hi lo) 20)))
    (list (first rows) lo (%sub hi lo))))

; Where a full name is in a pack: its offset, or () when the idx has no
; such name.
(def %idx-find
  (fn (_ idx sha)
    (def raw (%sha-raw sha))
    (def fd (File open idx (lit rdonly)))
    (when (< fd 0) (%fail (Str8 append "cannot open " idx)))
    (def bucket (%idx-bucket fd (%byte (%str->ptr raw) 0)))
    (def rows (%idx-rows fd (first (rest bucket)) (first (rest (rest bucket)))))
    (def rp (%str->ptr (first rows)))
    (def hit
      ((fn (self k)
         (match
           ((>= k (first (rest (rest rows)))) ())
           ((= 0 (%mem-cmp (%at rp (%mul k 20)) (%str->ptr raw) 20)) (%add (first (rest rows)) k))
           (#t (self (%add k 1)))))
       0))
    (def off (if (null? hit) () (%idx-offset fd (first bucket) hit)))
    (File close fd)
    off))

; The full names in a pack that a hex prefix (two digits or more) begins.
(def %idx-prefix
  (fn (_ idx prefix)
    (def fd (File open idx (lit rdonly)))
    (when (< fd 0) (%fail (Str8 append "cannot open " idx)))
    (def bucket (%idx-bucket fd (first (Hex decode-bytes (Str8 sub 0 2 prefix)))))
    (def rows (%idx-rows fd (first (rest bucket)) (first (rest (rest bucket)))))
    (def rp (%str->ptr (first rows)))
    (def hits
      ((fn (self k acc)
         (if (>= k (first (rest (rest rows)))) acc
           (let ((hex (%sha-hex rp (%mul k 20))))
             (self (%add k 1) (if (Str8 starts? prefix hex) (pair hex acc) acc)))))
       0 ()))
    (File close fd)
    (List reverse hits)))

; Every packed name a hex prefix begins, across the repository's packs.
(def git-pack-prefix
  (fn (_ gitdir prefix)
    (List flat-map (fn (_ pk) (%idx-prefix (first pk) prefix)) (git-packs gitdir))))

; Does a pack of the repository hold the full name?
(def git-pack-has?
  (fn (_ gitdir sha)
    (List any? (fn (_ pk) (not (null? (%idx-find (first pk) sha)))) (git-packs gitdir))))

; --- the pack ---

; A varint of 7-bit groups, least significant first, at i of p:
; (VALUE . NEXT-INDEX).
(def %varint
  (fn (_ p i)
    ((fn (self i v shift)
       (let ((c (%byte p i)))
         (let ((v2 (| v (<< (& c 127) shift))))
           (if (= (& c 128) 0) (pair v2 (%add i 1)) (self (%add i 1) v2 (%add shift 7))))))
     i 0 0)))

; An entry's header at i of p: (TYPE SIZE NEXT-INDEX); the size's low four
; bits ride the first byte with the type.
(def %entry-header
  (fn (_ p i)
    (def c (%byte p i))
    (def type (& (>> c 4) 7))
    ((fn (self i size shift c)
       (if (= (& c 128) 0) (list type size (%add i 1))
         (let ((c2 (%byte p (%add i 1))))
           (self (%add i 1) (| size (<< (& c2 127) shift)) (%add shift 7) c2))))
     i (& c 15) 4 c)))

; OFS_DELTA's distance back, at i of p: (DISTANCE . NEXT-INDEX).  The
; first byte's seven bits start it; each byte that follows adds one to
; what there is, shifts it seven and takes the byte's seven bits.
(def %ofs-distance
  (fn (_ p i)
    (def c0 (%byte p i))
    ((fn (self i v c)
       (if (= (& c 128) 0) (pair v (%add i 1))
         (let ((c2 (%byte p (%add i 1))))
           (self (%add i 1) (| (<< (%add v 1) 7) (& c2 127)) c2))))
     i (& c0 127) c0)))

(def %type-name
  (fn (_ t)
    (match ((= t 1) "commit") ((= t 2) "tree") ((= t 3) "blob") ((= t 4) "tag")
           (#t (%fail (Str8 append "a pack entry of type " (Str8 str t)))))))

; A span of the pack from off, as a region: it doubles from 4096 bytes
; until the entry's stream fits, so an object is read about once.
(def %entry-span
  (fn (self fd off size n)
    (def got (%pread fd off n))
    (if (if (>= n size) #t (= (rest got) n)) got
      (self fd off size (* n 2)))))

; An object this large is worth the compiled inflate engine's build, which
; the codec's own bar, on the compressed input, cannot foresee.
(def %engine-worth 65536)

; The entry at off, decoded: (TYPE-NUMBER BODY N BASE), BASE () for a whole
; object, (ofs . OFFSET) or (ref . SHA) for a delta's base.
(def %entry
  (fn (_ fd off size)
    ((fn (self span)
       (let ((p (%str->ptr (first span))) (avail (rest span)))
         (let ((h (%entry-header p 0)))
           (let ((type (first h)) (at (first (rest (rest h)))))
             (when (>= (first (rest h)) %engine-worth) (Inflate jit!))
             (let ((base (match
                           ((= type 6) (let ((d (%ofs-distance p at))) (pair (lit ofs) (%sub off (first d)))))
                           ((= type 7) (pair (lit ref) (%sha-hex p at)))
                           (#t ())))
                   (start (match
                            ((= type 6) (rest (%ofs-distance p at)))
                            ((= type 7) (%add at 20))
                            (#t at))))
               (let ((z (guard (e (if (Str8 includes? "ends inside" (e msg)) (lit short) (Err raise (Err label e) (e msg) ())))
                          (Inflate zlib (first span) start (%sub avail start)))))
                 (if (eq? z (lit short))
                   (if (>= avail (%sub size off)) (%fail "a pack entry's stream runs past the pack")
                     (self (%entry-span fd off size (* avail 2))))
                   (list type (first z) (first (rest z)) base))))))))
     (%entry-span fd off size 4096))))

; A delta applied to its base: the result region and its count.
(def %apply-delta
  (fn (_ base bn delta dn)
    (def dp (%str->ptr delta))
    (def bp (%str->ptr base))
    (def v1 (%varint dp 0))
    (def v2 (%varint dp (rest v1)))
    (unless (= (first v1) bn) (%fail "a delta's base size disagrees"))
    (def rn (first v2))
    (def out (%make-str (if (= rn 0) 1 rn)))
    (def op (%str->ptr out))
    ; one copy op: the offset from the bytes bits 0-3 of the op name, then
    ; the size from the bytes bits 4-6 name, each byte at the next eight
    ; bits of its field
    (def copy!
      (fn (_ i c at)
        (def read-field
          (fn (self i bit last shift v)
            (if (> bit last) (pair v i)
              (if (= (& c bit) 0) (self i (<< bit 1) last (%add shift 8) v)
                (self (%add i 1) (<< bit 1) last (%add shift 8) (| v (<< (%byte dp i) shift)))))))
        (def o (read-field i 1 8 0 0))
        (def s (read-field (rest o) 16 64 0 0))
        (def size (if (= (first s) 0) 65536 (first s)))
        (when (> (%add (first o) size) bn) (%fail "a delta copies past its base"))
        (when (> (%add at size) rn) (%fail "a delta writes past its result"))
        (%mem-copy (%at op at) (%at bp (first o)) size)
        (pair (rest s) (%add at size))))
    ((fn (self i at)
       (if (>= i dn)
         (do (unless (= at rn) (%fail "a delta's result size disagrees")) (pair out rn))
         (let ((c (%byte dp i)))
           (match
             ((= c 0) (%fail "a delta op of zero"))
             ((= (& c 128) 0)
               (do (when (> (%add at c) rn) (%fail "a delta writes past its result"))
                   (%mem-copy (%at op at) (%at dp (%add i 1)) c)
                   (self (%add (%add i 1) c) (%add at c))))
             (#t (let ((r (copy! (%add i 1) c at))) (self (first r) (rest r))))))))
     (rest v2) 0)))

; The object at off in the pack open on fd: (TYPE BODY N), deltas applied.
; read-base answers (TYPE SIZE REGION START) for a name, for REF_DELTA.
(def %object-at
  (fn (self fd size off read-base)
    (def e (%entry fd off size))
    (def base (first (rest (rest (rest e)))))
    (if (null? base)
      (list (%type-name (first e)) (first (rest e)) (first (rest (rest e))))
      (let ((b (if (eq? (first base) (lit ofs))
                 (self fd size (rest base) read-base)
                 (let ((o (read-base (rest base))))
                   (do (when (null? o) (%fail (Str8 append "a delta's base is missing: " (rest base))))
                       (let ((body (%make-str (if (= (first (rest o)) 0) 1 (first (rest o))))))
                         (do (%mem-copy (%str->ptr body) (%at (%str->ptr (first (rest (rest o)))) (first (rest (rest (rest o))))) (first (rest o)))
                             (list (first o) body (first (rest o))))))))))
        (let ((r (%apply-delta (first (rest b)) (first (rest (rest b))) (first (rest e)) (first (rest (rest e))))))
          (list (first b) (first r) (rest r)))))))

; A packed object by full name: (TYPE SIZE REGION START) as git-object-read
; answers, or () when no pack holds it.
(def git-pack-read
  (fn (_ gitdir sha read-base)
    ((fn (self pks)
       (if (null? pks) ()
         (let ((off (%idx-find (first (first pks)) sha)))
           (if (null? off) (self (rest pks))
             (let ((fd (File open (rest (first pks)) (lit rdonly))))
               (do (when (< fd 0) (%fail (Str8 append "cannot open " (rest (first pks)))))
                   (let ((size (Assoc get (lit size) (File stat (rest (first pks))))))
                     (let ((o (%object-at fd size off read-base)))
                       (do (File close fd)
                           (list (first o) (first (rest (rest o))) (first (rest o)) 0))))))))))
     (git-packs gitdir))))

(provide git/packs git-packs git-pack-read git-pack-prefix git-pack-has?)
