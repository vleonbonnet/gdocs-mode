(:name "styles"
       :body "Bold italic underline strike code verbatim\nNested style text\n"
       :text-ranges
       ((:text "Bold" :styles (:bold))
        (:text "italic" :styles (:italic))
        (:text "underline" :styles (:underline))
        (:text "strike" :styles (:strike))
        (:text "code" :styles (:code))
        (:text "verbatim" :styles (:verbatim))
        (:text "Nested style" :styles (:bold))
        (:text "style text" :styles (:italic)))
       :paragraph-styles
       ((:line 1 :kind :heading :level 2)
        (:line 2 :kind :heading :level 3))
       :repeated-blank-model
       ((:kind :para :runs ((:text "Before")))
        (:kind :blank :runs nil)
        (:kind :blank :runs nil)
        (:kind :heading :level 2 :runs ((:text "Heading")))
        (:kind :blank :runs nil)
        (:kind :blank :runs nil)
        (:kind :para :runs ((:text "After")))))
