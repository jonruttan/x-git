; # x-git -- git on x-lang
;
; ## git/objects.x -- the object store
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A git object is `TYPE SP SIZE NUL BODY`, named by the SHA-1 of those
; bytes, and kept loose as a zlib stream at .git/objects/AA/BBBB... (the
; name split after two hex digits), or packed (git/packs).  This file reads
; and writes loose objects, reads packed ones through git/packs when no
; loose one answers, finds the repository a directory sits in, resolves an
; object name to a full SHA-1, and lays a tree out as `cat-file -p` prints
; one.  Bodies are byte regions with a count, never strings: a blob holds
; any byte.

(module git/objects)

(import x/sys/file File)
(import x/sys/posix Sys)
(import x/codec/sha1 Sha1)
(import x/codec/inflate Inflate)
(import x/codec/deflate Deflate)
(import x/codec/hex Hex)
(import git/packs git-pack-read git-pack-prefix git-pack-has?)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset! (prim-ref (lit ptr) (lit set!)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %str-byte-len (prim-ref (lit str) (lit byte-len)))

(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))
(def %byte (fn (_ p i) (& (%pref p i 1) 255)))

; The k bytes from byte `start` of region r, as a fresh string.
(def %bytes->string
  (fn (_ r start k)
    (def s (%make-str k))
    (when (> k 0) (%mem-copy (%str->ptr s) (%at (%str->ptr r) start) k))
    s))

; The index of the first byte b at or past i in region r, or () before end.
(def %find-byte
  (fn (self r i end b)
    (match
      ((>= i end) ())
      ((= (%byte (%str->ptr r) i) b) i)
      (#t (self r (%add i 1) end b)))))

; A whole file as (REGION . SIZE): the size from stat, since a region's own
; length stops at a NUL.
(def git-read-file
  (fn (_ path)
    (def size (Assoc get (lit size) (File stat path)))
    (pair (File read-all path) size)))

; Write n bytes of region r to path, created read-only as git creates an
; object; answers n.
(def git-write-file!
  (fn (_ path r n)
    (def fd (File open path (list (lit wronly) (lit creat) (lit trunc)) 292))
    (when (< fd 0) (Err raise (lit io) (Str8 append "git: cannot write " path) ()))
    (def w (File write fd r n))
    (File close fd)
    w))

; --- the repository ---

; The .git directory for a working directory: dir's own, or the nearest
; parent's; () when none.
(def git-dir
  (fn (self dir)
    (def cand (Str8 append dir "/.git"))
    (match
      ((if (File exists? cand) (eq? (File type cand) (lit dir)) #f) cand)
      ((str=? dir "/") ())
      (#t (self (git-parent dir))))))

; The parent of a directory path; "/" is its own.
(def git-parent
  (fn (_ dir)
    (def i (Str8 last-index-of "/" dir))
    (match
      ((null? i) "/")
      ((= i 0) "/")
      (#t (Str8 sub 0 i dir)))))

(def %object-path
  (fn (_ gitdir sha)
    (Str8 append gitdir "/objects/" (Str8 sub 0 2 sha) "/" (Str8 sub 2 38 sha))))

; --- objects ---

; `TYPE SP SIZE NUL` then n bytes of body from byte `start` of src, as
; (REGION . TOTAL): what is hashed, and what is written.
(def %assemble
  (fn (_ type src start n)
    (def hdr (Str8 append type " " (Str8 str n)))
    (def hlen (%str-byte-len hdr))
    (def total (%add (%add hlen 1) n))
    (def r (%make-str total))
    (def p (%str->ptr r))
    (%mem-copy p (%str->ptr hdr) hlen)
    (%pset! p hlen 0 1)
    (when (> n 0) (%mem-copy (%at p (%add hlen 1)) (%at (%str->ptr src) start) n))
    (pair r total)))

; The name of an object of type with n bytes of body from byte `start` of
; src: its SHA-1 in hex.
(def git-hash
  (fn (_ type src start n)
    (def a (%assemble type src start n))
    (Sha1 hex-n (first a) (rest a))))

; The object written loose, unless it is there already; answers its name.
(def git-object-write!
  (fn (_ gitdir type src start n)
    (def a (%assemble type src start n))
    (def sha (Sha1 hex-n (first a) (rest a)))
    (def dir (Str8 append gitdir "/objects/" (Str8 sub 0 2 sha)))
    (def path (%object-path gitdir sha))
    (unless (File exists? path)
      (do (unless (File exists? dir) (File mkdir dir))
          (let ((z (Deflate zlib-stored (first a) 0 (rest a))))
            (git-write-file! path (first z) (first (rest z))))))
    sha))

; The object named by a full SHA-1: (TYPE SIZE REGION START), the body
; SIZE bytes from byte START of REGION; loose first, then the packs; ()
; when neither has it.  A malformed one raises a label 'value.
(def git-object-read
  (fn (self gitdir sha)
    (def path (%object-path gitdir sha))
    (if (not (File exists? path))
      (git-pack-read gitdir sha (fn (_ s) (self gitdir s)))
      (let ((f (git-read-file path)))
        (let ((z (Inflate zlib (first f) 0 (rest f))))
          (let ((out (first z)) (n (first (rest z))))
            (let ((sp (%find-byte out 0 n 32)))
              (let ((nul (if (null? sp) () (%find-byte out sp n 0))))
                (do (when (null? nul)
                      (Err raise (lit value) (Str8 append "git: malformed loose object " sha) ()))
                    (let ((type (%bytes->string out 0 sp))
                          (size (%str->number (%bytes->string out (%add sp 1) (%sub (%sub nul sp) 1)) 10)))
                      (do (unless (= size (%sub n (%add nul 1)))
                            (Err raise (lit value) (Str8 append "git: loose object size disagrees " sha) ()))
                          (list type size out (%add nul 1)))))))))))))

; --- names ---

(def %hex-digit?
  (fn (_ b) (or (and (>= b 48) (<= b 57)) (and (>= b 97) (<= b 102)))))

(def %hex-text?
  (fn (_ s)
    (def p (%str->ptr s))
    (def n (%str-byte-len s))
    ((fn (self i) (if (>= i n) #t (if (%hex-digit? (%byte p i)) (self (%add i 1)) #f))) 0)))

; The loose names a hex prefix begins, in full.
(def %loose-prefix
  (fn (_ gitdir name)
    (def dir (Str8 append gitdir "/objects/" (Str8 sub 0 2 name)))
    (def tail (Str8 sub 2 (%sub (%str-byte-len name) 2) name))
    (if (not (File exists? dir)) ()
      (List map (fn (_ f) (Str8 append (Str8 sub 0 2 name) f))
        (List filter (fn (_ f) (Str8 starts? tail f)) (File list-dir dir))))))

; The list with each name once: an object may be loose and packed both.
(def %unique
  (fn (self names)
    (match
      ((null? names) ())
      ((List any? (fn (_ s) (str=? s (first names))) (rest names)) (self (rest names)))
      (#t (pair (first names) (self (rest names)))))))

; An object name to a full SHA-1: a full name that is there, loose or
; packed, or a hex prefix of four digits or more that exactly one object
; starts with.  () otherwise.  Refs are not read yet.
(def git-resolve
  (fn (_ gitdir name)
    (def n (%str-byte-len name))
    (match
      ((not (%hex-text? name)) ())
      ((= n 40) (if (or (File exists? (%object-path gitdir name)) (git-pack-has? gitdir name)) name ()))
      ((< n 4) ())
      ((> n 40) ())
      (#t
        (let ((hits (%unique (List append (%loose-prefix gitdir name) (git-pack-prefix gitdir name)))))
          (if (= (List length hits) 1) (first hits) ()))))))

; --- trees ---

; What a tree entry's mode names.
(def %mode-type
  (fn (_ mode)
    (match
      ((str=? mode "40000") "tree")
      ((str=? mode "160000") "commit")
      (#t "blob"))))

; The 20 raw bytes at i of region r, in hex.
(def %sha-hex
  (fn (_ r i)
    (def p (%str->ptr r))
    (Hex encode-bytes
      ((fn (self k acc) (if (< k 0) acc (self (%sub k 1) (pair (%byte p (%add i k)) acc)))) 19 ()))))

; A tree body as `cat-file -p` prints it: a line an entry, the mode padded
; to six digits, its type, the entry's name in hex, a tab, the file name.
(def git-tree-pretty
  (fn (_ r start size)
    (def end (%add start size))
    (def lines
      ((fn (self i acc)
         (if (>= i end) acc
           (let ((sp (%find-byte r i end 32)))
             (let ((nul (%find-byte r sp end 0)))
               (let ((mode (%bytes->string r i (%sub sp i)))
                     (name (%bytes->string r (%add sp 1) (%sub (%sub nul sp) 1))))
                 (self (%add nul 21)
                   (pair (Str8 append (Str8 pad-left 6 #\0 mode) " " (%mode-type mode) " "
                                      (%sha-hex r (%add nul 1)) "\t" name "\n")
                         acc)))))))
       start ()))
    (Str8 join "" (List reverse lines))))

(provide git/objects git-dir git-parent git-read-file git-write-file! git-hash
  git-object-write! git-object-read git-resolve git-tree-pretty)
