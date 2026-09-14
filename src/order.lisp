;;;; lintsp — load-order discovery.
;;;; Order comes from (1) an explicit --order file, or (2) a discovered source:
;;;; an .asd's dependency-resolved component order, or a slope-style literal list
;;;; of "*.lisp" strings handed to a loader.
;;;; A discovered order is used only when it is the ONLY source and the analysed
;;;; set has one root. More than one root, or more than one source that
;;;; disagrees, or no source at all, means the order is not known: taking one
;;;; project's list and applying it to every other project turns every cross-file
;;;; rule into a guess. When the order is not known the hash is empty and rules
;;;; confine themselves to same-file cases, saying so in the summary.

(in-package #:lintsp)

(defun quoted-string-lists (path)
  "All (quote (\"a.lisp\" ...)) literal lists of .lisp strings in PATH, in source
order. This is how a project that has no .asd spells its load order."
  (let ((out nil))
    (multiple-value-bind (nodes src err) (read-file path)
      (declare (ignore src err))
      (labels ((rec (n)
                 (when (eq (node-kind n) :list)
                   (let ((f (node-form n)))
                     (when (and (consp f) (eq (car f) 'quote)
                                (listp (second f))
                                (every (lambda (x) (and (stringp x)
                                                        (> (length x) 5)
                                                        (string= (subseq x (- (length x) 5)) ".lisp")))
                                       (second f)))
                       (push (second f) out)))
                   (dolist (c (node-items n)) (rec c)))))
        (dolist (n nodes) (rec n))))
    (nreverse out)))

;;; ------------------------------------------------------------ .asd components
;;; The :components lists of one .asd name several systems, and a system's place
;;; in the load order is decided by its :depends-on graph, not by its position in
;;; the file. Reading the file top to bottom and concatenating every (:file ...)
;;; is what put ekko's src/geometry AFTER src/client even though ekko/client's
;;; system depends on ekko/scene: a flattened order where the dependency order is
;;; what matters. The systems are topologically sorted instead.

(defun component-files (v)
  "Relative file names declared by an ASDF :components list V, in order.
Nested (:module \"x\" :components (...)) lists are walked in place."
  (let ((out nil))
    (dolist (c v)
      (when (and (consp c) (symbolp (car c)))
        (let ((key (symbol-name (car c))) (arg (second c)))
          (cond ((string= key "FILE") (when (stringp arg) (setf out (append out (list arg)))))
                ((member key '("MODULE" "SYSTEM") :test #'string=)
                 (loop for (k val) on (cddr c) by #'cddr do
                   (when (and (equal (form-symbol-name k) "COMPONENTS") (listp val))
                     (setf out (append out (component-files val))))))
                ((string= key "COMPONENTS")
                 (when (listp arg) (setf out (append out (component-files arg)))))))))
    out))

(defun asd-system-forms (path)
  "Every (NAME DEPS FILES) declared by a DEFSYSTEM in PATH, in file order."
  (let ((out nil))
    (multiple-value-bind (nodes src err) (read-file path)
      (declare (ignore src err))
      (dolist (n (top-level-forms nodes))
        (let ((f (node-form n)))
          (when (and (consp f) (string= (form-symbol-name (car f)) "DEFSYSTEM")
                     (stringp (second f)))
            (let ((deps nil) (files nil))
              (loop for (k v) on (cddr f) by #'cddr do
                (let ((key (form-symbol-name k)))
                  (cond ((equal key "DEPENDS-ON")
                         (dolist (d v) (when (stringp d) (push d deps))))
                        ((equal key "COMPONENTS")
                         (setf files (append files (component-files v)))))))
              (push (list (second f) (nreverse deps) files) out))))))
    (nreverse out)))

(defun asd-order-files (path)
  "Component file names of PATH's systems, ordered so that a system's in-set
dependencies load before it. Declaration order breaks ties."
  (let ((systems (asd-system-forms path))
        (done nil) (out nil))
    (labels ((visit (s)
               (unless (member (first s) done :test #'string=)
                 (push (first s) done)
                 (dolist (d (second s))
                   (let ((dep (find d systems :key #'first :test #'string=)))
                     (when dep (visit dep))))
                 (setf out (append out (third s))))))
      (dolist (s systems) (visit s)))
    out))

(defun index-order-strings (strings dir order)
  "Map each relative file name in STRINGS (relative to DIR) to the next index.
An ASDF :file component omits the .lisp type, so try that too."
  (dolist (s strings)
    (let* ((p (merge-pathnames s dir))
           (tp (or (ignore-errors (probe-file p))
                   (ignore-errors (probe-file (merge-pathnames (concatenate 'string s ".lisp") dir)))
                   (ignore-errors (probe-file (merge-pathnames (concatenate 'string s ".asd") dir)))
                   p))
           (key (namestring (or (ignore-errors (truename tp)) tp))))
      (unless (gethash key order)
        (setf (gethash key order) (hash-table-count order))))))

;;; ------------------------------------------------------------------ discovery

(defun order-keys (h)
  "Keys of H, sorted by their assigned load position."
  (sort (loop for k being the hash-keys of h collect k) #'<
        :key (lambda (k) (gethash k h))))

(defun discover-orders (files asd-files)
  "Candidate load-order sources, each (DESCRIPTION . ORDER-HASH): one per .asd
(dependency-resolved), one per file that holds literal \"*.lisp\" load lists (all
of one file's lists are one source, in source order)."
  (let ((out nil))
    (dolist (a asd-files)
      (let ((strings (asd-order-files a)))
        (when strings
          (let ((h (make-hash-table :test #'equal)))
            (index-order-strings strings (make-pathname :directory (pathname-directory a)) h)
            (when (plusp (hash-table-count h))
              (push (cons (format nil "~A (:components)" (file-namestring a)) h) out))))))
    (dolist (f files)
      (let ((lists (quoted-string-lists f)))
        (when lists
          (let ((h (make-hash-table :test #'equal)))
            (index-order-strings (apply #'append lists)
                                 (make-pathname :directory (pathname-directory f)) h)
            (when (plusp (hash-table-count h))
              (push (cons (format nil "~A (literal load list)" (file-namestring f)) h) out))))))
    (nreverse out)))

(defun order-conflict-p (h1 h2)
  "True when H1 and H2 put a pair of files they both place in the opposite
relative order."
  (let* ((shared (coerce (loop for k being the hash-keys of h1
                               when (gethash k h2) collect k)
                         'vector))
         (n (length shared)))
    (loop for i from 0 below n do
      (loop for j from (1+ i) below n do
        (let ((a (aref shared i)) (b (aref shared j)))
          (when (/= (signum (- (gethash a h1) (gethash b h1)))
                    (signum (- (gethash a h2) (gethash b h2))))
            (return-from order-conflict-p t)))))
    nil))

(defun merge-orders (candidates)
  "Concatenate candidate orders, first occurrence winning. Safe once the
candidates are known to agree on every file pair they both place."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (c candidates)
      (dolist (k (order-keys (cdr c)))
        (unless (gethash k h)
          (setf (gethash k h) (hash-table-count h)))))
    h))

(defun build-order (files asd-files order-file root-count)
  "Return (values ORDER-HASH SOURCE-DESCRIPTION). ORDER-HASH maps a namestring to
its load position for every file whose position is known; it is empty, and
SOURCE-DESCRIPTION NIL, exactly when no single coherent order exists: several
roots were analysed at once, or the discovered sources disagree, or none was
found. An explicit --order is always taken as the order."
  (when order-file
    (let ((h (make-hash-table :test #'equal)))
      (with-open-file (in order-file)
        (loop for line = (read-line in nil nil)
              while line
              do (let ((p (string-trim '(#\Space #\Tab #\Return) line)))
                   (when (and (plusp (length p)) (not (char= (char p 0) #\#)))
                     (index-order-strings
                      (list p) (make-pathname :directory (pathname-directory (pathname order-file)))
                      h)))))
      (return-from build-order (values h (format nil "--order ~A" order-file)))))
  (let ((candidates (discover-orders files asd-files)))
    (cond
      ((null candidates) (values (make-hash-table :test #'equal) nil))
      ;; One project's load list applied to another project is not an order.
      ((> root-count 1) (values (make-hash-table :test #'equal) nil))
      ((loop for (x . hx) in candidates
             thereis (loop for (y . hy) in candidates
                           thereis (and (not (eq hx hy)) (order-conflict-p hx hy))))
       (values (make-hash-table :test #'equal) nil))
      (t (values (merge-orders candidates)
                 (format nil "~{~A~^, ~}" (mapcar #'car candidates)))))))

(defun order-index (ctx path)
  (gethash (namestring (or (ignore-errors (truename path)) path)) (ctx-order ctx)))

(defun sort-by-order (files order)
  "Files with a known load position first, in that order; the rest by name."
  (sort (copy-list files)
        (lambda (a b)
          (let ((ia (gethash (namestring (or (ignore-errors (truename a)) a)) order))
                (ib (gethash (namestring (or (ignore-errors (truename b)) b)) order)))
            (cond ((and ia ib) (< ia ib))
                  (ia t) (ib nil)
                  (t (string< (namestring a) (namestring b))))))))
