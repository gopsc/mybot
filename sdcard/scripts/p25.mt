@Action
cold.value;
   1;
@

@SQL
INSERT INTO P5Check (name, value) VALUES ('hot', '99');
@

@Action
hot.value;
   2;
@

@SQL
DELETE FROM P5Check WHERE name='hot';
@

@Action
cold.value;
   3;
@
