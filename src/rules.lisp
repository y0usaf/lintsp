;;;; lintsp — rules.
;;;; One registry, two kinds: :node rules see each list form; :file rules see the
;;;; whole file model plus the cross-file index. No rule mutates global state.

(in-package #:lintsp)

;;; ------------------------------------------------------------ reference walker
;;; Reference collection prunes declaration contexts (lambda lists, binding
;;; lists, slot lists) or almost every call site is misread as a reference.
;;; Quoted data is skipped; backquote/comma atoms count as references.

(defparameter *clause-key-ops*
  '("CASE" "ECASE" "CCASE" "TYPECASE" "ETYPECASE" "HANDLER-CASE" "RESTART-CASE"
    "HANDLER-BIND"))

(defparameter *function-definers*
  '("DEFUN" "DEFMACRO" "DEFMETHOD" "DEFGENERIC" "LAMBDA" "DEFSUBST" "DEFSETF"
    "DEFINE-COMPILER-MACRO" "DEFINE-SETF-EXPANDER" "DEFINE-MODIFY-MACRO"
    "DEFINE-METHOD-COMBINATION"))

(defun walk-refs (form acc)
  "Push every symbol name referenced by FORM (a datum) onto ACC. Declaration
positions are binders, not references; quoted data is not walked."
  (cond
    ((consp form)
     (let ((h (and (symbolp (car form)) (symbol-name (car form)))))
       (cond
         ((equal h "QUOTE") nil)
         ((member h *function-definers* :test #'string=) (scan-function-form form acc))
         ((member h '("FLET" "LABELS" "MACROLET") :test #'string=) (scan-flet form acc))
         ((member h '("LET" "LET*") :test #'string=) (scan-let form acc))
         ((member h '("DO" "DO*") :test #'string=) (scan-do form acc))
         ((member h '("DOLIST" "DOTIMES") :test #'string=) (scan-dolist form acc))
         ((member h '("MULTIPLE-VALUE-BIND" "DESTRUCTURING-BIND" "PROG" "PROG*") :test #'string=)
          (scan-mvbind form acc))
         ((member h '("DEFSTRUCT" "DEFCLASS" "DEFINE-CONDITION") :test #'string=)
          (scan-slots form acc))
         ((member h '("DEFVAR" "DEFPARAMETER" "DEFCONSTANT") :test #'string=)
          (dolist (x (cddr form)) (walk-refs x acc)))
         ((member h '("DEFTYPE" "DEFPACKAGE" "IN-PACKAGE" "DECLAIM" "DEFINE-SYMBOL-MACRO")
                   :test #'string=)
          nil)
         ((equal h "DECLARE")
          ;; (declare (ignore x) (ignorable y)) names a binder, not a use. Walking
          ;; the names made every correct (declare (ignore p)) look like the body
          ;; read P — the ignore-then-read false positive (audit §3.8 trap 4).
          (dolist (spec (cdr form))
            (unless (and (consp spec)
                         (member (form-symbol-name (car spec)) '("IGNORE" "IGNORABLE")
                                 :test #'string=))
              (walk-refs spec acc))))
         ((equal h "LOOP") (scan-loop form acc))
         ((member h *clause-key-ops* :test #'string=)
          ;; operator's subject is code; each clause's key is a literal type/label
          (when (cdr form) (walk-refs (second form) acc))
          (dolist (clause (cddr form))
            (if (consp clause)
                (dolist (b (cdr clause)) (walk-refs b acc))
                (walk-refs clause acc))))
         (t (when (proper-list-p form) (dolist (x form) (walk-refs x acc)))))))
    ((vectorp form) (loop for i from 0 below (length form) do (walk-refs (aref form i) acc)))
    ((stringp form) nil)
    ;; A keyword is data, never a variable or function reference. Counting
    ;; :configuration as a reference to a variable CONFIGURATION (and to a
    ;; defun CONFIGURATION) is a pure name-collision false positive.
    ((keywordp form) nil)
    ((symbolp form) (push (symbol-name form) (car acc)))
    #+sbcl
    ;; SBCL's reader leaves ,x / ,@x inside a backquote as an SB-IMPL::COMMA
    ;; struct, not a cons, so a plain datum walk never sees the unquoted form.
    ;; Without this, every macro parameter used only inside a backquote is
    ;; reported unused (audit §4 trap 1).
    ((typep form 'sb-impl::comma) (walk-refs (sb-impl::comma-expr form) acc))
    (t nil))
  acc)

;;; ------------------------------------------------- variable-namespace refs
;;; Common Lisp has separate variable and function namespaces: the head of a
;;; call form names a FUNCTION, never a variable. WALK-REFS is deliberately
;;; namespace-blind (the reference index and forward-reference want every name),
;;; but a declaration is about VARIABLES, so "does the body read X" must ask the
;;; variable namespace only. Otherwise a correct
;;;   (multiple-value-bind (format ...) ... (declare (ignore format)) (format nil ...))
;;; looks like a read of FORMAT when it is a call to cl:format. This walker
;;; counts a symbol only in a variable position: the operator of a form is
;;; skipped, function-definer lambda lists are binders, declarations are not
;;; reads, and quoted data is not walked.

(defun walk-var-refs (form acc)
  "Push every variable-position symbol name in FORM onto ACC."
  (cond
    ((consp form)
     (let ((h (and (symbolp (car form)) (symbol-name (car form)))))
       (cond
         ((equal h "QUOTE") nil)
         ((equal h "DECLARE") nil)
         ((member h *function-definers* :test #'string=) (scan-function-var-refs form acc))
         ((member h '("FLET" "LABELS" "MACROLET") :test #'string=) (scan-flet-var-refs form acc))
         ;; the binding list is binders; only the value forms are reads
         ((member h '("MULTIPLE-VALUE-BIND" "DESTRUCTURING-BIND") :test #'string=)
          (dolist (x (cddr form)) (walk-var-refs x acc)))
         ((member h '("DEFTYPE" "DEFPACKAGE" "IN-PACKAGE" "DECLAIM" "DEFINE-SYMBOL-MACRO")
                   :test #'string=)
          nil)
         ((member h '("DEFVAR" "DEFPARAMETER" "DEFCONSTANT") :test #'string=)
          (dolist (x (cddr form)) (walk-var-refs x acc)))
         ;; the operator is a function; its arguments are variable positions
         (t (when (proper-list-p form)
              (dolist (x (cdr form)) (walk-var-refs x acc)))))))
    ((vectorp form) (loop for i from 0 below (length form) do (walk-var-refs (aref form i) acc)))
    ((stringp form) nil)
    ((keywordp form) nil)
    ((symbolp form) (push (symbol-name form) (car acc)))
    #+sbcl
    ((typep form 'sb-impl::comma) (walk-var-refs (sb-impl::comma-expr form) acc))
    (t nil))
  acc)

(defun scan-function-var-refs (form acc)
  "Walk a function-defining form's body only: its name and lambda list are not
variable positions."
  (let* ((h (and (symbolp (car form)) (symbol-name (car form))))
         (rest (if (and h (string= h "LAMBDA")) (cdr form) (cddr form))))
    (loop while (and rest (atom (first rest)) (first rest) (> (length rest) 1))
          do (pop rest))
    (dolist (b (rest rest)) (walk-var-refs b acc))))

(defun scan-flet-var-refs (form acc)
  (dolist (d (second form))
    (when (consp d) (dolist (b (cddr d)) (walk-var-refs b acc))))
  (dolist (b (cddr form)) (walk-var-refs b acc)))

(defun scan-lambda-list (ll acc)
  "Scan a lambda list: bare symbols are binders, (var init) defaults are code."
  (when (proper-list-p ll)
    (dolist (x ll)
      (cond ((symbolp x) nil)
            ((consp x)
             (when (and (cdr x) (second x))
               (walk-refs (second x) acc)))))))

(defun scan-function-form (form acc)
  "Walk a function-defining form. LAMBDA has no name slot, so its lambda list is
(cdr form); using (cddr form) reads the first BODY form as the lambda list and
then treats the body's binders as references — the bug behind every
'(lambda (x) (declare (ignore x)))' false positive."
  (let* ((h (and (symbolp (car form)) (symbol-name (car form))))
         (rest (if (and h (string= h "LAMBDA")) (cdr form) (cddr form))))
    ;; skip defmethod-style qualifiers (non-list, non-nil atoms)
    (loop while (and rest (atom (first rest)) (first rest) (> (length rest) 1))
          do (pop rest))
    (let ((ll (first rest)) (body (rest rest)))
      (scan-lambda-list ll acc)
      (dolist (b body) (walk-refs b acc)))))

(defun scan-flet (form acc)
  (let ((defs (second form)) (body (cddr form)))
    (when (proper-list-p defs)
      (dolist (d defs)
        (when (consp d)
          (scan-lambda-list (second d) acc)
          (dolist (b (cddr d)) (walk-refs b acc)))))
    (dolist (b body) (walk-refs b acc))))

(defun scan-let (form acc)
  (let ((binds (second form)) (body (cddr form)))
    (when (proper-list-p binds)
      (dolist (b binds)
        (when (consp b) (dolist (init (cdr b)) (walk-refs init acc)))))
    (dolist (b body) (walk-refs b acc))))

(defun scan-do (form acc)
  (dolist (v (if (listp (second form)) (second form) nil))
    (when (consp v) (dolist (init (cdr v)) (walk-refs init acc))))
  (dolist (x (cddr form)) (walk-refs x acc)))

(defun scan-dolist (form acc)
  (let ((spec (second form)))
    (when (and (consp spec) (second spec)) (walk-refs (second spec) acc)))
  (dolist (x (cddr form)) (walk-refs x acc)))

(defun scan-mvbind (form acc)
  (dolist (x (cddr form)) (walk-refs x acc)))

(defun scan-slots (form acc)
  (flet ((slot (x)
           (when (consp x)
             (dolist (y (cdr x))
               (if (and (consp y) (keywordp (car y)))
                   (dolist (z (cdr y)) (walk-refs z acc))
                   (walk-refs y acc))))))
    (dolist (x (cddr form)) (slot x))))

(defun scan-loop (form acc)
  (let ((items (cdr form)))
    (loop while items do
      (let ((x (pop items)))
        (cond ((and (symbolp x)
                    (member (symbol-name x) '("FOR" "WITH" "AS") :test #'string=))
               (let ((b (pop items)))
                 (when (and (consp b) (proper-list-p (cdr b)))
                   (dolist (y (cdr b)) (walk-refs y acc)))))
              ((consp x) (walk-refs x acc))
              ((symbolp x) (push (symbol-name x) (car acc)))
              (t nil))))))

(defun refs-of (form)
  "Symbol names referenced by the datum FORM."
  (let ((box (list nil)))
    (handler-case (walk-refs form box) (error () nil))
    (nreverse (car box))))

(defun node-refs (node)
  "Every symbol name referenced by NODE's datum. ACC is a mutable box: a recursive
walker cannot PUSH onto a parameter and have the caller see it. Errors are
contained: a single odd form must not abort a whole run."
  (let ((box (list nil)))
    (handler-case (walk-refs (node-form node) box)
      (error () nil))
    (nreverse (car box))))

;;; ------------------------------------------------------------------ definitions

(defparameter *definer-heads*
  '("DEFUN" "DEFMACRO" "DEFGENERIC" "DEFMETHOD" "DEFVAR" "DEFPARAMETER"
    "DEFCONSTANT" "DEFCLASS" "DEFSTRUCT" "DEFINE-CONDITION" "DEFTYPE"))

(defun top-level-forms (nodes)
  "Flatten top-level PROGN / EVAL-WHEN / LOCALLY wrappers into their forms."
  (let ((out nil))
    (labels ((rec (n)
               (if (and (eq (node-kind n) :list)
                        (member (node-head n) '("PROGN" "EVAL-WHEN" "LOCALLY") :test #'string=))
                   (dolist (c (cdr (node-items n))) (rec c))
                   (push n out))))
      (dolist (n nodes) (rec n)))
    (nreverse out)))

(defun form-symbol-name (x)
  (cond ((symbolp x) (symbol-name x))
        ((consp x) (form-symbol-name (car x)))
        (t nil)))

(defun top-level-def (node)
  "Return (values kind name line) for a top-level definition NODE, else NIL."
  (when (eq (node-kind node) :list)
    (let* ((form (node-form node))
           (h (and (consp form) (symbolp (car form)) (symbol-name (car form)))))
      (when (and h (member h *definer-heads* :test #'string=) (cdr form))
        (let ((name (form-symbol-name (second form))))
          (when name (values h name (node-line node))))))))

(defun option-conc-name (o conc)
  (if (and (consp o) (equal (form-symbol-name (car o)) "CONC-NAME"))
      (if (cdr o) (or (form-symbol-name (second o)) "") "")
      conc))

(defun option-constructor (o out)
  (when (and (consp o) (equal (form-symbol-name (car o)) "CONSTRUCTOR"))
    (when (and (cdr o) (symbolp (second o)))
      (push (cons (symbol-name (second o)) "constructor") out))
    t))

(defun option-predicate (o name out)
  (when (and (consp o) (equal (form-symbol-name (car o)) "PREDICATE"))
    (push (cons (if (cdr o) (form-symbol-name (second o))
                    (concatenate 'string name "-P"))
                "predicate")
          out)
    t))

(defun accessor-option (o out)
  "Record the name in an (:ACCESSOR n) / (:READER n) / (:WRITER n) option."
  (when (and (consp o)
             (member (form-symbol-name (car o)) '("ACCESSOR" "READER" "WRITER")
                     :test #'string=)
             (cdr o))
    (push (cons (form-symbol-name (second o)) "slot-accessor") out)))

(defun struct-generated-names (form)
  "Names generated by a DEFSTRUCT/DEFCLASS/DEFINE-CONDITION FORM. Returns
((NAME . OPTION) ...) where OPTION says what generated NAME."
  (let* ((h (and (consp form) (symbolp (car form)) (symbol-name (car form))))
         (named (and (consp form) (second form)))
         (name (form-symbol-name named))
         (out nil)
         (constructed nil)
         (predicated nil)
         (conc nil))
    (unless (and name (member h '("DEFSTRUCT" "DEFCLASS" "DEFINE-CONDITION")
                             :test #'string=))
      (return-from struct-generated-names nil))
    (setf conc (concatenate 'string name "-"))
    (when (consp named)                       ; options may sit beside the name
      (dolist (o (cdr named))
        (setf conc (option-conc-name o conc))
        (setf constructed (or constructed (option-constructor o out)))
        (setf predicated (or predicated (option-predicate o name out)))))
    (let ((rest (cddr form)))
      (when (and rest (stringp (first rest))) (pop rest))    ; real docstring only
      (dolist (x rest)
        (cond
          ((and (symbolp x) (not (keywordp x)))              ; slot as an atom
           (push (cons (concatenate 'string conc (symbol-name x)) "slot") out))
          ((and (consp x) (symbolp (car x)) (not (keywordp (car x))))
           (push (cons (concatenate 'string conc (symbol-name (car x))) "slot") out)
           (dolist (o (cdr x)) (accessor-option o out)))
          ((consp x)                                        ; a struct option
           (setf conc (option-conc-name x conc))
           (setf constructed (or constructed (option-constructor x out)))
           (setf predicated (or predicated (option-predicate x name out)))
           (dolist (o (cdr x)) (accessor-option o out))))))
    (when (member h '("DEFCLASS" "DEFINE-CONDITION") :test #'string=)
      (dolist (slot (cdddr form))
        (when (consp slot) (dolist (o (cdr slot)) (accessor-option o out)))))
    (unless constructed
      (push (cons (concatenate 'string "MAKE-" name) "constructor") out))
    (unless predicated
      (push (cons (concatenate 'string name "-P") "predicate") out))
    (nreverse out)))

(defun exported-names (nodes)
  "All symbol names listed in a DEFPACKAGE :EXPORT clause."
  (let ((out nil))
    (dolist (n nodes)
      (labels ((rec (x)
                 (when (consp x)
                   (if (member (form-symbol-name (car x)) '("EXPORT")
                               :test #'string=)
                       (dolist (e (cdr x))
                         (cond ((consp e)
                                (dolist (s e) (when (symbolp s) (push (symbol-name s) out))))
                               ((symbolp e) (push (symbol-name e) out))))
                       (dolist (y x) (rec y))))))
        (rec (node-form n))))
    out))

;;; ============================================================ the rule registry

(defstruct rule name scope severity default description)
(defvar *rules* nil)

(defmacro emit (diag out)
  "Add DIAG to the collector OUT. OUT is a one-element list shared with the
driver: a rule cannot PUSH onto a parameter and have the caller see it, so the
collector is a mutable box."
  `(push ,diag (car ,out)))

(defmacro defrule (name scope severity default description)
  `(let ((r (make-rule :name ,name :scope ,scope :severity ,severity
                       :default ,default :description ,description)))
     (setf *rules* (remove ,name *rules* :key #'rule-name :test #'string=))
     (push r *rules*)
     r))

;;; --------------------------------------------------------------------- context

(defstruct ctx
  files                       ; list of file-model, in load order
  index                       ; hash name -> integer ref count
  defs                        ; hash name -> list of (kind path line)
  exports                     ; hash name -> t
  order                       ; hash path -> integer, or NIL when order unknown
  order-source                ; description string
  root-prefix
  allow-definitions allow-symbols specials
  macros                      ; hash name -> T for every DEFMACRO in the set
  fn-defs                     ; hash function name -> ((path line) ...), in file order
  package-exports             ; hash package name -> hash of its :export names
  defindex
  long-lines deep-depth)

(defun ctx-all-nodes (ctx)
  (loop for f in (ctx-files ctx) append (all-list-nodes (file-model-nodes f))))

(defun ctx-ref-count (ctx name) (gethash (string-upcase name) (ctx-index ctx) 0))

;;; ------------------------------------------------------------------ node rules

(defun rule-optional-and-key (node model ctx out)
  (declare (ignore ctx))
  (let ((form (node-form node)))
    (when (and (consp form) (symbolp (car form)))
      (let* ((h (symbol-name (car form)))
             (lls nil))
        (cond
          ((member h '("DEFUN" "DEFMACRO" "DEFGENERIC" "LAMBDA" "DEFSUBST"
                       "DEFINE-COMPILER-MACRO" "DEFINE-SETF-EXPANDER") :test #'string=)
           (push (nth 2 form) lls))
          ((string= h "DEFMETHOD") (push (third form) lls))
          ((member h '("FLET" "LABELS" "MACROLET") :test #'string=)
           (dolist (d (second form))
             (when (consp d) (push (second d) lls))))
          ((string= h "DEFSETF") (dolist (x (cdr form)) (when (listp x) (push x lls)))))
        (dolist (ll lls)
          (when (proper-list-p ll)
            (let ((names (loop for x in ll when (symbolp x) collect (symbol-name x))))
              (when (and (member "&OPTIONAL" names :test #'string=)
                         (member "&KEY" names :test #'string=))
                (emit (make-diagnostic "optional-and-key" :warning
                                       (file-model-path model) (node-line node) (node-col node)
                                       (format nil "~A mixes &OPTIONAL and &KEY in one lambda list; ~
callers cannot tell positional from keyword tail arguments"
                                               (or h "lambda list")))
                      out)))))))))

(defun rule-quadratic-append (node model ctx out)
  "SETF of a place to (append PLACE (list ...)) copies the whole list each time."
  (declare (ignore ctx))
  (let ((form (node-form node)))
    (when (and (consp form) (symbolp (car form)))
      (let ((h (symbol-name (car form))))
        (when (and (member h '("SETF" "SETQ") :test #'string=) (>= (length form) 3))
          (let ((place (second form)) (value (third form)))
            (when (and (consp value) (symbolp (car value))
                       (string= (symbol-name (car value)) "APPEND")
                       (eq (second value) place) (second value)
                       (consp (third value))
                       (string= (symbol-name (car (third value))) "LIST"))
              (emit (make-diagnostic "quadratic-append" :warning
                                     (file-model-path model) (node-line node) (node-col node)
                                     (format nil "~A ~A (append ~A (list ...)) copies the whole ~
list on every call; accumulate and NREVERSE once"
                                             (string-downcase h) place place))
                    out))))))))

;;; --------------------------------------- perf: copies and walks of a sequence
;;; Both rules below encode a CLHS complexity fact, not a measurement: each
;;; names an operation that copies or walks its whole sequence argument, so a
;;; form that runs it repeatedly over an accumulator is quadratic by
;;; construction. Neither asserts that the program is slow. Like quadratic-append
;;; above they are report-only (fix.lisp:12-15): reordering an accumulation or
;;; replacing an index walk is a design decision, not a text splice.

(defun quoted-name-p (form name)
  "FORM is the literal (QUOTE NAME), e.g. the 'STRING type argument of
CONCATENATE. Symbols are read into a private package, so the printed name is
what is compared, never the symbol."
  (and (consp form) (consp (cdr form))
       (equal (form-symbol-name (car form)) "QUOTE")
       (equal (form-symbol-name (second form)) name)))

(defun rule-self-concatenating-accumulator (node model ctx out)
  "SETF/SETQ of a place to a copy whose first input is that same place:
(setf P (concatenate 'string P ...)), or (setf P (append P ...)) whose tail is
not a literal (list ...) - that shape is quadratic-append's."
  (declare (ignore ctx))
  (let ((form (node-form node)))
    (when (and (consp form) (symbolp (car form)))
      (let ((h (symbol-name (car form))))
        (when (and (member h '("SETF" "SETQ") :test #'string=) (>= (length form) 3)
                   (not (gethash node (fm-quoted-nodes model))))
          (let ((place (second form)) (value (third form)) (msg nil))
            (when (and (symbolp place) (consp value) (symbolp (car value)))
              (let ((vh (symbol-name (car value))))
                (cond
                  ;; CONCATENATE allocates a fresh sequence and copies every
                  ;; argument, so the accumulator is copied in full per call.
                  ((and (string= vh "CONCATENATE") (consp (cdddr value))
                        (quoted-name-p (second value) "STRING")
                        (eq (third value) place))
                   (setf msg (format nil "~A ~A (concatenate 'string ~A ...) copies the whole ~
accumulated string on every call (CLHS CONCATENATE copies each argument); growing it in a loop ~
is quadratic - accumulate into a string stream and call GET-OUTPUT-STREAM-STRING once"
                                     (string-downcase h) place place)))
                  ;; APPEND copies every argument but the last, so the
                  ;; accumulator is copied in full per call.
                  ((and (string= vh "APPEND") (consp (cddr value))
                        (eq (second value) place)
                        (not (and (consp (third value))
                                  (equal (form-symbol-name (third value)) "LIST"))))
                   (setf msg (format nil "~A ~A (append ~A ...) copies the whole accumulated ~
list on every call (CLHS APPEND copies every argument but the last); growing it in a loop is ~
quadratic - accumulate and NREVERSE once"
                                     (string-downcase h) place place)))
                  (t nil))
                (when msg
                  (emit (make-diagnostic "self-concatenating-accumulator" :note
                                         (file-model-path model) (node-line node) (node-col node)
                                         msg)
                        out))))))))))

;;; -------------------------------------------------- perf: NTH-indexed list walk
;;; The list-ness is read off the form: NTH, MEMBER and TAILP are defined only
;;; for lists (CLHS), so a call proves its sequence argument is a list with no
;;; type knowledge and no binding model. LENGTH alone could not be classified -
;;; it is constant on a vector and linear on a list - so it is never the key;
;;; it is only believed when one of the list-only calls names the same sequence.

(defparameter *list-only-index-ops* '("NTH" "MEMBER" "TAILP")
  "List-only operators whose second argument is therefore proven a list by the
call itself.")

(defparameter *list-only-length-ops* '("LENGTH" "LIST-LENGTH")
  "Sequence-length operators. LENGTH is linear on a list but constant on a
vector, so it counts only against the same sequence a list-only call named;
LIST-LENGTH is list-only and linear.")

(defparameter *loop-bound-keywords*
  '("BELOW" "UPTO" "TO" "DOWNTO" "ABOVE" "WHILE" "UNTIL")
  "LOOP keywords whose following item is the loop's own bound.")

(defun loop-index-names (form)
  "Printed names of the variables loop FORM iterates (DOTIMES, DO, DO*, LOOP).
A dotted form (... . TAIL) has no item after TAIL, so the scans step by CONSP."
  (let ((h (form-symbol-name (car form))))
    (cond
      ((and (equal h "DOTIMES") (consp (second form)) (symbolp (first (second form))))
       (list (symbol-name (first (second form)))))
      ((member h '("DO" "DO*") :test #'equal)
       (loop for b in (if (listp (second form)) (second form) nil)
             when (and (consp b) (symbolp (first b))) collect (symbol-name (first b))))
      ((equal h "LOOP")
       (let ((items (cdr form)) (out nil))
         (loop while (consp items) do
           (let ((x (pop items)))
             (when (and (symbolp x) (not (keywordp x))
                        (member (symbol-name x) '("FOR" "AS") :test #'string=))
               (let ((v (pop items)))
                 (when (and (symbolp v) (not (keywordp v))) (push (symbol-name v) out))))))
         (nreverse out))))))

(defun loop-bound-forms (form)
  "The forms that decide how many times loop FORM runs: the DOTIMES count, the
DO/DO* end test, or the item after a LOOP bound keyword. A dotted form ends
without one, so the scans step by CONSP."
  (let ((h (form-symbol-name (car form))))
    (cond
      ((equal h "DOTIMES")
       (and (consp (second form)) (consp (cdr (second form))) (list (second (second form)))))
      ((member h '("DO" "DO*") :test #'equal)
       (and (consp (cddr form)) (consp (third form)) (list (first (third form)))))
      ((equal h "LOOP")
       (loop for (x . rest) on (cdr form)
             when (and (symbolp x) (not (keywordp x)) (consp rest)
                       (member (symbol-name x) *loop-bound-keywords* :test #'string=))
               collect (first rest))))))

(defun list-name-of (form)
  "The list variable FORM names, or NIL: an atom, or (the list X) around one."
  (cond
    ((and (symbolp form) (not (keywordp form))) (symbol-name form))
    ((and (consp form) (equal (form-symbol-name (car form)) "THE")
          (consp (cdr form)) (equal (form-symbol-name (second form)) "LIST"))
     (list-name-of (third form)))
    (t nil)))

(defun list-walk-names (form index-names)
  "Walk FORM - quoted data is data, not a call - and return (values CALLS BOUNDS):
the sequence name S of every (NTH/MEMBER/TAILP V S) whose V is one of
INDEX-NAMES, and the sequence name S of every (LENGTH S) / (LIST-LENGTH S).
A dotted pair - LOOP's own FOR (A . B) IN ... - has no cdr chain to step onto,
so the walk steps by hand instead of handing the tail to DOLIST."
  (let ((calls nil) (bounds nil))
    (labels ((walk (x)
               (when (consp x)
                 (let ((h (form-symbol-name (car x))))
                   (cond
                     ((equal h "QUOTE") nil)
                     ((and h (member h *list-only-index-ops* :test #'string=)
                           (consp (cdr x)) (consp (cddr x))
                           (member (list-name-of (second x)) index-names :test #'string=))
                      (let ((s (list-name-of (third x))))
                        (when s (pushnew s calls :test #'string=))))
                     ((and h (member h *list-only-length-ops* :test #'string=)
                           (consp (cdr x)))
                      (let ((s (list-name-of (second x))))
                        (when s (pushnew s bounds :test #'string=))))))
                 (do ((rest x (cdr rest))) ((atom rest)) (walk (car rest))))))
      (walk form))
    (values calls bounds)))

(defun rule-nth-indexed-list-loop (node model ctx out)
  "An index-driven walk over a list: a DOTIMES/DO/DO*/LOOP whose own bound is the
length of a sequence the body indexes by the loop variable."
  (declare (ignore ctx))
  (let ((form (node-form node)))
    (when (and (consp form) (symbolp (car form))
               (not (gethash node (fm-quoted-nodes model))))
      (let ((index-names (loop-index-names form))
            (bounds (loop-bound-forms form)))
        (when (and index-names bounds)
          (multiple-value-bind (calls ignored) (list-walk-names form index-names)
            (declare (ignore ignored))
            (let ((hit (loop for b in bounds
                             thereis (multiple-value-bind (bc bs) (list-walk-names b nil)
                                       (declare (ignore bc))
                                       (find-if (lambda (s) (member s calls :test #'string=))
                                                bs)))))
              (when hit
                (emit (make-diagnostic "nth-indexed-list-loop" :note
                                       (file-model-path model) (node-line node) (node-col node)
                                       (format nil "~A over ~A: each iteration walks ~A from the front ~
(CLHS NTH/MEMBER/TAILP search a list from its start) while the loop is bounded by (length ~A); ~
O(n^2) unless it exits early, so use DOLIST/MAPCAR or hold the remaining tail in a variable"
                                               (string-downcase (form-symbol-name (car form)))
                                               hit hit hit))
                      out)))))))))

;;; ------------------------------------------------------------------ file rules

(defun rule-ignore-then-read (model ctx out)
  (declare (ignore ctx))
  (dolist (node (fm-list-nodes model))
    (when (node-is node "DECLARE")
      (let ((ignored nil))
        (dolist (spec (cdr (node-items node)))
          (when (and (node-is spec "IGNORE") (node-aligned spec))
            (dolist (s (cdr (node-items spec)))
              (when (node-sym-name s)
                (push (cons (node-sym-name s) (or (node-line s) (node-line node))) ignored)))))
        (when ignored
          ;; A (declare (ignore x)) governs exactly the forms that follow it in
          ;; its immediate enclosing list. That is the precise scope: the
          ;; enclosing DEFUN would also see a use of x in a sibling nested
          ;; function, and a HANDLER-CASE would see one in another clause that
          ;; binds its own x. Both were residual false positives; reading only
          ;; the following siblings removes them while still catching a real
          ;; read of an ignored name. The reads are collected with
          ;; WALK-VAR-REFS, not WALK-REFS: CL has separate variable and function
          ;; namespaces, so (format nil ...) is the FUNCTION cl:format and does
          ;; not read a variable named FORMAT.
          (let ((body-refs (sibling-body-refs node (fm-list-nodes model))))
            (dolist (pair ignored)
              (when (member (car pair) body-refs :test #'string=)
                (emit (make-diagnostic "ignore-then-read" :warning
                                       (file-model-path model) (cdr pair) (or (node-col node) 1)
                                       (format nil "(declare (ignore ~A)) but the body reads or ~
writes ~A" (car pair) (car pair)))
                      out)))))))))

(defun sibling-body-refs (node nodes)
  "Every variable name read by the forms that FOLLOW NODE inside NODE's immediate
enclosing list. A DECLARE governs exactly that span. NODES is the file's list
nodes; the immediate parent is the smallest one containing NODE."
  (let ((parent nil) (parent-size nil))
    (dolist (d nodes)
      (when (and (not (eq d node))
                 (<= (node-start d) (node-start node))
                 (>= (node-end d) (node-end node)))
        (let ((size (- (node-end d) (node-start d))))
          (when (or (null parent-size) (< size parent-size))
            (setf parent d parent-size size)))))
    (when parent
      (let ((box (list nil)) (after nil))
        (dolist (c (node-items parent))
          (cond ((eq c node) (setf after t))
                (after (walk-var-refs (node-form c) box))))
        (nreverse (car box))))))

(defun function-body-refs (fn)
  "Hash of symbol names referenced in FN's body (lambda list excluded)."
  (let ((h (make-hash-table :test #'equal)))
    (let ((rest (cdr (node-items fn))))
      (loop while (and rest (atom (node-form (first rest))) (node-form (first rest))
                        (> (length rest) 1))
            do (pop rest))
      (dolist (b (rest rest))
        (dolist (name (node-refs b)) (incf (gethash name h 0)))))
    h))

(defun rule-unused-parameter (model ctx out)
  "Lambda-list parameters never referenced. LAMBDA has no name slot, so its
lambda list is (cdr form), not (cddr form) — getting that wrong reads the first
body form (a DECLARE or LET) as the lambda list."
  (declare (ignore ctx))
  (dolist (node (fm-list-nodes model))
    (when (and (member (node-head node) *function-definers* :test #'string=)
               ;; A DEFGENERIC has no body: its lambda list is a signature whose
               ;; parameters are supplied by methods, so none can be "read".
               (not (string= (node-head node) "DEFGENERIC")))
      (let* ((form (node-form node))
             (h (node-head node))
             (rest (if (string= h "LAMBDA") (cdr form) (cddr form)))
             (ll nil) (body nil))
        (loop while (and rest (atom (first rest)) (first rest) (> (length rest) 1))
              do (pop rest))
        (setf ll (first rest) body (rest rest))
        (let ((body-refs (function-body-refs node))
              (declared-ignore (list nil)))
          (dolist (b body)
            (collect-ignores b declared-ignore))
          ;; A bodyless definer (DEFGENERIC, or a stub) has nothing to reference
          ;; the parameters with; reporting them is pure noise.
          (when (and body (proper-list-p ll))
            (dolist (p (lambda-list-binders ll))
              (let ((name (car p)))
                (unless (or (gethash name body-refs)
                            (member name (car declared-ignore) :test #'string=)
                            (and (plusp (length name)) (char= (char name 0) #\_)))
                  (emit (make-diagnostic "unused-parameter" :note
                                         (file-model-path model)
                                         (or (node-line node) 1) (or (node-col node) 1)
                                         (format nil "~A: parameter ~A is never referenced"
                                                 (string-downcase h) name))
                        out))))))))))

(defun rule-unused-binding (model ctx out)
  "Lexical bindings never referenced."
  (declare (ignore ctx))
  (dolist (node (fm-list-nodes model))
    (let ((h (node-head node)))
      (when (member h '("LET" "LET*" "DO" "DO*" "DOLIST" "DOTIMES"
                        "MULTIPLE-VALUE-BIND" "DESTRUCTURING-BIND") :test #'string=)
        (let ((binders nil) (body nil))
          (cond
            ((member h '("LET" "LET*" "DO" "DO*") :test #'string=)
             (setf binders (binding-names (second (node-form node)))
                   body (cddr (node-form node))))
            ((member h '("DOLIST" "DOTIMES") :test #'string=)
             (let ((spec (second (node-form node))))
               (when (and (consp spec) (symbolp (first spec)))
                 (push (symbol-name (first spec)) binders))
               (setf body (cddr (node-form node)))))
            (t
             (setf binders (destructure-names (second (node-form node)))
                   body (cddr (node-form node)))))
          (when binders
            (let ((refs (make-hash-table :test #'equal)))
              (dolist (b body) (dolist (n (refs-of b))
                                 (incf (gethash n refs 0))))
              ;; let* / do* sibling initialisers may reference earlier binders
              (when (member h '("LET*" "DO*") :test #'string=)
                (dolist (b (if (member h '("DO" "DO*") :test #'string=)
                               (second (node-form node))
                               (second (node-form node))))
                  (when (consp b) (dolist (init (cdr b))
                                    (dolist (n (refs-of init))
                                      (incf (gethash n refs 0)))))))
              (let ((declared-ignore (list nil)))
                (dolist (b body) (collect-ignores b declared-ignore))
                (dolist (name binders)
                  (unless (or (gethash name refs)
                              (member name (car declared-ignore) :test #'string=)
                              (char= (char name 0) #\_)
                              (and (char= (char name 0) #\*) (char= (char name (1- (length name))) #\*)))
                    (emit (make-diagnostic "unused-binding" :note
                                           (file-model-path model)
                                           (or (node-line node) 1) (or (node-col node) 1)
                                           (format nil "~A binding ~A is never referenced"
                                                   (string-downcase h) name))
                          out)))))))))))

(defun collect-ignores (form acc)
  "Collect names in (DECLARE (IGNORE x) (IGNORABLE y)) anywhere in FORM. ACC is a
mutable box shared with the caller."
  (cond
    ((consp form)
     (when (and (symbolp (car form))
                (string= (symbol-name (car form)) "DECLARE"))
       (loop for specs = (cdr form) then (cdr specs)
             while (consp specs)
             for spec = (car specs)
             when (and (consp spec)
                       (member (form-symbol-name (car spec)) '("IGNORE" "IGNORABLE")
                               :test #'string=))
               do (loop for names = (cdr spec) then (cdr names)
                        while (consp names)
                        when (symbolp (car names))
                          do (push (symbol-name (car names)) (car acc)))))
     (loop for tail = form then (cdr tail)
           while (consp tail)
           do (collect-ignores (car tail) acc)))
    (t nil)))

(defun lambda-list-binders (ll)
  "((NAME . OWNER) ...) of names bound by lambda list LL. A bare symbol is a
binder; a (var init) pair binds only VAR; (var init supplied-p) binds both."
  (let ((out nil))
    (dolist (x ll)
      (cond
        ((symbolp x)
         (let ((n (symbol-name x)))
           (unless (and (plusp (length n)) (char= (char n 0) #\&))
             (push (cons n nil) out))))
        ((consp x)
         (cond ((symbolp (first x)) (push (cons (symbol-name (first x)) nil) out))
               ((consp (first x))             ; ((:keyword var) init)
                (when (symbolp (second (first x)))
                  (push (cons (symbol-name (second (first x))) nil) out))))
         (when (and (cddr x) (symbolp (third x)))
           (push (cons (symbol-name (third x)) nil) out)))))
    (nreverse out)))

(defun binding-names (binds)
  (let ((out nil))
    (when (proper-list-p binds)
      (dolist (b binds)
        (cond ((symbolp b) (push (symbol-name b) out))   ; dolist/do special forms
              ((consp b) (let ((n (form-symbol-name (first b))))
                           (when (and n (not (keywordp (first b)))) (push n out)))))))
    (nreverse out)))

(defun destructure-names (vars)
  "Names bound by a destructuring lambda list. Lambda-list keywords (&optional,
&rest, &key, &aux ...) are structure, not binders, so they are skipped — else
every '&OPTIONAL' / '&REST' is reported as an unused binding."
  (let ((out nil))
    (labels ((rec (v)
               (cond ((symbolp v)
                      (let ((n (symbol-name v)))
                        (unless (and (plusp (length n)) (char= (char n 0) #\&))
                          (push n out))))
                     ((consp v) (when (proper-list-p v) (dolist (x v) (rec x)))))))
      (rec vars))
    (nreverse out)))

;;; ------------------------------------------------------- load-order comparison
;;; A file whose position is not known (no --order, no .asd :components, no
;;; literal loader list) has no load position: the driver's alphabetical
;;; fallback order is NOT a load order. Comparing two such files turns every
;;; cross-file reference into a phantom "used before its definition". So a rule
;;; asks BEFORE-IN-LOAD-ORDER-P, which answers NIL — "cannot prove" — rather
;;; than guessing from the sort order.

(defun file-load-index (ctx path)
  "Load position of PATH, or NIL when its order is unknown."
  (gethash (namestring (or (ignore-errors (truename path)) path)) (ctx-order ctx)))

(defun before-in-load-order-p (ctx path-a line-a path-b line-b)
  "True when A (PATH-A:LINE-A) provably precedes B (PATH-B:LINE-B): same file
by line, or a known load order by position. NIL when the order is unprovable."
  (cond ((string= path-a path-b) (< line-a line-b))
        (t (let ((ia (file-load-index ctx path-a)) (ib (file-load-index ctx path-b)))
             (and ia ib (< ia ib))))))

(defun rule-defstruct-after-use (model ctx out)
  "A structure's generated accessor used before the DEFSTRUCT that defines it —
the inline-loss defect. Same-file uses always; cross-file uses only when the
load order is actually known (audit §3.2, §5)."
  ;; Cross-file, so it runs once for the whole set rather than once per file.
  (unless (eq model (first (ctx-files ctx))) (return-from rule-defstruct-after-use nil))
  (let ((gen (make-hash-table :test #'equal))
        (defspans nil))
    ;; Spans of every DEFSTRUCT-family form, tagged with its file: node offsets
    ;; are relative to their own source, so a span from one file must never be
    ;; matched against a node in another. A slot list or slot option inside one
    ;; is declaration syntax, never an accessor call site; reading its head as a
    ;; call is how the slot trap (audit §3.8 trap 4) produced phantom uses.
    (loop for m in (ctx-files ctx) do
      (dolist (node (top-level-forms (file-model-nodes m)))
        (let ((form (node-form node)))
          (when (and (consp form) (symbolp (car form))
                     (member (symbol-name (car form))
                             '("DEFSTRUCT" "DEFCLASS" "DEFINE-CONDITION") :test #'string=))
            (push (list (file-model-path m) (node-start node) (node-end node)) defspans)))))
    ;; Every generated name across the analysed set, with the file and line of
    ;; its first definition in load order.
    (loop for m in (ctx-files ctx) do
      (dolist (node (top-level-forms (file-model-nodes m)))
        (let ((form (node-form node)))
          (when (and (consp form) (symbolp (car form))
                     (member (symbol-name (car form))
                             '("DEFSTRUCT" "DEFCLASS" "DEFINE-CONDITION") :test #'string=))
            (dolist (pair (struct-generated-names form))
              (unless (gethash (string-upcase (car pair)) gen)
                (setf (gethash (string-upcase (car pair)) gen)
                      (list (file-model-path m) (node-line node) (cdr pair)))))))))
    (when (plusp (hash-table-count gen))
      (loop for m in (ctx-files ctx) do
        (let ((quoted (quoted-nodes m)))
        (dolist (node (fm-list-nodes m))
          (let ((h (node-head node)))
            (when (and h (>= (length h) 4)
                       ;; Quoted data and keyword-headed clauses are data, not
                       ;; calls: a (:viewer-exit-text ...) case clause is not a
                       ;; read of the VIEWER-EXIT-TEXT slot accessor.
                       (not (gethash node quoted))
                       (not (keywordp (car (node-form node))))
                       (not (loop for (sp sp-s sp-e) in defspans
                                  thereis (and (string= sp (file-model-path m))
                                               (<= sp-s (node-start node))
                                               (>= sp-e (node-end node))))))
              (let ((info (gethash h gen)))
                (when (and info
                           (before-in-load-order-p ctx (file-model-path m) (node-line node)
                                                   (first info) (second info)))
                  (emit (make-diagnostic "defstruct-after-use" :warning
                                         (file-model-path m) (node-line node) (node-col node)
                                         (format nil "~A (~A) is used before its definition at ~
~A:~D; the call cannot be inlined"
                                                 h (third info)
                                                 (short-name (first info)) (second info)))
                        out)))))))))))

(defun quoted-nodes (model)
  "Eq-set of every node inside a QUOTE form of MODEL. Quoted data is not a call
site, so a generated accessor name appearing in it must not be reported."
  (let ((h (make-hash-table :test 'eq)))
    (labels ((mark (n)
               (dolist (c (node-items n)) (setf (gethash c h) t) (mark c))))
      (dolist (n (fm-list-nodes model))
        (when (node-is n "QUOTE") (mark n))))
    h))

(defun rule-internal-symbol-leak (model ctx out)
  "A cross-package PKG:: reference appearing in SOURCE. Strings cannot match: the
rule sees parsed symbol nodes, so a \"::\" inside a string is never a symbol."
  (declare (ignore ctx))
  (let ((own (file-model-package model)))
    (dolist (node (fm-all-nodes model))
      (when (eq (node-kind node) :symbol)
        (let ((raw (node-raw node)))
          (when (and (stringp raw) (search "::" raw))
            (let* ((pos (search "::" raw))
                   (pkg (string-upcase (subseq raw 0 pos))))
              (unless (or (string= pkg own)
                          (member pkg '("CL" "COMMON-LISP" "CL-USER" "CL-USER::" "KEYWORD"
                                        "KEYWORD::" "LINTSP")
                                  :test #'string=)
                          (and (>= (length pkg) 3) (string= (subseq pkg 0 3) "SB-")))
                (emit (make-diagnostic "internal-symbol-leak" :warning
                                       (file-model-path model) (node-line node) (node-col node)
                                       (format nil "~A reaches past the package boundary; ~
export it or move the API" raw))
                      out)))))))))

(defun quoted-export-names (x)
  "The symbol names an EXPORT argument X names: a quoted symbol, a quoted list,
or a bare symbol. NIL for anything else (a computed list is not readable)."
  (cond ((and (consp x) (equal (form-symbol-name (car x)) "QUOTE") (cdr x))
         (let ((d (second x)))
           (cond ((symbolp d) (list (symbol-name d)))
                 ((and (listp d) (proper-list-p d))
                  (remove nil (mapcar #'form-symbol-name d)))
                 (t nil))))
        ((symbolp x) (list (symbol-name x)))
        (t nil)))

(defun quoted-export-package (x)
  "The package name designator X names, or NIL. A quoted symbol, a keyword, a
bare symbol, or a string; a computed designator is not readable."
  (cond ((and (consp x) (equal (form-symbol-name (car x)) "QUOTE") (cdr x))
         (let ((d (second x)))
           (cond ((and (symbolp d) (not (keywordp d))) (string-upcase (symbol-name d)))
                 ((stringp d) (string-upcase d))
                 (t nil))))
        ((and (symbolp x) (not (keywordp x))) (string-upcase (symbol-name x)))
        ((stringp x) (string-upcase x))
        (t nil)))

(defun package-export-table (models)
  "Hash of uppercased package name -> hash of the symbol names it exports. A
DEFPACKAGE :EXPORT clause and a top-level (EXPORT ...) call both count, unioned
over every one in MODELS: ekko/platform exports initialize-assets with an
(export '(...)) call, not in its defpackage, and a checker that ignored that
would cry wolf. A package declared or extended twice is one entry."
  (let ((out (make-hash-table :test #'equal)))
    (flet ((set-for (pname)
             (or (gethash pname out)
                 (setf (gethash pname out) (make-hash-table :test #'equal)))))
      (dolist (m models)
        (let ((own (file-model-package m)))
          (dolist (n (top-level-forms (file-model-nodes m)))
            (let ((f (node-form n)))
              (cond
                ((and (consp f) (equal (form-symbol-name (car f)) "DEFPACKAGE"))
                 (let ((pname (string-upcase (or (form-symbol-name (second f)) ""))))
                   (unless (zerop (length pname))
                     (let ((set (set-for pname)))
                       (dolist (e (exported-names (list n))) (setf (gethash e set) t))))))
                ((and (consp f) (equal (form-symbol-name (car f)) "EXPORT") (cdr f))
                 (let ((names (quoted-export-names (second f)))
                       (pkg (or (and (cddr f) (quoted-export-package (third f))) own)))
                   (when (and pkg (not (zerop (length pkg))))
                     (let ((set (set-for pkg)))
                       (dolist (s names) (setf (gethash s set) t))))))))))))
    out))

(defun ctx-package-export-table (ctx)
  "The analysed set's package -> :export table, built once per run."
  (or (ctx-package-exports ctx)
      (setf (ctx-package-exports ctx)
            (package-export-table (ctx-files ctx)))))

(defun rule-unexported-external-reference (model ctx out)
  "A PKG:SYM reference with a SINGLE colon whose SYM the analysed DEFPACKAGE for
PKG does not export. This is the reader error that the internal-symbol-leak fix
can introduce: narrowing a PKG::SYM reference to PKG:SYM is only sound when SYM
really is external. Strings cannot match (only parsed symbol nodes are read). A
package whose DEFPACKAGE is not in the analysed set is NOT reported: its exports
cannot be checked, and guessing that one is external is what produced the slope
regression."
  (let ((table (and ctx (ctx-package-export-table ctx))))
    (when table
      (dolist (node (fm-all-nodes model))
        (when (eq (node-kind node) :symbol)
          (let* ((raw (node-raw node))
                 (pos (and (stringp raw) (position #\: raw))))
            (when (and pos (plusp pos)
                       (not (char= (char raw (1+ pos)) #\:)))   ; not PKG::SYM
              (let* ((pkg (string-upcase (subseq raw 0 pos)))
                     (sym (string-upcase (subseq raw (1+ pos))))
                     (exports (gethash pkg table)))
                (when (and exports (plusp (length sym)) (not (gethash sym exports)))
                  (emit (make-diagnostic "unexported-external-reference" :warning
                                         (file-model-path model) (node-line node) (node-col node)
                                         (format nil "~A uses a single colon but ~A does not export ~A; ~
reading it signals a package error"
                                                 raw pkg sym))
                        out))))))))))


(defun rule-earmuffs (model ctx out)
  "A special variable named without *earmuffs*."
  (declare (ignore ctx))
  (dolist (node (top-level-forms (file-model-nodes model)))
    (let ((form (node-form node)))
      (when (and (consp form) (symbolp (car form)))
        (let ((h (symbol-name (car form)))
              (name (form-symbol-name (second form))))
          (when (and name (member h '("DEFVAR" "DEFPARAMETER") :test #'string=)
                     (not (and (plusp (length name))
                               (char= (char name 0) #\*)
                               (char= (char name (1- (length name))) #\*))))
            (emit (make-diagnostic "earmuffs" :note
                                   (file-model-path model) (node-line node) (node-col node)
                                   (format nil "(~A ~A) names a special without earmuffs; bind it ~
with LET and you rebind global state" (string-downcase h) name))
                  out)))))))

(defun rule-constant-looking-parameter (model ctx out)
  "A defparameter whose name uses the +constant+ convention."
  (declare (ignore ctx))
  (dolist (node (top-level-forms (file-model-nodes model)))
    (let ((form (node-form node)))
      (when (and (consp form) (symbolp (car form))
                 (string= (symbol-name (car form)) "DEFPARAMETER"))
        (let ((name (form-symbol-name (second form))))
          (when (and name (plusp (length name))
                     (char= (char name 0) #\+)
                     (char= (char name (1- (length name))) #\+))
            (emit (make-diagnostic "defparameter-named-like-constant" :note
                                   (file-model-path model) (node-line node) (node-col node)
                                   (format nil "(defparameter ~A) is named like a constant but ~
is rebindable" name))
                  out)))))))

(defun top-level-function-nodes (model)
  (remove-if-not (lambda (n) (member (node-head n)
                                     '("DEFUN" "DEFMACRO" "DEFMETHOD") :test #'string=))
                 (top-level-forms (file-model-nodes model))))

;;; LONG-FUNCTION and DEEP-NESTING are separate rules but map to one function in
;;; the registry, so a single function that emitted both ran twice and emitted
;;; every finding twice. One function per rule: one emission, and --disable on
;;; one name no longer drags the other's findings along with it.

(defun rule-long-function (model ctx out)
  "Overlong function bodies — a note, not a defect."
  (dolist (node (top-level-function-nodes model))
    (let* ((form (node-form node))
           (name (or (form-symbol-name (second form)) "?"))
           (span (- (node-line-end node) (node-line node))))
      (when (>= span (ctx-long-lines ctx))
        (emit (make-diagnostic "long-function" :note
                               (file-model-path model) (node-line node) (node-col node)
                               (format nil "~A ~A spans ~D lines (threshold ~D)"
                                       (string-downcase (node-head node)) name span
                                       (ctx-long-lines ctx)))
              out)))))

(defun rule-deep-nesting (model ctx out)
  "Deeply nested function bodies — a note, not a defect."
  (dolist (node (top-level-function-nodes model))
    (let* ((form (node-form node))
           (name (or (form-symbol-name (second form)) "?"))
           (depth (form-depth (node-form node) 1)))
      (when (>= depth (ctx-deep-depth ctx))
        (emit (make-diagnostic "deep-nesting" :note
                               (file-model-path model) (node-line node) (node-col node)
                               (format nil "~A ~A reaches list depth ~D (threshold ~D)"
                                       (string-downcase (node-head node)) name depth
                                       (ctx-deep-depth ctx)))
              out)))))

(defun form-depth (form d)
  (cond ((stringp form) d)
        ((vectorp form)
         (let ((m d))
           (loop for i from 0 below (length form)
                 do (setf m (max m (form-depth (aref form i) (1+ d)))))
           m))
        ((consp form)
         (let ((m d))
           (loop for tail = form then (cdr tail)
                 while (consp tail)
                 do (setf m (max m (form-depth (car tail) (1+ d)))))
           m))
        (t d)))

;;; ------------------------------------------------------------- cross-file rules

(defun rule-dead-definition (model ctx out)
  "A top-level definition referenced nowhere in the analysed files. Sits near
name-dispatched handlers by design, so --allow-definition exists."
  ;; Cross-file: run once for the whole set, not once per file.
  (unless (eq model (first (ctx-files ctx))) (return-from rule-dead-definition nil))
  (dolist (m (ctx-files ctx))
    (dolist (node (top-level-forms (file-model-nodes m)))
      (multiple-value-bind (kind name line) (top-level-def node)
        (when (and name
                   (member kind '("DEFUN" "DEFMACRO" "DEFVAR" "DEFPARAMETER" "DEFCONSTANT")
                           :test #'string=)
                   (zerop (ctx-ref-count ctx name))
                   (not (gethash name (ctx-exports ctx)))
                   (not (member name (ctx-allow-definitions ctx) :test #'string=)))
          (emit (make-diagnostic "dead-definition" :warning
                                 (file-model-path m) line (node-col node)
                                 (format nil "~A ~A is never referenced in the analysed files; ~
delete it, or --allow-definition it if a name-dispatched handler reaches it"
                                         (string-downcase kind) name))
                out))))))

(defun rule-duplicated-literal-table (model ctx out)
  ;; Cross-file: run once for the whole set, not once per file.
  (unless (eq model (first (ctx-files ctx))) (return-from rule-duplicated-literal-table nil))
  (let ((tables nil))                   ; (path file-index line symbols)
    (loop for m in (ctx-files ctx) for idx from 0 do
      (dolist (node (fm-list-nodes m))
        (when (and (node-is node "QUOTE") (node-aligned node))
          (let ((data (second (node-items node))))
            (when (and data (eq (node-kind data) :list))
              (let ((syms (mapcar (lambda (c) (or (node-sym-name c) (node-raw c)))
                                  (node-items data))))
                (when (and (>= (length syms) 8)
                           (every (lambda (s) (and s (plusp (length s))))
                                  syms)
                           (every #'symbolp (node-elements data)))
                  (push (list (file-model-path m) idx (node-line node) syms) tables))))))))
    (let ((arr (coerce (nreverse tables) 'vector))
          (seen (make-hash-table :test #'equal)))
      (loop for i from 0 below (length arr) do
        (loop for j from (1+ i) below (length arr) do
          (let* ((a (aref arr i)) (b (aref arr j))
                 (path-a (first a)) (path-b (first b))
                 (line-a (third a)) (line-b (third b))
                 (sa (fourth a)) (sb (fourth b)))
            ;; Arrays are in load order; compare by (file-index, line). Ordering
            ;; two different files by their line numbers has no meaning.
            (when (or (< (second a) (second b))
                      (and (= (second a) (second b)) (< line-a line-b)))
              (let ((seta (remove-duplicates sa :test #'string=))
                    (setb (remove-duplicates sb :test #'string=)))
                (let ((shared (count-if (lambda (x) (member x setb :test #'string=)) seta))
                      (only-a (sort (remove-if (lambda (x) (member x setb :test #'string=)) seta)
                                    #'string<))
                      (only-b (sort (remove-if (lambda (x) (member x seta :test #'string=)) setb)
                                    #'string<)))
                  (when (and (>= shared 8)
                             (<= (+ (length only-a) (length only-b)) 16)
                             (or only-a only-b))
                    (let ((key (list path-a sa path-b sb)))
                      (unless (gethash key seen)
                        (setf (gethash key seen) t)
                        (emit (make-diagnostic
                               "duplicated-literal-table" :warning
                               path-b line-b 1
                               (format nil "key list matches ~A:~D but has drifted; ~
missing here: ~A; extra here: ~A"
                                       (short-name path-a) line-a
                                       (if only-a (format nil "~{~A~^ ~}" only-a) "(none)")
                                       (if only-b (format nil "~{~A~^ ~}" only-b) "(none)")))
                              out)))))))))))))

(defun definition-index (ctx)
  "Hash NAME -> (LINE PATH) of the first definition in load order. Cached on the
context: rebuilding it per file is what makes a large tree quadratic."
  (or (ctx-defindex ctx)
      (setf (ctx-defindex ctx)
            (let ((defined (make-hash-table :test #'equal)))
              (loop for m in (ctx-files ctx) do
                (dolist (node (top-level-forms (file-model-nodes m)))
                  (multiple-value-bind (kind name line) (top-level-def node)
                    (when (and name (member kind '("DEFVAR" "DEFPARAMETER" "DEFCONSTANT"
                                                   "DEFUN" "DEFMACRO")
                                             :test #'string=))
                      (unless (gethash name defined)
                        (setf (gethash name defined) (list line (file-model-path m))))))))
              defined))))

(defun specials-forward-pass (model ctx out)
  "Special variables referenced in MODEL before their definition."
  (let ((defined (definition-index ctx)))
    (dolist (node (fm-all-nodes model))
      (when (eq (node-kind node) :symbol)
        (let* ((name (node-sym-name node))
               (d (and name (gethash name defined))))
          (when (and d
                     (before-in-load-order-p ctx (file-model-path model) (node-line node)
                                             (second d) (first d))
                     (gethash name (ctx-specials ctx))
                     (not (member name (ctx-allow-symbols ctx) :test #'string=)))
            (emit (make-diagnostic "forward-reference" :note
                                   (file-model-path model) (node-line node) (node-col node)
                                   (format nil "special ~A is used before its definition; the ~
reference compiles as an untyped global lookup" name))
                  out)))))))

(defun rule-forward-reference (model ctx out)
  "Load-time uses of a function or special variable before its definition.
A call inside a function body runs later, so it is not reported: only top-level
forms (which LOAD evaluates immediately) and special variables (where an unbound
reference silently becomes a new global). Cross-file claims are made only when
the load order is actually known — otherwise a name defined in another
unordered file (a test framework's CHECK, say) is not a forward reference at
all. Emitted at most once per (name, file)."
  ;; Cross-file: run once for the whole set.
  (unless (eq model (first (ctx-files ctx))) (return-from rule-forward-reference nil))
  (let ((defined (definition-index ctx))
        (seen (make-hash-table :test #'equal)))
    (loop for m in (ctx-files ctx) do
      (dolist (node (top-level-forms (file-model-nodes m)))
        (unless (top-level-def node)
          (dolist (name (remove-duplicates (node-refs node) :test #'string=))
            (let ((d (gethash name defined)))
              (when (and d
                         (before-in-load-order-p ctx (file-model-path m) (node-line node)
                                                 (second d) (first d))
                         (not (member name (ctx-allow-symbols ctx) :test #'string=))
                         (not (gethash (list name (file-model-path m)) seen)))
                (setf (gethash (list name (file-model-path m)) seen) t)
                (emit (make-diagnostic "forward-reference" :note
                                       (file-model-path m) (node-line node) (node-col node)
                                       (format nil "~A is used at load time before it is ~
defined (later in load order)" name))
                      out))))))))
  (specials-forward-pass model ctx out))

(defun node-line-end (node)
  (or (node-end-line node) (node-line node)))

;;; ------------------------------------------------------------------- the list

(defrule "optional-and-key" :node :warning t
  "a lambda list containing both &OPTIONAL and &KEY (not auto-fixed: splitting it is an API change)")
(defrule "quadratic-append" :node :warning t
  "(setf x (append x (list y))) — copies the whole list on every call (not auto-fixed: the correct rewrite reorders the accumulation or needs an nreverse at the use site)")
(defrule "self-concatenating-accumulator" :node :note t
  "(setf x (concatenate 'string x ...)) or (setf x (append x ...)) - CONCATENATE copies each argument and APPEND copies every argument but the last, so the accumulator is copied in full on every call (not auto-fixed: the correct rewrite reorders the accumulation or needs a string stream)")
(defrule "nth-indexed-list-loop" :node :note nil
  "an index-driven walk over a list: a DOTIMES/DO/DO*/LOOP whose own bound is (length X) and whose body indexes X by the loop variable with NTH, MEMBER or TAILP - all three are defined only for lists, so list-ness is read off the form with no type inference; off by default, no occurrence was found across ~40k LOC of real code, so it is opt-in (--enable nth-indexed-list-loop; not auto-fixed: replacing the walk is a design change)")
(defrule "ignore-then-read" :file :warning t
  "a (declare (ignore x)) on a parameter the body then reads or writes (variable namespace only: a call position is a function reference, not a read). fix deletes a false declaration")
(defrule "unused-binding" :file :note t
  "a lexical binding never referenced (fix deletes a LET/LET* binding whose init form is side-effect-free)")
(defrule "unused-parameter" :file :note t
  "a lambda-list parameter never referenced")
(defrule "defstruct-after-use" :file :warning t
  "a structure accessor used before the DEFSTRUCT that defines it (not auto-fixed: structural, needs reordering or an .asd edit)")
(defrule "internal-symbol-leak" :file :warning t
  "a cross-package PKG:: reference in source, strings excluded (fix narrows it to PKG: only when the analysed set has a DEFPACKAGE for PKG whose :export already lists the symbol; the fix never creates an export, and refuses report-only otherwise)")
(defrule "unexported-external-reference" :file :warning t
  "a PKG:SYM reference with a single colon whose SYM the analysed DEFPACKAGE for PKG does not export, strings excluded (not auto-fixed: the reference is a reader error, not a rewrite; a package whose DEFPACKAGE is not in the analysed set is not reported)")
(defrule "earmuffs" :file :note t
  "a special variable named without *earmuffs*")
(defrule "defparameter-named-like-constant" :file :note nil
  "a defparameter whose name uses the +constant+ convention; off by default, it is a project policy not a defect (autolith's AGENTS.md forbids defconstant), so fix never rewrites it")
(defrule "dead-definition" :file :warning t
  "a top-level definition referenced nowhere in the analysed files (not auto-fixed: name-dispatched handlers reach definitions the reader cannot see)")
(defrule "long-function" :file :note t
  "a function body longer than the line threshold (not auto-fixed: splitting a function is a design change)")
(defrule "deep-nesting" :file :note nil
  "a form nested deeper than the depth threshold; off by default, ordinary test bodies clear depth 10-12 (--deep-nesting-depth N to tune; not auto-fixed: flattening is a design change)")
(defrule "duplicated-literal-table" :file :warning t
  "two near-identical literal key lists with a divergence (not auto-fixed: which side is right is a judgement)")
(defrule "forward-reference" :file :note nil
  "a load-time use of a name before its definition; off by default, a reader cannot tell a quoted test name from a load-time call")

(defun rule-default-on-p (name)
  (let ((r (find name *rules* :key #'rule-name :test #'string=)))
    (and r (rule-default r))))
