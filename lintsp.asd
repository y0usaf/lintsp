(asdf:defsystem "lintsp"
  :description "Reader-only Common Lisp linter: parses source with the host reader and reports structural pathologies."
  :version "0.1.0"
  :license "AGPL-3.0-only"
  :serial t
  :components ((:file "src/package")
               (:file "src/core")
               (:file "src/rules")
               (:file "src/order")
               (:file "src/simplify")
               (:file "src/house")
               (:file "src/cli")
               (:file "src/fix")))
