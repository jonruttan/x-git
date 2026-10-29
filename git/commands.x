; # x-git -- git on x-lang
;
; ## git/commands.x -- cat-file, hash-object and rev-parse; what commands share
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Each command takes the repository (its .git directory, or () outside one)
; and its own arguments, and answers (STREAM TEXT STATUS): what to print,
; on out or err, and the exit status.  TEXT is a string, or (REGION . N)
; for bytes that may hold a NUL.  The words and statuses are git's own.

(module git/commands)

(import x/sys/opts Opts)
(import x/sys/file File)
(import x/sys/posix Sys)
(import git/objects git-hash git-object-write! git-object-read git-tree-pretty git-read-file)
(import git/refs git-rev-parse git-rev-path-missing)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))

(def git-fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))

; git's refusal of an option it does not know: a long one is an "option",
; a short one a "switch", each named without its dashes, then the usage.
(def git-unknown-option
  (fn (_ w usage)
    (def n (Str8 length w))
    (list (lit err)
      (Str8 append
        (if (Str8 starts? "--" w)
          (Str8 append "error: unknown option `" (Str8 sub 2 (- n 2) w))
          (Str8 append "error: unknown switch `" (Str8 sub 1 (- n 1) w)))
        "'\n" usage)
      129)))
(def git-no-repo
  (fn (_) (git-fatal "not a git repository (or any of the parent directories): .git")))

; A path less one trailing slash; "/" stays as it is.
(def git-strip-slash
  (fn (_ s) (if (and (> (Str8 length s) 1) (Str8 ends? "/" s)) (Str8 sub 0 (%sub (Str8 length s) 1) s) s)))

; --- cat-file ---

(def git-cat-file-options
  (Opts declare "git cat-file" "(-t | -s | -p | -e) <object>\n   or: git cat-file <type> <object>" ()
    (list
      (Opts flag "-t" "Show the object's type")
      (Opts flag "-s" "Show the object's size in bytes")
      (Opts flag "-p" "Pretty-print the object's content")
      (Opts flag "-e" "Exit with zero when the object exists, 1 when not"))))

(def %cat-file-usage (fn (_) (Opts usage git-cat-file-options)))

; The one of -t -s -p -e that was given, or ().
(def %cat-file-mode
  (fn (_ o)
    (List find (fn (_ f) (Opts on? o f)) (list "-t" "-s" "-p" "-e"))))

(def git-cat-file
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-cat-file-options ops))
    (def mode (%cat-file-mode o))
    (def operands (Opts operands o))
    (match
      ((Opts help? git-cat-file-options ops) (list (lit out) (%cat-file-usage) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (%cat-file-usage)))
      ((and (null? mode) (null? operands)) (list (lit err) (%cat-file-usage) 129))
      ((and (null? mode) (null? (rest operands)))
        (list (lit err) (Str8 append "fatal: only two arguments allowed in <type> <object> mode, not 1\n\n" (%cat-file-usage)) 129))
      ((null? operands)
        (list (lit err) (Str8 append "fatal: <object> required with '" mode "'\n\n" (%cat-file-usage)) 129))
      ((null? gitdir) (git-no-repo))
      (#t
        (let ((name (if (null? mode) (first (rest operands)) (first operands))))
          (let ((sha (git-rev-parse gitdir name)))
            (match
              ((and (null? sha) (not (null? mode)) (str=? mode "-e") (= (Str8 length name) 40)) (list (lit out) "" 1))
              ((and (null? sha) (not (null? (git-rev-path-missing gitdir name))))
                (let ((i (Str8 index-of ":" name)))
                  (git-fatal (Str8 append "path '" (Str8 sub (+ i 1) (- (Str8 length name) (+ i 1)) name)
                                       "' does not exist in '" (Str8 sub 0 i name) "'"))))
              ((null? sha) (git-fatal (Str8 append "Not a valid object name " name)))
              (#t
                (let ((obj (git-object-read gitdir sha)))
                  (let ((type (first obj)) (size (first (rest obj)))
                        (r (first (rest (rest obj)))) (start (first (rest (rest (rest obj))))))
                    (match
                      ((null? mode)
                        (if (str=? (first operands) type)
                          (list (lit out) (pair (%body r start size) size) 0)
                          (git-fatal (Str8 append "git cat-file " name ": bad file"))))
                      ((str=? mode "-e") (list (lit out) "" 0))
                      ((str=? mode "-t") (list (lit out) (Str8 append type "\n") 0))
                      ((str=? mode "-s") (list (lit out) (Str8 append (Str8 str size) "\n") 0))
                      ((str=? type "tree") (list (lit out) (git-tree-pretty r start size) 0))
                      (#t (list (lit out) (pair (%body r start size) size) 0)))))))))))))

; The body alone, as a region of its own.
(def %body
  (fn (_ r start size)
    (def b (%make-str size))
    (when (> size 0)
      (%mem-copy (%str->ptr b) (%int->ptr (%add (%ptr->int (%str->ptr r)) start)) size))
    b))

; --- hash-object ---

(def git-hash-object-options
  (Opts declare "git hash-object" "[-t <type>] [-w] [--stdin] [--] <file>..." ()
    (list
      (Opts arg "-t" "<type>" "The object's type; default blob")
      (Opts flag "-w" "Write the object into the object database")
      (Opts flag "--stdin" "Read the object from standard input"))))

; All of a descriptor, as (REGION . N).
(def %read-fd
  (fn (_ fd)
    (def chunks
      ((fn (self acc)
         (let ((buf (%make-str 65536)))
           (let ((n (File read fd buf 65536)))
             (if (<= n 0) acc (self (pair (pair buf n) acc))))))
       ()))
    (def total (List fold (fn (_ sum c) (%add sum (rest c))) 0 chunks))
    (def r (%make-str total))
    ((fn (self cs at)
       (unless (null? cs)
         (do (%mem-copy (%int->ptr (%add (%ptr->int (%str->ptr r)) at)) (%str->ptr (first (first cs))) (rest (first cs)))
             (self (rest cs) (%add at (rest (first cs)))))))
     (List reverse chunks) 0)
    (pair r total)))

; Standard input, which under the launcher waits on descriptor 3.
(def %stdin
  (fn (_)
    (when (>= (Sys dup2 3 0) 0) (Sys close 3))
    (%read-fd 0)))

(def git-stdin (fn (_) (%stdin)))

; --- bytes ---

(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset! (prim-ref (lit ptr) (lit set!)))
(def %str-byte-len (prim-ref (lit str) (lit byte-len)))
(def %at (fn (_ p off) (%int->ptr (%add (%ptr->int p) off))))
(def %byte (fn (_ p i) (& (%pref p i 1) 255)))

; The k bytes from byte `start` of region r, as a fresh string.
(def %bytes->string
  (fn (_ r start k)
    (def s (%make-str k))
    (when (> k 0) (%mem-copy (%str->ptr s) (%at (%str->ptr r) start) k))
    s))

; The records of the n bytes of region r, each ended by the byte b -- the
; last perhaps not -- as strings.
(def git-records
  (fn (_ r n b)
    ((fn (self i at acc)
       (match
         ((>= i n) (List reverse (if (> i at) (pair (%bytes->string r at (%sub i at)) acc) acc)))
         ((= (%byte (%str->ptr r) i) b) (self (%add i 1) (%add i 1) (pair (%bytes->string r at (%sub i at)) acc)))
         (#t (self (%add i 1) at acc))))
     0 0 ())))

; Strings each ended by a NUL, as (REGION . N): what -z prints.
(def git-nul-joined
  (fn (_ strs)
    (def total (List fold (fn (_ t s) (%add t (%add (%str-byte-len s) 1))) 0 strs))
    (def r (%make-str total))
    ((fn (self l at)
       (unless (null? l)
         (let ((k (%str-byte-len (first l))))
           (do (when (> k 0) (%mem-copy (%at (%str->ptr r) at) (%str->ptr (first l)) k))
               (%pset! (%str->ptr r) (%add at k) 0 1)
               (self (rest l) (%add at (%add k 1)))))))
     strs 0)
    (pair r total)))

; A path as given, against the working directory when it is relative.
(def %in-wd
  (fn (_ wd path)
    (if (Str8 starts? "/" path) path (Str8 append wd "/" path))))

(def git-hash-object
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-hash-object-options ops))
    (def type (Opts value o "-t" "blob"))
    (def write? (Opts on? o "-w"))
    (def files (Opts operands o))
    (def name-of
      (fn (_ r n)
        (if write? (git-object-write! gitdir type r 0 n) (git-hash type r 0 n))))
    (match
      ((Opts help? git-hash-object-options ops) (list (lit out) (Opts usage git-hash-object-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-hash-object-options)))
      ((and write? (null? gitdir)) (git-no-repo))
      (#t
        (let go ((fs files) (lines (if (Opts on? o "--stdin") (let ((in (%stdin))) (list (Str8 append (name-of (first in) (rest in)) "\n"))) ())))
          (match
            ((null? fs) (list (lit out) (Str8 join "" (List reverse lines)) 0))
            ((not (File exists? (%in-wd wd (first fs))))
              (git-fatal (Str8 append "could not open '" (first fs) "' for reading: No such file or directory")))
            (#t
              (let ((f (git-read-file (%in-wd wd (first fs)))))
                (go (rest fs) (pair (Str8 append (name-of (first f) (rest f)) "\n") lines))))))))))

; --- rev-parse ---

(def git-rev-parse-options
  (Opts declare "git rev-parse" "<revision>..." () ()))

; git's refusal of a revision nothing answers to, hint lines and all, on
; standard error; on standard output the names resolved before it and
; then the argument itself, which git echoes as a path.  The fourth
; element is that standard-output text.
(def %ambiguous
  (fn (_ rev resolved)
    (list (lit err)
      (Str8 join "\n"
        (list (Str8 append "fatal: ambiguous argument '" rev "': unknown revision or path not in the working tree.")
              "Use '--' to separate paths from revisions, like this:"
              "'git <command> [<revision>...] -- [<file>...]'"
              ""))
      128
      (Str8 append resolved rev "\n"))))

(def git-rev-parse-command
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-rev-parse-options ops))
    (match
      ((Opts help? git-rev-parse-options ops) (list (lit out) (Opts usage git-rev-parse-options) 0))
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-rev-parse-options)))
      ((null? gitdir) (git-no-repo))
      (#t
        (let go ((revs (Opts operands o)) (lines ()))
          (if (null? revs) (list (lit out) (Str8 join "" (List reverse lines)) 0)
            (let ((sha (git-rev-parse gitdir (first revs))))
              (if (null? sha) (%ambiguous (first revs) (Str8 join "" (List reverse lines)))
                (go (rest revs) (pair (Str8 append sha "\n") lines))))))))))

(provide git/commands git-cat-file git-cat-file-options git-hash-object git-hash-object-options
  git-rev-parse-command git-rev-parse-options git-fatal git-unknown-option git-no-repo git-strip-slash
  git-stdin git-records git-nul-joined)
