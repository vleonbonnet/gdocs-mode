(:name "multiple-images-not-entity-order"
 :body "One\n*\nTwo\n*\nThree\n"
 :ops
 (((ty . "is") (s . "One\n*\nTwo\n*\nThree\n"))
  ;; Entity definitions and attachments are deliberately in reverse
  ;; document order. `te.spi' is authoritative.
  ((ty . "ae") (et . "inline")
   (id . "kix.synthetic-image-two")
   (law . t)
   (epm . ((ee_eo . ((i_cid . "s-blob-v1-IMAGE-synthetic-two")
                     (i_wth . 320.0)
                     (i_ht . 240.0))))))
  ((ty . "ae") (et . "inline")
   (id . "kix.synthetic-image-one")
   (law . t)
   (epm . ((ee_eo . ((i_cid . "s-blob-v1-IMAGE-synthetic-one")
                     (i_wth . 160.0)
                     (i_ht . 120.0))))))
  ((ty . "te") (id . "kix.synthetic-image-two") (spi . 11))
  ((ty . "te") (id . "kix.synthetic-image-one") (spi . 5)))
 )
)
