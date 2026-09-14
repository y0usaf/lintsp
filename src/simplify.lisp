;;;; lintsp — SIMPLIFICATION family (strictix parity).
;;;;
;;;; Rewrites that are local and mechanical, and a finding only when the rewrite
;;;; is provably value-preserving in Common Lisp. The traps that kill a naive
;;;; version, and how each is handled:
;;;;   - test position is not value position: (not (null x)) is T/NIL, x is x, so
;;;;     boolean-coercion-in-test fires and fixes ONLY in a test position;
;;;;   - evaluation count: every rewrite here keeps the same number and order of
;;;;     evaluations (one -> one, or one -> one);
;;;;   - copy vs sharing: nothing here replaces a copying operation with an
;;;;     aliasing one;
;;;;   - multiple values: PROGN and a spliced WHEN/UNLESS body pass values
;;;;     through identically, so the rewrites preserve them;
;;;;   - data vs code: a form inside a QUOTE is data and is never touched;
;;;;   - name capture: funcall-literal-function and eta-reduction refuse a name
;;;;     the analysed set defines as a MACRO (a macro call expands, a funcall
;;;;     calls the macro function - different meanings).
;;;;
;;;; One more, found by testing against SBCL and not fixed because the rewrite is
;;;; simply wrong: (quote (quote x)) - see rule-quote-quote.

(in-package #:lintsp)

;;; --------------------------------------------------------------------- helpers

(defparameter *special-operator-names*
  '("BLOCK" "CATCH" "DECLARE" "EVAL-WHEN" "FLET" "FUNCTION" "GO" "IF" "LABELS"
    "LET" "LET*" "LOAD-TIME-VALUE" "LOCALLY" "MACROLET" "MULTIPLE-VALUE-CALL"
    "MULTIPLE-VALUE-PROG1" "PROGN" "PROG1" "PROG2" "PROGV" "QUOTE" "RETURN-FROM"
    "SETQ" "SYMBOL-MACROLET" "TAGBODY" "THE" "THROW" "UNWIND-PROTECT")
  "Names that are special operators in Common Lisp. Calling one through FUNCALL
or APPLY is not the same as writing the special form, so a rewrite that turns
(funcall #'if ...) into (if ...) must refuse.")

(defun node-symbol-node (n) (and n (eq (node-kind n) :symbol) (node-form n)))

(defun node-nil-node (n)
  "N is the literal NIL. The reader interns symbols in a private package, so NIL
is not the symbol CL:NIL by identity - the name is what is portable."
  (and n (eq (node-kind n) :symbol) (equal (symbol-name (node-form n)) "NIL")))

(defun node-atom-name (n) (and n (eq (node-kind n) :symbol) (symbol-name (node-form n))))

(defun ws-trim-right (src e)
  "E with trailing whitespace removed (the reader consumes one delimiter past a datum)."
  (let ((e (min e (length src))))
    (loop while (and (> e 0)
                     (member (char src (1- e)) '(#\Space #\Tab #\Newline #\Return #\Page)))
          do (decf e))
    e))

(defun node-span (src n)
  "Exact [start,end) source span of node N. For a paren-delimited list the span
ends at its `)`, for anything else (an atom, a 'X or #'X or #( datum) it ends at
the last significant character - a node's own END can sit past the token."
  (let* ((s (skip-trivia src (node-start n) (min (node-end n) (length src))))
         (e (min (node-end n) (length src))))
    (if (and (eq (node-kind n) :list) (< s (length src))
             (or (char= (char src s) #\()
                 (and (char= (char src s) #\#) (< (1+ s) (length src))
                      (char= (char src (1+ s)) #\())))
        (let ((cp (close-paren-pos src e)))
          (if (and (>= cp 0) (char= (char src cp) #\)))
              (values s (1+ cp))
              (values s (ws-trim-right src e))))
        (values s (ws-trim-right src e)))))

(defun node-text (src n)
  (multiple-value-bind (s e) (node-span src n) (subseq src s e)))

(defun children-span-text (src nodes)
  "Source text spanning NODES (a non-empty list of child nodes), from the first
node's start to the last node's end."
  (when nodes
    (let ((s (skip-trivia src (node-start (first nodes))
                          (min (node-end (first nodes)) (length src)))))
      (multiple-value-bind (ls le) (node-span src (car (last nodes)))
        (declare (ignore ls))
        (subseq src s (min le (length src)))))))

(defun one-line-short (s)
  (let ((s (substitute #\Space #\Newline (substitute #\Space #\Return (or s "")))))
    (if (> (length s) 40) (concatenate 'string (subseq s 0 37) "...") s)))

(defun function-designator-name (n)
  "NAME when N is a literal (FUNCTION NAME) form, else NIL."
  (when (and n (eq (node-kind n) :list) (node-is n "FUNCTION")
             (= (length (node-items n)) 2)
             (node-symbol-node (second (node-items n))))
    (symbol-name (node-form (second (node-items n))))))

(defun ctx-macro-names (ctx)
  (and ctx (ctx-macros ctx)))

(defun call-head-macro-p (name macros)
  (and macros name (gethash name macros)))

;;; --------------------------------------------------- a proposal and its emitter
;;; One representation feeds both the rule (which emits it) and `fix` (which
;;; applies its edits), so the finding and the rewrite can never disagree. Each
;;; proposal is (RULE SEVERITY LINE COL MESSAGE EDITS); EDITS is a list of edit
;;; structs, empty for a report-only rule.

(defun emit-proposals (proposals model out)
  (dolist (p proposals)
    (emit (make-diagnostic (first p) (second p) (file-model-path model)
                           (third p) (fourth p) (fifth p))
          out)))

(defun proposal-edits (proposals)
  (loop for p in proposals append (sixth p)))

;;; ===================================================================== rule 1
;;; (progn X) with a single body form is X; (progn (progn A B)) is (progn A B).
;;; PROGN returns the value(s) of its last form and evaluates each form once, so
;;; replacing a one-form PROGN by that form is value- and effect-preserving in
;;; every position, including a top level.

(defun simplify-propose-redundant-progn (model ctx)
  (declare (ignore ctx))
  (let ((src (file-model-src model)) (quoted (fm-quoted-nodes model)) (out nil))
    (dolist (node (fm-list-nodes model))
      (when (and (node-is node "PROGN")
                 (= (length (node-items node)) 2)
                 (not (gethash node quoted)))
        (let ((inner (second (node-items node))))
          (multiple-value-bind (s e) (node-span src node)
            (push (list "redundant-progn" :note (node-line node) (node-col node)
                        (format nil "(progn ~A) has a single body form; it is the form itself"
                                (one-line-short (node-text src inner)))
                        (list (make-edit :path (file-model-path model) :line (node-line node)
                                         :rule "redundant-progn" :start s :end e
                                         :text (node-text src inner))))
                  out)))))
    (nreverse out)))

;;; ===================================================================== rule 2
;;; (when C (progn A B)) is (when C A B): the WHEN/UNLESS body is already an
;;; implicit PROGN, and PROGN passes values through, so splicing its forms into
;;; the body is value- and effect-preserving. Applies to any PROGN that is a
;;; direct body form, not only the last one.

(defun simplify-propose-when-progn (model ctx)
  (declare (ignore ctx))
  (let ((src (file-model-src model)) (quoted (fm-quoted-nodes model)) (out nil))
    (dolist (node (fm-list-nodes model))
      (when (and (member (node-head node) '("WHEN" "UNLESS") :test #'string=)
                 (not (gethash node quoted)))
        (dolist (child (cdr (node-items node)))
          (when (and (node-is child "PROGN") (>= (length (node-items child)) 2))
            (let ((forms (cdr (node-items child))))
              (multiple-value-bind (s e) (node-span src child)
                (push (list "when-progn" :note (node-line child) (node-col child)
                            (format nil "the PROGN body of ~A can be spliced into the ~A itself"
                                    (node-head node) (node-head node))
                            (list (make-edit :path (file-model-path model)
                                             :line (node-line child) :rule "when-progn"
                                             :start s :end e
                                             :text (children-span-text src forms))))
                      out)))))))
    (nreverse out)))

;;; ===================================================================== rule 3
;;; In a TEST position (the test of IF, WHEN or UNLESS) only the truthiness of
;;; the test matters. (not (null x)) is true exactly when x is non-NIL, so
;;; (if (not (null x)) a b) is (if x a b); (null x) is true exactly when x is
;;; NIL, so (if (null x) a b) is (if x b a). NOT fixed in a value position,
;;; where (not (null x)) returns T or NIL and x returns x - a different value.
;;; The (null x) branch-swap is done only for the 3-argument IF, where both
;;; branches exist.

(defun quoted-keyword-node-p (n)
  "N is a literal (QUOTE X) whose X is a keyword."
  (and n (eq (node-kind n) :list) (node-is n "QUOTE")
       (= (length (node-items n)) 2)
       (let ((d (second (node-items n))))
         (and (eq (node-kind d) :symbol) (keywordp (node-form d))))))

(defun simplify-propose-boolean-coercion (model ctx)
  (declare (ignore ctx))
  (let ((src (file-model-src model)) (quoted (fm-quoted-nodes model)) (out nil))
    (labels ((push1 (line col msg edits)
               (push (list "boolean-coercion-in-test" :note line col msg edits) out)))
      (dolist (node (fm-list-nodes model))
        (when (and (member (node-head node) '("IF" "WHEN" "UNLESS") :test #'string=)
                   (not (gethash node quoted)))
          (let* ((h (node-head node))
                 (items (node-items node))
                 (test (second items)))
            (when (and test (node-is test "NOT") (= (length (node-items test)) 2))
              (let ((arg (second (node-items test))))
                (when (and arg (node-is arg "NULL") (= (length (node-items arg)) 2))
                  (let ((x (second (node-items arg))))
                    (multiple-value-bind (s e) (node-span src test)
                      (push1 (node-line test) (node-col test)
                             (format nil "(~A (not (null ~A)) a b) tests the same as (~A ~A a b)"
                                     h (node-text src x) h (node-text src x))
                             (list (make-edit :path (file-model-path model)
                                              :line (node-line test)
                                              :rule "boolean-coercion-in-test"
                                              :start s :end e :text (node-text src x)))))))))
            (when (and (string= h "IF") (= (length items) 4)
                       (node-is test "NULL") (= (length (node-items test)) 2))
              (let ((x (second (node-items test))) (a (third items)) (b (fourth items)))
                (multiple-value-bind (ts te) (node-span src test)
                  (multiple-value-bind (as ae) (node-span src a)
                    (multiple-value-bind (bs be) (node-span src b)
                      (push1 (node-line test) (node-col test)
                             (format nil "(if (null ~A) a b) is the same as (if ~A b a)"
                                     (node-text src x) (node-text src x))
                             (list (make-edit :path (file-model-path model)
                                              :line (node-line test)
                                              :rule "boolean-coercion-in-test"
                                              :start ts :end te :text (node-text src x))
                                   (make-edit :path (file-model-path model)
                                              :line (node-line a)
                                              :rule "boolean-coercion-in-test"
                                              :start as :end ae :text (node-text src b))
                                   (make-edit :path (file-model-path model)
                                              :line (node-line b)
                                              :rule "boolean-coercion-in-test"
                                              :start bs :end be :text (node-text src a))))))))))))
      (nreverse out))))

;;; ===================================================================== rule 4
;;; (funcall #'f a b) is (f a b); (apply #'f (list a b)) is (f a b). The
;;; arguments are evaluated once, in order, in both spellings. A macro name is
;;; refused: (m a b) would expand the macro, while (funcall #'m a b) calls the
;;; macro function directly - different meanings. A non-literal designator
;;; (funcall g ...) or a non-LIST arg list is refused: the reader cannot prove it.

(defun special-or-macro-p (name macros)
  (and name
       (or (call-head-macro-p name macros)
           (member name *special-operator-names* :test #'string=))))

(defun simplify-propose-funcall (model ctx)
  (let ((src (file-model-src model)) (quoted (fm-quoted-nodes model))
        (macros (ctx-macro-names ctx)) (out nil))
    (dolist (node (fm-list-nodes model))
      (when (and (member (node-head node) '("FUNCALL" "APPLY") :test #'string=)
                 (not (gethash node quoted))
                 (>= (length (node-items node)) 2))
        (let* ((items (node-items node))
               (fd (second items))
               (name (function-designator-name fd)))
          (when (and name (not (special-or-macro-p name macros)))
            (cond
              ;; (funcall #'f a b ...) -> (f a b ...): splice only the head.
              ((string= (node-head node) "FUNCALL")
               (multiple-value-bind (fs e) (node-span src fd)
                 (declare (ignore fs))
                 (push (list "funcall-literal-function" :note (node-line node) (node-col node)
                             (format nil "(funcall #'~A ...) calls ~A directly" name name)
                             (list (make-edit :path (file-model-path model)
                                              :line (node-line node)
                                              :rule "funcall-literal-function"
                                              :start (skip-trivia src (node-start node) (min (node-end node) (length src)))
                                              :end e
                                              :text (concatenate 'string "("
                                                                 (node-text src (second (node-items fd)))))))
                       out)))
              ;; (apply #'f (list a b)) -> (f a b): only a literal LIST arg list.
              ((and (= (length items) 3) (node-is (third items) "LIST"))
               (let* ((lst (third items))
                      (args (cdr (node-items lst)))
                      (interior (if args
                                    (multiple-value-bind (as ae) (node-span src (first args))
                                      (declare (ignore as))
                                      (multiple-value-bind (ls le) (node-span src (car (last args)))
                                        (declare (ignore ls))
                                        (subseq src (skip-trivia src (node-start (first args))
                                                                 (min ae (length src)))
                                                (min le (length src)))))
                                    "")))
                 (multiple-value-bind (s e) (node-span src node)
                   (push (list "funcall-literal-function" :note (node-line node) (node-col node)
                               (format nil "(apply #'~A (list ...)) calls ~A directly" name name)
                               (list (make-edit :path (file-model-path model)
                                                :line (node-line node)
                                                :rule "funcall-literal-function"
                                                :start s :end e
                                                :text (if (string= interior "")
                                                          (concatenate 'string "(" (node-text src (second (node-items fd))) ")")
                                                          (concatenate 'string "(" (node-text src (second (node-items fd))) " "
                                                                       interior ")")))))
                         out)))))))))
    (nreverse out)))

;;; ===================================================================== rule 5
;;; (quote (quote x)) - NOT fixed. SBCL, quoted here, settles it:
;;;   (eval ''xx) => 'XX   (a two-element list)
;;;   (eval 'xx)  => BOUND-VALUE
;;;   (equal ...) => NIL
;;; The inner QUOTE is data; dropping it changes the value from the list
;;; (QUOTE X) to X. So the rule only reports the doubly-quoted form as a note,
;;; and never rewrites it.

(defun simplify-propose-quote-quote (model ctx)
  (declare (ignore ctx))
  (let ((out nil))
    (dolist (node (fm-list-nodes model))
      (when (and (node-is node "QUOTE") (= (length (node-items node)) 2))
        (let ((datum (second (node-items node))))
          (when (and datum (eq (node-kind datum) :list) (node-is datum "QUOTE")
                     (= (length (node-items datum)) 2))
            (let ((txt (node-text (file-model-src model) (second (node-items datum)))))
              (push (list "quote-quote" :note (node-line node) (node-col node)
                          (format nil "doubly-quoted form: its value is the list (QUOTE ~A), not ~A; \
drop one quote only if that is what you meant (not auto-fixed: the rewrite is not value-preserving)"
                                  txt txt)
                          nil)
                    out))))))
    (nreverse out)))

;;; ===================================================================== rule 6
;;; (lambda (a b) (f a b)) is #'f, when the parameters are passed positionally,
;;; unchanged and in order, each used exactly once, the body is exactly one call,
;;; the lambda list has no &-keywords, and f is neither a parameter nor a macro
;;; or special operator. Fixed, because the rewrite keeps the same call with the
;;; same arguments - but ONLY when f is already defined where the reference is
;;; FORCED. #'f resolves the function at load time; (lambda ...) resolves it when
;;; the closure is called. So a rewrite whose target is defined later turns a
;;; deferred lookup into a load-time undefined-function error (the autolith
;;; regression: handoff.lisp referenced localgroup-handoff--launch at line 52 and
;;; defined it at 381). The fix therefore applies EXACTLY when the analysed set
;;; holds a definition of f that provably precedes the reference: same file, the
;;; defun line before the reference; cross file, earlier in a KNOWN load order.
;;; When that is not provable - f defined later, f not in the set, or two files
;;; with no order - the finding is report-only. A lambda in quoted or
;;; macro-expansion position is already skipped; a TOP-LEVEL lambda is covered by
;;; the same rule, since only a preceding definition makes #'f safe there too.

(defun function-def-index (models)
  "Hash of function NAME -> list of (PATH LINE), every top-level definition of
NAME in MODELS, in file order. Only a form that DEFINES a function counts; a
reference to any other name has no provable definition point."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (m models)
      (dolist (n (top-level-forms (file-model-nodes m)))
        (multiple-value-bind (kind name line) (top-level-def n)
          (when (and name
                     (member kind '("DEFUN" "DEFMACRO" "DEFGENERIC" "DEFMETHOD"
                                    "DEFSUBST" "DEFINE-COMPILER-MACRO")
                             :test #'string=))
            (push (list (file-model-path m) line) (gethash name h))))))
    h))

(defun eta-target-precedes-p (ctx defs fname path line)
  "T when some analysed definition of FNAME provably precedes PATH:LINE in load
order. NIL means unprovable: the caller must refuse the rewrite, never guess."
  (some (lambda (d) (before-in-load-order-p ctx (first d) (second d) path line))
        (gethash fname defs)))

(defun eta-refusal-reason (defs fname)
  (cond ((null defs)
         (format nil "the analysed set is not available to prove ~A is defined first" fname))
        ((null (gethash fname defs))
         (format nil "~A is not defined in the analysed set" fname))
        (t (format nil "the definition of ~A does not precede this reference in load order"
                   fname))))

(defun lambda-list-simple-params (ll)
  "The parameter names of LL when LL is a proper list of plain (non-&) symbols,
else NIL."
  (when (and (eq (node-kind ll) :list) (proper-list-p (node-form ll)))
    (let ((names (mapcar #'node-atom-name (node-items ll))))
      (when (and names (every #'identity names)
                 (every (lambda (n) (char/= (char n 0) #\&)) names))
        names))))

(defun simplify-propose-eta-reduction (model ctx)
  (let ((src (file-model-src model)) (quoted (fm-quoted-nodes model))
        (macros (ctx-macro-names ctx)) (defs (and ctx (ctx-fn-defs ctx))) (out nil))
    (dolist (node (fm-list-nodes model))
      (when (and (node-is node "LAMBDA")
                 (= (length (node-items node)) 3)
                 (not (gethash node quoted)))
        (let* ((items (node-items node))
               (ll (second items))
               (body (third items))
               (params (lambda-list-simple-params ll)))
          (when (and params (eq (node-kind body) :list))
            (let* ((fname (node-atom-name (first (node-items body))))
                   (args (mapcar #'node-atom-name (cdr (node-items body)))))
              (when (and fname args
                         (not (member fname params :test #'string=))
                         (not (special-or-macro-p fname macros))
                         (equal args params)
                         (= (length args) (length (remove-duplicates args :test #'string=))))
                (let ((path (file-model-path model)) (line (node-line node)))
                  (multiple-value-bind (s e) (node-span src node)
                    (let ((precedes (and defs (eta-target-precedes-p ctx defs fname path line))))
                      (unless precedes
                        (record-fix-refusal path line "eta-reduction"
                                            (eta-refusal-reason defs fname)))
                      (push (list "eta-reduction" :note line (node-col node)
                                  (format nil "(lambda (~{~A~^ ~}) (~A ...)) just passes its arguments through; it is #'~A~@[ (not auto-fixed: ~A)~]"
                                          params fname fname
                                          (unless precedes (eta-refusal-reason defs fname)))
                                  (when precedes
                                    (list (make-edit :path path
                                                     :line line :rule "eta-reduction"
                                                     :start s :end e
                                                     :text (concatenate
                                                            'string "#'"
                                                            (node-text src (first (node-items body))))))))
                            out))))))))))
    (nreverse out)))

;;; ===================================================================== rule 7
;;; (list* a nil) is (cons a nil) is (list a); (list* a b nil) is (list a b).
;;; The arguments are evaluated once, in order, in both spellings; only the
;;; final literal NIL is dropped.

(defun simplify-propose-list-star (model ctx)
  (declare (ignore ctx))
  (let ((src (file-model-src model)) (quoted (fm-quoted-nodes model)) (out nil))
    (dolist (node (fm-list-nodes model))
      (when (and (node-is node "LIST*")
                 (>= (length (node-items node)) 3)
                 (not (gethash node quoted))
                 (node-nil-node (car (last (node-items node)))))
        (let* ((items (node-items node))
               (args (subseq items 1 (1- (length items)))))
          (multiple-value-bind (s e) (node-span src node)
            (push (list "list-star-nil" :note (node-line node) (node-col node)
                        (format nil "(list* ... nil) appends NIL to the list; its value is (list ~{~A~^ ~})"
                                (mapcar (lambda (a) (node-text src a)) args))
                        (list (make-edit :path (file-model-path model)
                                         :line (node-line node) :rule "list-star-nil"
                                         :start s :end e
                                         :text (concatenate 'string "(list"
                                                            (if args
                                                                (concatenate 'string " "
                                                                             (children-span-text src args))
                                                                "")
                                                            ")"))))
                  out)))))
    (nreverse out)))

;;; ------------------------------------------------------------------ the rules

(defun rule-redundant-progn (model ctx out)
  (emit-proposals (simplify-propose-redundant-progn model ctx) model out))

(defun rule-when-progn (model ctx out)
  (emit-proposals (simplify-propose-when-progn model ctx) model out))

(defun rule-boolean-coercion-in-test (model ctx out)
  (emit-proposals (simplify-propose-boolean-coercion model ctx) model out))

(defun rule-funcall-literal-function (model ctx out)
  (emit-proposals (simplify-propose-funcall model ctx) model out))

(defun rule-quote-quote (model ctx out)
  (emit-proposals (simplify-propose-quote-quote model ctx) model out))

(defun rule-eta-reduction (model ctx out)
  (emit-proposals (simplify-propose-eta-reduction model ctx) model out))

(defun rule-list-star-nil (model ctx out)
  (emit-proposals (simplify-propose-list-star model ctx) model out))

;;; --------------------------------------------------------------- fix wiring

(defun defmacro-names-of (models)
  "Hash of every macro name a DEFMACRO in MODELS defines. A rule that walks the
analysed set without a per-run context uses this in place of one."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (m models)
      (dolist (n (top-level-forms (file-model-nodes m)))
        (multiple-value-bind (kind name line) (top-level-def n)
          (declare (ignore line))
          (when (and name (equal kind "DEFMACRO")) (setf (gethash name h) t)))))
    h))

(defun simplification-fix-edits (models &optional order)
  "The edits of every fixable SIMPLIFICATION finding, with the macro check done
against the analysed set rather than a per-run context, the function-definition
index for the eta guard, and the load order (ORDER, or NIL when unknown) so the
eta guard can prove a cross-file target precedes the reference."
  (let ((macros (defmacro-names-of models))
        (fn-defs (function-def-index models))
        (edits nil))
    (flet ((mc () (make-ctx :macros macros :fn-defs fn-defs :order order :files models)))
      (dolist (m models)
        (setf edits (append edits
                            (proposal-edits (simplify-propose-redundant-progn m nil))
                            (proposal-edits (simplify-propose-when-progn m nil))
                            (proposal-edits (simplify-propose-boolean-coercion m nil))
                            (proposal-edits (simplify-propose-funcall m (mc)))
                            (proposal-edits (simplify-propose-eta-reduction m (mc)))
                            (proposal-edits (simplify-propose-list-star m nil))))))
    edits))

;;; --------------------------------------------------------------- rule registry
;;; One row per rule: scope :file (the rule walks the file's list nodes itself, so
;;; the quoted-data set is built once per file, not once per node).

(defrule "redundant-progn" :file :note t
  "a (progn X) whose sole body form is X, or a PROGN nested in a PROGN (fixable: PROGN returns its last form's values and evaluates it once, so the replacement is a no-op in every position)")
(defrule "when-progn" :file :note t
  "a (when/unless C (progn A B)) whose PROGN is body syntax (fixable: WHEN/UNLESS's body is already an implicit PROGN and PROGN passes values through)")
(defrule "boolean-coercion-in-test" :file :note t
  "an (if (not (null X)) A B) or (if (null X) A B) test (fixable in a TEST position only: (not (null X)) yields T/NIL as a value, not X, so the rewrite is refused outside a test)")
(defrule "funcall-literal-function" :file :note t
  "(funcall #'f ...) or (apply #'f (list ...)) with a literal function designator (fixable: same call, same argument evaluations; refused when f names a macro or a special operator, or the designator or argument list is not literal)")
(defrule "quote-quote" :file :note t
  "a doubly-quoted (quote (quote X)) (NOT auto-fixed: its value is the LIST (QUOTE X), not X, so dropping the inner quote changes the value - verified against SBCL, (equal (eval ''x) (eval 'x)) is NIL)")
(defrule "eta-reduction" :file :note t
  "a (lambda (A...) (f A...)) that only passes its arguments through (fixable to #'f ONLY when the analysed set holds a definition of f that provably precedes the reference in load order - same file, defun line before the reference; cross file, earlier in a KNOWN load order. #'f is resolved when the form is forced at load time, while a lambda defers it, so a target defined later turns the rewrite into an undefined-function error: refused on &optional/&key/&rest, any transformation, a captured name, a shadowed f, a macro f, a target not defined in the set, a target defined later, and any cross-file target whose order is unknown)")
(defrule "list-star-nil" :file :note t
  "(list* A ... nil), whose value is (list A ...) (fixable: the arguments are evaluated once, in order, in both spellings; only the final literal NIL is dropped)")

