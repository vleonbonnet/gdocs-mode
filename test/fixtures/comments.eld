(:name "comments"
       :anchor "kix.synthetic-final-letter"
       :ot-body "A word\n"
       :org-body "A *word*\n"
       :anchor-range (:start 6 :end 6)
       :threads
       ((:id "thread.synthetic.one"
             :anchor "kix.synthetic-final-letter"
             :text "Root   comment"
             :replies ("A reply"))
        (:id "thread.synthetic.two"
             :anchor "kix.synthetic-other"
             :text "Second comment"
             :replies nil))
       :ambiguous-org-body "same text\nsame text\n"
       :ambiguous-ot-body "same text\nsame text\n"
       :ambiguous-range (:start 9 :end 10))
