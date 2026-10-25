;;; rmsbolt-test.el --- Tests for rmsbolt  -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for rmsbolt

;;; Code:

(require 'el-mock nil t)
(require 'rmsbolt)

(ert-deftest sanity-check-ert ()
  "Check if ERT is working. :)"
  (should t))

(defun test-asm-preprocessor (pre post)
  "Tests the asm preprocessor on the current buffer."
  (insert-file-contents pre)
  (setq-local buffer-file-name (expand-file-name default-directory))
  (let
      ((source
        (string-trim
         (string-join
          (rmsbolt--process-asm-lines (current-buffer)
                                      (split-string (buffer-string) "\n" t))
          "\n")))
       (target
        (with-temp-buffer
          (insert-file-contents post)
          (string-trim
           (buffer-string)))))
    (should (string= source target))))

;;;; Filtration tests

(ert-deftest filter-tests-all-c ()
  "Test if assembly filteration in c is working."
  (with-temp-buffer
    (setq-local rmsbolt-disassemble nil)
    (setq-local rmsbolt-filter-comment-only t)
    (setq-local rmsbolt-filter-directives t)
    (setq-local rmsbolt-filter-labels t)
    (test-asm-preprocessor "test/rmsbolt-c-pre1.s" "test/rmsbolt-c-post1.s")))
(ert-deftest filter-tests-none-c ()
  "Test if assembly filteration in c is working."
  (with-temp-buffer
    (setq-local rmsbolt-disassemble nil)
    (setq-local rmsbolt-filter-comment-only nil)
    (setq-local rmsbolt-filter-directives nil)
    (setq-local rmsbolt-filter-labels nil)
    (test-asm-preprocessor "test/rmsbolt-c-pre1.s" "test/rmsbolt-c-post2.s")))
(ert-deftest filter-tests-dir-c ()
  "Test if assembly filteration in c is working."
  (with-temp-buffer
    (setq-local rmsbolt-disassemble nil)
    (setq-local rmsbolt-filter-comment-only nil)
    (setq-local rmsbolt-filter-directives t)
    (setq-local rmsbolt-filter-labels nil)
    (test-asm-preprocessor "test/rmsbolt-c-pre1.s" "test/rmsbolt-c-post3.s")))
(ert-deftest filter-tests-weak-ref-c ()
  "Test if assembly filteration in c is working."
  (with-temp-buffer
    (setq-local rmsbolt-disassemble nil)
    (setq-local rmsbolt-filter-comment-only nil)
    (setq-local rmsbolt-filter-directives t)
    (setq-local rmsbolt-filter-labels t)
    (test-asm-preprocessor "test/rmsbolt-c-pre2.s" "test/rmsbolt-c-post4.s")))

;;;; Demangler tests

(ert-deftest demangler-test-disabled ()
  (with-temp-buffer
    (setq-local rmsbolt-demangle nil)
    (should
     (string-empty-p
      (rmsbolt--demangle-command
       ""
       (make-rmsbolt-lang :demangler nil)
       (current-buffer))))))

(ert-deftest demangler-test-invalid-demangler ()
  (with-temp-buffer
    (setq-local rmsbolt-demangle t)
    (should
     (string-empty-p
      (rmsbolt--demangle-command
       ""
       (make-rmsbolt-lang :demangler nil)
       (current-buffer))))))

(ert-deftest demangler-test-not-path ()
  (with-temp-buffer
    (setq-local rmsbolt-demangle t)
    (should
     (string-empty-p
      (rmsbolt--demangle-command
       ""
       (make-rmsbolt-lang :demangler "nonsense-binary-name-not-on-path")
       (current-buffer))))))

(ert-deftest demangler-test-valid-demangler ()
  ;; Assumes test is on the path!
  (with-temp-buffer
    (setq-local rmsbolt-demangle t)
    (should
     (string-match-p
      (regexp-opt '("test"))
      (rmsbolt--demangle-command
       ""
       (make-rmsbolt-lang :demangler "test")
       (current-buffer))))))

;;;; Output chunk navigation tests

(defmacro rmsbolt-test--with-chunk-buffers (&rest body)
  "Run BODY with a fake rmsbolt output buffer and its source buffer.
The output buffer has eight lines.  Source line 5 maps to the chunks on
lines 1-2 and 6-7, and source line 6 maps to line 4.  The mapping is
stored out of order to exercise sorting."
  (declare (indent 0) (debug (body)))
  `(let ((src-buffer (generate-new-buffer " *rmsbolt-test-src*"))
         (output-buffer (get-buffer-create rmsbolt-output-buffer)))
     (unwind-protect
         (progn
           (with-current-buffer src-buffer
             (setq rmsbolt-line-mapping (make-hash-table :test #'eq))
             (puthash 5 '((6 . 7) (1 . 2)) rmsbolt-line-mapping)
             (puthash 6 '((4 . 4)) rmsbolt-line-mapping))
           (with-current-buffer output-buffer
             (erase-buffer)
             (insert "a\nb\nc\nd\ne\nf\ng\nh\n")
             (setq rmsbolt-src-buffer src-buffer)
             (dolist (chunk '((1 2 5) (4 4 6) (6 7 5)))
               (goto-char (point-min))
               (forward-line (1- (nth 0 chunk)))
               (dotimes (_ (1+ (- (nth 1 chunk) (nth 0 chunk))))
                 (add-text-properties (line-beginning-position)
                                      (line-end-position)
                                      `(rmsbolt-src-line ,(nth 2 chunk)))
                 (forward-line 1))))
           ,@body)
       (kill-buffer src-buffer)
       (kill-buffer output-buffer))))

(ert-deftest output-chunks-sorted-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (should (equal (rmsbolt--output-chunks 5) '((1 . 2) (6 . 7))))
      (should (equal (rmsbolt--output-chunks 6) '((4 . 4))))
      (should-not (rmsbolt--output-chunks 42)))
    ;; Sorting must not change the stored mapping.
    (with-current-buffer src-buffer
      (should (equal (gethash 5 rmsbolt-line-mapping) '((6 . 7) (1 . 2)))))))

(ert-deftest output-chunk-forward-and-backward-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (goto-char (point-min))
      (rmsbolt-output-forward-chunk)
      (should (= (line-number-at-pos) 6))
      (rmsbolt-output-forward-chunk)
      (should (= (line-number-at-pos) 1))
      (rmsbolt-output-backward-chunk)
      (should (= (line-number-at-pos) 6))
      (rmsbolt-output-backward-chunk)
      (should (= (line-number-at-pos) 1)))))

(ert-deftest output-chunk-single-chunk-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (goto-char (point-min))
      (forward-line 3)
      (rmsbolt-output-forward-chunk)
      (should (= (line-number-at-pos) 4))
      (rmsbolt-output-backward-chunk)
      (should (= (line-number-at-pos) 4)))))

(ert-deftest output-chunk-unmapped-position-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (goto-char (point-min))
      (forward-line 2)
      (should-error (rmsbolt-output-forward-chunk) :type 'user-error)
      (should-error (rmsbolt-output-backward-chunk) :type 'user-error))))

(ert-deftest output-chunk-outside-output-buffer-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-temp-buffer
      (should-error (rmsbolt-output-forward-chunk) :type 'user-error)
      (should-error (rmsbolt-output-backward-chunk) :type 'user-error))))

;;;; Cargo integration tests

(ert-deftest cargo-extract-and-clean-cmd-test ()
  (let* ((sample-output
          (concat
           "   Compiling foo v0.1.0 (/tmp/ws/crates/foo)\n"
           "     Running `CARGO=/usr/bin/cargo "
           "rustc --crate-name build_script_build --edition=2024 build.rs "
           "--crate-type bin --emit=dep-info,link -C extra-filename=-111 "
           "--out-dir /tmp/ws/target/debug/build/foo-111`\n"
           "     Running `/tmp/ws/target/debug/build/foo-111/build-script-build`\n"
           "     Running `CARGO=/usr/bin/cargo CARGO_BIN_EXE_my-bin=/tmp/ws/target/debug/my-bin "
           "CARGO_PKG_DESCRIPTION='A `quoted` description\nwith newline' "
           "OUT_DIR=/tmp/ws/target/debug/build/foo-123/out "
           "rustc --crate-name foo_lib --edition=2024 src/lib.rs "
           "--error-format=json --json=diagnostic-rendered-ansi,artifacts "
           "--crate-type lib --emit=dep-info,metadata,link "
           "-C embed-bitcode=no -C debuginfo=2 "
           "--check-cfg 'cfg(feature, values(\"default\", \"loader\"))' "
           "-C metadata=abc -C extra-filename=-def "
           "--out-dir /tmp/ws/target/debug/deps "
           "-C incremental=/tmp/ws/target/debug/incremental "
           "-L dependency=/tmp/ws/target/debug/deps "
           "--print crate-name -C lto=thin`\n"
           "foo_lib\n"))
         (extracted (rmsbolt--extract-cargo-rustc-cmd sample-output "foo-lib"))
         (cleaned (rmsbolt--clean-cargo-rustc-cmd extracted))
         (build-extracted (rmsbolt--extract-cargo-rustc-cmd sample-output t))
         (build-cleaned (rmsbolt--clean-cargo-rustc-cmd build-extracted)))
    (should (equal (rmsbolt-split--tokenize cleaned)
                   '("env"
                     "CARGO=/usr/bin/cargo"
                     "CARGO_BIN_EXE_my-bin=/tmp/ws/target/debug/my-bin"
                     "CARGO_PKG_DESCRIPTION='A `quoted` description\nwith newline'"
                     "OUT_DIR=/tmp/ws/target/debug/build/foo-123/out"
                     "rustc"
                     "--crate-name" "foo_lib"
                     "--edition=2024"
                     "src/lib.rs"
                     "--crate-type" "lib"
                     "-C" "embed-bitcode=no"
                     "--check-cfg" "'cfg(feature, values(\"default\", \"loader\"))'"
                     "-C" "metadata=abc"
                     "-L" "dependency=/tmp/ws/target/debug/deps")))
    (should (equal (rmsbolt-split--tokenize build-cleaned)
                   '("env"
                     "CARGO=/usr/bin/cargo"
                     "rustc"
                     "--crate-name" "build_script_build"
                     "--edition=2024"
                     "build.rs"
                     "--crate-type" "bin")))))

(ert-deftest cargo-find-target-test ()
  (let* ((tmp-root (make-temp-file "rmsbolt-cargo-test-" t))
         (src-dir (expand-file-name "src" tmp-root))
         (tests-dir (expand-file-name "tests" tmp-root))
         (sub-crate-dir (expand-file-name "crates/sub" tmp-root))
         (sub-src-dir (expand-file-name "src" sub-crate-dir))
         (target-dir (expand-file-name "target" tmp-root))
         (deps-dir (expand-file-name "debug/deps" target-dir))
         (manifest (expand-file-name "Cargo.toml" tmp-root))
         (sub-manifest (expand-file-name "Cargo.toml" sub-crate-dir))
         (lib-rs (expand-file-name "lib.rs" src-dir))
         (main-rs (expand-file-name "main.rs" src-dir))
         (sub-rs (expand-file-name "asdl.rs" src-dir))
         (cli-rs (expand-file-name "cli.rs" src-dir))
         (dep-only-rs (expand-file-name "dep_only.rs" src-dir))
         (test-rs (expand-file-name "mini_sql.rs" tests-dir))
         (build-rs (expand-file-name "build.rs" tmp-root))
         (member-lib-rs (expand-file-name "lib.rs" sub-src-dir))
         (member-mod-rs (expand-file-name "helper.rs" sub-src-dir)))
    (unwind-protect
        (progn
          (make-directory src-dir t)
          (make-directory tests-dir t)
          (make-directory sub-src-dir t)
          (make-directory deps-dir t)
          (with-temp-file manifest (insert "[package]\nname = \"demo\"\n"))
          (with-temp-file sub-manifest (insert "[package]\nname = \"sub\"\n"))
          (with-temp-file lib-rs
            (insert "// mod cli;\nlet _ = \"mod cli;\";\npub mod asdl;\n"))
          (with-temp-file main-rs (insert "mod cli;\nfn main() {}\n"))
          (with-temp-file sub-rs (insert "pub fn f() {}\n"))
          (with-temp-file cli-rs (insert "pub fn g() {}\n"))
          (with-temp-file dep-only-rs (insert "pub fn d() {}\n"))
          (with-temp-file test-rs (insert "#[test] fn t() {}\n"))
          (with-temp-file build-rs (insert "#[path = \"src/asdl.rs\"]\nmod asdl;\nfn main() {}\n"))
          (with-temp-file member-lib-rs (insert "pub mod helper;\n"))
          (with-temp-file member-mod-rs (insert "pub fn h() {}\n"))
          (with-temp-file (expand-file-name "demo_bin-1234abcd.d" deps-dir)
            (insert "target/debug/deps/demo_bin-1234abcd.d: src/main.rs src/cli.rs src/dep_only.rs\n"))
          (let ((metadata
                 `((workspace_root . ,tmp-root)
                   (target_directory . ,target-dir)
                   (packages
                    . [((name . "demo")
                        (manifest_path . ,manifest)
                        (targets
                         . [((name . "demo")
                             (kind . ["lib"])
                             (src_path . ,lib-rs))
                            ((name . "demo-bin")
                             (kind . ["bin"])
                             (src_path . ,main-rs))
                            ((name . "mini_sql")
                             (kind . ["test"])
                             (required-features . ["feat-a" "feat-b"])
                             (src_path . ,test-rs))
                            ((name . "build-script-build")
                             (kind . ["custom-build"])
                             (src_path . ,build-rs))]))
                       ((name . "sub")
                        (manifest_path . ,sub-manifest)
                        (targets
                         . [((name . "sub")
                             (kind . ["rlib"])
                             (src_path . ,member-lib-rs))]))]))))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata lib-rs)))
                           '("--lib")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata sub-rs)))
                           '("--lib")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata main-rs)))
                           '("--bin" "demo-bin")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata cli-rs)))
                           '("--bin" "demo-bin")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata dep-only-rs)))
                           '("--bin" "demo-bin")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata test-rs)))
                           '("--test" "mini_sql" "--features" "feat-a,feat-b")))
            (should (rmsbolt--cargo-build-script-p
                     (cdr (rmsbolt--cargo-find-target metadata build-rs))))
            (should-not (rmsbolt--cargo-target-args
                         (cdr (rmsbolt--cargo-find-target metadata build-rs))))
            (should (equal (alist-get 'name (car (rmsbolt--cargo-find-target metadata member-lib-rs)))
                           "sub"))
            (should (equal (alist-get 'name (car (rmsbolt--cargo-find-target metadata member-mod-rs)))
                           "sub"))))
      (delete-directory tmp-root t))))

(ert-deftest cargo-handle-rust-compile-cmd-gating-test ()
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/nonexistent/src/lib.rs")
    (setq-local rmsbolt-command "rustc-custom")
    (setq-local rmsbolt-default-directory nil)
    (setq-local rmsbolt--default-variables '(rmsbolt-default-directory))
    (should-not (rmsbolt--handle-rust-compile-cmd (current-buffer)))
    (should (equal rmsbolt-command "rustc-custom"))
    (setq-local rmsbolt-command nil)
    (setq-local rmsbolt-default-directory "/tmp/custom-dir/")
    (setq-local rmsbolt--default-variables '(rmsbolt-command))
    (should-not (rmsbolt--handle-rust-compile-cmd (current-buffer)))
    (should (equal rmsbolt-default-directory "/tmp/custom-dir/"))))

(ert-deftest cargo-parse-compile-cmd-end-to-end-test ()
  (skip-unless (executable-find "cargo"))
  (let* ((tmp-root (make-temp-file "rmsbolt-cargo-e2e-" t))
         (src-dir (expand-file-name "src" tmp-root))
         (manifest (expand-file-name "Cargo.toml" tmp-root))
         (lib-rs (expand-file-name "lib.rs" src-dir)))
    (unwind-protect
        (progn
          (make-directory src-dir t)
          (with-temp-file manifest
            (insert "[package]\nname = \"e2e_demo\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"))
          (with-temp-file lib-rs
            (insert "pub fn add(a: i32, b: i32) -> i32 { a + b }\n"))
          (let ((res1 (rmsbolt--parse-cargo-compile-cmd tmp-root lib-rs))
                (res2 (rmsbolt--parse-cargo-compile-cmd tmp-root lib-rs)))
            (should res1)
            (should (equal res1 res2))
            (should (equal (car res1) (file-name-as-directory (file-truename tmp-root))))
            (should (member "e2e_demo" (rmsbolt-split--tokenize (cadr res1))))
            (should (member "src/lib.rs" (rmsbolt-split--tokenize (cadr res1))))))
      (delete-directory tmp-root t))))


;;;; C/C++ compile_commands.json and compile_flags.txt tests

(ert-deftest c-compile-cmd-flags-and-commands-test ()
  (let* ((tmp-root (make-temp-file "rmsbolt-c-test-" t))
         (src-dir (expand-file-name "src" tmp-root))
         (build-dir (expand-file-name "build" tmp-root))
         (ccj-file (expand-file-name "compile_commands.json" tmp-root))
         (cft-file (expand-file-name "compile_flags.txt" tmp-root))
         (file-a (expand-file-name "a.c" src-dir))
         (file-b (expand-file-name "b.c" src-dir)))
    (unwind-protect
        (progn
          (make-directory src-dir t)
          (make-directory build-dir t)
          (with-temp-file file-a (insert "int a(void) { return 1; }\n"))
          (with-temp-file file-b (insert "int b(void) { return 2; }\n"))
          (with-temp-file cft-file
            (insert "  -I\n  include/  \n\n-O2\n-c\n-flto=thin\n-o\nignored.o\n"))
          (with-temp-buffer
            (setq-local buffer-file-name file-b)
            (setq-local rmsbolt-command "gcc")
            (setq-local rmsbolt-default-directory nil)
            (setq-local rmsbolt--default-variables
                        '(rmsbolt-default-directory rmsbolt-command))
            (should (rmsbolt--handle-c-compile-cmd (current-buffer)))
            (should (equal rmsbolt-default-directory
                           (file-name-as-directory tmp-root)))
            (should (equal rmsbolt-command
                           (format "gcc -I include/ -O2 %s" file-b))))
          (with-temp-file ccj-file
            (insert (format "[{\"directory\": %S, \"command\": %S, \"file\": %S}]"
                            build-dir
                            (format "clang -Wall -O3 -c -o a.o -flto %s" file-a)
                            file-a)))
          (with-temp-buffer
            (setq-local buffer-file-name file-a)
            (setq-local rmsbolt-command "gcc")
            (setq-local rmsbolt-default-directory nil)
            (setq-local rmsbolt--default-variables
                        '(rmsbolt-default-directory rmsbolt-command))
            (should (rmsbolt--handle-c-compile-cmd (current-buffer)))
            (should (equal rmsbolt-default-directory
                           (file-name-as-directory build-dir)))
            (should (equal rmsbolt-command
                           (format "clang -Wall -O3 %s" file-a))))
          (with-temp-buffer
            (setq-local buffer-file-name file-b)
            (setq-local rmsbolt-command "gcc")
            (setq-local rmsbolt-default-directory nil)
            (setq-local rmsbolt--default-variables
                        '(rmsbolt-default-directory rmsbolt-command))
            (should (rmsbolt--handle-c-compile-cmd (current-buffer)))
            (should (equal rmsbolt-default-directory
                           (file-name-as-directory tmp-root)))
            (should (equal rmsbolt-command
                           (format "gcc -I include/ -O2 %s" file-b)))))
      (delete-directory tmp-root t))))

(ert-deftest c-handle-compile-cmd-gating-test ()
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/nonexistent/src/main.c")
    (setq-local rmsbolt-command "gcc-custom")
    (setq-local rmsbolt-default-directory nil)
    (setq-local rmsbolt--default-variables '(rmsbolt-default-directory))
    (should-not (rmsbolt--handle-c-compile-cmd (current-buffer)))
    (should (equal rmsbolt-command "gcc-custom"))
    (setq-local rmsbolt-command nil)
    (setq-local rmsbolt-default-directory "/tmp/custom-dir/")
    (setq-local rmsbolt--default-variables '(rmsbolt-command))
    (should-not (rmsbolt--handle-c-compile-cmd (current-buffer)))
    (should (equal rmsbolt-default-directory "/tmp/custom-dir/"))))

;;; rmsbolt-test.el ends here
(provide 'rmsbolt-test)
