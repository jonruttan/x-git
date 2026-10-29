; # x-git -- git on x-lang
;
; ## git/quote.x -- paths quoted as git quotes them
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; core.quotePath on, as git leaves it: a path holding a byte under 32 or
; over 126, `"` or `\` goes in double quotes, C's escapes for those that
; have one -- \a \b \t \n \v \f \r \" \\ -- and three octal digits for
; the rest.  (git-quote-path s) quotes so; (git-quote-path-sp s) a space
; too, as short status does; (git-unquote-path s) undoes it, () when s is
; badly quoted.

(module git/quote)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset! (prim-ref (lit ptr) (lit set!)))
(def %shr (prim-ref (lit int) (lit >>)))
(def %str-byte-len (prim-ref (lit str) (lit byte-len)))
(def %byte (fn (_ p i) (& (%pref p i 1) 255)))

; A list of bytes as a string.
(def %list->string
  (fn (_ l)
    (def s (%make-str (List length l)))
    ((fn (self i l) (unless (null? l) (do (%pset! (%str->ptr s) i (first l) 1) (self (%add i 1) (rest l)))))
     0 l)
    s))

; C's escapes, as (BYTE . LETTER).
(def %escapes
  (list (pair 7 97) (pair 8 98) (pair 9 116) (pair 10 110) (pair 11 118) (pair 12 102) (pair 13 114)
        (pair 34 34) (pair 92 92)))

; s quoted when a byte of it is not plain?, else s.
(def %quote
  (fn (_ s plain?)
    (def n (%str-byte-len s))
    (def p (%str->ptr s))
    (if ((fn (self i) (if (>= i n) #t (if (plain? (%byte p i)) (self (%add i 1)) #f))) 0) s
      (%list->string
        (pair 34
          ((fn (self i)
             (if (>= i n) (list 34)
               (let ((c (%byte p i)))
                 (match
                   ((and (>= c 32) (< c 127) (not (= c 34)) (not (= c 92))) (pair c (self (%add i 1))))
                   ((not (null? (Assoc entry c %escapes)))
                     (pair 92 (pair (rest (Assoc entry c %escapes)) (self (%add i 1)))))
                   (#t (pair 92 (pair (%add 48 (%shr c 6)) (pair (%add 48 (& (%shr c 3) 7))
                         (pair (%add 48 (& c 7)) (self (%add i 1)))))))))))
           0))))))

(def git-quote-path
  (fn (_ s) (%quote s (fn (_ c) (and (>= c 32) (< c 127) (not (= c 34)) (not (= c 92)))))))

(def git-quote-path-sp
  (fn (_ s) (%quote s (fn (_ c) (and (> c 32) (< c 127) (not (= c 34)) (not (= c 92)))))))

; A path git quoted, its quotes taken off and its escapes undone; () when
; it is badly quoted.
(def git-unquote-path
  (fn (_ s)
    (def n (%str-byte-len s))
    (def p (%str->ptr s))
    (def octal? (fn (_ i) (and (< i n) (>= (%byte p i) 48) (<= (%byte p i) 55))))
    (def letter (fn (_ c) (List find (fn (_ e) (= (rest e) c)) %escapes)))
    ((fn (self i acc)
       (match
         ((>= i n) ())
         ((= (%byte p i) 34) (if (= i (%sub n 1)) (%list->string (List reverse acc)) ()))
         ((not (= (%byte p i) 92)) (self (%add i 1) (pair (%byte p i) acc)))
         ((and (octal? (%add i 1)) (<= (%byte p (%add i 1)) 51) (octal? (%add i 2)) (octal? (%add i 3)))
           (self (%add i 4)
             (pair (%add (%add (* 64 (%sub (%byte p (%add i 1)) 48)) (* 8 (%sub (%byte p (%add i 2)) 48)))
                         (%sub (%byte p (%add i 3)) 48))
                   acc)))
         ((and (< (%add i 1) n) (not (null? (letter (%byte p (%add i 1))))))
           (self (%add i 2) (pair (first (letter (%byte p (%add i 1)))) acc)))
         (#t ())))
     1 ())))

(provide git/quote git-quote-path git-quote-path-sp git-unquote-path)
