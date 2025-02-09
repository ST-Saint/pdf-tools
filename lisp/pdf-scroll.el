;;; pdf-scroll.el --- PDF scroll. -*- lexical-binding:t -*-

;; Copyright (C) 2022  Daniel Nicolai

;; Author: Daniel Nicolai <dalanicolai@gmail.com>
;; Keywords: files, doc-view, pdf

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; TODO fix history mode (push to stack)

;;  Functions related to displaying PDF documents as a scroll.


;;;; Code:
(require 'cl-lib)
(require 'image-mode)
(require 'pdf-macs)

(defcustom pdf-scroll-step-size 50
  "Scroll step size in pixels."
  :group 'pdf-scroll
  :type 'integer)

(defcustom pdf-scroll-page-separation-height 5
  "Page separation height."
  :group 'pdf-scroll
  :type 'integer)

(defcustom pdf-scroll-page-separation-color "dim gray"
  "Page color of space between the pages."
  :group 'pdf-scroll
  :type 'color)

(defmacro pdf-scroll-page-overlays (&optional window)
  `(image-mode-window-get 'page-overlays ,window))
(defmacro pdf-scroll-separation-overlays (&optional window)
  `(image-mode-window-get 'separation-overlays ,window))
(defmacro pdf-scroll-image-sizes (&optional window)
  `(image-mode-window-get 'image-sizes ,window))
(defmacro pdf-scroll-image-positions (&optional window)
  `(image-mode-window-get 'image-positions ,window))
(defmacro pdf-scroll-relative-vscroll (&optional window)
  `(image-mode-window-get 'relative-vscroll ,window))
(defmacro pdf-scroll-currently-displayed-pages (&optional window)
  `(image-mode-window-get 'displayed-pages ,window))

;;; Scroll
(defun pdf-scroll-create-image-positions (image-sizes)
  (let* ((sum 0)
         (positions (list 0)))
    (dolist (s image-sizes)
      ;; TODO report Spacemacs/Doom bug, height is not 'acknowledged' in split
      ;; buffer
      (setq sum (+ sum (cdr s) pdf-scroll-page-separation-height))
      ;; remove separation height after last page
      (pop image-sizes)
      (push (if image-sizes
                sum
              (- sum pdf-scroll-page-separation-height))
            positions))
    (nreverse positions)))

(defun pdf-scroll-create-overlays-lists (number-of-pages winprops)
  "Create NUMBER-OF-PAGES overlays for page images and page separators.
If car of WINPROPS is a window object, the overlays are made to
apply to that window only (by adding the 'window
overlay-property)."
  (goto-char (point-max))
  (let ((win (car winprops)))
    ;; We start with adding the first overlay after which we add
    ;; `(1- number-of-pages)' pairs of separation and page overlays
    (insert " ")
    (let ((page-ols (list (make-overlay (1- (point)) (point))))
          separation-ols)
      (overlay-put (car page-ols) 'window win)
      (dotimes (_ (1- number-of-pages))
        (insert "\n ")
        (let ((po (make-overlay (1- (point)) (point))))
          (overlay-put po 'window win)
          (push po separation-ols))
        (insert "\n ")
        (let ((po (make-overlay (1- (point)) (point))))
          (overlay-put po 'window win)
          (push po page-ols)))
      (image-mode-window-put 'page-overlays (nreverse page-ols) winprops)
      (image-mode-window-put 'separation-overlays (nreverse separation-ols) winprops))))

(defun pdf-scroll-page-placeholder (page win &optional color)
  (let ((idx (1- page)))
    (overlay-put (nth idx (pdf-scroll-page-overlays win))
                 'display `(space . (:width (,(car (nth idx (pdf-scroll-image-sizes))))
                                     :height (,(cdr (nth idx (pdf-scroll-image-sizes)))))))
    (overlay-put (nth (1- page) (pdf-scroll-page-overlays win))
                 ;; 'face `(background-color . ,(pcase page
                 ;;                               (1 "red")
                 ;;                               (2 "blue")
                 ;;                               (_ "gray"))))
                 'face `(background-color . ,(or color "gray")))
    ))

(defun pdf-scroll-separation-placeholder (after-page win &optional color)
  (let ((idx (1- after-page)))
    (overlay-put (nth idx (pdf-scroll-separation-overlays win))
                 'display `(space . (:width (,(car (nth idx (pdf-scroll-image-sizes))))
                                     :height (,pdf-scroll-page-separation-height))))
    (when color
      (overlay-put (nth idx (pdf-scroll-separation-overlays win))
                   'face `(background-color . ,color)))))

(defun pdf-scroll-create-placeholders (number-of-pages winprops)
  (let ((win (car winprops)))
    (pdf-scroll-page-placeholder 1 winprops)
    (dotimes (ol (1- number-of-pages))
      (let ((ol (1+ ol)))
        (pdf-scroll-separation-placeholder ol win pdf-scroll-page-separation-color)
        (pdf-scroll-page-placeholder (1+ ol) win)
        (setq ol (1+ ol))))))

(defun pdf-scroll-vscroll-to-relative (vscroll)
  (let* ((page (or (pdf-view-current-page) 1))
         (page-fraction (/ (float (max 0
                                       (- vscroll
                                          (nth (1- page) (pdf-scroll-image-positions)))))
                           (cdr (nth (1- page) (pdf-scroll-image-sizes))))))
    (cons page page-fraction)))

(defun pdf-scroll-relative-to-vscroll (window)
  (let* ((rel-pos (pdf-scroll-relative-vscroll window))
         (page (or (car rel-pos) 1)))
    (round (+
            (or (nth (1- page) (pdf-scroll-image-positions)) 0)
            (* (or (cdr rel-pos) 0)
               (cdr (nth (1- page) (pdf-scroll-image-sizes))))))))

(defun pdf-scroll-page-triplet (page)
  ;; first handle the cases when the doc has only one or two pages
  (pcase (pdf-cache-number-of-pages)
    (1 '(1))
    (2 '(1 2))
    (_ (pcase page
         (1 '(1 2))
         ((pred (= (pdf-cache-number-of-pages))) (list page (- page 1)))
         (p (list (- p 1) p (+ p 1)))))))

(defun pdf-scroll-set-vscroll (vscroll)
  (setf (image-mode-window-get 'relative-vscroll)
        (pdf-scroll-vscroll-to-relative vscroll))
  (set-window-vscroll (selected-window) vscroll t))

(defun pdf-scroll-scroll-forward ()
  (interactive)
  (let* ((page-end (nth (pdf-view-current-page) (pdf-scroll-image-positions)))
         (vscroll (window-vscroll nil t))
         (new-vscroll (image-set-window-vscroll (+ vscroll pdf-scroll-step-size))))
    (pdf-scroll-set-vscroll new-vscroll)
    (when (> new-vscroll page-end)
      (let* ((new-page (alist-get 'page (cl-incf (pdf-view-current-page))))
             (next-page (1+ new-page)))
        ;; (when (> new-page 2)
        ;;   (book-remove-page-image (- new-page 2))
        (pdf-scroll-display-image next-page
                                  (pdf-view-create-page next-page))
        (push next-page (pdf-scroll-currently-displayed-pages))))))

(defun pdf-scroll-scroll-backward ()
  (interactive)
  (let* ((page-beg (nth (1- (pdf-view-current-page)) (pdf-scroll-image-positions)))
         (vscroll (window-vscroll nil t))
         (new-vscroll (image-set-window-vscroll (- vscroll pdf-scroll-step-size))))
    (pdf-scroll-set-vscroll new-vscroll)
    (when (< new-vscroll page-beg)
      (let* ((new-page (alist-get 'page (cl-decf (pdf-view-current-page))))
             (previous-page (1- new-page)))
        ;; (when (> new-page 2)
        ;;   (book-remove-page-image (- new-page 2))
        (pdf-scroll-display-image previous-page
                                  (pdf-view-create-page previous-page))
        (push previous-page (pdf-scroll-currently-displayed-pages))))))

(defun pdf-scroll-reapply-winprops ()
  ;; When set-window-buffer, set hscroll and vscroll to what they were
  ;; last time the image was displayed in this window.
  (pdf-debug-debug "reapply winprops")
  (when (listp image-mode-winprops-alist)
    ;; Beware: this call to image-mode-winprops can't be optimized away,
    ;; because it not only gets the winprops data but sets it up if needed
    ;; (e.g. it's used by doc-view to display the image in a new window).
    (let* ((winprops (image-mode-winprops nil t))
           (hscroll (image-mode-window-get 'hscroll winprops))
           ;; (vscroll (print (nth (1- (or (pdf-view-current-page) 1)) (pdf-scroll-image-positions)))))
           (vscroll (pdf-scroll-relative-to-vscroll (car winprops))))
      (when (image-get-display-property) ;Only do it if we display an image!
        (goto-char (point-min))
	      (if hscroll (set-window-hscroll (selected-window) hscroll))

        ;; TODO report Emacs bug, printing the value eliminates the vscroll issues
        ;; (if vscroll (print (set-window-vscroll (selected-window) vscroll t)))))))

        (if vscroll (set-window-vscroll (selected-window) vscroll t))
        (pdf-debug-debug "reapply scroll" (window-vscroll nil t) (car winprops) (backtrace-frame 5))))))

(defun pdf-scroll-setup-winprops ()
  ;; Record current scroll settings.
  (unless (listp image-mode-winprops-alist)
    (setq image-mode-winprops-alist nil))
  (add-hook 'window-configuration-change-hook
	    #'pdf-scroll-reapply-winprops nil t))

(defun pdf-scroll-display-image (page image &optional window inhibit-slice-p)
  ;; TODO: write documentation!
  (let ((ol (nth (1- page) (pdf-scroll-page-overlays window))))
    (when (window-live-p (overlay-get ol 'window))
      (let* ((size (image-size image t))
             (slice (if (not inhibit-slice-p)
                        (pdf-view-current-slice window)))
             (displayed-width (floor
                               (if slice
                                   (* (nth 2 slice)
                                      (car (image-size image)))
                                 (car (image-size image))))))
        (setf (pdf-view-current-image window) image)
        ;; In case the window is wider than the image, center the image
        ;; horizontally.
        (overlay-put ol 'before-string
                     (when (> (window-width window)
                              displayed-width)
                       (propertize " " 'display
                                   `(space :align-to
                                           ,(/ (- (window-width window)
                                                  displayed-width) 2)))))
        (overlay-put ol 'display
                     (if slice
                         (list (cons 'slice
                                     (pdf-util-scale slice size 'round))
                               image)
                       image))))))

(defun pdf-scroll-new-window-function (winprops)
  ;; check if overlays have already been added
  ;; This works reliably for a maximum of two buffers
  (if-let ((page-overlays (image-mode-window-get 'page-overlays))
           (separation-overlays (image-mode-window-get 'separation-overlays)))
      (let ((pols (mapcar (lambda (o)
                                  (let ((ol (copy-overlay o)))
                                    (overlay-put ol 'window (car winprops))
                                    ol))
                                page-overlays))
            (sols (mapcar (lambda (o)
                                  (let ((ol (copy-overlay o)))
                                    (overlay-put ol 'window (car winprops))
                                    ol))
                                separation-overlays)))
            (image-mode-window-put 'page-overlays pols winprops)
            (image-mode-window-put 'separation-overlays sols winprops))
    ;; (let ((ol (make-overlay (point-min) (point-max))))
    ;;   (overlay-put ol 'invisible t))
    (let ((pages (pdf-cache-number-of-pages))
          (inhibit-read-only t))
      (unless (= (or (char-after 1) 0) 32)
        (erase-buffer))
      (unless (eq (car winprops) t)
        (pdf-scroll-create-overlays-lists pages winprops)
        ;; (setf (pdf-scroll-image-sizes) (let (s)
        ;;                                  (dotimes (i (pdf-info-number-of-pages) (nreverse s))
        ;;                                    (push (pdf-view-desired-image-size (1+ i)) s))))
        ;; (setf (pdf-scroll-image-positions) (pdf-scroll-create-image-positions (pdf-scroll-image-sizes)))
        ;; (pdf-scroll-create-placeholders pages winprops)
        (when (and (windowp (car winprops))
                   (null (image-mode-window-get 'image winprops)))
          ;; We're not displaying an image yet, so let's do so.  This
          ;; happens when the buffer is displayed for the first time.
          (with-selected-window (car winprops)
            ;; (pdf-scroll-set-vscroll 0)
            (pdf-view-goto-page
             (or (image-mode-window-get 'page t) 1))
            (goto-char (point-min))))))))


(define-minor-mode pdf-scroll-mode "Read books in Emacs"
  :lighter "Book"
  :keymap
  '(("j" . pdf-scroll-scroll-forward)))

(evil-define-minor-mode-key 'normal 'pdf-scroll-mode
  "j" #'pdf-scroll-scroll-forward)

;; This is a demo function 
(defun pdf-scroll-demo (&optional number-of-pages page-size)
  (interactive)
  (pop-to-buffer (get-buffer-create "*pdf-scroll-demo*"))
  (erase-buffer)
  (image-mode-setup-winprops)
  (let ((winprops (image-mode-winprops))
        (pages (or number-of-pages 426)))
    (setf (pdf-scroll-image-sizes) (make-list pages (or page-size '(783 . 1014))))
    (pdf-scroll-create-overlays-lists pages winprops)
    (pdf-scroll-create-placeholders pages winprops)
    (pdf-scroll-mode)))

(provide 'pdf-scroll)

;;; pdf-scroll.el ends here
