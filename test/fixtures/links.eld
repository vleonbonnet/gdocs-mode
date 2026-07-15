(:name "links"
       :org-text "See [[https://example.test/guide][Example guide]], then [[mailto:reader@example.test][email]].\n"
       :plain-text "See Example guide, then email.\n"
       :runs
       ((:text "See ")
        (:text "Example guide" :link "https://example.test/guide")
        (:text ", then ")
        (:text "email" :link "mailto:reader@example.test")
        (:text ".")))
