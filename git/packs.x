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
(import x/type/vector Vector)
(import x/codec/inflate Inflate)
(import x/codec/deflate Deflate)
(import x/codec/sha1 Sha1)
(import x/codec/crc32 Crc32)
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

; The entry at off, decoded: (TYPE-NUMBER BODY N BASE END), BASE () for a
; whole object, (ofs . OFFSET) or (ref . SHA) for a delta's base, END the
; offset after the entry's stream, where the next entry starts.
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
                   (list type (first z) (first (rest z)) base
                         (%add off (%add start (first (rest (rest z)))))))))))))
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

; --- writing a pack ---
;
; A pack of whole objects, no deltas, as git accepts one from any
; transport: the header, then each object's type and size in a varint and
; its zlib stream, then the SHA-1 of all that, which names the pack.  Its
; .idx (version 2) beside it: the fanout, the names sorted, each entry's
; CRC-32 and offset, the pack's checksum, the index's own.  The bytes are
; gathered in a buffer that doubles, then written once.

(def %oref (prim-ref (lit obj) (lit ref)))
(def %oset! (prim-ref (lit obj) (lit set!)))
(def %str-byte-len (prim-ref (lit str) (lit byte-len)))

; A buffer's slots: the region, its size, how much is written, its address.
(def %buf-make
  (fn (_)
    (def v (Vector make 4 0))
    (def r (%make-str 4096))
    (%oset! v 1 r)
    (%oset! v 2 4096)
    (%oset! v 3 0)
    (%oset! v 4 (%str->ptr r))
    v))

(def %buf-room!
  (fn (_ b n)
    (def need (%add (%oref b 3) n))
    (if (> need (%oref b 2))
      (do (def cap ((fn (grow c) (if (< c need) (grow (%mul c 2)) c)) (%mul (%oref b 2) 2)))
          (def r (%make-str cap))
          (%mem-copy (%str->ptr r) (%oref b 4) (%oref b 3))
          (%oset! b 1 r)
          (%oset! b 2 cap)
          (%oset! b 4 (%str->ptr r)))
      ())))

(def %buf-put-bytes!
  (fn (_ b p n)
    (%buf-room! b n)
    (%mem-copy (%at (%oref b 4) (%oref b 3)) p n)
    (%oset! b 3 (%add (%oref b 3) n))))

(def %buf-put-byte!
  (fn (_ b c)
    (%buf-room! b 1)
    (%pset! (%oref b 4) (%oref b 3) c 1)
    (%oset! b 3 (%add (%oref b 3) 1))))

(def %buf-put-u32!
  (fn (_ b v)
    (%buf-put-byte! b (& (>> v 24) 255))
    (%buf-put-byte! b (& (>> v 16) 255))
    (%buf-put-byte! b (& (>> v 8) 255))
    (%buf-put-byte! b (& v 255))))

(def %buf-put-str! (fn (_ b s) (%buf-put-bytes! b (%str->ptr s) (%str-byte-len s))))

; An entry's header: the type in bits 4-6 of the first byte with the
; size's low four bits, then the rest of the size seven bits a byte, each
; byte but the last with its high bit set.
(def %put-entry-header!
  (fn (_ b type size)
    (def head (| (<< type 4) (& size 15)))
    (def more (>> size 4))
    (if (= more 0) (%buf-put-byte! b head)
      (do (%buf-put-byte! b (| head 128))
          ((fn (self v)
             (if (< v 128) (%buf-put-byte! b v)
               (do (%buf-put-byte! b (| (& v 127) 128)) (self (>> v 7)))))
           more)))))

(def %type-number
  (fn (_ t)
    (match ((str=? t "commit") 1) ((str=? t "tree") 2) ((str=? t "blob") 3) ((str=? t "tag") 4)
           (#t (%fail (Str8 append "an object of type " t " cannot be packed"))))))

; n bytes of region r written to path, created read-only as git creates
; a pack.
(def %write-region!
  (fn (_ path r n)
    (def fd (File open path (list (lit wronly) (lit creat) (lit trunc)) 292))
    (when (< fd 0) (%fail (Str8 append "cannot write " path)))
    (File write fd r n)
    (File close fd)))

; The objects -- (SHA TYPE SIZE REGION START) each, as git-object-read
; answers them with their names -- as a pack: (BUFFER ROWS SHA), the
; buffer holding the bytes, the rows (SHA OFFSET CRC) for an index, the
; pack's name.
(def %pack-build
  (fn (_ objects)
    (def b (%buf-make))
    (%buf-put-str! b "PACK")
    (%buf-put-u32! b 2)
    (%buf-put-u32! b (List length objects))
    ; each object's row: its name, its offset, the CRC-32 of its entry
    (def rows
      (List map
        (fn (_ o)
          (def off (%oref b 3))
          (def size (first (rest (rest o))))
          (%put-entry-header! b (%type-number (first (rest o))) size)
          (def z (Deflate zlib (first (rest (rest (rest o)))) (first (rest (rest (rest (rest o))))) size))
          (%buf-put-bytes! b (%str->ptr (first z)) (first (rest z)))
          (list (first o) off (Crc32 of (%oref b 1) off (%sub (%oref b 3) off))))
        objects))
    (def pack-sha (Sha1 hex-n (%oref b 1) (%oref b 3)))
    (%buf-put-bytes! b (%str->ptr (%sha-raw pack-sha)) 20)
    (list b rows pack-sha)))

; The objects written as a pack and its index under gitdir's
; objects/pack; answers the pack's path.
(def git-pack-write!
  (fn (_ gitdir objects)
    (def p (%pack-build objects))
    (def b (first p))
    (def dir (Str8 append gitdir "/objects/pack"))
    (unless (File exists? dir) (File mkdir dir))
    (def stem (Str8 append dir "/pack-" (first (rest (rest p)))))
    (%write-region! (Str8 append stem ".pack") (%oref b 1) (%oref b 3))
    (%idx-write! stem (first (rest (rest p))) (first (rest p)))
    (Str8 append stem ".pack")))

; The objects as the bytes of a pack, for the wire: (REGION . N).  No
; objects make the empty pack git asks for when a ref is created on
; what it already has.
(def git-pack-bytes
  (fn (_ objects)
    (def b (first (%pack-build objects)))
    (pair (%oref b 1) (%oref b 3))))

; The index of a pack named pack-sha, written beside it: rows are (SHA
; OFFSET CRC) each.
(def %idx-write!
  (fn (_ stem pack-sha rows)
    ; the index: names in order, with a count of those under each first byte
    (def sorted (List sort (fn (_ x y) (Str8 <? (first x) (first y))) rows))
    (def idx (%buf-make))
    (%buf-put-byte! idx 255)
    (%buf-put-str! idx "tOc")
    (%buf-put-u32! idx 2)
    (def counts (Vector make 256 0))
    (List for-each
      (fn (_ r)
        (def k (%add (first (Hex decode-bytes (Str8 sub 0 2 (first r)))) 1))
        (%oset! counts k (%add (%oref counts k) 1)))
      sorted)
    ((fn (self k acc)
       (if (< k 256)
         (do (def acc2 (%add acc (%oref counts (%add k 1))))
             (%buf-put-u32! idx acc2)
             (self (%add k 1) acc2))
         ()))
     0 0)
    (List for-each (fn (_ r) (%buf-put-bytes! idx (%str->ptr (%sha-raw (first r))) 20)) sorted)
    (List for-each (fn (_ r) (%buf-put-u32! idx (first (rest (rest r))))) sorted)
    (List for-each (fn (_ r) (%buf-put-u32! idx (first (rest r)))) sorted)
    (%buf-put-bytes! idx (%str->ptr (%sha-raw pack-sha)) 20)
    (%buf-put-bytes! idx (%str->ptr (%sha-raw (Sha1 hex-n (%oref idx 1) (%oref idx 3)))) 20)
    (%write-region! (Str8 append stem ".idx") (%oref idx 1) (%oref idx 3))))

; --- indexing a pack that arrived ---
;
; A pack another repository sent holds deltas, and names nothing until it
; has an index.  The bytes are checked against the SHA-1 that ends them,
; which names the pack; then each entry is read in turn, its name the
; SHA-1 of the object it decodes to, its base read back from the pack
; when it is a delta, and the index is written beside the pack.

; An object's name: the SHA-1 of its header and body.
(def %object-sha
  (fn (_ type body n)
    (def hdr (Str8 append type " " (Str8 str n)))
    (def hlen (%str-byte-len hdr))
    (def total (%add (%add hlen 1) n))
    (def r (%make-str total))
    (def p (%str->ptr r))
    (%mem-copy p (%str->ptr hdr) hlen)
    (%pset! p hlen 0 1)
    (when (> n 0) (%mem-copy (%at p (%add hlen 1)) (%str->ptr body) n))
    (Sha1 hex-n r total)))

; The first n bytes of region r, a pack as it came off the wire, written
; under gitdir's objects/pack with its index; answers the pack's path.
; read-base answers (TYPE SIZE REGION START) for an object this
; repository already has, for a delta whose base is not in the pack.
(def git-pack-index!
  (fn (_ gitdir r n read-base)
    (def p (%str->ptr r))
    (when (< n 32) (%fail "a pack too short to be one"))
    (unless (= (%mem-cmp p (%str->ptr "PACK") 4) 0) (%fail "a pack without its signature"))
    (unless (= (%u32 p 4) 2) (%fail "a pack of a version other than 2"))
    (def count (%u32 p 8))
    (def pack-sha (Sha1 hex-n r (%sub n 20)))
    (unless (str=? pack-sha (%sha-hex p (%sub n 20))) (%fail "a pack whose checksum disagrees"))
    (def dir (Str8 append gitdir "/objects/pack"))
    (unless (File exists? dir) (File mkdir dir))
    (def stem (Str8 append dir "/pack-" pack-sha))
    (def path (Str8 append stem ".pack"))
    (if (File exists? (Str8 append stem ".idx")) path
      (do
        (unless (File exists? path) (%write-region! path r n))
        (def fd (File open path (lit rdonly)))
        (when (< fd 0) (%fail (Str8 append "cannot open " path)))
        ; each entry's offset, its base and where it ends: a whole object is
        ; named at once; a delta waits for every whole object's name, since
        ; a REF_DELTA may name a base anywhere in the pack
        (def entries
          ((fn (self i off acc)
             (if (>= i count) (List reverse acc)
               (let ((e (%entry fd off n)))
                 (let ((base (first (rest (rest (rest e))))) (end (first (rest (rest (rest (rest e)))))))
                   (self (%add i 1) end
                         (pair (list off end base
                                     (if (null? base) (%object-sha (%type-name (first e)) (first (rest e)) (first (rest (rest e)))) ()))
                               acc))))))
           0 12 ()))
        (def named (List filter (fn (_ e) (not (null? (first (rest (rest (rest e))))))) entries))
        (def in-pack
          (fn (self sha)
            (def hit (List find (fn (_ e) (str=? (first (rest (rest (rest e)))) sha)) named))
            (if (null? hit) (read-base sha)
              (let ((o (%object-at fd n (first hit) self)))
                (list (first o) (first (rest (rest o))) (first (rest o)) 0)))))
        (def rows
          (List map
            (fn (_ e)
              (def off (first e))
              (def sha
                (if (null? (first (rest (rest e)))) (first (rest (rest (rest e))))
                  (let ((o (%object-at fd n off in-pack)))
                    (%object-sha (first o) (first (rest o)) (first (rest (rest o)))))))
              (list sha off (Crc32 of r off (%sub (first (rest e)) off))))
            entries))
        (File close fd)
        (%idx-write! stem pack-sha rows)
        path))))

; --- a pack arriving on a stream ---
;
; A pack says how many entries it holds, not how long it is: its end is
; found by reading each entry in turn, the header's varint, a delta's
; base, then the zlib stream, whose own end the inflater finds.  The
; first n bytes of r are what has arrived so far; a scan goes as far as
; they allow and says where it stopped, so the next one can go on from
; there when more come.

; i at most n, the offset after a varint whose bytes start at i, or ()
; when the bytes run out first.
(def %varint-end
  (fn (self p i n)
    (match ((>= i n) ()) ((= (& (%byte p i) 128) 0) (%add i 1)) (#t (self p (%add i 1) n)))))

; Where the entry at off ends, or () when its bytes have not all come.
(def %entry-end
  (fn (_ r off n)
    (def p (%str->ptr r))
    (def after-header (%varint-end p off n))
    (if (null? after-header) ()
      (let ((type (& (>> (%byte p off) 4) 7)))
        (let ((start (match
                       ((= type 6) (%varint-end p after-header n))
                       ((= type 7) (if (<= (%add after-header 20) n) (%add after-header 20) ()))
                       (#t after-header))))
          (if (null? start) ()
            (let ((z (guard (e (if (Str8 includes? "ends inside" (e msg)) () (Err raise (Err label e) (e msg) ())))
                       (Inflate zlib r start (%sub n start)))))
              (if (null? z) () (%add start (first (rest (rest z))))))))))))

; The scan of a pack's first n bytes in r from entry i at offset off:
; (I . OFF), the entries read whole and where the next starts.  The pack
; is whole when I is its count and twenty bytes of checksum follow OFF.
(def git-pack-scan
  (fn (self r n count i off)
    (if (>= i count) (pair i off)
      (let ((end (%entry-end r off n)))
        (if (null? end) (pair i off) (self r n count (%add i 1) end))))))

; The count a pack's header gives, from its first twelve bytes.
(def git-pack-count
  (fn (_ r)
    (def p (%str->ptr r))
    (unless (= (%mem-cmp p (%str->ptr "PACK") 4) 0) (%fail "a pack without its signature"))
    (%u32 p 8)))

; --- bytes gathered for the wire ---

; A growable byte buffer for callers that gather a pack as it arrives:
; made empty; bytes put at its end; its region and count read back.
(def git-bytes-make (fn (_) (%buf-make)))
(def git-bytes-put! (fn (_ b p n) (%buf-put-bytes! b p n)))
(def git-bytes-region (fn (_ b) (%oref b 1)))
(def git-bytes-count (fn (_ b) (%oref b 3)))

(provide git/packs git-packs git-pack-read git-pack-prefix git-pack-has? git-pack-write! git-pack-bytes git-pack-index!
  git-pack-scan git-pack-count git-bytes-make git-bytes-put! git-bytes-region git-bytes-count)
