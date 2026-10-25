;;; rmsbolt-split.el --- An Elisp library to edit command lines -*- lexical-binding: t; -*-

;; Copyright (C) 2018 Jay Kamat
;; Author: Jay Kamat <jaygkamat@gmail.com>
;; Version: 0.1.0
;; Keywords: compilation, tools
;; URL: http://gitlab.com/jgkamat/rmsbolt
;; Package-Requires: ((emacs "25.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a small library for editing command line parameters, passed as
;; a string. For example, given:
;; gcc -o one two -c -S
;; This library tries to make it possible to remove '-o one' '-c' and '-S'.
;;
;; This is not easy to do without bugs, and therefore this is mostly incomplete.
;; Hopefully we will never see more complicated formats (such as quoted arguments)
;; in generated commands, or we will need to write a parser.

;;; Requires:

(require 'cl-lib)

;;; Variables

(defvar rmsbolt-split--regexp (rx (1+ blank)))

(defvar rmsbolt-split--token-regexp
  (rx (1+ (or (seq "'" (0+ (not (any "'"))) "'")
              (seq "\"" (0+ (or (seq "\\" anything)
                                (not (any "\"\\"))))
                   "\"")
              (seq "\\" anything)
              (not (any blank "\n" "'" "\"" "\\"))
              "'" "\""))))

;;; Code:

(defun rmsbolt-split--tokenize (cmd)
  "Split CMD into shell tokens and keep quoted strings intact."
  (let ((pos 0)
        tokens)
    (save-match-data
      (while (string-match rmsbolt-split--token-regexp cmd pos)
        (push (match-string 0 cmd) tokens)
        (setq pos (match-end 0))))
    (nreverse tokens)))

(defun rmsbolt-split-rm-single (cmd flag &optional comparator)
  "Remove a single FLAG from CMD.

Optionally compares using COMPARATOR."
  (let ((cmd (rmsbolt-split--tokenize cmd))
        (comparator (or comparator #'string=)))
    (mapconcat
     #'identity
     (cl-remove-if (apply-partially comparator flag) cmd)
     " ")))

(defun rmsbolt-split-rm-double (cmd flag &optional arg comparator)
  "Remove a single FLAG and its argument from CMD.

If ARG is non-nil, remove FLAG and its argument only when the argument
matches ARG with COMPARATOR."
  (let ((cmd (rmsbolt-split--tokenize cmd))
        (comparator (or comparator #'string=))
        res)
    (while cmd
      (let ((f (pop cmd)))
        (if (and (string= f flag)
                 (or (not arg)
                     (and cmd (funcall comparator arg (car cmd)))))
            (pop cmd)
          (push f res))))
    (mapconcat #'identity (nreverse res) " ")))
(provide 'rmsbolt-split)

;;; rmsbolt-split.el ends here
