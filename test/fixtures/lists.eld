(:name "lists"
       :body "Bullet one\nNested bullet\nNumber one\nNested number\n"
       :list-defs
       ((:id "list.synthetic-bullets" :glyph :bullet)
        (:id "list.synthetic-numbers" :glyph :number))
       :list-bindings
       ((:line 1 :id "list.synthetic-bullets" :nest 0)
        (:line 2 :id "list.synthetic-bullets" :nest 1)
        (:line 3 :id "list.synthetic-numbers" :nest 0)
        (:line 4 :id "list.synthetic-numbers" :nest 1)))
