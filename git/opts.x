; # x-git -- git on x-lang
;
; ## git/opts.x -- a command's options read as git reads them
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; x-lang's Opts reads the options a command declares; git's own parser
; adds two rules, applied here before Opts reads them:
;
;   - `--no-NAME` takes back `--NAME`, a flag's or a value's, given
;     before it: the last word on the line wins.
;   - a flag given a value, `--NAME=V` or `--no-NAME=V`, is refused:
;     "option `NAME' takes no value".  The parsed line's unknown is then
;     (no-value . NAME), as git-unknown-option prints it.
;
; (git-opts-parse decl ops) and (git-opts-parse-leading decl ops) answer
; what (Opts parse decl ops) and (Opts parse-leading decl ops) do, with
; those rules.  A declaration's own `--no-NAME` is its own option, as
; `commit --no-edit` is, and is left to it.

(module git/opts)

(import x/sys/opts Opts)

(import x/core/doors int+ int-)

; The row of a declaration that spells s, or ().
(def %row
  (fn (_ decl s)
    (List find (fn (_ r) (and (not (eq? (first r) (lit text))) (List any? (fn (_ w) (str=? w s)) (List ref 1 r))))
      (rest (Assoc entry (lit rows) decl)))))

(def %flag? (fn (_ r) (and (not (null? r)) (eq? (first r) (lit flag)))))

; A long word split at its `=`: (NAME . VALUE), VALUE () when none.
(def %split
  (fn (_ w)
    (def i (Str8 index-of "=" w))
    (if (null? i) (pair w ()) (pair (Str8 sub 0 i w) (Str8 sub (int+ i 1) (int- (Str8 length w) (int+ i 1)) w)))))

; The words, each group (the option and the value it takes, or the one
; word) kept together: (GROUPS . REFUSAL), REFUSAL the NAME of the first
; flag given a value, or ().  leading? stops at the first operand.
(def %read
  (fn (_ decl words leading?)
    ((fn (self ws groups refusal)
       (if (null? ws) (pair (List reverse groups) refusal)
         (let ((w (first ws)))
           (match
             ; `--`, and with leading? the first operand, end the options
             ((or (str=? w "--") (and leading? (not (Str8 starts? "-" w))))
               (pair (List reverse (pair ws groups)) refusal))
             ((not (Str8 starts? "--" w))
               (let ((r (%row decl w)))
                 (if (and (not (null? r)) (eq? (first r) (lit value)) (not (null? (rest ws))))
                   (self (rest (rest ws)) (pair (list w (first (rest ws))) groups) refusal)
                   (self (rest ws) (pair (list w) groups) refusal))))
             (#t
               (let ((nv (%split w)))
                 (let ((r (%row decl (first nv)))
                       (base (if (Str8 starts? "--no-" (first nv)) (Str8 append "--" (Str8 sub 5 (int- (Str8 length (first nv)) 5) (first nv))) ()))
                       (named (Str8 sub 2 (int- (Str8 length (first nv)) 2) (first nv))))
                   (match
                     ((and (%flag? r) (not (null? (rest nv))))
                       (self (rest ws) (pair (list w) groups) (or refusal named)))
                     ((not (null? r))
                       (if (and (eq? (first r) (lit value)) (null? (rest nv)) (not (null? (rest ws))))
                         (self (rest (rest ws)) (pair (list w (first (rest ws))) groups) refusal)
                         (self (rest ws) (pair (list w) groups) refusal)))
                     ; --no-NAME of an option declared as --NAME
                     ((and (not (null? base)) (not (null? (%row decl base))))
                       (if (not (null? (rest nv)))
                         (self (rest ws) groups (or refusal named))
                         (let ((spellings (List ref 1 (%row decl base))))
                           (self (rest ws)
                             (List filter
                               (fn (_ g) (not (List any? (fn (_ s) (or (str=? s (first g)) (Str8 starts? (Str8 append s "=") (first g)))) spellings)))
                               groups)
                             refusal))))
                     (#t (self (rest ws) (pair (list w) groups) refusal))))))))))
     words () ())))

; A declaration, as Opts declare makes one, and not the list of flags
; Opts also reads.
(def %declared?
  (fn (_ decl) (and (pair? decl) (pair? (first decl)) (eq? (first (first decl)) (lit name)))))

(def %flatten
  (fn (_ groups) (List reverse (List fold (fn (_ acc g) (List fold (fn (_ a w) (pair w a)) acc g)) () groups))))

(def %parse
  (fn (_ decl ops leading?)
    (if (not (%declared? decl))
      (if leading? (Opts parse-leading decl ops) (Opts parse decl ops))
      (let ((g (%read decl ops leading?)))
        (let ((words (%flatten (first g))))
          (let ((o (if leading? (Opts parse-leading decl words) (Opts parse decl words))))
            (if (null? (rest g)) o
              (List map (fn (_ kv) (if (eq? (first kv) (lit unknown)) (pair (lit unknown) (pair (lit no-value) (rest g))) kv)) o))))))))

(def git-opts-parse (fn (_ decl ops) (%parse decl ops #f)))
(def git-opts-parse-leading (fn (_ decl ops) (%parse decl ops #t)))

(provide git/opts git-opts-parse git-opts-parse-leading)
