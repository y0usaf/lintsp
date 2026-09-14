;;;; Build an executable image. Run from the source directory:
;;;;   sbcl --non-interactive --load build.lisp
;;;; Produces ./lintsp, a single binary (strictix shape: one thing that runs).

(require :asdf)

(defvar *here*
  (or *load-truename* (merge-pathnames "build.lisp" (uiop:getcwd))))

(defvar *dir*
  (make-pathname :name nil :type nil :version nil :defaults *here*))

(asdf:load-asd (merge-pathnames "lintsp.asd" *dir*))

(asdf:load-system "lintsp")

(format t "~&lintsp: system loaded~%")

;; Resolve RUN at run time: a package-qualified reference here would have to be
;; read before LINTSP exists, which is a reader error.
(defvar *entry*
  (let ((run (find-symbol "RUN" "LINTSP")))
    (unless run (error "LINTSP:RUN is missing after loading the system"))
    run))

(sb-ext:save-lisp-and-die (merge-pathnames "lintsp" *dir*)
                          :executable t
                          :save-runtime-options t
                          :toplevel (lambda ()
                                      (funcall *entry* (uiop:command-line-arguments))))
