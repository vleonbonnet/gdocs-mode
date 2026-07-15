(:name "unsupported-entities"
       :body "Before\n\uFFFC\nAfter\n"
       :unknown-ops
       (((ty . "ae") (et . "image") (id . "image.synthetic-placeholder"))
        ((ty . "as") (st . "unknown_entity") (si . 1) (ei . 1)
         (sm . ((entity . "image.synthetic-placeholder")))))
       :expected-org "Before\n\uFFFC\nAfter\n")
