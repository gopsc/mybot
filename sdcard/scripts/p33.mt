@Action
base.value;
   1;
@

@SQL
INSERT INTO P5Check (name, value) VALUES ('hot', '42');
DELETE FROM P5Check WHERE name='missing';
@

@Action
base.value;
   2;
@
