;;; seriesTracker.el --- Series tracker -*- lexical-binding: t; -*-
;; Package-Requires: ((dash "2.12.1"))
;;; Commentary:
;;; Code:

;;; Requirements

(require 'url)                                                                  ; used to fetch api data
(require 'json)                                                                 ; used to parse api response
(require 'dash)                                                                 ; threading etc.
(require 'transient)                                                            ; transient for command dispatch

;;; Helpers

;;;; alist-select

(defun st--utils-alist-select (fields alist)
  "Keep only FIELDS in ALIST by constructing a new alist containing only these elements.

alist-select '(a c) '((a .1) (b , \"b\") (c . c)
returns '((a . 1) (c . c))"

  (->> fields
       reverse
       (--reduce-from (acons it (alist-get it alist) acc)
                     nil)))

;;;; array-select

(defun st--utils-array-select (fields array)
  "Keep only FIELDS in every alist in the ARRAY.

array-select '(a c) '(((a . 1) (b . 2) (c . c)) ((a . 3) (b . 5) (c . d)))
returns '(((a . 1) (c . c)) ((a . 3) (c . d)))"

  (--map (st--utils-alist-select fields it) array))

;;;; array-pull

(defun st--utils-array-pull (field array)
  "Keep only FIELD in every alist in the ARRAY and flatten.

array-pull 'a '(((a . 1) (b . 2)) ((a . 3) (b . 4)))
returns '(1 3)"

  (--map (alist-get field it) array))

;;;; getJSON

(defun st--getJSON (url-buffer)
  "Parse the JSON in the URL-BUFFER returned by url."

  (with-current-buffer url-buffer
    (goto-char (point-max))
    (move-beginning-of-line 1)
    (json-read-object)))

;;; episodate.com API

;;;; search

(defun st--search (name)
  "Search episodate.com db for NAME."

  (->> (let ((url-request-method "GET"))
         (url-retrieve-synchronously (concat "https://www.episodate.com/api/search?q=" name)))
       st--getJSON
       (st--utils-alist-select '(tv_shows))
       car
       cdr
       (st--utils-array-select '(id name start_date status network permalink))))

;;;; series

(defun st--episodes (series)
         (setf (alist-get 'episodes series)
               (mapcar (lambda (x) x) (alist-get 'episodes series)))
         series)

(defun st--series (id)
  "Get series ID info."

  (->> (let ((url-request-method "GET"))
         (url-retrieve-synchronously (concat "https://www.episodate.com/api/show-details?q=" (int-to-string id))))
       st--getJSON
       car
       (st--utils-alist-select '(id name start_date status episodes))
       st--episodes))

;;; Internal API

;;;; Data model

(defvar st--data
  nil
  "Internal data containing followed series and episode.

Of the form :

'(((id . seriesId) (props . value) (…) (episodes ((id . episodeId) (watched . t) (props.value) (…))
                                                 ((id . episodeId) (watched . nil) (props.value) (…)))))
  ((id . seriesId) (…) (episodes ((id . episodeId) (…))
                                 ((id . episodeId) (…)))))

series props are name and start_date.
episodes props are season, episode, name, and air_date.")

;;;; Add series

(defun st-add (id)
  "Add series with ID to st--data.
Adding an already existing series resets it."

  (setq st--data
        (--> st--data
            (--remove (= id (alist-get 'id it)) it)
            (-snoc it (--> (st--series id))))))

;;;; Remove series

(defun st--remove (id)
  "Remove series with ID from st--data."

  (setq st--data
        (--remove (= id (alist-get 'id it)) st--data)))

;;;; Watch episode

(defun st--watch (id seasonN episodeN)
  "Watch EPISODEN of SEASONN in series ID."

  (->> st--data
       (-map-when (lambda (series) (= id (alist-get 'id series)))
                  (lambda (series)
                    (setf (alist-get 'episodes series)
                          (-map-when (lambda (episode) (and (= seasonN (alist-get 'season episode))
                                                       (= episodeN (alist-get 'episode episode))))
                                     (lambda (episode)
                                       (setf (alist-get 'watched episode) t)
                                       episode)
                                     (alist-get 'episodes series)))))))

(defun st--unwatch (id seasonN episodeN)
  "Watch EPISODEN of SEASONN in series ID."

  (->> st--data
       (-map-when (lambda (series) (= id (alist-get 'id series)))
                  (lambda (series)
                    (setf (alist-get 'episodes series)
                          (-map-when (lambda (episode) (and (= seasonN (alist-get 'season episode))
                                                       (= episodeN (alist-get 'episode episode))))
                                     (lambda (episode)
                                       (setf (alist-get 'watched episode) nil)
                                       episode)
                                     (alist-get 'episodes series)))))))

;;;; Watch all episodes

(defun st--watch-all (id)
  "Watch all episodes in series ID."

  (->> st--data
       (-map-when (lambda (series) (= id (alist-get 'id series)))
                  (lambda (series)
                    (setf (alist-get 'episodes series)
                          (-map (lambda (episode)
                                  (setf (alist-get 'watched episode) t)
                                  episode)
                                (alist-get 'episodes series)))))))

;;;; Watch all episodes up to episode

(defun st--watch-up (id seasonN episodeN)
  "Watch all episodes up to EPISODEN of SEASON in series ID."

  (->> st--data
       (-map-when (lambda (series) (= id (alist-get 'id series)))
                  (lambda (series)
                    (setf (alist-get 'episodes series)
                          (-map-when (lambda (episode)
                                       (or (< (alist-get 'season episode) seasonN)
                                           (and (= (alist-get 'season episode) seasonN)
                                                (<= (alist-get 'episode episode) episodeN))))
                                     (lambda (episode)
                                       (setf (alist-get 'watched episode) t)
                                       episode)
                                     (alist-get 'episodes series)))))))

;;;; Query updates

(defun st--update ()
  "Update all non-finished shows."

  (->> st--data
       (-map-when (lambda (series) (string-equal "Running" (alist-get 'status series)))
                  (lambda (series) (st--update-series series)))))

(defun st--update-series (series)
  "Update the SERIES."

  (let* ((new (st--series (alist-get 'id series)))
         (newEp (alist-get 'episodes new))
         (status (alist-get 'status new))
         (watched (-find-indices (lambda (episode) (alist-get 'watched episode)) (alist-get 'episodes series)))
         (newEps (--map-indexed (if (-contains? watched it-index)
                                    (progn
                                      (setf (alist-get 'watched it) t)
                                      it)
                                  it) newEp)))

    (when (string-equal status "Ended") (setf (alist-get 'status series) "Ended"))
    (setf (alist-get 'episodes series) newEps)

    series))

;;;; Load/save data

(defvar st--file
  "~/.emacs.d/st.el"
  "Location of the save file")

(defun st--save ()
  (with-temp-file st--file
    (let ((print-level nil)
          (print-length nil))
      (prin1 st--data (current-buffer)))))

(defun st--load ()
  (with-temp-buffer
    (insert-file-contents st--file)
    (cl-assert (eq (point) (point-min)))
    (setq st--data (read (current-buffer)))))

;;; Interface

;;;; Faces

(defface st-series
  '((t (:height 1.9 :weight bold :foreground "DeepSkyBlue")))
  "Face for series names")

(defface st-finished-series
  '((t (:height 2.0 :weight bold :foreground "DimGrey")))
  "Face for finished series names")

(defface st-season
  '((t (:height 1.7 :weight bold :foreground "MediumPurple")))
  "Face for seasons")

(defface st-watched
  '((t (:foreground "DimGrey" :strike-through t)))
  "Face for watched episodes")

;;;; Draw buffer

(defun st--refresh ()
  "Refresh the st buffer."

  (let ((line (line-number-at-pos)))
    (st--draw-buffer)
    (goto-line line)))

(defun st--draw-buffer ()
  "Draw the buffer.
Erase first then redraw the whole buffer."

  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; (insert "0")
    ;; (put-text-property (point-min) (point) 'invisible t)
    ;; (put-text-property (point-min) (point) 'st-series 0)
    (-each st--data 'st--draw-series)
    (delete-char -1)))

(defun st--draw-series (series)
  "Print the series id and name."

  (let ((id (alist-get 'id series))
        (name (alist-get 'name series))
        (finished (string-equal "Ended" (alist-get 'status series)))
        (episodes (alist-get 'episodes series)))
    (let ((start (point)))
      (insert (concat name "\n"))
      (set-text-properties start (point)
                           `(st-series ,id
                             st-season nil
                             st-episode nil))
      (if finished
          (put-text-property start (point) 'face 'st-finished-series)
        (put-text-property start (point) 'face 'st-series))
      (when (-all? (lambda (episode) (alist-get 'watched episode))
                   (alist-get 'episodes series))
        (let ((overlay (make-overlay start (point))))
          (overlay-put overlay 'invisible 'st-watched)
          (overlay-put overlay 'priority -1))))
    (--each episodes (st--draw-episode series it))))

(defun st--draw-episode (series episode)
  "Print the episode id, S**E**, and name."

  (let ((id (alist-get 'id series))
        (season (alist-get 'season episode))
        (episode (alist-get 'episode episode))
        (name (alist-get 'name episode))
        (air_date (alist-get 'air_date episode))
        (watched (alist-get 'watched episode)))
    (when (= episode 1)
      (let ((start (point)))
        (insert (concat "Season " (int-to-string season) "\n"))
        (set-text-properties start (point)
                             `(face st-season
                                    st-series ,id
                                    st-season ,season
                                    st-episode nil))
        (when (-all? (lambda (episode) (alist-get 'watched episode))
                     (-filter (lambda (episode) (= season (alist-get 'season episode)))
                              (alist-get 'episodes series)))
          (let ((overlay (make-overlay start (point))))
            (overlay-put overlay 'invisible 'st-watched)
            (overlay-put overlay 'priority -1)))))
    (let ((start (point)))
      (insert air_date)
      (let ((end-date (point)))
        (insert (concat " " (format "%02d" episode) " - " name "\n"))
        (set-text-properties start (point)
                             `(face default
                                    st-series ,id
                                    st-season ,season
                                    st-episode ,episode))
        (if (<= (car (date-to-time air_date))
                (car (current-time)))
            (put-text-property start end-date 'face '(t ((:foreground "MediumSpringGreen"))))
          (put-text-property start end-date 'face '(t ((:foreground "firebrick"))))))
      (when watched
        (set-text-properties start (point)
                             `(face st-watched
                                    st-series ,id
                                    st-season ,season
                                    st-episode ,episode
                                    invisible st-watched))))))

;;;; Movements

(defun st-up ()
  "Move up in the hierarchy."

  (interactive)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (cond (episode (goto-char (previous-single-property-change (point) 'st-season)))
              (season (goto-char (previous-single-property-change (point) 'st-series)))))
    (message "Not in st buffer!")))

(defun st-prev ()
  "Move up in the hierarchy."

  (interactive)

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (goto-char (previous-single-property-change (point) 'st-season nil (point-min))))
    (message "Not in st buffer!"))
  (when (and (= 1 (point))
             (invisible-p 1))
    (st-next))
  (when (invisible-p (point)) (st-prev)))

(defun st-next ()
  "Move up in the hierarchy."

  (interactive)

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (goto-char (next-single-property-change (point) 'st-season nil (point-max))))
    (message "Not in st buffer!"))
  (when (invisible-p (point)) (st-next)))

(defun st--next-any ()
  "Move up in the hierarchy, including invisible headings."

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (goto-char (next-single-property-change (point) 'st-season nil (point-max))))
    (message "Not in st buffer!")))

(defun st-prev-same ()
  "Move up in the hierarchy."

  (interactive)

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (cond ((or episode season) (goto-char (previous-single-property-change (point) 'st-season nil (point-min))))
              (series (goto-char (previous-single-property-change (point) 'st-series nil (point-min))))))
    (message "Not in st buffer!"))
  (when (and (= 1 (point))
             (invisible-p 1))
    (st-next))
  (when (invisible-p (point)) (st-prev-same)))

(defun st-next-same ()
  "Move up in the hierarchy."

  (interactive)

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (progn (when (= 1 (point))
               (goto-char 2))
             (let ((series (get-text-property (point) 'st-series))
                   (season (get-text-property (point) 'st-season))
                   (episode (get-text-property (point) 'st-episode)))
               (cond ((or episode season) (goto-char (next-single-property-change (point) 'st-season nil (point-max))))
                     (series (goto-char (next-single-property-change (point) 'st-series nil (point-max)))))))
    (message "Not in st buffer!"))
  (when (invisible-p (point)) (st-next-same)))

;;;; Folding

(defun st-fold-at-point ()
  "Fold the section at point."

  (interactive)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (cond (episode (st-fold-episodes))
              (season (st-fold-season))
              (t (st-fold-series))))
    (message "Not in st buffer!")))

(defun st-fold-episodes ()
  "Fold the episodes at point."

  (let* ((season-start (previous-single-property-change (point) 'st-season))
         (fold-start (next-single-property-change season-start 'st-episode))
         (fold-end (next-single-property-change (point) 'st-season nil (point-max)))
         (overlay (make-overlay fold-start fold-end)))
    (overlay-put overlay 'invisible 'st-season)))

(defun st-fold-season ()
  "Fold the season at point."

  (let* ((fold-start (next-single-property-change (point) 'st-episode))
         (fold-end (next-single-property-change (point) 'st-season nil (point-max)))
         (overlay (make-overlay fold-start fold-end)))
    (overlay-put overlay 'invisible 'st-season)))

(defun st-fold-series ()
  "Fold the series at point."

  (let* ((fold-start (next-single-property-change (point) 'st-season))
         (fold-end (next-single-property-change (point) 'st-series nil (point-max)))
         (overlay (when (and fold-start fold-end) (make-overlay fold-start fold-end))))
    (when overlay (overlay-put overlay 'invisible 'st-series))))

(defun st-unfold-at-point ()
  "Unfold the section at point."

  (interactive)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (cond (season (st-unfold-season))
              (t (st-unfold-series))))
    (message "Not in st buffer!")))

(defun st-unfold-season ()
  "Fold the season at point."

  (let ((fold-start (next-single-property-change (point) 'st-episode))
        (fold-end (next-single-property-change (point) 'st-season)))
    (remove-overlays fold-start fold-end 'invisible 'st-season)))

(defun st-unfold-series ()
  "Fold the series at point."

  (let ((fold-start (next-single-property-change (point) 'st-season))
        (fold-end (next-single-property-change (point) 'st-series)))
    (remove-overlays fold-start fold-end 'invisible 'st-series)))

(defun st-switch-watched ()
  "Switch visibility for watched episodes."

  (interactive)

  (if (-contains? buffer-invisibility-spec 'st-watched)
      (remove-from-invisibility-spec 'st-watched)
    (add-to-invisibility-spec 'st-watched)))

;;;; Cycle folding

(defvar fold-cycle 'st-all-folded)

(defun st-cycle ()
  "Cycle folding."

  (interactive)

  (cond ((eq fold-cycle 'st-all-folded)
         (st-unfold-all-series)
         (setq fold-cycle 'st-series-folded))
        ((eq fold-cycle 'st-series-folded)
         (st-unfold-all)
         (setq fold-cycle 'st-all-unfolded))
        ((eq fold-cycle 'st-all-unfolded)
         (st-fold-all)
         (setq fold-cycle 'st-all-folded))))

(defun st-unfold-all ()
  "Unfold everything."

  (interactive)

  (remove-overlays (point-min) (point-max) 'invisible 'st-series)
  (remove-overlays (point-min) (point-max) 'invisible 'st-season))

(defun st-fold-all ()
  "Fold everything."

  (interactive)

  (save-excursion
    (st-unfold-all)
    (goto-char 1)
    (while (< (point)
              (point-max))
      (st-fold-at-point)
      (st--next-any))))

(defun st-unfold-all-series ()
  "Unfold all series."

  (interactive)

  (st-fold-all)
  (remove-overlays (point-min) (point-max) 'invisible 'st-series))

;;;; Transient

(transient-define-prefix st-dispatch ()
  "Command dispatch for st."

  ["Series"
   :if-derived st-mode
   [("a" "Search and add a series" st-search)
    ("d" "Delete a series" st-remove)
    ("ww" "Watch at point" st-watch)
    ("wu" "Watch up to point" st-watch-up)
    ("u" "Unwatch at point" st-unwatch)
    ("U" "Update and refresh the buffer" st-update)]]

  ["Display"
   :if-derived st-mode
   [("W" "Hide/show watched" st-switch-watched)
    ("S" "Sort series" st-dispatch-sort)]]

  ["Load/Save"
   :if-derived st-mode
   [("s" "Save database" st-save)
    ("l" "Load database" st-load)]]
  )

(transient-define-prefix st-dispatch-sort ()
  "Sort commands dispatch for st."

  ["Sort"
   :if-derived st-mode
   [("a" "Sort alphabetically" st-sort-alpha)
    ("z" "Reverse sort alphabetically" st-sort-alpha-rev)
    ("w" "Sort by date of last watched episode" st-sort-watched)
    ("t" "Sort by date of next episode to watch" st-sort-next)]])

;;;; Load/save data

(defun st-save ()
  (interactive)
  (st--save))

(defun st-load ()
  (interactive)
  (st--load))

;;;; Add series

(defun st-search ()

  (interactive)

  (let* ((searchterm (read-from-minibuffer "Search: "))
         (series-list (st--search searchterm))
         (names-list (st--utils-array-pull 'permalink series-list))
         (nametoadd (completing-read "Options: " names-list))
         (toadd (alist-get 'id (-find (lambda (series) (string-equal nametoadd (alist-get 'permalink series))) series-list))))
    (st-add toadd)
    (st--refresh)))

;;;; (un)Watch episodes

(defun st-watch ()
  "Watch at point."

  (interactive)

  (let ((inhibit-read-only t)
        (series (get-text-property (point) 'st-series))
        (season (get-text-property (point) 'st-season))
        (episode (get-text-property (point) 'st-episode)))
    (cond (episode (st--watch series season episode))
          (season (st-watch-season series season))
          (t (st-watch-series series))))
  (st--refresh)
  (forward-line))

(defun st-watch-season (id seasonN)
  "Watch all episode in a season."

  (->> st--data
       (-map-when (lambda (series) (= id (alist-get 'id series)))
                  (lambda (series)
                    (setf (alist-get 'episodes series)
                          (-map-when (lambda (episode) (= seasonN (alist-get 'season episode)))
                                     (lambda (episode)
                                       (setf (alist-get 'watched episode) t)
                                       episode)
                                     (alist-get 'episodes series)))))))

(defun st-watch-series (id)
  "Watch all episode in a series."

  (->> st--data
       (-map-when (lambda (series) (= id (alist-get 'id series)))
                  (lambda (series)
                    (setf (alist-get 'episodes series)
                          (-map (lambda (episode)
                                  (setf (alist-get 'watched episode) t)
                                  episode)
                                (alist-get 'episodes series)))))))

(defun st-unwatch ()
  "Watch at point."

  (interactive)

  (let ((inhibit-read-only t)
        (series (get-text-property (point) 'st-series))
        (season (get-text-property (point) 'st-season))
        (episode (get-text-property (point) 'st-episode)))
    (cond (episode (st--unwatch series season episode))
          (season (st-unwatch-season series season))
          (t (st-unwatch-series series))))
  (st--refresh)
  (forward-line))

(defun st-unwatch-season (id seasonN)
  "Watch all episode in a season."

  (->> st--data
       (-map-when (lambda (series) (= id (alist-get 'id series)))
                  (lambda (series)
                    (setf (alist-get 'episodes series)
                          (-map-when (lambda (episode) (= seasonN (alist-get 'season episode)))
                                     (lambda (episode)
                                       (setf (alist-get 'watched episode) nil)
                                       episode)
                                     (alist-get 'episodes series)))))))

(defun st-unwatch-series (id)
  "Watch all episode in a series."

  (->> st--data
       (-map-when (lambda (series) (= id (alist-get 'id series)))
                  (lambda (series)
                    (setf (alist-get 'episodes series)
                          (-map (lambda (episode)
                                  (setf (alist-get 'watched episode) nil)
                                  episode)
                                (alist-get 'episodes series)))))))

(defun st-watch-up ()
  "Watch up to episode at point."

  (interactive)

  (let ((inhibit-read-only t)
        (series (get-text-property (point) 'st-series))
        (season (get-text-property (point) 'st-season))
        (episode (get-text-property (point) 'st-episode)))
    (when episode (st--watch-up series season episode)))
  (st--refresh)
  (forward-line))


;;;; Remove series

(defun st-remove ()
  "Remove series at point."

  (interactive)
  (let ((inhibit-read-only t)
        (series (get-text-property (point) 'st-series))
        (season (get-text-property (point) 'st-season))
        (episode (get-text-property (point) 'st-episode)))
    (when (y-or-n-p "Are you sure you want to delete this series? ") (st--remove series))
    (st--refresh)))

;;;; Sort series

(defun st-sort-next ()
  "Sort series by date of next episode to watch."

  (interactive)

  (defun first-next-date (series)
    (let ((dates (->> series
                      (alist-get 'episodes)
                      (--filter (not (alist-get 'watched it))))))
      (if dates
          (->> dates
               (st--utils-array-pull 'air_date)
               (--map (car (date-to-time it)))
               -min)
        0)))

  (defun comp (a b)
    (< (first-next-date a)
       (first-next-date b)))

  (setq st--data (-sort 'comp st--data))

  (st--refresh))

(defun st-sort-watched ()
  "Sort series by date of last watched episode."

  (interactive)

  (defun max-air-date (series)
    (->> series
         (alist-get 'episodes)
         (--filter (alist-get 'watched it))
         (st--utils-array-pull 'air_date)
         (--map (car (date-to-time it)))
         -max))

  (defun comp (a b)
    (< (max-air-date a)
       (max-air-date b)))

  (setq st--data (-sort 'comp st--data))

  (st--refresh))

(defun st-sort-alpha-rev ()
  "Sort alphabetically."

  (interactive)

  (defun comp (a b)
    (string> (alist-get 'name a)
             (alist-get 'name b)))

  (setq st--data (-sort 'comp st--data))

  (st--refresh))

(defun st-sort-alpha ()
  "Sort alphabetically."

  (interactive)

  (defun comp (a b)
    (string< (alist-get 'name a)
             (alist-get 'name b)))

  (setq st--data (-sort 'comp st--data))

  (st--refresh))

;;;; Create mode

(defun st-update ()
  "Update the db and refresh the buffer."

  (interactive)
  (st--update)
  (st--refresh))

(defun st ()
  "Run ST"

  (interactive)
  (switch-to-buffer "st")
  (st-mode)
  (st-update))
  (cond ((eq fold-cycle 'st-all-folded)
         (st-fold-all))
        ((eq fold-cycle 'st-all-unfolded)
         (st-unfold-all))
        ((eq fold-cycle 'st-series-folded)
         (st-unfold-all-series))))

(define-derived-mode st-mode special-mode "st"
  "Series tracking with episodate.com."

  (setq-local buffer-invisibility-spec '(t st-series st-season))

  ;; keymap

  (local-set-key "d" 'previous-line)
  (local-set-key "s" 'next-line)

  (local-set-key "ð" 'st-prev)
  (local-set-key "ß" 'st-next)

  (local-set-key "Þ" 'st-up)
  (local-set-key "Ð" 'st-prev-same)
  (local-set-key "ẞ" 'st-next-same)

  (local-set-key "þ" 'st-fold-at-point)
  (local-set-key "®" 'st-unfold-at-point)

  (local-set-key "h" 'st-dispatch)
  (local-set-key "W" 'st-switch-watched)
  (local-set-key "U" 'st-update)
  (local-set-key "a" 'st-search)
  (local-set-key "w" 'st-watch)
  (local-set-key "u" 'st-unwatch)
  (local-set-key [tab] 'st-cycle))

;;; Postamble

(provide 'seriesTracker)

;;; seriesTracker.el ends here
