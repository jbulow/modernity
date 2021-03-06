; helper for match-class matcher form

(defn make-class (s)
  (let* ((out (array))
         (i   0)
         (l   (string-length s))
         (k   (- l 2)))

    (while (< i k)
      (let ((c (string-at s i))
            (d (string-at s (+ i 1))))

        (if (= ?- d)
          (let ((e (string-at s (+ i 2))))
            (if (<= c e)
              (if (<= (- e c) 2048)
                (for (d c (+ e 1)) (array-append out d))
                (error "character range too large: "c"-"e))
              (error "malformed character range: "c"-"e))
            (set i (+ i 3)))

          (array-append out c)
          (set i (+ i 1)))))

    (while (< i l)
      (array-append out (string-at s i))
      (set i (+ i 1)))

    (let ((c (array->string (array-sort out))))

      c)))


;; ------------------- Matcher forms

(define-form match-save (exp)	`(let ((pos (<parser-stream>-position self.source))) ,exp))
(define-form match-ok ()	`(set (<parser-stream>-position self.source) pos))
(define-form match-ko ()	`(let () (set (<parser-stream>-position self.source) pos) ()))

(define-form match-rule (name . args)
  (if args
      `(match-save
	 (let ()
	   ,@(map (lambda (arg) (list 'parser-stream-push 'self.source arg)) args)
	   (or (,(concat-symbol '$ name) self)
	       (match-ko))))
    `(,(concat-symbol '$ name) self)))

(define-form match-rule-in (type name . args)
  (let ((tname (concat-symbol '< (concat-symbol type '>)))
	(rname (concat-symbol '$ name)))
    (if args
     `(match-save
        (let ((_p (parser ,tname self.source)))
	  ,@(map (lambda (arg) (list 'parser-stream-push 'self.source arg)) args)
          (let ((_s (,rname _p)))
	    (if _s
		(let () (set self.result (<parser>-result _p)) _s))
	    (match-ko))))
     `(let ((_p (parser ,tname self.source)))
	,@(map (lambda (arg) (list 'parser-stream-push 'self.source arg)) args)
	(let ((_s (,rname _p)))
	  (and _s
	       (let () (set self.result (<parser>-result _p)) _s)))))))

(define-form match-first exprs		`(or ,@exprs))

(defn %match-all (exprs)
  (if (pair? exprs)
      `(and (let ((_s_ ,(car exprs)))
	      ;;(println "MATCH ALL -> "_s_)
	      (and _s_
		   (or (= _s_ *recurred*)
		       ,(%match-all (cdr exprs))))))
    1))

(define-form match-all exprs
  `(match-save
    (or ,(%match-all exprs)
	(match-ko))))

(define-form match-zero-one (exp)
  `(let ((_list_ (group)))
     (and ,exp (group-append _list_ self.result self.source))
     (set self.result (group->list! _list_))
     1))

(define-form match-zero-more (exp)
  `(let ((_list_ (group)))
     (while ,exp (group-append _list_ self.result self.source))
     (set self.result (group->list! _list_))
     1))

(define-form match-one-more (exp)
  `(let ((_list_ (group)))
     (while ,exp (group-append _list_ self.result self.source))
     (and (not (group-empty? _list_))
	  (let ()
	    (set self.result (group->list! _list_))
	    1))))

(define-form peek-for  (exp)	`(match-save (and ,exp (match-ok))))
(define-form peek-expr (exp)	exp)
(define-form peek-not  (exp)	`(not (peek-for ,exp)))



(define-form match-list (exp)
  `(and (pair? (parser-stream-peek self.source))
	(let ((src self.source))
	  (set self.source (parser-stream (list-stream (parser-stream-peek src))))
	  (let ((ok ,exp))
	    (set self.source src)
	    (and ok (parser-stream-next src))))))


(define-form match-class
  (str)
  `(set self.result (parser-stream-match-class self.source ,(make-class str))))

(define-form match-string
  (str)
  `(set self.result (parser-stream-match-string self.source ,str)))

(define-form match-object
  (obj)
  `(and (= ',obj (parser-stream-peek self.source))
        (set self.result (parser-stream-next self.source))))

(define-form match-any
  ()
  '(and (!= *end* (parser-stream-peek self.source))
        (let ()
          (set self.result (parser-stream-next self.source)) 1)))


;; ------------------- Constructor forms

(define-form make-span (exp)
  `(let ((pos (<parser-stream>-position self.source)))
     (and ,exp
          (let ()
            (set self.result (list-from-to pos (<parser-stream>-position self.source)))
             1))))

(define-form make-string
  (exp)
  `(and ,exp (set self.result (list->string self.result))))

(define-form make-symbol
  (exp)
  `(and ,exp (set self.result (string->symbol (list->string self.result)))))

(define-form make-number
  (base exp)
  `(and ,exp (set self.result (string->number-base (list->string self.result) ,base))))


;; ------------------- Result handling forms

(define-form assign-result (name exp)	`(let ((_s ,exp)) (and _s (let () (set ,name self.result) _s))))
(define-form result-expr (exp)		`(let () (set self.result ,exp) 1))



(defn peg-find-variables (tree vars)
  (and (pair? tree)
       (if (= (car tree) 'assign-result)
	   (or (assq (cadr tree) vars)
	       (set vars (peg-find-variables (caddr tree) (cons (cons (cadr tree)) vars))))
	 (and (!= (car tree) 'result-expr)
	      (map (lambda (exp) (set vars (peg-find-variables exp vars))) (cdr tree)))))
  vars)

(defn peg-make-declaration (type rule)
  `(define-selector ,(concat-symbol '$ (car rule))))

(defn peg-make-definition-without-memo (type rule)
  `(define-method ,(concat-symbol '$ (car rule)) ,type ()
     (let ,(peg-find-variables (cadr rule) ())
       ,(expand (cadr rule)))))

(defn peg-make-definition-with-memo (type rule)
  (let* ((name  (string->symbol (car rule)))
	 (qname (list 'quote name)))
    `(define-method ,(concat-symbol '$ name) ,type ()
       (let ,(peg-find-variables (cadr rule) ())
	 (let ((_here_ (<parser-stream>-position self.source))
	       (_memo_ (get (<token>-notes _here_) ,qname)))
	   (if _memo_
	       (let ()
		 (and (<memo>-success _memo_)
		      (let ()
			(set self.result (<memo>-result _memo_))
			(set (<parser-stream>-position self.source) (<memo>-position _memo_))
			(<memo>-success _memo_))))
	     (let ((success  ,(expand (cadr rule)))
		   (_memo_2  (get (<token>-notes _here_) ,qname)))
	       (if _memo_2
		   (memoise _memo_2 success self.result (<parser-stream>-position self.source))
		 (put (<token>-notes _here_) ,qname (new <memo> success self.result (<parser-stream>-position self.source))))
	       success)))))))

(defn peg-make-definition-with-recursion (type rule)
  (let* ((name  (string->symbol (car rule)))
	 (qname (list 'quote name)))
    `(define-method ,(concat-symbol '$ (car rule)) ,type ()
       (let ,(peg-find-variables (cadr rule) ())
	 (let ((_here_ (<parser-stream>-position self.source))
	       (_memo_ (get (<token>-notes _here_) ,(list 'quote name))))
	   (if _memo_
	       (cond
		 ((= *outer* (<memo>-success _memo_))	(set (<memo>-success _memo_) *inner*)
							;;(println ,qname"\tOUTER -> INNER "_here_)
							(if ,(expand (cadr rule))
							    (let ((_pos_ (<parser-stream>-position self.source)))
							      (set (<memo>-success _memo_) *recur*)
							      (set (<memo>-result  _memo_) self.result)
							      ;;(println ,qname"\tINNER -> RECUR "_pos_)
							      (put (<token>-notes _pos_) ,(list 'quote name) _memo_)
							      (while (and ,(expand (cadr rule))
									  (!= _pos_ (<parser-stream>-position self.source)))
								;;(println ,qname"\tRECUR -> RECUR "_pos_)
								(set _pos_ (<parser-stream>-position self.source))
								(set (<memo>-result _memo_) self.result)
								(put (<token>-notes _pos_) ,(list 'quote name) _memo_)
								)
							      ;;(println ,qname"\tRECUR -> DONE "_pos_" "(!= _pos_ _here_)" "(<memo>-result _memo_))
							      (set (<memo>-position _memo_) _pos_)
							      (set (<memo>-success _memo_) *recurred*))))
		 ((= *inner* (<memo>-success _memo_))	;;(println ,qname"\t<- INNER "_here_)
							())
		 ((= *recur* (<memo>-success _memo_))	(set self.result (<memo>-result _memo_))
							;;(println ,qname"\t<- RECUR "_here_)
							102)
		 (else					(and (<memo>-success _memo_)
							     (let ()
							       (set self.result (<memo>-result _memo_))
							       (set (<parser-stream>-position self.source) (<memo>-position _memo_))
							       101))))
	     (set _memo_ (new <memo> *outer*))
	     (put (<token>-notes _here_) ,(list 'quote name) _memo_)
	     ;;(println ,qname  "\tBEGIN  "_here_)
	     (let ((success  ,(expand (cadr rule))))
	       ;;(println ,qname"\tEND    "_here_" "success" "(<memo>-success _memo_)" "(<parser-stream>-position self.source)" "(<memo>-position _memo_))
	       (and success
		    (if (= (<memo>-success  _memo_) *recur*)
			(let ()
			  (set (<memo>-success _memo_) 1)
			  (set self.result (<memo>-result   _memo_))
			  ;;(set (<memo>-position _memo_) (<parser-stream>-position self.source))
			  (set (<parser-stream>-position self.source) (<memo>-position _memo_))
			  *recurred*)
		      103)))))))))

(define peg-make-definition peg-make-definition-without-memo)

(defn peg-compile-grammar (grammar)
  (let ((class (list 'define-class (<grammar>-name grammar) (<grammar>-base grammar) (<grammar>-fields grammar)))
  (decls (with-map peg-make-declaration (<grammar>-name grammar) (<grammar>-rules grammar)))
  (defns (with-map peg-make-definition  (<grammar>-name grammar) (<grammar>-rules grammar))))
    (set (<grammar>-type grammar) (eval class))
    (list-do decl decls (eval decl))
    (list-do defunc defns (eval defunc))
    (cons class (concat-list decls defns))))

(defn peg-compile-rules (name rules)
  (let ((decls (with-map peg-make-declaration name rules))
  (defns (with-map peg-make-definition  name rules)))
    (list-do decl decls (eval decl))
    (list-do defunc defns (eval defunc))
    (concat-list decls defns)))

