(:name "lists"
       :body "Bullet one\nNested number one\nDeep bullet\nNested number two\nBullet two\nNumber one\nNested bullet\nAfter list\n"
       :list-defs
       ((:id "list.synthetic-bullets" :glyph :bullet)
        (:id "list.synthetic-numbers" :glyph :number))
       :list-bindings
       ((:line 1 :id "list.synthetic-bullets" :nest 0)
        (:line 2 :id "list.synthetic-numbers" :nest 1)
        (:line 3 :id "list.synthetic-bullets" :nest 2)
        (:line 4 :id "list.synthetic-numbers" :nest 1)
        (:line 5 :id "list.synthetic-bullets" :nest 0)
        (:line 6 :id "list.synthetic-numbers" :nest 0)
        (:line 7 :id "list.synthetic-bullets" :nest 1)))
